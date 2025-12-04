const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Piece = @import("buffer.zig").Piece;
const PieceIterator = @import("buffer.zig").PieceIterator;
const View = @import("view.zig").View;
const Terminal = @import("terminal.zig").Terminal;
const input = @import("input.zig");
const config = @import("config.zig");

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
    cursor_pos: usize, // 操作前のカーソルバイト位置

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
    quit_confirmation: bool, // 終了確認フラグ
    mark_pos: ?usize, // 範囲選択のマーク位置（null=未設定）
    kill_ring: ?[]const u8, // コピー/カットバッファ
    undo_stack: std.ArrayList(UndoEntry),
    redo_stack: std.ArrayList(UndoEntry),

    pub fn init(allocator: std.mem.Allocator) !Editor {
        var buffer = try Buffer.init(allocator);
        const view = View.init(allocator, &buffer);
        const terminal = try Terminal.init(allocator);

        return Editor{
            .buffer = buffer,
            .view = view,
            .terminal = terminal,
            .allocator = allocator,
            .running = true,
            .filename = null,
            .modified = false,
            .quit_confirmation = false,
            .mark_pos = null,
            .kill_ring = null,
            .undo_stack = std.ArrayList(UndoEntry).initCapacity(allocator, 0) catch unreachable,
            .redo_stack = std.ArrayList(UndoEntry).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
        self.view.deinit(self.allocator);
        self.terminal.deinit();
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
        if (self.kill_ring) |text| {
            self.allocator.free(text);
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
            // カーソル位置をバッファ範囲内にクランプ（大量削除後の対策）
            self.clampCursorPosition();

            try self.view.render(&self.terminal);

            if (try input.readKey(stdin)) |key| {
                // 何かキー入力があればエラーメッセージをクリア
                self.view.clearError();

                // キー処理でエラーが発生したらステータスバーに表示
                self.processKey(key) catch |err| {
                    const err_name = @errorName(err);
                    self.view.setError(err_name);
                };
            }
        }
    }

    // バッファから指定範囲のテキストを取得（削除前に使用）
    // PieceIterator.seekを使ってO(pieces + len)で効率的に取得
    fn extractText(self: *Editor, pos: usize, len: usize) ![]u8 {
        // 実際に読み取れるバイト数を計算（buffer末尾を超えないように）
        const actual_len = @min(len, self.buffer.len() - pos);
        var result = try self.allocator.alloc(u8, actual_len);
        errdefer self.allocator.free(result);

        var iter = PieceIterator.init(&self.buffer);
        iter.seek(pos); // O(pieces)で直接ジャンプ

        // actual_len分読み取る（保証されている）
        var i: usize = 0;
        while (i < actual_len) : (i += 1) {
            result[i] = iter.next() orelse {
                // Piece table の不整合が発生した場合
                // メモリリークを防ぐため、エラーを返す（errdefer が解放する）
                return error.BufferInconsistency;
            };
        }

        return result;
    }

    // 現在のカーソル位置の行番号を取得（dirty tracking用）
    fn getCurrentLine(self: *const Editor) usize {
        return self.view.top_line + self.view.cursor_y;
    }

    // カーソル位置をバッファの有効範囲にクランプ（大量削除後の対策）
    fn clampCursorPosition(self: *Editor) void {
        const total_lines = self.buffer.lineCount();
        if (total_lines == 0) return;

        const max_screen_lines = self.terminal.height - 1; // ステータスバー分を引く

        // top_lineが範囲外の場合は調整
        if (self.view.top_line >= total_lines) {
            if (total_lines > max_screen_lines) {
                self.view.top_line = total_lines - max_screen_lines;
            } else {
                self.view.top_line = 0;
            }
            self.view.markFullRedraw();
        }

        // cursor_yが範囲外の場合は調整
        const current_line = self.view.top_line + self.view.cursor_y;
        if (current_line >= total_lines) {
            if (total_lines > self.view.top_line) {
                self.view.cursor_y = total_lines - self.view.top_line - 1;
            } else {
                self.view.cursor_y = 0;
            }

            // cursor_xも行末にクランプ
            const line_width = self.view.getCurrentLineWidth();
            if (self.view.cursor_x > line_width) {
                self.view.cursor_x = line_width;
            }
        }
    }

    // Undoスタックの最大エントリ数
    const MAX_UNDO_ENTRIES = config.Editor.MAX_UNDO_ENTRIES;

    // 編集操作を記録（差分ベース、連続挿入はマージ）
    fn recordInsert(self: *Editor, pos: usize, text: []const u8, cursor_pos_before_edit: usize) !void {
        const cursor_pos = cursor_pos_before_edit;

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
                    // cursor_posは最初の操作のものを保持
                    return;
                }
            }
        }

        const text_copy = try self.allocator.dupe(u8, text);
        try self.undo_stack.append(self.allocator, .{
            .op = .{ .insert = .{ .pos = pos, .text = text_copy } },
            .cursor_pos = cursor_pos,
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

    fn recordDelete(self: *Editor, pos: usize, text: []const u8, cursor_pos_before_edit: usize) !void {
        const cursor_pos = cursor_pos_before_edit;

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
                    // cursor_posは最初の操作のものを保持
                    return;
                }
                // Delete: 削除位置が同じ（連続してpos位置で削除）
                if (pos == last_del.pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ last_del.text, text });
                    errdefer self.allocator.free(new_text);
                    self.allocator.free(last_del.text);
                    last.op.delete.text = new_text;
                    // cursor_posは最初の操作のものを保持
                    return;
                }
            }
        }

        const text_copy = try self.allocator.dupe(u8, text);
        try self.undo_stack.append(self.allocator, .{
            .op = .{ .delete = .{ .pos = pos, .text = text_copy } },
            .cursor_pos = cursor_pos,
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

        const saved_cursor = entry.cursor_pos;

        // 逆操作を実行してredoスタックに保存
        switch (entry.op) {
            .insert => |ins| {
                // insertの取り消し: deleteする
                try self.buffer.delete(ins.pos, ins.text.len);
                const text_copy = try self.allocator.dupe(u8, ins.text);
                try self.redo_stack.append(self.allocator, .{
                    .op = .{ .insert = .{ .pos = ins.pos, .text = text_copy } },
                    .cursor_pos = self.view.getCursorBufferPos(),
                });
            },
            .delete => |del| {
                // deleteの取り消し: insertする
                try self.buffer.insertSlice(del.pos, del.text);
                const text_copy = try self.allocator.dupe(u8, del.text);
                try self.redo_stack.append(self.allocator, .{
                    .op = .{ .delete = .{ .pos = del.pos, .text = text_copy } },
                    .cursor_pos = self.view.getCursorBufferPos(),
                });
            },
        }

        self.modified = true;

        // 画面全体を再描画
        self.view.markFullRedraw();

        // カーソル位置を復元（保存された位置へ）
        self.restoreCursorPos(saved_cursor);
    }

    fn redo(self: *Editor) !void {
        if (self.redo_stack.items.len == 0) return;

        const entry = self.redo_stack.pop() orelse return;
        defer entry.deinit(self.allocator);

        const saved_cursor = entry.cursor_pos;

        // 逆操作を実行してundoスタックに保存
        switch (entry.op) {
            .insert => |ins| {
                // redoのinsert: もう一度insertする
                try self.buffer.insertSlice(ins.pos, ins.text);
                const text_copy = try self.allocator.dupe(u8, ins.text);
                try self.undo_stack.append(self.allocator, .{
                    .op = .{ .insert = .{ .pos = ins.pos, .text = text_copy } },
                    .cursor_pos = self.view.getCursorBufferPos(),
                });
            },
            .delete => |del| {
                // redoのdelete: もう一度deleteする
                try self.buffer.delete(del.pos, del.text.len);
                const text_copy = try self.allocator.dupe(u8, del.text);
                try self.undo_stack.append(self.allocator, .{
                    .op = .{ .delete = .{ .pos = del.pos, .text = text_copy } },
                    .cursor_pos = self.view.getCursorBufferPos(),
                });
            },
        }

        self.modified = true;

        // 画面全体を再描画
        self.view.markFullRedraw();

        // カーソル位置を復元（保存された位置へ）
        self.restoreCursorPos(saved_cursor);
    }

    // バイト位置からカーソル座標を計算して設定（grapheme cluster考慮）
    fn setCursorToPos(self: *Editor, target_pos: usize) void {
        const clamped_pos = @min(target_pos, self.buffer.len());

        // LineIndexでO(log N)行番号計算
        const line = self.buffer.findLineByPos(clamped_pos);
        const line_start = self.buffer.getLineStart(line) orelse 0;

        // 画面内の行位置を計算
        const max_screen_lines = self.terminal.height - 1;
        if (line < max_screen_lines) {
            self.view.top_line = 0;
            self.view.cursor_y = line;
        } else {
            self.view.top_line = line - max_screen_lines / 2; // 中央に表示
            self.view.cursor_y = line - self.view.top_line;
        }

        // カーソルX位置を計算（grapheme clusterの表示幅）
        var iter = PieceIterator.init(&self.buffer);
        iter.seek(line_start);

        var display_col: usize = 0;
        while (iter.global_pos < clamped_pos) {
            const cluster = iter.nextGraphemeCluster() catch {
                _ = iter.next();
                display_col += 1;
                continue;
            };
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                display_col += gc.width; // 絵文字は2、通常文字は1
            } else {
                break;
            }
        }

        self.view.cursor_x = display_col;
    }

    // エイリアス: restoreCursorPosはsetCursorToPosと同じ
    fn restoreCursorPos(self: *Editor, target_pos: usize) void {
        self.setCursorToPos(target_pos);
    }

    fn processKey(self: *Editor, key: input.Key) !void {
        // Ctrl+Q以外のキーが押されたら終了確認フラグをリセット
        const is_quit_key = switch (key) {
            .ctrl => |c| c == 'q',
            else => false,
        };
        if (!is_quit_key and self.quit_confirmation) {
            self.quit_confirmation = false;
        }

        switch (key) {
            // Ctrl キー
            .ctrl => |c| {
                switch (c) {
                    0, '@' => self.setMark(), // C-Space / C-@ マーク設定
                    'q' => {
                        // 未保存の変更がある場合は警告
                        if (self.modified and !self.quit_confirmation) {
                            self.view.setError("未保存の変更があります。もう一度Ctrl-Qで終了、Ctrl-Sで保存");
                            self.quit_confirmation = true;
                        } else {
                            self.running = false;
                        }
                    },
                    'f' => self.view.moveCursorRight(&self.terminal), // C-f 前進
                    'b' => self.view.moveCursorLeft(), // C-b 後退
                    'n' => self.view.moveCursorDown(&self.terminal), // C-n 次行
                    'p' => self.view.moveCursorUp(), // C-p 前行
                    'a' => self.view.moveToLineStart(), // C-a 行頭
                    'e' => self.view.moveToLineEnd(), // C-e 行末
                    'd' => try self.deleteChar(), // C-d 文字削除
                    'k' => try self.killLine(), // C-k 行削除
                    'w' => try self.killRegion(), // C-w 範囲削除（カット）
                    'y' => try self.yank(), // C-y ペースト
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
                    'w' => try self.copyRegion(), // M-w 範囲コピー
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
        try self.recordInsert(pos, &[_]u8{ch}, pos); // 編集前のカーソル位置を記録
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
        try self.recordInsert(pos, buf[0..len], pos); // 編集前のカーソル位置を記録
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
            try self.recordDelete(pos, deleted, pos); // 編集前のカーソル位置を記録

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
            try self.recordDelete(pos, deleted, pos); // 編集前のカーソル位置を記録

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
        try self.recordDelete(char_start, deleted, pos); // 編集前のカーソル位置を記録

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

        // PieceIteratorで行末を探す
        var iter = PieceIterator.init(&self.buffer);
        iter.seek(pos);

        var end_pos = pos;
        while (iter.next()) |ch| {
            if (ch == '\n') {
                end_pos = iter.global_pos;
                break;
            }
        } else {
            end_pos = self.buffer.len();
        }

        const count = end_pos - pos;
        if (count > 0) {
            const deleted = try self.extractText(pos, count);
            errdefer self.allocator.free(deleted);

            try self.buffer.delete(pos, count);
            errdefer self.buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted, pos); // 編集前のカーソル位置を記録

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

        // PieceIteratorで単語終端を探す
        var iter = PieceIterator.init(&self.buffer);
        iter.seek(pos);

        // 空白をスキップ
        var non_ws_start: ?usize = null;
        while (iter.next()) |ch| {
            if (!std.ascii.isWhitespace(ch)) {
                non_ws_start = iter.global_pos - 1;
                break;
            }
        }

        // 空白しかない場合はEOFまで移動
        if (non_ws_start == null) {
            self.setCursorToPos(self.buffer.len());
            return;
        }

        // non-whitespaceの開始位置から単語終端を探す
        iter.seek(non_ws_start.?);
        _ = iter.next(); // 最初の文字をスキップ

        // 単語をスキップ
        while (iter.next()) |ch| {
            if (std.ascii.isWhitespace(ch)) break;
        }

        const new_pos = iter.global_pos;

        // カーソル位置を直接計算して設定
        self.setCursorToPos(new_pos);
    }

    fn backwardWord(self: *Editor) !void {
        const pos = self.view.getCursorBufferPos();
        if (pos == 0) return;

        // パフォーマンス最適化: 現在位置から適度な範囲だけ走査
        // 大きなファイルでも高速に動作するように、最大1000バイト程度を見る
        const scan_distance: usize = 1000;
        const start_pos = if (pos > scan_distance) pos - scan_distance else 0;

        var iter = PieceIterator.init(&self.buffer);
        if (start_pos > 0) {
            iter.seek(start_pos);
        }

        var new_pos: usize = 0;
        var in_word = false;
        var last_word_start: usize = 0;

        // start_posから現在位置まで走査して単語境界を記録
        while (iter.global_pos < pos) {
            const ch = iter.next() orelse break;
            const is_ws = std.ascii.isWhitespace(ch);

            if (!is_ws and !in_word) {
                // 単語開始
                last_word_start = iter.global_pos - 1;
                in_word = true;
            } else if (is_ws and in_word) {
                // 単語終了
                in_word = false;
            }
        }

        // 現在位置が単語中なら、その単語の開始位置へ
        // そうでなければ、直前の単語の開始位置へ
        new_pos = last_word_start;

        // カーソル位置を直接計算して設定
        self.setCursorToPos(new_pos);
    }

    fn deleteWord(self: *Editor) !void {
        const current_line = self.getCurrentLine();
        const pos = self.view.getCursorBufferPos();
        if (pos >= self.buffer.len()) return;

        // PieceIteratorで単語終端を探す
        var iter = PieceIterator.init(&self.buffer);
        iter.seek(pos);

        // 空白をスキップ
        while (iter.next()) |ch| {
            if (!std.ascii.isWhitespace(ch)) {
                // 1文字戻る
                if (iter.global_pos > 0) {
                    iter.global_pos -= 1;
                }
                break;
            }
        }

        // 単語をスキップ
        while (iter.next()) |ch| {
            if (std.ascii.isWhitespace(ch)) break;
        }

        const end_pos = iter.global_pos;
        const count = end_pos - pos;
        if (count > 0) {
            const deleted = try self.extractText(pos, count);
            errdefer self.allocator.free(deleted);

            try self.buffer.delete(pos, count);
            errdefer self.buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted, pos); // 編集前のカーソル位置を記録

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

    // マークを設定/解除（Ctrl+Space）
    fn setMark(self: *Editor) void {
        if (self.mark_pos) |_| {
            // マークがある場合は解除
            self.mark_pos = null;
            self.view.setError("Mark deactivated");
        } else {
            // マークを設定
            self.mark_pos = self.view.getCursorBufferPos();
            self.view.setError("Mark set");
        }
    }

    // マーク位置とカーソル位置から範囲を取得（開始位置と長さを返す）
    fn getRegion(self: *Editor) ?struct { start: usize, len: usize } {
        const mark = self.mark_pos orelse return null;
        const cursor = self.view.getCursorBufferPos();

        if (mark < cursor) {
            return .{ .start = mark, .len = cursor - mark };
        } else if (cursor < mark) {
            return .{ .start = cursor, .len = mark - cursor };
        } else {
            return null; // 範囲が空
        }
    }

    // 範囲をコピー（M-w）
    fn copyRegion(self: *Editor) !void {
        const region = self.getRegion() orelse {
            self.view.setError("No active region");
            return;
        };

        // 既存のkill_ringを解放
        if (self.kill_ring) |old_text| {
            self.allocator.free(old_text);
        }

        // 範囲のテキストをコピー
        self.kill_ring = try self.extractText(region.start, region.len);

        // マークを解除
        self.mark_pos = null;

        self.view.setError("Saved text to kill ring");
    }

    // 範囲を削除（カット）（C-w）
    fn killRegion(self: *Editor) !void {
        const current_line = self.getCurrentLine();
        const region = self.getRegion() orelse {
            self.view.setError("No active region");
            return;
        };

        // 既存のkill_ringを解放
        if (self.kill_ring) |old_text| {
            self.allocator.free(old_text);
        }

        // 範囲のテキストをコピー
        const deleted = try self.extractText(region.start, region.len);
        errdefer self.allocator.free(deleted);

        // バッファから削除
        try self.buffer.delete(region.start, region.len);
        errdefer self.buffer.insertSlice(region.start, deleted) catch unreachable;
        try self.recordDelete(region.start, deleted, self.view.getCursorBufferPos());

        // kill_ringに保存（extractTextと同じデータなので、新たにdupeせずそのまま使う）
        self.kill_ring = deleted;

        self.modified = true;

        // カーソルを範囲の開始位置に移動
        self.setCursorToPos(region.start);

        // マークを解除
        self.mark_pos = null;

        // 改行が含まれる場合は末尾まで再描画
        if (std.mem.indexOf(u8, deleted, "\n") != null) {
            self.view.markDirty(current_line, null);
        } else {
            self.view.markDirty(current_line, current_line);
        }

        self.view.setError("Killed region");
    }

    // kill_ringの内容をペースト（C-y）
    fn yank(self: *Editor) !void {
        const current_line = self.getCurrentLine();
        const text = self.kill_ring orelse {
            self.view.setError("Kill ring is empty");
            return;
        };

        const pos = self.view.getCursorBufferPos();

        // バッファに挿入
        try self.buffer.insertSlice(pos, text);
        errdefer self.buffer.delete(pos, text.len) catch unreachable;
        try self.recordInsert(pos, text, pos);

        self.modified = true;

        // カーソルを挿入後の位置に移動
        self.setCursorToPos(pos + text.len);

        // 改行が含まれる場合は末尾まで再描画
        if (std.mem.indexOf(u8, text, "\n") != null) {
            self.view.markDirty(current_line, null);
        } else {
            self.view.markDirty(current_line, current_line);
        }

        self.view.setError("Yanked text");
    }
};
