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

const EditorMode = enum {
    normal,
    prefix_x, // C-xプレフィックス待ち
    prefix_r, // C-x rプレフィックス待ち（矩形選択コマンド）
    quit_confirm, // 終了確認中（y/n/cを待つ）
    filename_input, // ファイル名入力中
    isearch_forward, // インクリメンタルサーチ（前方）
    isearch_backward, // インクリメンタルサーチ（後方）
};

pub const Editor = struct {
    buffer: Buffer,
    view: View,
    terminal: Terminal,
    allocator: std.mem.Allocator,
    running: bool,
    filename: ?[]const u8,
    modified: bool,
    mode: EditorMode, // エディタのモード
    input_buffer: std.ArrayList(u8), // ミニバッファ入力用（検索文字列、ファイル名入力等）
    quit_after_save: bool, // ファイル名入力後に終了するか
    prompt_buffer: ?[]const u8, // allocPrintで作成したプロンプト文字列
    mark_pos: ?usize, // 範囲選択のマーク位置（null=未設定）
    kill_ring: ?[]const u8, // コピー/カットバッファ
    rectangle_ring: ?std.ArrayList([]const u8), // 矩形コピー/カットバッファ（各行の文字列の配列）
    search_start_pos: ?usize, // 検索開始時のカーソル位置（C-gでここに戻る）
    last_search: ?[]const u8, // 最後に実行した検索文字列（検索繰り返し用）
    undo_stack: std.ArrayList(UndoEntry),
    redo_stack: std.ArrayList(UndoEntry),

    pub fn init(allocator: std.mem.Allocator) !Editor {
        var editor = Editor{
            .buffer = try Buffer.init(allocator),
            .view = undefined, // 後で初期化
            .terminal = try Terminal.init(allocator),
            .allocator = allocator,
            .running = true,
            .filename = null,
            .modified = false,
            .mode = .normal,
            .input_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
            .quit_after_save = false,
            .prompt_buffer = null,
            .mark_pos = null,
            .kill_ring = null,
            .rectangle_ring = null,
            .search_start_pos = null,
            .last_search = null,
            .undo_stack = std.ArrayList(UndoEntry).initCapacity(allocator, 0) catch unreachable,
            .redo_stack = std.ArrayList(UndoEntry).initCapacity(allocator, 0) catch unreachable,
        };

        // bufferが最終的な位置に配置された後、viewを初期化
        editor.view = View.init(allocator, &editor.buffer);

        return editor;
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
        if (self.rectangle_ring) |*rect| {
            for (rect.items) |line| {
                self.allocator.free(line);
            }
            rect.deinit(self.allocator);
        }
        if (self.last_search) |search| {
            self.allocator.free(search);
        }

        // プロンプトバッファのクリーンアップ
        if (self.prompt_buffer) |prompt| {
            self.allocator.free(prompt);
        }

        // 入力バッファのクリーンアップ
        self.input_buffer.deinit(self.allocator);

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

        // 端末サイズが0の場合は何もしない
        if (self.terminal.height == 0) return;

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

        // Undoスタックが空になったら元の状態に戻ったのでmodified=false
        if (self.undo_stack.items.len == 0) {
            self.modified = false;
        } else {
            self.modified = true;
        }

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

        // Undoスタックが空でなければ変更されている
        // （Redoによって変更が再適用されたため）
        self.modified = (self.undo_stack.items.len > 0);

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
        const max_screen_lines = if (self.terminal.height >= 1) self.terminal.height - 1 else 0;
        if (max_screen_lines == 0 or line < max_screen_lines) {
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
        // 古いプロンプトバッファを解放
        if (self.prompt_buffer) |old_prompt| {
            self.allocator.free(old_prompt);
            self.prompt_buffer = null;
        }

        // モード別に処理を分岐
        switch (self.mode) {
            .filename_input => {
                // ファイル名入力モード：文字とバックスペース、Enter、C-gのみ受け付ける
                switch (key) {
                    .char => |c| {
                        // 入力バッファに文字を追加
                        try self.input_buffer.append(self.allocator, c);
                        // プロンプトを更新
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Write file: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.view.setError(prompt);
                        } else {
                            self.view.setError("Write file: ");
                        }
                    },
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: キャンセル
                                self.mode = .normal;
                                self.quit_after_save = false; // フラグをリセット
                                self.input_buffer.clearRetainingCapacity();
                                self.view.clearError();
                            },
                            else => {},
                        }
                    },
                    .backspace => {
                        // バックスペース：最後の文字を削除
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Write file: {s}", .{self.input_buffer.items}) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.view.setError(prompt);
                            } else {
                                self.view.setError("Write file: ");
                            }
                        }
                    },
                    .enter => {
                        // Enter: ファイル名確定
                        if (self.input_buffer.items.len > 0) {
                            // 既存のfilenameがあれば解放
                            if (self.filename) |old| {
                                self.allocator.free(old);
                            }
                            // 新しいfilenameを設定
                            self.filename = try self.allocator.dupe(u8, self.input_buffer.items);
                            self.input_buffer.clearRetainingCapacity();

                            // ファイルを保存
                            try self.saveFile();
                            self.mode = .normal;

                            // quit_after_saveフラグが立っている場合は終了
                            if (self.quit_after_save) {
                                self.quit_after_save = false;
                                self.running = false;
                            }
                        }
                    },
                    else => {},
                }
                return;
            },
            .isearch_forward, .isearch_backward => {
                // インクリメンタルサーチモード
                const is_forward = (self.mode == .isearch_forward);
                switch (key) {
                    .char => |c| {
                        // 検索文字列に文字を追加
                        try self.input_buffer.append(self.allocator, c);
                        // プロンプトを更新して検索実行
                        const prefix = if (is_forward) "I-search: " else "I-search backward: ";
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, self.input_buffer.items }) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.view.setError(prompt);
                        }
                        // 検索実行（現在位置から）
                        if (self.input_buffer.items.len > 0) {
                            self.view.setSearchHighlight(self.input_buffer.items);
                            try self.performSearch(is_forward, false);
                        }
                    },
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: 検索キャンセル、元の位置に戻る
                                if (self.search_start_pos) |start_pos| {
                                    self.setCursorToPos(start_pos);
                                }
                                self.mode = .normal;
                                self.input_buffer.clearRetainingCapacity();
                                self.view.setSearchHighlight(null); // ハイライトクリア
                                self.view.clearError();
                            },
                            's' => {
                                // C-s: 次の一致を検索（前方）
                                if (self.input_buffer.items.len > 0) {
                                    self.view.setSearchHighlight(self.input_buffer.items);
                                    try self.performSearch(true, true);
                                }
                            },
                            'r' => {
                                // C-r: 前の一致を検索（後方）
                                if (self.input_buffer.items.len > 0) {
                                    self.view.setSearchHighlight(self.input_buffer.items);
                                    try self.performSearch(false, true);
                                }
                            },
                            else => {},
                        }
                    },
                    .backspace => {
                        // バックスペース：検索文字列の最後の文字を削除
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            const prefix = if (is_forward) "I-search: " else "I-search backward: ";
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, self.input_buffer.items }) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.view.setError(prompt);
                            } else {
                                self.view.clearError();
                            }
                            // 検索文字列が残っていれば再検索
                            if (self.input_buffer.items.len > 0) {
                                self.view.setSearchHighlight(self.input_buffer.items);
                                // 開始位置から再検索
                                if (self.search_start_pos) |start_pos| {
                                    self.setCursorToPos(start_pos);
                                }
                                try self.performSearch(is_forward, false);
                            } else {
                                // 検索文字列が空になったら開始位置に戻る
                                self.view.setSearchHighlight(null); // ハイライトクリア
                                if (self.search_start_pos) |start_pos| {
                                    self.setCursorToPos(start_pos);
                                }
                            }
                        }
                    },
                    .enter => {
                        // Enter: 検索確定（現在位置で確定）
                        // 検索文字列を保存
                        if (self.input_buffer.items.len > 0) {
                            if (self.last_search) |old_search| {
                                self.allocator.free(old_search);
                            }
                            self.last_search = self.allocator.dupe(u8, self.input_buffer.items) catch null;
                        }
                        self.mode = .normal;
                        self.input_buffer.clearRetainingCapacity();
                        self.view.setSearchHighlight(null); // ハイライトクリア
                        self.view.clearError();
                    },
                    else => {},
                }
                return;
            },
            .prefix_x => {
                // C-xプレフィックスモード：次のCtrlキーを待つ
                self.mode = .normal; // デフォルトでnormalに戻る
                switch (key) {
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: キャンセル
                                self.view.clearError();
                            },
                            's' => {
                                // C-x C-s: 保存
                                if (self.filename == null) {
                                    // 新規ファイル：ファイル名入力モードへ
                                    self.mode = .filename_input;
                                    self.quit_after_save = false; // 保存後は終了しない
                                    self.input_buffer.clearRetainingCapacity();
                                    self.view.setError("Write file: ");
                                } else {
                                    // 既存ファイル：そのまま保存
                                    try self.saveFile();
                                }
                            },
                            'c' => {
                                // C-x C-c: 終了
                                if (self.modified) {
                                    if (self.filename) |name| {
                                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Save changes to {s}? (y/n/c): ", .{name}) catch null;
                                        if (self.prompt_buffer) |prompt| {
                                            self.view.setError(prompt);
                                        } else {
                                            self.view.setError("Save changes? (y/n/c): ");
                                        }
                                    } else {
                                        self.view.setError("Save changes? (y/n/c): ");
                                    }
                                    self.mode = .quit_confirm;
                                } else {
                                    self.running = false;
                                }
                            },
                            else => {
                                self.view.setError("Unknown command");
                            },
                        }
                    },
                    .char => |c| {
                        // C-x の後に通常文字を受け付ける（C-x h、C-x r など）
                        switch (c) {
                            'h' => self.selectAll(), // C-x h 全選択
                            'r' => {
                                // C-x r: 矩形コマンドプレフィックス
                                self.mode = .prefix_r;
                                return;
                            },
                            else => {
                                self.view.setError("Unknown command");
                            },
                        }
                    },
                    else => {
                        self.view.setError("Expected C-x C-[key]");
                    },
                }
                return;
            },
            .quit_confirm => {
                // 終了確認モード：y/n/cのみ受け付ける
                switch (key) {
                    .char => |c| {
                        switch (c) {
                            'y', 'Y' => {
                                // 保存して終了
                                if (self.filename == null) {
                                    // 新規ファイル：ファイル名入力モードへ
                                    self.mode = .filename_input;
                                    self.quit_after_save = true; // 保存後に終了
                                    self.input_buffer.clearRetainingCapacity();
                                    self.view.setError("Write file: ");
                                } else {
                                    self.saveFile() catch |err| {
                                        self.view.setError(@errorName(err));
                                        self.mode = .normal;
                                        return;
                                    };
                                    self.running = false;
                                }
                            },
                            'n', 'N' => {
                                // 保存せずに終了
                                self.running = false;
                            },
                            'c', 'C' => {
                                // キャンセル
                                self.mode = .normal;
                                self.view.clearError();
                            },
                            else => {
                                // 無効な入力
                                self.view.setError("Please answer: (y)es, (n)o, (c)ancel");
                            },
                        }
                    },
                    .ctrl => |c| {
                        // Ctrl-Gでもキャンセル
                        if (c == 'g') {
                            self.mode = .normal;
                            self.view.clearError();
                        }
                    },
                    else => {},
                }
                return;
            },
            .prefix_r => {
                // C-x r プレフィックスモード：矩形コマンドを受け付ける
                self.mode = .normal; // 次のキーの後は通常モードに戻る
                switch (key) {
                    .char => |c| {
                        switch (c) {
                            'k' => self.killRectangle(), // C-x r k 矩形削除
                            'y' => self.yankRectangle(), // C-x r y 矩形貼り付け
                            't' => {
                                // C-x r t 矩形文字列挿入（未実装）
                                self.view.setError("C-x r t not implemented yet");
                            },
                            else => {
                                self.view.setError("Unknown rectangle command");
                            },
                        }
                    },
                    .ctrl => |c| {
                        // Ctrl-Gでキャンセル
                        if (c == 'g') {
                            self.view.clearError();
                        } else {
                            self.view.setError("Unknown rectangle command");
                        }
                    },
                    else => {
                        self.view.setError("Unknown rectangle command");
                    },
                }
                return;
            },
            .normal => {},
        }

        // 通常モード
        switch (key) {
            // Ctrl キー
            .ctrl => |c| {
                switch (c) {
                    0, '@' => self.setMark(), // C-Space / C-@ マーク設定
                    'x' => {
                        // C-x プレフィックスキー
                        self.mode = .prefix_x;
                        self.view.setError("C-x-");
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
                    'g' => self.view.clearError(), // C-g キャンセル
                    'u' => try self.undo(), // C-u Undo
                    31, '/' => try self.redo(), // C-/ または C-_ Redo
                    's' => {
                        // C-s インクリメンタルサーチ（前方）
                        // 前回の検索文字列がある場合は、それを使って次の一致を検索
                        if (self.last_search) |search_str| {
                            // input_bufferに前回の検索文字列をコピー
                            self.input_buffer.clearRetainingCapacity();
                            self.input_buffer.appendSlice(self.allocator, search_str) catch {};
                            self.view.setSearchHighlight(search_str);
                            try self.performSearch(true, true); // skip_current=true で次を検索
                            // 検索ハイライトは残すが、プロンプトはクリア（Emacs風）
                            self.view.clearError();
                        } else {
                            // 新規検索開始
                            self.mode = .isearch_forward;
                            self.search_start_pos = self.view.getCursorBufferPos();
                            self.input_buffer.clearRetainingCapacity();
                            self.view.setError("I-search: ");
                        }
                    },
                    'r' => {
                        // C-r インクリメンタルサーチ（後方）
                        self.mode = .isearch_backward;
                        self.search_start_pos = self.view.getCursorBufferPos();
                        self.input_buffer.clearRetainingCapacity();
                        self.view.setError("I-search backward: ");
                    },
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
                    '<' => self.view.moveToBufferStart(), // M-< ファイル先頭
                    '>' => self.view.moveToBufferEnd(&self.terminal), // M-> ファイル終端
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

        // 改行削除の場合、削除後のカーソル位置を計算
        const is_newline = std.mem.indexOf(u8, deleted, "\n") != null;

        try self.buffer.delete(char_start, char_len);
        errdefer self.buffer.insertSlice(char_start, deleted) catch unreachable; // rollback失敗は致命的
        try self.recordDelete(char_start, deleted, pos); // 編集前のカーソル位置を記録

        self.modified = true;
        // 改行削除の場合は末尾まで再描画
        if (is_newline) {
            self.view.markDirty(current_line, null);
        } else {
            self.view.markDirty(current_line, current_line);
        }
        self.allocator.free(deleted);

        // カーソル移動
        if (self.view.cursor_x >= char_width) {
            self.view.cursor_x -= char_width;
        } else if (self.view.cursor_y > 0) {
            self.view.cursor_y -= 1;
            if (is_newline) {
                // 改行削除の場合、削除位置（char_start）が新しいカーソル位置
                // そこまでの行内の表示幅を計算
                const new_line = self.getCurrentLine();
                if (self.buffer.getLineStart(self.view.top_line + new_line)) |line_start| {
                    var x: usize = 0;
                    var width_iter = PieceIterator.init(&self.buffer);
                    width_iter.seek(line_start);
                    while (width_iter.global_pos < char_start) {
                        const cluster = width_iter.nextGraphemeCluster() catch break;
                        if (cluster) |gc| {
                            if (gc.base == '\n') break;
                            x += gc.width;
                        } else {
                            break;
                        }
                    }
                    self.view.cursor_x = x;
                }
            } else {
                self.view.moveToLineEnd();
            }
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

    // 全選択（C-x h）：バッファの先頭にマークを設定し、終端にカーソルを移動
    fn selectAll(self: *Editor) void {
        // バッファの先頭（位置0）にマークを設定
        self.mark_pos = 0;
        // カーソルをバッファの終端に移動
        self.view.moveToBufferEnd(&self.terminal);
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

    // インクリメンタルサーチ実行
    // forward: true=前方検索、false=後方検索
    // skip_current: true=現在位置をスキップして次を検索、false=現在位置から検索
    fn performSearch(self: *Editor, forward: bool, skip_current: bool) !void {
        const search_str = self.input_buffer.items;
        if (search_str.len == 0) return;

        // バッファの全内容を取得
        const content = try self.extractText(0, self.buffer.total_len);
        defer self.allocator.free(content);

        const start_pos = self.view.getCursorBufferPos();
        const search_from = if (skip_current and start_pos < content.len) start_pos + 1 else start_pos;

        if (forward) {
            // 前方検索
            if (search_from < content.len) {
                if (std.mem.indexOf(u8, content[search_from..], search_str)) |offset| {
                    const found_pos = search_from + offset;
                    self.setCursorToPos(found_pos);
                    return;
                }
            }
            // 見つからなかったら先頭から検索（ラップアラウンド）
            if (start_pos > 0) {
                if (std.mem.indexOf(u8, content[0..start_pos], search_str)) |offset| {
                    self.setCursorToPos(offset);
                    return;
                }
            }
            // それでも見つからない
            self.view.setError("Failing I-search");
        } else {
            // 後方検索
            if (search_from > 0) {
                if (std.mem.lastIndexOf(u8, content[0..search_from], search_str)) |offset| {
                    self.setCursorToPos(offset);
                    return;
                }
            }
            // 見つからなかったら末尾から検索（ラップアラウンド）
            if (start_pos < content.len) {
                if (std.mem.lastIndexOf(u8, content[start_pos..], search_str)) |offset| {
                    self.setCursorToPos(start_pos + offset);
                    return;
                }
            }
            // それでも見つからない
            self.view.setError("Failing I-search backward");
        }
    }

    // 矩形領域の削除（C-x r k）
    fn killRectangle(self: *Editor) void {
        _ = self;
        // TODO: 矩形領域の削除を実装
    }

    // 矩形の貼り付け（C-x r y）
    fn yankRectangle(self: *Editor) void {
        _ = self;
        // TODO: 矩形の貼り付けを実装
    }
};
