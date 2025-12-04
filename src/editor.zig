const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Piece = @import("buffer.zig").Piece;
const PieceIterator = @import("buffer.zig").PieceIterator;
const View = @import("view.zig").View;
const Terminal = @import("terminal.zig").Terminal;
const input = @import("input.zig");

const UndoEntry = struct {
    pieces: []const Piece,
};

pub const Editor = struct {
    buffer: Buffer,
    view: View,
    terminal: Terminal,
    allocator: std.mem.Allocator,
    running: bool,
    filename: ?[]const u8,
    modified: bool,
    undo_stack: std.ArrayList(UndoEntry),
    redo_stack: std.ArrayList(UndoEntry),

    pub fn init(allocator: std.mem.Allocator) !Editor {
        var buffer = try Buffer.init(allocator);
        const view = View.init(&buffer);
        const terminal = try Terminal.init(allocator);

        return Editor{
            .buffer = buffer,
            .view = view,
            .terminal = terminal,
            .allocator = allocator,
            .running = true,
            .filename = null,
            .modified = false,
            .undo_stack = .{},
            .redo_stack = .{},
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        self.terminal.deinit();
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }

        // Undo/Redoスタックのクリーンアップ
        for (self.undo_stack.items) |entry| {
            self.allocator.free(entry.pieces);
        }
        self.undo_stack.deinit(self.allocator);

        for (self.redo_stack.items) |entry| {
            self.allocator.free(entry.pieces);
        }
        self.redo_stack.deinit(self.allocator);
    }

    pub fn loadFile(self: *Editor, path: []const u8) !void {
        self.buffer.deinit();
        self.buffer = try Buffer.loadFromFile(self.allocator, path);
        self.view.buffer = &self.buffer;

        // View状態をリセット（新しいファイルを開いた時に前のカーソル位置が残らないように）
        self.view.top_line = 0;
        self.view.cursor_x = 0;
        self.view.cursor_y = 0;

        self.filename = try self.allocator.dupe(u8, path);
        self.modified = false;
    }

    pub fn saveFile(self: *Editor) !void {
        if (self.filename) |path| {
            try self.buffer.saveToFile(path);
            self.modified = false;
        }
    }

    pub fn run(self: *Editor) !void {
        const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };

        while (self.running) {
            try self.view.render(&self.terminal);

            if (try input.readKey(stdin)) |key| {
                try self.processKey(key);
            }
        }
    }

    fn saveUndo(self: *Editor) !void {
        const pieces = try self.buffer.clonePieces(self.allocator);
        try self.undo_stack.append(self.allocator, .{ .pieces = pieces });

        // Redoスタックをクリア
        for (self.redo_stack.items) |entry| {
            self.allocator.free(entry.pieces);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn undo(self: *Editor) !void {
        if (self.undo_stack.items.len == 0) return;

        // 現在の状態をredoスタックに保存
        const current = try self.buffer.clonePieces(self.allocator);
        try self.redo_stack.append(self.allocator, .{ .pieces = current });

        // undoスタックから状態を復元
        const entry = self.undo_stack.pop() orelse return;
        try self.buffer.restorePieces(entry.pieces);
        self.allocator.free(entry.pieces);
    }

    fn redo(self: *Editor) !void {
        if (self.redo_stack.items.len == 0) return;

        // 現在の状態をundoスタックに保存
        const current = try self.buffer.clonePieces(self.allocator);
        try self.undo_stack.append(self.allocator, .{ .pieces = current });

        // redoスタックから状態を復元
        const entry = self.redo_stack.pop() orelse return;
        try self.buffer.restorePieces(entry.pieces);
        self.allocator.free(entry.pieces);
    }

    fn processKey(self: *Editor, key: input.Key) !void {
        switch (key) {
            // Ctrl キー
            .ctrl => |c| {
                switch (c) {
                    'q' => self.running = false, // C-q で終了
                    'f' => self.view.moveCursorRight(&self.terminal), // C-f 前進
                    'b' => self.view.moveCursorLeft(), // C-b 後退
                    'n' => self.view.moveCursorDown(&self.terminal), // C-n 次行
                    'p' => self.view.moveCursorUp(), // C-p 前行
                    'a' => self.view.moveToLineStart(), // C-a 行頭
                    'e' => self.view.moveToLineEnd(), // C-e 行末
                    'd' => try self.deleteChar(), // C-d 文字削除
                    'k' => try self.killLine(), // C-k 行削除
                    's' => try self.saveFile(), // C-s 保存
                    'u' => try self.undo(), // C-u Undo
                    'r' => try self.redo(), // C-r Redo
                    else => {},
                }
            },

            // Alt キー
            .alt => |c| {
                switch (c) {
                    'f' => try self.forwardWord(), // M-f 単語前進
                    'b' => try self.backwardWord(), // M-b 単語後退
                    'd' => try self.deleteWord(), // M-d 単語削除
                    else => {},
                }
            },

            // M-delete
            .alt_delete => try self.deleteWord(),

            // 矢印キー
            .arrow_up => self.view.moveCursorUp(),
            .arrow_down => self.view.moveCursorDown(&self.terminal),
            .arrow_left => self.view.moveCursorLeft(),
            .arrow_right => self.view.moveCursorRight(&self.terminal),

            // 特殊キー
            .enter => try self.insertChar('\n'),
            .backspace => try self.backspace(),
            .tab => try self.insertChar('\t'),

            // 通常の文字 (ASCII)
            .char => |c| {
                if (c >= 32 and c < 127) {
                    try self.insertChar(c);
                }
            },

            // UTF-8文字
            .codepoint => |cp| {
                try self.insertCodepoint(cp);
            },

            else => {},
        }
    }

    fn insertChar(self: *Editor, ch: u8) !void {
        try self.saveUndo();

        const pos = self.view.getCursorBufferPos();
        try self.buffer.insert(pos, ch);
        self.modified = true;

        if (ch == '\n') {
            // 改行: 次の行の先頭に移動
            const max_screen_line = self.terminal.height - 2; // ステータスバー分を引く
            if (self.view.cursor_y < max_screen_line) {
                self.view.cursor_y += 1;
            } else {
                // 画面の最下部の場合はスクロール
                self.view.top_line += 1;
            }
            self.view.cursor_x = 0;
        } else {
            // UTF-8文字の幅を計算してカーソルを移動
            const width = Buffer.charWidth(@as(u21, ch));
            self.view.cursor_x += width;
        }
    }

    fn insertCodepoint(self: *Editor, codepoint: u21) !void {
        try self.saveUndo();

        // UTF-8にエンコード
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidUtf8;

        const pos = self.view.getCursorBufferPos();
        try self.buffer.insertSlice(pos, buf[0..len]);
        self.modified = true;

        if (codepoint == '\n') {
            // 改行: 次の行の先頭に移動
            const max_screen_line = self.terminal.height - 2; // ステータスバー分を引く
            if (self.view.cursor_y < max_screen_line) {
                self.view.cursor_y += 1;
            } else {
                // 画面の最下部の場合はスクロール
                self.view.top_line += 1;
            }
            self.view.cursor_x = 0;
        } else {
            // UTF-8文字の幅を計算してカーソルを移動
            const width = Buffer.charWidth(codepoint);
            self.view.cursor_x += width;
        }
    }

    fn deleteChar(self: *Editor) !void {
        const pos = self.view.getCursorBufferPos();
        if (pos >= self.buffer.len()) return;

        try self.saveUndo();

        // カーソル位置のgrapheme clusterのバイト数を取得
        var iter = PieceIterator.init(&self.buffer);
        while (iter.global_pos < pos) {
            _ = iter.next();
        }

        const cluster = iter.nextGraphemeCluster() catch {
            try self.buffer.delete(pos, 1);
            self.modified = true;
            return;
        };

        if (cluster) |gc| {
            try self.buffer.delete(pos, gc.byte_len);
            self.modified = true;
        }
    }

    fn backspace(self: *Editor) !void {
        const pos = self.view.getCursorBufferPos();
        if (pos == 0) return;

        try self.saveUndo();

        // 削除するgrapheme clusterのバイト数と幅を取得
        var iter = PieceIterator.init(&self.buffer);
        var char_start: usize = 0;
        var char_width: usize = 1;
        var char_len: usize = 1;

        while (iter.global_pos < pos) {
            char_start = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch {
                _ = iter.next();
                continue;
            };
            if (cluster) |gc| {
                char_width = gc.width;
                char_len = gc.byte_len;
            } else {
                break;
            }
        }

        try self.buffer.delete(char_start, char_len);
        self.modified = true;

        if (self.view.cursor_x >= char_width) {
            self.view.cursor_x -= char_width;
        } else if (self.view.cursor_y > 0) {
            self.view.cursor_y -= 1;
            self.view.moveToLineEnd();
        }
    }

    fn killLine(self: *Editor) !void {
        const pos = self.view.getCursorBufferPos();
        var end_pos = pos;

        // 行末まで削除
        while (end_pos < self.buffer.len()) {
            const ch = self.buffer.charAt(end_pos).?;
            if (ch == '\n') {
                end_pos += 1;
                break;
            }
            end_pos += 1;
        }

        const count = end_pos - pos;
        if (count > 0) {
            try self.saveUndo();
            try self.buffer.delete(pos, count);
            self.modified = true;
        }
    }

    fn forwardWord(self: *Editor) !void {
        const pos = self.view.getCursorBufferPos();
        var new_pos = pos;

        // 空白をスキップ
        while (new_pos < self.buffer.len()) {
            const ch = self.buffer.charAt(new_pos).?;
            if (!std.ascii.isWhitespace(ch)) break;
            new_pos += 1;
        }

        // 単語をスキップ
        while (new_pos < self.buffer.len()) {
            const ch = self.buffer.charAt(new_pos).?;
            if (std.ascii.isWhitespace(ch)) break;
            new_pos += 1;
        }

        // カーソルを移動
        const diff = new_pos - pos;
        for (0..diff) |_| {
            self.view.moveCursorRight(&self.terminal);
        }
    }

    fn backwardWord(self: *Editor) !void {
        const pos = self.view.getCursorBufferPos();
        if (pos == 0) return;

        var new_pos = pos - 1;

        // 空白をスキップ
        while (new_pos > 0) {
            const ch = self.buffer.charAt(new_pos).?;
            if (!std.ascii.isWhitespace(ch)) break;
            if (new_pos == 0) break;
            new_pos -= 1;
        }

        // 単語をスキップ
        while (new_pos > 0) {
            const ch = self.buffer.charAt(new_pos).?;
            if (std.ascii.isWhitespace(ch)) {
                new_pos += 1;
                break;
            }
            if (new_pos == 0) break;
            new_pos -= 1;
        }

        // カーソルを移動
        const diff = pos - new_pos;
        for (0..diff) |_| {
            self.view.moveCursorLeft();
        }
    }

    fn deleteWord(self: *Editor) !void {
        const pos = self.view.getCursorBufferPos();
        if (pos >= self.buffer.len()) return;

        var end_pos = pos;

        // 空白をスキップ
        while (end_pos < self.buffer.len()) {
            const ch = self.buffer.charAt(end_pos).?;
            if (!std.ascii.isWhitespace(ch)) break;
            end_pos += 1;
        }

        // 単語をスキップ
        while (end_pos < self.buffer.len()) {
            const ch = self.buffer.charAt(end_pos).?;
            if (std.ascii.isWhitespace(ch)) break;
            end_pos += 1;
        }

        const count = end_pos - pos;
        if (count > 0) {
            try self.saveUndo();
            try self.buffer.delete(pos, count);
            self.modified = true;
        }
    }
};
