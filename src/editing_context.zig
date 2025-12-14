// ============================================================================
// EditingContext - テキスト編集の核心部分
// ============================================================================
//
// 【設計思想】
// EditingContextはテキスト編集に必要な状態と操作を完全にカプセル化する。
// UIやViewに一切依存せず、純粋なテキスト操作のみを担当する。
//
// 【責務】
// - バッファ（テキストデータ）の管理
// - カーソル位置の管理
// - 選択範囲（マーク）の管理
// - Undo/Redo履歴
// - 編集操作（挿入、削除、コピー、ペースト等）
//
// 【通知メカニズム】
// 編集が発生するとコールバック（ChangeListener）を通じて外部に通知する。
// これにより、Viewの更新やその他の副作用を完全に分離できる。
// ============================================================================

const std = @import("std");
const buffer_mod = @import("buffer");
const Buffer = buffer_mod.Buffer;
const PieceIterator = buffer_mod.PieceIterator;
const unicode = @import("unicode");

/// 変更の種類
pub const ChangeType = enum {
    insert,
    delete,
    cursor_move,
    selection_change,
};

/// 変更イベント
pub const ChangeEvent = struct {
    change_type: ChangeType,
    position: usize,
    length: usize, // insert/deleteの場合のバイト数
    line: usize, // 影響を受ける開始行
    line_end: ?usize, // 影響を受ける終了行（nullは末尾まで）
};

/// 変更を通知するためのコールバック型
pub const ChangeListener = *const fn (event: ChangeEvent, context: ?*anyopaque) void;

/// Undo/Redo用の編集操作
const EditOp = enum { insert, delete };

/// Undo/Redoエントリ
const UndoEntry = struct {
    op: EditOp,
    position: usize,
    data: []const u8,
    cursor_before: usize,
    cursor_after: usize,
    /// グループ化可能フラグ（連続入力をまとめるため）
    groupable: bool = true,
};

/// 選択範囲
pub const Selection = struct {
    start: usize,
    end: usize,

    pub fn len(self: Selection) usize {
        return if (self.end > self.start) self.end - self.start else self.start - self.end;
    }

    pub fn normalize(self: Selection) Selection {
        return if (self.start <= self.end)
            self
        else
            Selection{ .start = self.end, .end = self.start };
    }
};

/// EditingContext - UIに依存しないテキスト編集コンテキスト
pub const EditingContext = struct {
    allocator: std.mem.Allocator,
    buffer: *Buffer,
    owns_buffer: bool, // trueならdeinit時にbufferも解放

    // カーソル位置（バッファ内のバイトオフセット）
    cursor: usize,

    // 選択範囲（マーク位置、nullなら選択なし）
    mark: ?usize,

    // Kill ring（コピー/カット用バッファ）
    kill_ring: ?[]const u8,

    // Undo/Redo
    undo_stack: std.ArrayList(UndoEntry),
    redo_stack: std.ArrayList(UndoEntry),

    // 変更フラグ
    modified: bool,

    // セーブポイント（保存時のundo_stackの長さ）
    savepoint: ?usize,

    // 変更リスナー
    listeners: std.ArrayList(ListenerEntry),

    const ListenerEntry = struct {
        callback: ChangeListener,
        context: ?*anyopaque,
    };

    /// 新規バッファで初期化
    pub fn init(allocator: std.mem.Allocator) !*EditingContext {
        const buffer = try allocator.create(Buffer);
        buffer.* = try Buffer.init(allocator);
        return initWithBuffer(allocator, buffer, true);
    }

    /// 既存バッファで初期化
    pub fn initWithBuffer(allocator: std.mem.Allocator, buffer: *Buffer, owns_buffer: bool) !*EditingContext {
        const ctx = try allocator.create(EditingContext);
        ctx.* = EditingContext{
            .allocator = allocator,
            .buffer = buffer,
            .owns_buffer = owns_buffer,
            .cursor = 0,
            .mark = null,
            .kill_ring = null,
            .undo_stack = .{},
            .redo_stack = .{},
            .modified = false,
            .savepoint = 0, // 初期状態はセーブポイント0
            .listeners = .{},
        };
        return ctx;
    }

    pub fn deinit(self: *EditingContext) void {
        // Kill ring解放
        if (self.kill_ring) |kr| {
            self.allocator.free(kr);
        }

        // Undoスタック解放
        for (self.undo_stack.items) |entry| {
            self.allocator.free(entry.data);
        }
        self.undo_stack.deinit(self.allocator);

        // Redoスタック解放
        for (self.redo_stack.items) |entry| {
            self.allocator.free(entry.data);
        }
        self.redo_stack.deinit(self.allocator);

        // リスナー解放
        self.listeners.deinit(self.allocator);

        // バッファ解放（所有している場合）
        if (self.owns_buffer) {
            self.buffer.deinit();
            self.allocator.destroy(self.buffer);
        }

        self.allocator.destroy(self);
    }

    // ========================================
    // リスナー管理
    // ========================================

    pub fn addListener(self: *EditingContext, callback: ChangeListener, context: ?*anyopaque) !void {
        try self.listeners.append(self.allocator, .{ .callback = callback, .context = context });
    }

    pub fn removeListener(self: *EditingContext, callback: ChangeListener) void {
        var i: usize = 0;
        while (i < self.listeners.items.len) {
            if (self.listeners.items[i].callback == callback) {
                _ = self.listeners.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn notifyChange(self: *EditingContext, event: ChangeEvent) void {
        for (self.listeners.items) |entry| {
            entry.callback(event, entry.context);
        }
    }

    // ========================================
    // 基本情報
    // ========================================

    pub fn len(self: *EditingContext) usize {
        return self.buffer.len();
    }

    pub fn lineCount(self: *EditingContext) usize {
        return self.buffer.lineCount();
    }

    pub fn getSelection(self: *EditingContext) ?Selection {
        const m = self.mark orelse return null;
        if (m == self.cursor) return null;
        return Selection{ .start = m, .end = self.cursor };
    }

    pub fn getCursorLine(self: *EditingContext) usize {
        return self.buffer.findLineByPos(self.cursor);
    }

    pub fn getCursorColumn(self: *EditingContext) usize {
        return self.buffer.findColumnByPos(self.cursor);
    }

    // ========================================
    // カーソル操作
    // ========================================

    pub fn setCursor(self: *EditingContext, pos: usize) void {
        const old_cursor = self.cursor;
        self.cursor = @min(pos, self.buffer.len());
        if (old_cursor != self.cursor) {
            self.notifyChange(.{
                .change_type = .cursor_move,
                .position = self.cursor,
                .length = 0,
                .line = self.buffer.findLineByPos(self.cursor),
                .line_end = null,
            });
        }
    }

    pub fn setMark(self: *EditingContext) void {
        if (self.mark != null) {
            self.mark = null;
        } else {
            self.mark = self.cursor;
        }
        self.notifyChange(.{
            .change_type = .selection_change,
            .position = self.cursor,
            .length = 0,
            .line = self.getCursorLine(),
            .line_end = null,
        });
    }

    pub fn clearMark(self: *EditingContext) void {
        if (self.mark != null) {
            self.mark = null;
            self.notifyChange(.{
                .change_type = .selection_change,
                .position = self.cursor,
                .length = 0,
                .line = self.getCursorLine(),
                .line_end = null,
            });
        }
    }

    // ========================================
    // カーソル移動（grapheme cluster対応）
    // ========================================

    /// 次のgrapheme clusterへ移動（C-f）
    pub fn moveForward(self: *EditingContext) void {
        if (self.cursor >= self.buffer.len()) return;

        var iter = PieceIterator.init(self.buffer);
        iter.seek(self.cursor);

        const cluster = iter.nextGraphemeCluster() catch {
            // 不正なUTF-8の場合は1バイト進む
            self.setCursor(self.cursor + 1);
            return;
        };

        if (cluster) |gc| {
            self.setCursor(self.cursor + gc.byte_len);
        }
    }

    /// 前のgrapheme clusterへ移動（C-b）
    pub fn moveBackward(self: *EditingContext) void {
        if (self.cursor == 0) return;

        var iter = PieceIterator.init(self.buffer);
        var char_start: usize = 0;

        while (iter.global_pos < self.cursor) {
            char_start = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch {
                _ = iter.next();
                continue;
            };
            if (cluster == null) break;
        }

        self.setCursor(char_start);
    }

    /// 次の行へ移動（C-n）
    pub fn moveNextLine(self: *EditingContext) void {
        const current_line = self.getCursorLine();
        if (current_line >= self.lineCount()) return;

        const current_line_start = self.buffer.getLineStart(current_line) orelse 0;
        const column = self.cursor - current_line_start;

        if (self.buffer.getLineStart(current_line + 1)) |next_line_start| {
            const next_line_end = self.buffer.findNextLineFromPos(next_line_start);
            const next_line_len = if (next_line_end > next_line_start) next_line_end - next_line_start - 1 else 0;
            const new_column = @min(column, next_line_len);
            self.setCursor(next_line_start + new_column);
        }
    }

    /// 前の行へ移動（C-p）
    pub fn movePrevLine(self: *EditingContext) void {
        const current_line = self.getCursorLine();
        if (current_line == 0) return;

        const current_line_start = self.buffer.getLineStart(current_line) orelse 0;
        const column = self.cursor - current_line_start;

        if (self.buffer.getLineStart(current_line - 1)) |prev_line_start| {
            const prev_line_end = self.buffer.findNextLineFromPos(prev_line_start);
            const prev_line_len = if (prev_line_end > prev_line_start) prev_line_end - prev_line_start - 1 else 0;
            const new_column = @min(column, prev_line_len);
            self.setCursor(prev_line_start + new_column);
        }
    }

    /// 行頭へ移動（C-a）
    pub fn moveBeginningOfLine(self: *EditingContext) void {
        const line = self.getCursorLine();
        if (self.buffer.getLineStart(line)) |start| {
            self.setCursor(start);
        }
    }

    /// 行末へ移動（C-e）
    pub fn moveEndOfLine(self: *EditingContext) void {
        const end_pos = self.buffer.findNextLineFromPos(self.cursor);
        // 改行文字の前に移動（改行があれば）
        if (end_pos > 0) {
            var iter = PieceIterator.init(self.buffer);
            iter.seek(end_pos - 1);
            const byte = iter.next();
            if (byte == '\n') {
                self.setCursor(end_pos - 1);
            } else {
                self.setCursor(end_pos);
            }
        } else {
            self.setCursor(end_pos);
        }
    }

    /// バッファ先頭へ移動（M-<）
    pub fn moveBeginningOfBuffer(self: *EditingContext) void {
        self.setCursor(0);
    }

    /// バッファ末尾へ移動（M->）
    pub fn moveEndOfBuffer(self: *EditingContext) void {
        self.setCursor(self.buffer.len());
    }

    /// 次の単語へ移動（M-f）
    pub fn moveForwardWord(self: *EditingContext) void {
        var pos = self.cursor;
        const buf_len = self.buffer.len();

        // 現在の単語をスキップ
        while (pos < buf_len) {
            var iter = PieceIterator.init(self.buffer);
            iter.seek(pos);
            const byte = iter.next() orelse break;
            if (!isWordChar(byte)) break;
            pos += 1;
        }

        // 非単語文字をスキップ
        while (pos < buf_len) {
            var iter = PieceIterator.init(self.buffer);
            iter.seek(pos);
            const byte = iter.next() orelse break;
            if (isWordChar(byte)) break;
            pos += 1;
        }

        self.setCursor(pos);
    }

    /// 前の単語へ移動（M-b）
    pub fn moveBackwardWord(self: *EditingContext) void {
        if (self.cursor == 0) return;
        var pos = self.cursor;

        // 非単語文字をスキップ
        while (pos > 0) {
            pos -= 1;
            var iter = PieceIterator.init(self.buffer);
            iter.seek(pos);
            const byte = iter.next() orelse continue;
            if (isWordChar(byte)) {
                pos += 1;
                break;
            }
        }

        // 単語の先頭まで戻る
        while (pos > 0) {
            pos -= 1;
            var iter = PieceIterator.init(self.buffer);
            iter.seek(pos);
            const byte = iter.next() orelse continue;
            if (!isWordChar(byte)) {
                pos += 1;
                break;
            }
        }

        self.setCursor(pos);
    }

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    // ========================================
    // 挿入操作
    // ========================================

    pub fn insert(self: *EditingContext, text: []const u8) !void {
        if (text.len == 0) return;

        const pos = self.cursor;
        const line = self.buffer.findLineByPos(pos);

        // バッファに挿入
        try self.buffer.insertSlice(pos, text);

        // Undo記録
        try self.recordInsert(pos, text);

        // カーソル移動
        self.cursor = pos + text.len;
        self.modified = true;

        // 改行を含むかで影響範囲を決定
        const has_newline = std.mem.indexOf(u8, text, "\n") != null;
        self.notifyChange(.{
            .change_type = .insert,
            .position = pos,
            .length = text.len,
            .line = line,
            .line_end = if (has_newline) null else line,
        });
    }

    pub fn insertChar(self: *EditingContext, char: u8) !void {
        const buf = [_]u8{char};
        try self.insert(&buf);
    }

    pub fn insertCodepoint(self: *EditingContext, codepoint: u21) !void {
        var buf: [4]u8 = undefined;
        const byte_len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidUtf8;
        try self.insert(buf[0..byte_len]);
    }

    // ========================================
    // 削除操作
    // ========================================

    pub fn delete(self: *EditingContext, count: usize) !void {
        if (count == 0) return;
        const pos = self.cursor;
        if (pos >= self.buffer.len()) return;

        const actual_count = @min(count, self.buffer.len() - pos);
        const line = self.buffer.findLineByPos(pos);

        // 削除するテキストを保存
        const deleted = try self.extractText(pos, actual_count);
        errdefer self.allocator.free(deleted);

        // 改行を含むかで影響範囲を決定（freeする前に判定）
        const has_newline = std.mem.indexOf(u8, deleted, "\n") != null;

        // バッファから削除
        try self.buffer.delete(pos, actual_count);

        // Undo記録（recordDeleteOp内でコピーされる）
        try self.recordDelete(pos, deleted);

        // recordDeleteが成功したらextractTextの結果を解放
        self.allocator.free(deleted);

        self.modified = true;
        self.notifyChange(.{
            .change_type = .delete,
            .position = pos,
            .length = actual_count,
            .line = line,
            .line_end = if (has_newline) null else line,
        });
    }

    pub fn backspace(self: *EditingContext) !void {
        if (self.cursor == 0) return;

        // 前のgrapheme clusterを見つける
        var iter = PieceIterator.init(self.buffer);
        var char_start: usize = 0;
        var char_len: usize = 1;

        while (iter.global_pos < self.cursor) {
            char_start = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch {
                _ = iter.next();
                char_len = 1;
                continue;
            };
            if (cluster) |gc| {
                char_len = gc.byte_len;
            } else {
                break;
            }
        }

        // カーソルを移動してから削除
        self.cursor = char_start;
        try self.delete(char_len);
    }

    pub fn deleteChar(self: *EditingContext) !void {
        if (self.cursor >= self.buffer.len()) return;

        // 現在位置のgrapheme clusterのサイズを取得
        var iter = PieceIterator.init(self.buffer);
        iter.seek(self.cursor);

        const cluster = iter.nextGraphemeCluster() catch {
            try self.delete(1);
            return;
        };

        if (cluster) |gc| {
            try self.delete(gc.byte_len);
        }
    }

    // ========================================
    // 行操作
    // ========================================

    pub fn killLine(self: *EditingContext) !void {
        const pos = self.cursor;
        const end_pos = self.buffer.findNextLineFromPos(pos);
        const count = end_pos - pos;
        if (count > 0) {
            // Kill ringに保存
            const deleted = try self.extractText(pos, count);
            if (self.kill_ring) |old| {
                self.allocator.free(old);
            }
            self.kill_ring = deleted;

            try self.delete(count);
        }
    }

    pub fn duplicateLine(self: *EditingContext) !void {
        const line = self.getCursorLine();
        const line_start = self.buffer.getLineStart(line) orelse return;
        const line_end = self.buffer.findNextLineFromPos(line_start);
        const line_len = line_end - line_start;

        if (line_len == 0) return;

        const content = try self.extractText(line_start, line_len);
        defer self.allocator.free(content);

        // 行末に挿入
        const old_cursor = self.cursor;
        self.cursor = line_end;

        if (line_end >= self.buffer.len()) {
            // ファイル末尾なら改行を追加してから
            try self.insertChar('\n');
            try self.insert(content);
        } else {
            try self.insert(content);
        }

        // カーソルを次の行の同じ位置に
        self.cursor = old_cursor + line_len;
    }

    // ========================================
    // 選択範囲操作
    // ========================================

    pub fn copyRegion(self: *EditingContext) !void {
        const sel = self.getSelection() orelse return;
        const norm = sel.normalize();

        if (self.kill_ring) |old| {
            self.allocator.free(old);
        }
        self.kill_ring = try self.extractText(norm.start, norm.len());
        self.mark = null;

        self.notifyChange(.{
            .change_type = .selection_change,
            .position = self.cursor,
            .length = 0,
            .line = self.getCursorLine(),
            .line_end = null,
        });
    }

    pub fn killRegion(self: *EditingContext) !void {
        const sel = self.getSelection() orelse return;
        const norm = sel.normalize();

        if (self.kill_ring) |old| {
            self.allocator.free(old);
        }
        self.kill_ring = try self.extractText(norm.start, norm.len());

        self.cursor = norm.start;
        try self.delete(norm.len());
        self.mark = null;
    }

    pub fn yank(self: *EditingContext) !void {
        const text = self.kill_ring orelse return;
        try self.insert(text);
    }

    pub fn selectAll(self: *EditingContext) void {
        self.mark = 0;
        self.cursor = self.buffer.len();
        self.notifyChange(.{
            .change_type = .selection_change,
            .position = self.cursor,
            .length = 0,
            .line = 0,
            .line_end = null,
        });
    }

    // ========================================
    // Undo/Redo
    // ========================================

    /// Undo/Redo履歴をクリア
    pub fn clearUndoHistory(self: *EditingContext) void {
        for (self.undo_stack.items) |entry| {
            self.allocator.free(entry.data);
        }
        self.undo_stack.clearRetainingCapacity();

        for (self.redo_stack.items) |entry| {
            self.allocator.free(entry.data);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    /// Undoの結果を表す構造体
    pub const UndoResult = struct {
        cursor_pos: usize,
    };

    pub fn undo(self: *EditingContext) !bool {
        const result = try self.undoWithCursor();
        return result != null;
    }

    /// Undo操作を行い、復元すべきカーソル位置を返す
    pub fn undoWithCursor(self: *EditingContext) !?UndoResult {
        const entry = self.undo_stack.pop() orelse return null;

        switch (entry.op) {
            .insert => {
                // 挿入を取り消す = 削除
                try self.buffer.delete(entry.position, entry.data.len);
            },
            .delete => {
                // 削除を取り消す = 挿入
                try self.buffer.insertSlice(entry.position, entry.data);
            },
        }

        // Redoスタックに追加
        try self.redo_stack.append(self.allocator, entry);

        // カーソル復元
        self.cursor = entry.cursor_before;

        // セーブポイントに戻ったらmodifiedをfalseに
        if (self.savepoint) |sp| {
            self.modified = (self.undo_stack.items.len != sp);
        } else {
            // セーブポイントがない場合は、スタックが空なら未変更
            self.modified = (self.undo_stack.items.len != 0);
        }

        const line = self.buffer.findLineByPos(entry.position);
        self.notifyChange(.{
            .change_type = if (entry.op == .insert) .delete else .insert,
            .position = entry.position,
            .length = entry.data.len,
            .line = line,
            .line_end = null,
        });

        return .{ .cursor_pos = entry.cursor_before };
    }

    pub fn redo(self: *EditingContext) !bool {
        const result = try self.redoWithCursor();
        return result != null;
    }

    /// Redo操作を行い、復元すべきカーソル位置を返す
    pub fn redoWithCursor(self: *EditingContext) !?UndoResult {
        const entry = self.redo_stack.pop() orelse return null;

        switch (entry.op) {
            .insert => {
                // 挿入を再実行
                try self.buffer.insertSlice(entry.position, entry.data);
            },
            .delete => {
                // 削除を再実行
                try self.buffer.delete(entry.position, entry.data.len);
            },
        }

        // Undoスタックに追加
        try self.undo_stack.append(self.allocator, entry);

        // カーソル復元
        self.cursor = entry.cursor_after;

        // セーブポイントと比較してmodifiedを更新
        if (self.savepoint) |sp| {
            self.modified = (self.undo_stack.items.len != sp);
        } else {
            self.modified = (self.undo_stack.items.len != 0);
        }

        const line = self.buffer.findLineByPos(entry.position);
        self.notifyChange(.{
            .change_type = if (entry.op == .insert) .insert else .delete,
            .position = entry.position,
            .length = entry.data.len,
            .line = line,
            .line_end = null,
        });

        return .{ .cursor_pos = entry.cursor_after };
    }

    // ========================================
    // Undo記録（外部から呼び出し可能）
    // ========================================
    //
    // 【グループ化の仕組み】
    // 連続した入力/削除を1つのUndo操作にまとめる:
    // - 挿入: "abc"と入力 → 1回のUndoで"abc"を削除
    // - 削除: Backspace連打 → 1回のUndoで復元
    //
    // 【グループ化条件】
    // - 同じ操作タイプ（insert or delete）
    // - 位置が連続している（直前の操作の直後）
    // - 改行を含まない（改行でグループを分割）
    //
    // 【cursor_before/cursor_after】
    // Undo/Redo時のカーソル復元に使用:
    // - cursor_before: 操作前の位置（Undoで復元）
    // - cursor_after: 操作後の位置（Redoで復元）

    /// 挿入操作をUndo履歴に記録
    pub fn recordInsertOp(self: *EditingContext, pos: usize, text: []const u8, cursor_pos_before: usize) !void {
        // 連続した挿入操作をグループ化
        // 条件: 直前の操作も挿入で、位置が連続している場合
        if (self.undo_stack.items.len > 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.op == .insert and last.groupable and
                last.position + last.data.len == pos and
                !containsNewline(text) and !containsNewline(last.data))
            {
                // 既存のエントリにデータを追加
                const new_len = last.data.len + text.len;
                const new_data = try self.allocator.alloc(u8, new_len);
                @memcpy(new_data[0..last.data.len], last.data);
                @memcpy(new_data[last.data.len..], text);
                self.allocator.free(last.data);
                last.data = new_data;
                last.cursor_after = pos + text.len;
                // cursor_beforeは最初の文字入力時のまま保持
                return;
            }
        }

        self.clearRedoStack();
        const data_copy = try self.allocator.dupe(u8, text);
        try self.undo_stack.append(self.allocator, .{
            .op = .insert,
            .position = pos,
            .data = data_copy,
            .cursor_before = cursor_pos_before,
            .cursor_after = pos + text.len,
        });
        self.modified = true;
    }

    /// 削除操作をUndo履歴に記録（外部から呼び出し用）
    /// textはコピーされるので、呼び出し元でfreeしても問題ない
    /// 連続した削除はグループ化される
    pub fn recordDeleteOp(self: *EditingContext, pos: usize, text: []const u8, cursor_pos_before: usize) !void {
        // 連続した削除操作をグループ化
        // 条件: 直前の操作も削除で、位置が連続している場合（Backspace）
        if (self.undo_stack.items.len > 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.op == .delete and last.groupable and
                !containsNewline(text) and !containsNewline(last.data))
            {
                // Backspaceの場合: 削除位置が直前のエントリの直前
                if (pos + text.len == last.position) {
                    // 先頭に追加（Backspaceは逆順に文字を削除）
                    const new_len = last.data.len + text.len;
                    const new_data = try self.allocator.alloc(u8, new_len);
                    @memcpy(new_data[0..text.len], text);
                    @memcpy(new_data[text.len..], last.data);
                    self.allocator.free(last.data);
                    last.data = new_data;
                    last.position = pos;
                    last.cursor_after = pos;
                    // cursor_beforeは最初の削除時のまま保持
                    return;
                }
                // Delete (C-d)の場合: 削除位置が同じ
                if (pos == last.position) {
                    // 末尾に追加
                    const new_len = last.data.len + text.len;
                    const new_data = try self.allocator.alloc(u8, new_len);
                    @memcpy(new_data[0..last.data.len], last.data);
                    @memcpy(new_data[last.data.len..], text);
                    self.allocator.free(last.data);
                    last.data = new_data;
                    // cursor_before/afterは変わらない
                    return;
                }
            }
        }

        self.clearRedoStack();
        const data_copy = try self.allocator.dupe(u8, text);
        try self.undo_stack.append(self.allocator, .{
            .op = .delete,
            .position = pos,
            .data = data_copy,
            .cursor_before = cursor_pos_before,
            .cursor_after = pos,
        });
        self.modified = true;
    }

    /// 置換操作をUndo履歴に記録（delete + insertを1つの操作として）
    /// 両テキストはコピーされるので、呼び出し元でfreeしても問題ない
    pub fn recordReplaceOp(self: *EditingContext, pos: usize, old_text: []const u8, new_text: []const u8, cursor_pos_before: usize) !void {
        // 置換は「削除」として記録（undoすると old_text を挿入）
        // new_text は別途 Bufferに直接挿入されているので、ここでは old_text のみ保持
        self.clearRedoStack();

        // 削除 -> 挿入 の順に2つのエントリとして記録
        // undo時は逆順で実行される

        // 挿入分（undo時に削除される）
        const new_copy = try self.allocator.dupe(u8, new_text);
        try self.undo_stack.append(self.allocator, .{
            .op = .insert,
            .position = pos,
            .data = new_copy,
            .cursor_before = cursor_pos_before,
            .cursor_after = pos + new_text.len,
        });

        // 削除分（undo時に挿入される）
        const old_copy = try self.allocator.dupe(u8, old_text);
        try self.undo_stack.append(self.allocator, .{
            .op = .delete,
            .position = pos,
            .data = old_copy,
            .cursor_before = cursor_pos_before,
            .cursor_after = pos,
        });

        self.modified = true;
    }

    fn clearRedoStack(self: *EditingContext) void {
        for (self.redo_stack.items) |entry| {
            self.allocator.free(entry.data);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    // ========================================
    // 内部ヘルパー
    // ========================================

    /// 内部用：現在のカーソル位置でInsertを記録
    fn recordInsert(self: *EditingContext, pos: usize, text: []const u8) !void {
        try self.recordInsertOp(pos, text, self.cursor);
    }

    fn containsNewline(text: []const u8) bool {
        return std.mem.indexOf(u8, text, "\n") != null;
    }

    /// 内部用：現在のカーソル位置でDeleteを記録
    fn recordDelete(self: *EditingContext, pos: usize, text: []const u8) !void {
        try self.recordDeleteOp(pos, text, self.cursor);
    }

    fn extractText(self: *EditingContext, start: usize, length: usize) ![]const u8 {
        var result = try self.allocator.alloc(u8, length);
        var iter = PieceIterator.init(self.buffer);
        iter.seek(start);

        var i: usize = 0;
        while (i < length) : (i += 1) {
            result[i] = iter.next() orelse break;
        }
        return result[0..i];
    }
};
