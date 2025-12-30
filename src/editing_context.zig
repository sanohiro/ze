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
const config = @import("config");

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
    data: []u8, // 可変にして追記可能に
    data_capacity: usize, // 確保済み容量（追記最適化用）
    cursor_before: usize,
    cursor_after: usize,
    /// グループ化可能フラグ（連続入力をまとめるため）
    groupable: bool = true,
    /// Undoグループ識別子（nullは非グループ、同じIDは一括undo）
    group_id: ?u32 = null,

    /// データメモリを解放
    fn freeData(self: *const UndoEntry, allocator: std.mem.Allocator) void {
        if (self.data_capacity > 0) {
            allocator.free(self.data.ptr[0..self.data_capacity]);
        }
    }

    /// データ末尾に追加（償却O(1)）
    fn appendData(self: *UndoEntry, allocator: std.mem.Allocator, text: []const u8) !void {
        const new_len = self.data.len + text.len;
        if (new_len <= self.data_capacity) {
            // 容量内に収まる場合は追記のみ（再アロケーションなし）
            const full_slice = self.data.ptr[0..self.data_capacity];
            @memcpy(full_slice[self.data.len..][0..text.len], text);
            self.data = full_slice[0..new_len];
        } else {
            // 容量不足: 2倍に拡張（償却O(1)を実現）
            const new_capacity = @max(new_len * 2, 64);
            const new_data = try allocator.alloc(u8, new_capacity);
            @memcpy(new_data[0..self.data.len], self.data);
            @memcpy(new_data[self.data.len..][0..text.len], text);
            self.freeData(allocator);
            self.data = new_data[0..new_len];
            self.data_capacity = new_capacity;
        }
    }
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

    // Undoグループ管理
    current_group_id: ?u32 = null, // 現在アクティブなグループID
    next_group_id: u32 = 1, // 次に使うグループID

    // Undoグループ分け（ハイブリッド方式）
    // 1. 単語境界（スペース、記号）で新しいグループを開始
    // 2. 一定時間（300ms）経過後も新しいグループを開始
    last_record_time: i128 = 0, // 直前のUndo記録時刻（ナノ秒）


    const ListenerEntry = struct {
        callback: ChangeListener,
        context: ?*anyopaque,
    };

    /// セーブポイントと比較してmodifiedフラグを更新
    fn updateModifiedFlag(self: *EditingContext) void {
        if (self.savepoint) |sp| {
            self.modified = (self.undo_stack.items.len != sp);
        } else {
            self.modified = (self.undo_stack.items.len != 0);
        }
    }

    /// 前のgrapheme clusterの位置とバイト長を取得
    /// 最適化: 行頭からスキャン（バッファ先頭からではなくO(行の長さ)）
    /// 戻り値: .start = 開始位置, .len = バイト長
    fn findPrevGrapheme(self: *EditingContext) struct { start: usize, len: usize } {
        if (self.cursor == 0) return .{ .start = 0, .len = 0 };

        // 行頭を取得（行インデックスはキャッシュされている）
        const current_line = self.buffer.findLineByPos(self.cursor);
        const line_start = self.buffer.getLineStart(current_line) orelse 0;

        // 行頭ならさらに前の行末へ（改行1バイト）
        if (self.cursor == line_start) {
            return .{ .start = self.cursor - 1, .len = 1 };
        }

        // 行頭からカーソル位置までスキャン
        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);
        var char_start: usize = line_start;
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

        return .{ .start = char_start, .len = char_len };
    }

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
            entry.freeData(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);

        // Redoスタック解放
        for (self.redo_stack.items) |entry| {
            entry.freeData(self.allocator);
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
    // 変更通知
    // ========================================

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
        self.mark = if (self.mark != null) null else self.cursor;
        self.notifyChange(.{
            .change_type = .selection_change,
            .position = self.cursor,
            .length = 0,
            .line = self.getCursorLine(),
            .line_end = null,
        });
    }

    pub fn clearMark(self: *EditingContext) void {
        if (self.mark == null) return;
        self.mark = null;
        self.notifyChange(.{
            .change_type = .selection_change,
            .position = self.cursor,
            .length = 0,
            .line = self.getCursorLine(),
            .line_end = null,
        });
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
        const prev = self.findPrevGrapheme();
        if (prev.len > 0) {
            self.setCursor(prev.start);
        }
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
    /// 最適化: PieceIteratorを1つ作成してシーケンシャルに読み進める（O(n)）
    pub fn moveForwardWord(self: *EditingContext) void {
        var pos = self.cursor;
        const buf_len = self.buffer.len();
        if (pos >= buf_len) return;

        // イテレータを1つ作成してシーケンシャルに読み進める
        var iter = PieceIterator.init(self.buffer);
        iter.seek(pos);

        // 現在の単語をスキップ
        while (pos < buf_len) {
            const byte = iter.next() orelse break;
            if (!unicode.isWordCharByte(byte)) {
                // 非単語文字を見つけた: 第2フェーズへ
                pos += 1; // この非単語文字の位置を含める
                break;
            }
            pos += 1;
        }

        // 非単語文字をスキップして次の単語の先頭へ
        while (pos < buf_len) {
            // 次のバイトをpeek（読み込まずに確認）
            const check_pos = iter.global_pos;
            const byte = iter.next() orelse break;
            if (unicode.isWordCharByte(byte)) {
                // 単語文字を見つけた: その位置で停止
                pos = check_pos;
                break;
            }
            pos = iter.global_pos;
        }

        self.setCursor(pos);
    }

    /// 前の単語へ移動（M-b）
    /// 最適化: チャンク読み込みで後方スキャン（O(n)に改善）
    pub fn moveBackwardWord(self: *EditingContext) void {
        if (self.cursor == 0) return;
        var pos = self.cursor;

        // 後方スキャン用にチャンクを読み込む（最大256バイト）
        const look_back = @min(pos, 256);
        const scan_start = pos - look_back;

        var iter = PieceIterator.init(self.buffer);
        iter.seek(scan_start);

        // チャンクを読み込み
        var chunk: [256]u8 = undefined;
        var chunk_len: usize = 0;
        while (chunk_len < look_back) {
            chunk[chunk_len] = iter.next() orelse break;
            chunk_len += 1;
        }

        // チャンクを後方から処理（非単語文字をスキップ）
        var i = chunk_len;
        while (i > 0) {
            i -= 1;
            const byte = chunk[i];
            if (unicode.isWordCharByte(byte)) {
                i += 1;
                break;
            }
        }
        pos = scan_start + i;

        // 単語の先頭まで戻る
        while (i > 0) {
            i -= 1;
            const byte = chunk[i];
            if (!unicode.isWordCharByte(byte)) {
                i += 1;
                break;
            }
        }
        pos = scan_start + i;

        // チャンク先頭に到達した場合、さらに後方を処理
        while (i == 0 and pos > 0) {
            const next_look_back = @min(pos, 256);
            const next_scan_start = pos - next_look_back;

            iter.seek(next_scan_start);
            chunk_len = 0;
            while (chunk_len < next_look_back) {
                chunk[chunk_len] = iter.next() orelse break;
                chunk_len += 1;
            }

            i = chunk_len;
            while (i > 0) {
                i -= 1;
                const byte = chunk[i];
                if (!unicode.isWordCharByte(byte)) {
                    i += 1;
                    break;
                }
            }
            pos = next_scan_start + i;
        }

        self.setCursor(pos);
    }

    // isWordChar は unicode.isWordCharByte に共通化済み

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

    /// バックスペース: 前のgrapheme clusterを削除
    pub fn backspace(self: *EditingContext) !void {
        const prev = self.findPrevGrapheme();
        if (prev.len > 0) {
            self.cursor = prev.start;
            try self.delete(prev.len);
        }
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

        const at_eof = line_end >= self.buffer.len();
        if (at_eof) {
            // ファイル末尾なら改行を追加してから
            try self.insertChar('\n');
            try self.insert(content);
        } else {
            try self.insert(content);
        }

        // カーソルを次の行の同じ位置に
        // EOF時は追加した改行分の+1が必要
        self.cursor = old_cursor + line_len + @as(usize, if (at_eof) 1 else 0);
    }

    // ========================================
    // 選択範囲操作
    // ========================================

    pub fn copyRegion(self: *EditingContext) !void {
        const sel = self.getSelection() orelse return;
        const norm = sel.normalize();

        // 先にallocateしてからfreeする（allocate失敗時のダングリングポインタ防止）
        const new_text = try self.extractText(norm.start, norm.len());
        if (self.kill_ring) |old| {
            self.allocator.free(old);
        }
        self.kill_ring = new_text;
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

        // 先にallocateしてからfreeする（allocate失敗時のダングリングポインタ防止）
        const new_text = try self.extractText(norm.start, norm.len());
        if (self.kill_ring) |old| {
            self.allocator.free(old);
        }
        self.kill_ring = new_text;

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

    /// Undoグループを開始
    /// グループ内の操作は1回のundoで一括して元に戻る
    /// 戻り値: グループID（endUndoGroupで使用）
    pub fn beginUndoGroup(self: *EditingContext) u32 {
        const group_id = self.next_group_id;
        self.next_group_id +%= 1; // オーバーフロー時はラップ
        self.current_group_id = group_id;
        return group_id;
    }

    /// Undoグループを終了
    pub fn endUndoGroup(self: *EditingContext) void {
        self.current_group_id = null;
    }

    /// Undo/Redo履歴をクリア
    pub fn clearUndoHistory(self: *EditingContext) void {
        for (self.undo_stack.items) |entry| {
            entry.freeData(self.allocator);
        }
        self.undo_stack.clearRetainingCapacity();

        for (self.redo_stack.items) |entry| {
            entry.freeData(self.allocator);
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
    /// グループ化された操作は一括してundoされる
    pub fn undoWithCursor(self: *EditingContext) !?UndoResult {
        if (self.undo_stack.items.len == 0) return null;

        // 最後のエントリのgroup_idを確認
        const group_id = self.undo_stack.items[self.undo_stack.items.len - 1].group_id;
        var first_cursor: usize = 0;
        var last_position: usize = 0;
        var last_op: EditOp = .insert;
        var last_len: usize = 0;
        var processed: bool = false;

        // 同じgroup_idを持つ全エントリを処理
        while (self.undo_stack.items.len > 0) {
            const current = self.undo_stack.items[self.undo_stack.items.len - 1];

            // group_idが異なればループを抜ける（最初のエントリは必ず処理）
            if (processed) {
                if (group_id == null) break; // 非グループは1つだけ
                if (current.group_id != group_id) break;
            }

            const entry = self.undo_stack.pop().?;
            first_cursor = entry.cursor_before;
            last_position = entry.position;
            last_op = entry.op;
            last_len = entry.data.len;

            switch (entry.op) {
                .insert => try self.buffer.delete(entry.position, entry.data.len),
                .delete => try self.buffer.insertSlice(entry.position, entry.data),
            }

            try self.redo_stack.append(self.allocator, entry);
            processed = true;
        }

        // カーソル復元
        self.cursor = first_cursor;

        // セーブポイントに戻ったらmodifiedをfalseに
        self.updateModifiedFlag();

        const line = self.buffer.findLineByPos(last_position);
        self.notifyChange(.{
            .change_type = if (last_op == .insert) .delete else .insert,
            .position = last_position,
            .length = last_len,
            .line = line,
            .line_end = null,
        });

        return .{ .cursor_pos = first_cursor };
    }

    pub fn redo(self: *EditingContext) !bool {
        const result = try self.redoWithCursor();
        return result != null;
    }

    /// Redo操作を行い、復元すべきカーソル位置を返す
    /// グループ化された操作は一括してredoされる
    pub fn redoWithCursor(self: *EditingContext) !?UndoResult {
        if (self.redo_stack.items.len == 0) return null;

        // 最後のエントリのgroup_idを確認
        const group_id = self.redo_stack.items[self.redo_stack.items.len - 1].group_id;
        var last_cursor: usize = 0;
        var last_position: usize = 0;
        var last_op: EditOp = .insert;
        var last_len: usize = 0;
        var processed: bool = false;

        // 同じgroup_idを持つ全エントリを処理
        while (self.redo_stack.items.len > 0) {
            const current = self.redo_stack.items[self.redo_stack.items.len - 1];

            // group_idが異なればループを抜ける（最初のエントリは必ず処理）
            if (processed) {
                if (group_id == null) break; // 非グループは1つだけ
                if (current.group_id != group_id) break;
            }

            const entry = self.redo_stack.pop().?;
            last_cursor = entry.cursor_after;
            last_position = entry.position;
            last_op = entry.op;
            last_len = entry.data.len;

            switch (entry.op) {
                .insert => try self.buffer.insertSlice(entry.position, entry.data),
                .delete => try self.buffer.delete(entry.position, entry.data.len),
            }

            try self.undo_stack.append(self.allocator, entry);
            processed = true;
        }

        // カーソル復元
        self.cursor = last_cursor;

        // セーブポイントと比較してmodifiedを更新
        self.updateModifiedFlag();

        const line = self.buffer.findLineByPos(last_position);
        self.notifyChange(.{
            .change_type = if (last_op == .insert) .insert else .delete,
            .position = last_position,
            .length = last_len,
            .line = line,
            .line_end = null,
        });

        return .{ .cursor_pos = last_cursor };
    }

    // ========================================
    // Undoグループ分けルール
    // ========================================
    //
    // 【設計思想】
    // - 単語移動（M-f, M-b）と同じ境界定義を使用（unicode.isWordCharByte）
    // - VSCode風に空白は次の単語に属する
    // - 連続した入力/削除を1つのUndo操作にまとめる
    //
    // 【マージ条件】（同じUndoグループに統合）
    // 1. 両方とも単語文字（a-z, A-Z, 0-9, _）
    // 2. 両方とも非単語文字（記号の連続）
    // 3. 前が空白で新が単語文字（空白は次の単語に属す）
    //
    // 【新グループ開始】
    // - 前が非空白記号で新が単語文字 → "#" と "include"
    // - 前が単語文字で新が記号 → "hello" と ","
    // - ASCII↔非ASCII境界 → "hello" と "日本語"
    // - 300ms以上経過（タイムアウト）
    // - カーソル位置が不連続
    // - 改行を含む
    //
    // 【例】
    // "hello world" → ["hello", " world"]
    // "hello, world" → ["hello", ", world"]
    // "#include" → ["#", "include"]
    // "x = 1" → ["x", " = 1"]
    // "hello日本語" → ["hello", "日本語"]
    //
    // 【cursor_before/cursor_after】
    // Undo/Redo時のカーソル復元に使用:
    // - cursor_before: 操作前の位置（Undoで復元）
    // - cursor_after: 操作後の位置（Redoで復元）

    /// 空白文字かどうか
    fn isWhitespace(byte: u8) bool {
        return byte == ' ' or byte == '\t';
    }

    /// ASCII/非ASCII境界をまたぐかどうか（例: "hello"→"日本語"）
    fn crossesAsciiBoundary(last_byte: u8, new_byte: u8) bool {
        const last_ascii = last_byte < 0x80;
        const new_ascii = new_byte < 0x80;
        return last_ascii != new_ascii;
    }

    /// 挿入操作をUndo履歴に記録
    pub fn recordInsertOp(self: *EditingContext, pos: usize, text: []const u8, cursor_pos_before: usize) !void {
        const now = std.time.nanoTimestamp();
        const time_elapsed = now - self.last_record_time;

        // 連続した挿入操作をグループ化
        // 条件: 直前の操作も挿入で、位置が連続していて、
        //       タイムアウト内かつ単語境界をまたがない
        if (self.undo_stack.items.len > 0 and time_elapsed < config.Editor.UNDO_GROUP_TIMEOUT_NS) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.op == .insert and last.groupable and
                last.position + last.data.len == pos and
                !containsNewline(text) and !containsNewline(last.data))
            {
                // グループ分けルール（VSCode方式 + 単語移動と統一）：
                //
                // 例: "hello world" → ["hello", " world"]
                //     "hello, world" → ["hello", ", world"]
                //     "#include" → ["#", "include"]
                //     "x = 1" → ["x", " = 1"]
                const last_byte = last.data[last.data.len - 1];
                const new_byte = text[0];

                // ASCII/非ASCII境界は常に分割
                if (crossesAsciiBoundary(last_byte, new_byte)) {
                    // 新グループ開始（下のコードへフォールスルー）
                } else {
                    const new_is_word = unicode.isWordCharByte(new_byte);
                    const last_is_word = unicode.isWordCharByte(last_byte);
                    const last_is_whitespace = isWhitespace(last_byte);

                    // マージ条件:
                    // 1. 両方とも単語文字 → マージ（"hello"）
                    // 2. 両方とも非単語文字 → マージ（", " や " = "）
                    // 3. 前が空白で新が単語文字 → マージ（" world"）
                    const should_merge = (new_is_word and last_is_word) or
                        (!new_is_word and !last_is_word) or
                        (last_is_whitespace and new_is_word);

                    if (should_merge) {
                        try last.appendData(self.allocator, text);
                        last.cursor_after = pos + text.len;
                        self.last_record_time = now;
                        return;
                    }
                    // マージしない → 新グループ（下へフォールスルー）
                }
            }
        }

        self.last_record_time = now;

        self.clearRedoStack();
        const data_copy = try self.allocator.alloc(u8, text.len);
        @memcpy(data_copy, text);
        try self.undo_stack.append(self.allocator, .{
            .op = .insert,
            .position = pos,
            .data = data_copy,
            .data_capacity = text.len,
            .cursor_before = cursor_pos_before,
            .cursor_after = pos + text.len,
            .group_id = self.current_group_id,
        });
        self.modified = true;
    }

    /// 削除操作をUndo履歴に記録（外部から呼び出し用）
    /// textはコピーされるので、呼び出し元でfreeしても問題ない
    /// 連続した削除はグループ化される（タイムアウト内のみ）
    pub fn recordDeleteOp(self: *EditingContext, pos: usize, text: []const u8, cursor_pos_before: usize) !void {
        const now = std.time.nanoTimestamp();
        const time_elapsed = now - self.last_record_time;

        // 連続した削除操作をグループ化
        // 条件: 直前の操作も削除で、位置が連続していて、タイムアウト内
        if (self.undo_stack.items.len > 0 and time_elapsed < config.Editor.UNDO_GROUP_TIMEOUT_NS) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            if (last.op == .delete and last.groupable and
                !containsNewline(text) and !containsNewline(last.data))
            {
                // Backspaceの場合: 削除位置が直前のエントリの直前
                if (pos + text.len == last.position) {
                    // 先頭に追加（Backspaceは逆順に文字を削除）
                    // 先頭追加は容量ベース最適化が困難なため、毎回再アロケーション
                    const new_len = last.data.len + text.len;
                    const new_capacity = @max(new_len * 2, 64);
                    const new_data = try self.allocator.alloc(u8, new_capacity);
                    @memcpy(new_data[0..text.len], text);
                    @memcpy(new_data[text.len..][0..last.data.len], last.data);
                    last.freeData(self.allocator);
                    last.data = new_data[0..new_len];
                    last.data_capacity = new_capacity;
                    last.position = pos;
                    last.cursor_after = pos;
                    // cursor_beforeは最初の削除時のまま保持
                    self.last_record_time = now;
                    return;
                }
                // Delete (C-d)の場合: 削除位置が同じ
                if (pos == last.position) {
                    try last.appendData(self.allocator, text);
                    // cursor_before/afterは変わらない
                    self.last_record_time = now;
                    return;
                }
            }
        }

        self.clearRedoStack();
        const data_copy = try self.allocator.alloc(u8, text.len);
        @memcpy(data_copy, text);
        try self.undo_stack.append(self.allocator, .{
            .op = .delete,
            .position = pos,
            .data = data_copy,
            .data_capacity = text.len,
            .cursor_before = cursor_pos_before,
            .cursor_after = pos,
            .group_id = self.current_group_id,
        });
        self.last_record_time = now;
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
        // 単一置換でも2つのエントリは必ず一緒にundoされる必要があるため、
        // グループIDを付与する（current_group_idがあればそれを使い、なければ新規作成）
        const replace_group_id = self.current_group_id orelse blk: {
            const id = self.next_group_id;
            self.next_group_id +%= 1;
            break :blk id;
        };

        // 順序が重要！undo時はLIFO（後入れ先出し）なので：
        // 1. Delete entry（old_text）を先に追加 → undo時は後に実行（old_textを挿入）
        // 2. Insert entry（new_text）を後に追加 → undo時は先に実行（new_textを削除）

        // 削除分（undo時に挿入される）- 先に追加
        const old_copy = try self.allocator.alloc(u8, old_text.len);
        @memcpy(old_copy, old_text);
        try self.undo_stack.append(self.allocator, .{
            .op = .delete,
            .position = pos,
            .data = old_copy,
            .data_capacity = old_text.len,
            .cursor_before = cursor_pos_before,
            .cursor_after = pos,
            .group_id = replace_group_id,
        });

        // 挿入分（undo時に削除される）- 後に追加
        const new_copy = try self.allocator.alloc(u8, new_text.len);
        @memcpy(new_copy, new_text);
        try self.undo_stack.append(self.allocator, .{
            .op = .insert,
            .position = pos,
            .data = new_copy,
            .data_capacity = new_text.len,
            .cursor_before = cursor_pos_before,
            .cursor_after = pos + new_text.len,
            .group_id = replace_group_id,
        });

        self.modified = true;
    }

    fn clearRedoStack(self: *EditingContext) void {
        for (self.redo_stack.items) |entry| {
            entry.freeData(self.allocator);
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
        // 実際にコピー可能なバイト数を事前に計算
        const actual_length = @min(length, self.buffer.len() -| start);
        if (actual_length == 0) {
            return &[_]u8{};
        }

        var result = try self.allocator.alloc(u8, actual_length);
        errdefer self.allocator.free(result);

        var iter = PieceIterator.init(self.buffer);
        iter.seek(start);

        // copyBytes()でスライス単位コピー（50-100倍高速）
        const copied = iter.copyBytes(result);

        // コピー数がアロケーションと一致することを確認
        // 事前計算しているので通常は一致するはず
        if (copied != actual_length) {
            // 一致しない場合は新しくallocしてコピー（freeサイズ不一致を防ぐ）
            const final = try self.allocator.alloc(u8, copied);
            @memcpy(final, result[0..copied]);
            self.allocator.free(result);
            return final;
        }
        return result;
    }
};
