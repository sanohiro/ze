const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Piece = @import("buffer.zig").Piece;
const PieceIterator = @import("buffer.zig").PieceIterator;
const View = @import("view.zig").View;
const Terminal = @import("terminal.zig").Terminal;
const input = @import("input.zig");

// 差分ログベースのUndo/Redo
const EditOp = union(enum) {
    insert: struct {
        pos: usize,
        text: []const u8, // owned by allocator
    },
    delete: struct {
        pos: usize,
        text: []const u8, // owned by allocator (削除されたテキストを保存)
    },
};

const UndoEntry = struct {
    op: EditOp,

    fn deinit(self: *const UndoEntry, allocator: std.mem.Allocator) void {
        switch (self.op) {
            .insert => |ins| allocator.free(ins.text),
            .delete => |del| allocator.free(del.text),
        }
    }
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
            entry.deinit(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);

        for (self.redo_stack.items) |entry| {
            entry.deinit(self.allocator);
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

    // バッファから指定範囲のテキストを取得（削除前に使用）
    // PieceIterator.seekを使ってO(pieces + len)で効率的に取得
    fn extractText(self: *Editor, pos: usize, len: usize) ![]u8 {
        var result = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(result);

        var iter = PieceIterator.init(&self.buffer);
        iter.seek(pos); // O(pieces)で直接ジャンプ

        // len分読み取る
        var i: usize = 0;
        while (i < len) : (i += 1) {
            result[i] = iter.next() orelse break;
        }

        return result[0..i];
    }

    // 現在のカーソル位置の行番号を取得（dirty tracking用）
    fn getCurrentLine(self: *const Editor) usize {
        return self.view.top_line + self.view.cursor_y;
    }

    // Undoスタックの最大エントリ数
    const MAX_UNDO_ENTRIES = 1000;

    // 編集操作を記録（差分ベース、連続挿入はマージ）
    fn recordInsert(self: *Editor, pos: usize, text: []const u8) !void {
        // 連続挿入のコアレッシング: 直前の操作が連続する挿入ならマージ
        if (self.undo_stack.items.len > 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.op == .insert) {
                const last_ins = last.op.insert;
                // 直前の挿入の直後に続く挿入ならマージ
                if (last_ins.pos + last_ins.text.len == pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ last_ins.text, text });
                    errdefer self.allocator.free(new_text); // concat成功後の保護
                    self.allocator.free(last_ins.text);
                    last.op.insert.text = new_text;
                    return;
                }
            }
        }

        const text_copy = try self.allocator.dupe(u8, text);
        try self.undo_stack.append(self.allocator, .{
            .op = .{ .insert = .{ .pos = pos, .text = text_copy } },
        });

        // Undoスタックが上限を超えたら古いエントリを削除
        if (self.undo_stack.items.len > MAX_UNDO_ENTRIES) {
            const old_entry = self.undo_stack.orderedRemove(0);
            old_entry.deinit(self.allocator);
        }

        // Redoスタックをクリア
        for (self.redo_stack.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn recordDelete(self: *Editor, pos: usize, text: []const u8) !void {
        // 連続削除のコアレッシング: 直前の操作が連続する削除ならマージ
        if (self.undo_stack.items.len > 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.op == .delete) {
                const last_del = last.op.delete;
                // Backspace: 削除位置が前に移動（pos == last_pos - text.len）
                if (pos + text.len == last_del.pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ text, last_del.text });
                    errdefer self.allocator.free(new_text);
                    self.allocator.free(last_del.text);
                    last.op.delete.text = new_text;
                    last.op.delete.pos = pos;
                    return;
                }
                // Delete: 削除位置が同じ（連続してpos位置で削除）
                if (pos == last_del.pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ last_del.text, text });
                    errdefer self.allocator.free(new_text);
                    self.allocator.free(last_del.text);
                    last.op.delete.text = new_text;
                    return;
                }
            }
        }

        const text_copy = try self.allocator.dupe(u8, text);
        try self.undo_stack.append(self.allocator, .{
            .op = .{ .delete = .{ .pos = pos, .text = text_copy } },
        });

        // Undoスタックが上限を超えたら古いエントリを削除
        if (self.undo_stack.items.len > MAX_UNDO_ENTRIES) {
            const old_entry = self.undo_stack.orderedRemove(0);
            old_entry.deinit(self.allocator);
        }

        // Redoスタックをクリア
        for (self.redo_stack.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn undo(self: *Editor) !void {
        if (self.undo_stack.items.len == 0) return;

        const entry = self.undo_stack.pop() orelse return;
        defer entry.deinit(self.allocator);

        // 逆操作を実行してredoスタックに保存
        switch (entry.op) {
            .insert => |ins| {
                // insertの取り消し: deleteする
                try self.buffer.delete(ins.pos, ins.text.len);
                const text_copy = try self.allocator.dupe(u8, ins.text);
                try self.redo_stack.append(self.allocator, .{
                    .op = .{ .insert = .{ .pos = ins.pos, .text = text_copy } },
                });
            },
            .delete => |del| {
                // deleteの取り消し: insertする
                try self.buffer.insertSlice(del.pos, del.text);
                const text_copy = try self.allocator.dupe(u8, del.text);
                try self.redo_stack.append(self.allocator, .{
                    .op = .{ .delete = .{ .pos = del.pos, .text = text_copy } },
                });
            },
        }

        self.modified = true;

        // 画面全体を再描画
        self.view.markFullRedraw();

        // カーソル位置をリセット（簡易版: ホーム位置）
        self.view.top_line = 0;
        self.view.cursor_x = 0;
        self.view.cursor_y = 0;
    }

    fn redo(self: *Editor) !void {
        if (self.redo_stack.items.len == 0) return;

        const entry = self.redo_stack.pop() orelse return;
        defer entry.deinit(self.allocator);

        // 逆操作を実行してundoスタックに保存
        switch (entry.op) {
            .insert => |ins| {
                // redoのinsert: もう一度insertする
                try self.buffer.insertSlice(ins.pos, ins.text);
                const text_copy = try self.allocator.dupe(u8, ins.text);
                try self.undo_stack.append(self.allocator, .{
                    .op = .{ .insert = .{ .pos = ins.pos, .text = text_copy } },
                });
            },
            .delete => |del| {
                // redoのdelete: もう一度deleteする
                try self.buffer.delete(del.pos, del.text.len);
                const text_copy = try self.allocator.dupe(u8, del.text);
                try self.undo_stack.append(self.allocator, .{
                    .op = .{ .delete = .{ .pos = del.pos, .text = text_copy } },
                });
            },
        }

        self.modified = true;

        // 画面全体を再描画
        self.view.markFullRedraw();

        // カーソル位置をリセット（簡易版: ホーム位置）
        self.view.top_line = 0;
        self.view.cursor_x = 0;
        self.view.cursor_y = 0;
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
        const current_line = self.getCurrentLine();
        const pos = self.view.getCursorBufferPos();

        // バッファ変更を先に実行（失敗した場合はundoログに記録しない）
        try self.buffer.insert(pos, ch);
        errdefer self.buffer.delete(pos, 1) catch unreachable; // rollback失敗は致命的
        try self.recordInsert(pos, &[_]u8{ch});
        self.modified = true;

        if (ch == '\n') {
            // 改行: 現在行以降すべてdirty
            self.view.markDirty(current_line, null); // EOF まで再描画

            // 次の行の先頭に移動
            const max_screen_line = self.terminal.height - 2; // ステータスバー分を引く
            if (self.view.cursor_y < max_screen_line) {
                self.view.cursor_y += 1;
            } else {
                // 画面の最下部の場合はスクロール
                self.view.top_line += 1;
            }
            self.view.cursor_x = 0;
        } else {
            // 通常文字: 現在行のみdirty
            self.view.markDirty(current_line, current_line);

            // UTF-8文字の幅を計算してカーソルを移動
            const width = Buffer.charWidth(@as(u21, ch));
            self.view.cursor_x += width;
        }
    }

    fn insertCodepoint(self: *Editor, codepoint: u21) !void {
        const current_line = self.getCurrentLine();

        // UTF-8にエンコード
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidUtf8;

        const pos = self.view.getCursorBufferPos();

        // バッファ変更を先に実行
        try self.buffer.insertSlice(pos, buf[0..len]);
        errdefer self.buffer.delete(pos, len) catch unreachable; // rollback失敗は致命的
        try self.recordInsert(pos, buf[0..len]);
        self.modified = true;

        if (codepoint == '\n') {
            // 改行: 現在行以降すべてdirty
            self.view.markDirty(current_line, null);

            // 次の行の先頭に移動
            const max_screen_line = self.terminal.height - 2; // ステータスバー分を引く
            if (self.view.cursor_y < max_screen_line) {
                self.view.cursor_y += 1;
            } else {
                // 画面の最下部の場合はスクロール
                self.view.top_line += 1;
            }
            self.view.cursor_x = 0;
        } else {
            // 通常文字: 現在行のみdirty
            self.view.markDirty(current_line, current_line);

            // UTF-8文字の幅を計算してカーソルを移動
            const width = Buffer.charWidth(codepoint);
            self.view.cursor_x += width;
        }
    }

    fn deleteChar(self: *Editor) !void {
        const current_line = self.getCurrentLine();
        const pos = self.view.getCursorBufferPos();
        if (pos >= self.buffer.len()) return;

        // カーソル位置のgrapheme clusterのバイト数を取得
        var iter = PieceIterator.init(&self.buffer);
        while (iter.global_pos < pos) {
            _ = iter.next();
        }

        const cluster = iter.nextGraphemeCluster() catch {
            const deleted = try self.extractText(pos, 1);
            errdefer self.allocator.free(deleted);

            try self.buffer.delete(pos, 1);
            errdefer self.buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted);

            self.modified = true;
            // 改行削除の場合は末尾まで再描画
            if (std.mem.indexOf(u8, deleted, "\n") != null) {
                self.view.markDirty(current_line, null);
            } else {
                self.view.markDirty(current_line, current_line);
            }
            self.allocator.free(deleted);
            return;
        };

        if (cluster) |gc| {
            const deleted = try self.extractText(pos, gc.byte_len);
            errdefer self.allocator.free(deleted);

            try self.buffer.delete(pos, gc.byte_len);
            errdefer self.buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted);

            self.modified = true;
            // 改行削除の場合は末尾まで再描画
            if (std.mem.indexOf(u8, deleted, "\n") != null) {
                self.view.markDirty(current_line, null);
            } else {
                self.view.markDirty(current_line, current_line);
            }
            self.allocator.free(deleted);
        }
    }

    fn backspace(self: *Editor) !void {
        const current_line = self.getCurrentLine();
        const pos = self.view.getCursorBufferPos();
        if (pos == 0) return;

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

        const deleted = try self.extractText(char_start, char_len);
        errdefer self.allocator.free(deleted);

        try self.buffer.delete(char_start, char_len);
        errdefer self.buffer.insertSlice(char_start, deleted) catch unreachable; // rollback失敗は致命的
        try self.recordDelete(char_start, deleted);

        self.modified = true;
        // 改行削除の場合は末尾まで再描画
        if (std.mem.indexOf(u8, deleted, "\n") != null) {
            self.view.markDirty(current_line, null);
        } else {
            self.view.markDirty(current_line, current_line);
        }
        self.allocator.free(deleted);

        if (self.view.cursor_x >= char_width) {
            self.view.cursor_x -= char_width;
        } else if (self.view.cursor_y > 0) {
            self.view.cursor_y -= 1;
            self.view.moveToLineEnd();
        }
    }

    fn killLine(self: *Editor) !void {
        const current_line = self.getCurrentLine();
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
            const deleted = try self.extractText(pos, count);
            errdefer self.allocator.free(deleted);

            try self.buffer.delete(pos, count);
            errdefer self.buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted);

            self.modified = true;
            // 改行削除の場合は末尾まで再描画
            if (std.mem.indexOf(u8, deleted, "\n") != null) {
                self.view.markDirty(current_line, null);
            } else {
                self.view.markDirty(current_line, current_line);
            }
            self.allocator.free(deleted);
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
        const current_line = self.getCurrentLine();
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
            const deleted = try self.extractText(pos, count);
            errdefer self.allocator.free(deleted);

            try self.buffer.delete(pos, count);
            errdefer self.buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted);

            self.modified = true;
            // 改行削除の場合は末尾まで再描画
            if (std.mem.indexOf(u8, deleted, "\n") != null) {
                self.view.markDirty(current_line, null);
            } else {
                self.view.markDirty(current_line, current_line);
            }
            self.allocator.free(deleted);
        }
    }
};
