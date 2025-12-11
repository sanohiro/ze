// 編集コマンド
// deleteChar, backspace, killLine, undo, redo, yank, killRegion, copyRegion
// joinLine, toggleComment, moveLineUp, moveLineDown, deleteWord, setMark, clearError

const std = @import("std");
const Editor = @import("editor").Editor;
const buffer_mod = @import("buffer");
const Buffer = buffer_mod.Buffer;
const PieceIterator = buffer_mod.PieceIterator;
const unicode = @import("unicode");

// ========================================
// 共通ヘルパー関数
// ========================================

/// テキスト変更後のdirtyマークを適切に設定
/// 改行を含む場合は現在行以降全体、そうでなければ現在行のみ
/// 同一バッファを表示している全ウィンドウを更新
/// 挿入・削除どちらにも使用可能
fn markDirtyForText(e: *Editor, current_line: usize, text: []const u8) void {
    const buffer_id = e.getCurrentBuffer().id;
    if (std.mem.indexOf(u8, text, "\n") != null) {
        e.markAllViewsDirtyForBuffer(buffer_id, current_line, null);
    } else {
        e.markAllViewsDirtyForBuffer(buffer_id, current_line, current_line);
    }
}

/// 範囲削除の共通処理
/// readonly check、extract、delete、record、modified、dirty markを一括処理
/// 戻り値: 削除したテキスト（呼び出し側でfree必要）、またはnull（削除なし/readonly）
fn deleteRangeCommon(e: *Editor, start: usize, len: usize, cursor_pos_for_undo: usize) !?[]const u8 {
    if (e.isReadOnly()) return null;
    if (len == 0) return null;

    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const current_line = e.getCurrentLine();

    const deleted = try e.extractText(start, len);
    errdefer e.allocator.free(deleted);

    try buffer.delete(start, len);
    errdefer buffer.insertSlice(start, deleted) catch unreachable;
    try e.recordDelete(start, deleted, cursor_pos_for_undo);

    buffer_state.editing_ctx.modified = true;
    markDirtyForText(e, current_line, deleted);

    return deleted;
}

/// 編集後のdirtyマーク（同一バッファを表示している全ウィンドウを更新）
fn markDirtyAll(e: *Editor, start_line: usize, end_line: ?usize) void {
    const buffer_id = e.getCurrentBuffer().id;
    e.markAllViewsDirtyForBuffer(buffer_id, start_line, end_line);
}

/// 全画面再描画（同一バッファを表示している全ウィンドウを更新）
fn markFullRedrawAll(e: *Editor) void {
    const buffer_id = e.getCurrentBuffer().id;
    e.markAllViewsFullRedrawForBuffer(buffer_id);
}

/// 選択範囲から行範囲を計算（indentRegion/unindentRegion共通）
fn getSelectedLineRange(e: *Editor) struct { start_line: usize, end_line: usize } {
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const window = e.getCurrentWindow();

    if (window.mark_pos) |mark| {
        const cursor_pos = view.getCursorBufferPos();
        const sel_start = @min(mark, cursor_pos);
        const sel_end = @max(mark, cursor_pos);
        const line1 = buffer.findLineByPos(sel_start);
        var line2 = buffer.findLineByPos(sel_end);
        // sel_endが行頭にあり、範囲が行をまたいでいる場合は前の行までとする
        if (sel_end > sel_start) {
            if (buffer.getLineStart(line2)) |ls| {
                if (sel_end == ls and line2 > line1) {
                    line2 -= 1;
                }
            }
        }
        return .{ .start_line = line1, .end_line = line2 };
    }

    const current = e.getCurrentLine();
    return .{ .start_line = current, .end_line = current };
}

// ========================================
// 基本編集コマンド
// ========================================

/// C-d: カーソル位置の文字を削除
pub fn deleteChar(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const current_line = e.getCurrentLine();
    const pos = e.getCurrentView().getCursorBufferPos();
    if (pos >= buffer.len()) return;

    // カーソル位置のgrapheme clusterのバイト数を取得
    var iter = PieceIterator.init(buffer);
    iter.seek(pos);

    const cluster = iter.nextGraphemeCluster() catch {
        const deleted = try e.extractText(pos, 1);
        errdefer e.allocator.free(deleted);

        try buffer.delete(pos, 1);
        errdefer buffer.insertSlice(pos, deleted) catch unreachable;
        try e.recordDelete(pos, deleted, pos);

        buffer_state.editing_ctx.modified = true;
        markDirtyForText(e, current_line, deleted);
        e.allocator.free(deleted);
        return;
    };

    if (cluster) |gc| {
        const deleted = try e.extractText(pos, gc.byte_len);
        errdefer e.allocator.free(deleted);

        try buffer.delete(pos, gc.byte_len);
        errdefer buffer.insertSlice(pos, deleted) catch unreachable;
        try e.recordDelete(pos, deleted, pos);

        buffer_state.editing_ctx.modified = true;
        markDirtyForText(e, current_line, deleted);
        e.allocator.free(deleted);
    }
}

/// Backspace: カーソル前の文字を削除
pub fn backspace(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const current_line = e.getCurrentLine();
    const pos = e.getCurrentView().getCursorBufferPos();
    if (pos == 0) return;

    // 削除するgrapheme clusterのバイト数と幅を取得
    // 前の文字の開始位置を見つけてそこから cluster を読む
    const char_start = buffer.findUtf8CharStart(pos - 1);
    var iter = PieceIterator.init(buffer);
    iter.seek(char_start);

    var char_width: usize = 1;
    var char_len: usize = pos - char_start; // デフォルト

    if (iter.nextGraphemeCluster() catch null) |gc| {
        char_width = gc.width;
        char_len = gc.byte_len;
    }

    const deleted = try e.extractText(char_start, char_len);
    errdefer e.allocator.free(deleted);

    const is_newline = std.mem.indexOf(u8, deleted, "\n") != null;

    try buffer.delete(char_start, char_len);
    errdefer buffer.insertSlice(char_start, deleted) catch unreachable;
    try e.recordDelete(char_start, deleted, pos);

    buffer_state.editing_ctx.modified = true;
    markDirtyForText(e, current_line, deleted);
    e.allocator.free(deleted);

    // カーソル移動
    const view = e.getCurrentView();
    if (view.cursor_x >= char_width) {
        view.cursor_x -= char_width;
        if (view.cursor_x < view.top_col) {
            view.top_col = view.cursor_x;
            view.markFullRedraw();
        }
    } else if (view.cursor_y > 0) {
        view.cursor_y -= 1;
        if (is_newline) {
            const new_line = e.getCurrentLine();
            if (buffer.getLineStart(view.top_line + new_line)) |line_start| {
                var x: usize = 0;
                var width_iter = PieceIterator.init(buffer);
                width_iter.seek(line_start);
                while (width_iter.global_pos < char_start) {
                    const cl = width_iter.nextGraphemeCluster() catch break;
                    if (cl) |gc| {
                        if (gc.base == '\n') break;
                        x += gc.width;
                    } else {
                        break;
                    }
                }
                view.cursor_x = x;
                const line_num_width = view.getLineNumberWidth();
                const visible_width = if (view.viewport_width > line_num_width) view.viewport_width - line_num_width else 1;
                if (view.cursor_x >= view.top_col + visible_width) {
                    view.top_col = view.cursor_x - visible_width + 1;
                } else if (view.cursor_x < view.top_col) {
                    view.top_col = view.cursor_x;
                }
                view.markFullRedraw();
            }
        } else {
            view.moveToLineEnd();
        }
    }
}

/// C-k: 行末まで削除
pub fn killLine(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const pos = e.getCurrentView().getCursorBufferPos();
    const end_pos = buffer.findNextLineFromPos(pos);

    if (try deleteRangeCommon(e, pos, end_pos - pos, pos)) |deleted| {
        e.allocator.free(deleted);
    }
}

// ========================================
// Undo/Redo
// ========================================

/// C-u: 元に戻す
pub fn undo(e: *Editor) !void {
    const buffer_state = e.getCurrentBuffer();

    const result = try buffer_state.editing_ctx.undoWithCursor();
    if (result == null) return;

    markFullRedrawAll(e);
    e.restoreCursorPos(result.?.cursor_pos);
}

/// C-/ or C-_: やり直し
pub fn redo(e: *Editor) !void {
    const buffer_state = e.getCurrentBuffer();

    const result = try buffer_state.editing_ctx.redoWithCursor();
    if (result == null) return;

    markFullRedrawAll(e);
    e.restoreCursorPos(result.?.cursor_pos);
}

// ========================================
// キルリング（コピー/カット/ペースト）
// ========================================

/// C-y: kill ringからペースト
pub fn yank(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const current_line = e.getCurrentLine();
    const text = e.kill_ring orelse {
        e.getCurrentView().setError("Kill ring is empty");
        return;
    };

    const pos = e.getCurrentView().getCursorBufferPos();

    try buffer.insertSlice(pos, text);
    errdefer buffer.delete(pos, text.len) catch unreachable;
    try e.recordInsert(pos, text, pos);

    buffer_state.editing_ctx.modified = true;

    e.setCursorToPos(pos + text.len);

    markDirtyForText(e, current_line, text);

    e.getCurrentView().setError("Yanked text");
}

/// C-w: 選択範囲を削除してkill ringに保存
pub fn killRegion(e: *Editor) !void {
    const window = e.getCurrentWindow();
    const region = e.getRegion() orelse {
        e.getCurrentView().setError("No active region");
        return;
    };

    const deleted = try deleteRangeCommon(e, region.start, region.len, e.getCurrentView().getCursorBufferPos()) orelse return;

    // kill ringに保存（freeせずに所有権移転）
    if (e.kill_ring) |old_text| {
        e.allocator.free(old_text);
    }
    e.kill_ring = deleted;

    e.setCursorToPos(region.start);
    window.mark_pos = null;
    e.getCurrentView().setError("Killed region");
}

/// M-w: 選択範囲をkill ringにコピー
pub fn copyRegion(e: *Editor) !void {
    const window = e.getCurrentWindow();
    const region = e.getRegion() orelse {
        e.getCurrentView().setError("No active region");
        return;
    };

    if (e.kill_ring) |old_text| {
        e.allocator.free(old_text);
    }

    e.kill_ring = try e.extractText(region.start, region.len);

    window.mark_pos = null;

    e.getCurrentView().setError("Saved text to kill ring");
}

// ========================================
// 行操作
// ========================================

/// M-^: 行の結合 (delete-indentation)
pub fn joinLine(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();

    const current_line = e.getCurrentLine();
    if (current_line == 0) {
        return;
    }

    const line_start = buffer.getLineStart(current_line) orelse return;

    var iter = PieceIterator.init(buffer);
    iter.seek(line_start);
    var first_non_space = line_start;
    while (iter.next()) |ch| {
        if (ch != ' ' and ch != '\t') {
            first_non_space = iter.global_pos - 1;
            break;
        }
    }

    const prev_line_end = line_start - 1;
    const delete_start = prev_line_end;
    const delete_len = first_non_space - prev_line_end;

    if (delete_len > 0) {
        const deleted = try e.extractText(delete_start, delete_len);
        errdefer e.allocator.free(deleted);

        try buffer.delete(delete_start, delete_len);
        try e.recordDelete(delete_start, deleted, view.getCursorBufferPos());

        var needs_space = true;
        if (delete_start > 0) {
            var check_iter = PieceIterator.init(buffer);
            check_iter.seek(delete_start - 1);
            if (check_iter.next()) |prev_char| {
                if (prev_char == ' ' or prev_char == '\t') {
                    needs_space = false;
                }
            }
        }

        if (needs_space and first_non_space > line_start) {
            try buffer.insertSlice(delete_start, " ");
            try e.recordInsert(delete_start, " ", view.getCursorBufferPos());
        }

        buffer_state.editing_ctx.modified = true;
        markDirtyAll(e, current_line - 1, null);

        e.setCursorToPos(delete_start);

        e.allocator.free(deleted);
    }
}

/// M-;: コメント切り替え
pub fn toggleComment(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const window = e.getCurrentWindow();

    const line_comment = view.language.line_comment orelse "#";
    var comment_buf: [64]u8 = undefined;
    const comment_str = std.fmt.bufPrint(&comment_buf, "{s} ", .{line_comment}) catch "# ";

    const current_line = e.getCurrentLine();
    const line_start = buffer.getLineStart(current_line) orelse return;

    const line_range = buffer.getLineRange(current_line) orelse return;
    const max_line_len = if (line_range.end > line_range.start) line_range.end - line_range.start else 0;
    var line_list = try std.ArrayList(u8).initCapacity(e.allocator, max_line_len);
    defer line_list.deinit(e.allocator);

    var iter = PieceIterator.init(buffer);
    iter.seek(line_range.start);
    while (iter.next()) |ch| {
        if (ch == '\n') break;
        try line_list.append(e.allocator, ch);
    }
    const line_content = line_list.items;

    const is_comment = view.language.isCommentLine(line_content);

    if (is_comment) {
        const comment_start = view.language.findCommentStart(line_content) orelse return;
        const comment_pos = line_start + comment_start;

        var delete_len: usize = line_comment.len;
        if (comment_start + line_comment.len < line_content.len and
            line_content[comment_start + line_comment.len] == ' ')
        {
            delete_len += 1;
        }

        const deleted = try e.extractText(comment_pos, delete_len);
        defer e.allocator.free(deleted);

        try buffer.delete(comment_pos, delete_len);
        try e.recordDelete(comment_pos, deleted, view.getCursorBufferPos());
    } else {
        try buffer.insertSlice(line_start, comment_str);
        try e.recordInsert(line_start, comment_str, view.getCursorBufferPos());
    }

    buffer_state.editing_ctx.modified = true;
    markDirtyAll(e, current_line, current_line);

    window.mark_pos = null;
}

/// Alt+Up: 行を上に移動
pub fn moveLineUp(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const current_line = e.getCurrentLine();

    if (current_line == 0) return;

    const line_start = buffer.getLineStart(current_line) orelse return;
    const line_end = buffer.findNextLineFromPos(line_start);

    const prev_line_start = buffer.getLineStart(current_line - 1) orelse return;

    const line_len = line_end - line_start;
    const line_content = try e.extractText(line_start, line_len);
    defer e.allocator.free(line_content);

    try buffer.delete(line_start, line_len);

    try buffer.insertSlice(prev_line_start, line_content);

    try e.recordDelete(line_start, line_content, view.getCursorBufferPos());
    try e.recordInsert(prev_line_start, line_content, view.getCursorBufferPos());

    buffer_state.editing_ctx.modified = true;
    markDirtyAll(e, current_line - 1, null);

    view.moveCursorUp();
}

/// Alt+Down: 行を下に移動
pub fn moveLineDown(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const current_line = e.getCurrentLine();
    const total_lines = buffer.lineCount();

    if (current_line >= total_lines - 1) return;

    const line_start = buffer.getLineStart(current_line) orelse return;
    const line_end = buffer.findNextLineFromPos(line_start);

    const next_line_end = buffer.findNextLineFromPos(line_end);

    const line_len = line_end - line_start;
    const line_content = try e.extractText(line_start, line_len);
    defer e.allocator.free(line_content);

    try buffer.delete(line_start, line_len);

    const new_insert_pos = next_line_end - line_len;
    try buffer.insertSlice(new_insert_pos, line_content);

    try e.recordDelete(line_start, line_content, view.getCursorBufferPos());
    try e.recordInsert(new_insert_pos, line_content, view.getCursorBufferPos());

    buffer_state.editing_ctx.modified = true;
    markDirtyAll(e, current_line, null);

    view.moveCursorDown();
}

// ========================================
// 単語操作
// ========================================

/// M-d: カーソル位置から次の単語までを削除
pub fn deleteWord(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    if (start_pos >= buffer.len()) return;

    // 単語境界を探索
    var iter = PieceIterator.init(buffer);
    iter.seek(start_pos);

    var prev_type: ?unicode.CharType = null;
    var end_pos = start_pos;

    while (iter.nextCodepoint() catch null) |cp| {
        const current_type = unicode.getCharType(cp);

        if (prev_type) |pt| {
            if (current_type != .space and pt != .space and current_type != pt) {
                break;
            }
            if (pt == .space and current_type != .space) {
                break;
            }
        }

        prev_type = current_type;
        end_pos = iter.global_pos;
    }

    if (try deleteRangeCommon(e, start_pos, end_pos - start_pos, start_pos)) |deleted| {
        e.allocator.free(deleted);
        // 単語削除は全体再描画（行番号変動の可能性）
        markFullRedrawAll(e);
    }
}

// ========================================
// マーク/選択
// ========================================

/// C-Space / C-@: マークを設定/解除
pub fn setMark(e: *Editor) !void {
    const window = e.getCurrentWindow();
    if (window.mark_pos) |_| {
        window.mark_pos = null;
        e.getCurrentView().setError("Mark deactivated");
    } else {
        window.mark_pos = e.getCurrentView().getCursorBufferPos();
        e.getCurrentView().setError("Mark set");
    }
    // 選択範囲のハイライトが変わるので再描画
    e.getCurrentView().markFullRedraw();
}

// ========================================
// 行操作
// ========================================

/// 行の複製 (duplicate-line)
pub fn duplicateLine(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const current_line = e.getCurrentLine();

    // 現在の行の開始・終了位置を取得
    const line_start = buffer.getLineStart(current_line) orelse return;
    const line_end = buffer.findNextLineFromPos(line_start);

    // 行の内容を取得（改行を含む）
    const line_len = line_end - line_start;
    if (line_len == 0) return;

    const line_content = try e.extractText(line_start, line_len);
    defer e.allocator.free(line_content);

    // 改行後に挿入（または行末に改行+内容を挿入）
    const insert_pos = line_end;
    var to_insert: []const u8 = undefined;
    var allocated = false;

    if (line_end < buffer.len()) {
        // 改行がある場合はそのまま挿入
        to_insert = line_content;
    } else {
        // ファイル末尾の場合は改行を追加
        const with_newline = try e.allocator.alloc(u8, line_len + 1);
        with_newline[0] = '\n';
        @memcpy(with_newline[1..], line_content);
        to_insert = with_newline;
        allocated = true;
    }
    defer if (allocated) e.allocator.free(to_insert);

    try buffer.insertSlice(insert_pos, to_insert);
    try e.recordInsert(insert_pos, to_insert, view.getCursorBufferPos());

    buffer_state.editing_ctx.modified = true;
    markDirtyAll(e, current_line, null);

    // カーソルを複製した行に移動
    view.moveCursorDown();
}

/// 選択範囲または現在行をインデント
pub fn indentRegion(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const window = e.getCurrentWindow();

    // インデント文字を検出
    const indent_char = detectIndentStyle(e);
    const indent_str: []const u8 = if (indent_char == '\t') "\t" else "    ";

    // 選択範囲があればその行全体をインデント、なければ現在行のみ
    const range = getSelectedLineRange(e);
    const start_line = range.start_line;
    const end_line = range.end_line;

    // 行ごとにインデント（後ろから処理してバイト位置がずれないようにする）
    var line = end_line + 1;
    while (line > start_line) {
        line -= 1;
        const line_start = buffer.getLineStart(line) orelse continue;
        try buffer.insertSlice(line_start, indent_str);
        try e.recordInsert(line_start, indent_str, view.getCursorBufferPos());
    }

    buffer_state.editing_ctx.modified = true;
    markDirtyAll(e, start_line, end_line);

    // マークをクリア
    window.mark_pos = null;
}

/// 選択範囲または現在行をアンインデント
pub fn unindentRegion(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const window = e.getCurrentWindow();

    // 選択範囲があればその行全体をアンインデント、なければ現在行のみ
    const range = getSelectedLineRange(e);
    const start_line = range.start_line;
    const end_line = range.end_line;

    var any_modified = false;

    // 行ごとにアンインデント（後ろから処理してバイト位置がずれないようにする）
    var line = end_line + 1;
    while (line > start_line) {
        line -= 1;
        const line_start = buffer.getLineStart(line) orelse continue;

        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        // 先頭の空白を数える
        var spaces_to_remove: usize = 0;
        if (iter.next()) |ch| {
            if (ch == '\t') {
                spaces_to_remove = 1;
            } else if (ch == ' ') {
                spaces_to_remove = 1;
                // 最大4スペースまで削除
                var count: usize = 1;
                while (count < 4) : (count += 1) {
                    if (iter.next()) |next_ch| {
                        if (next_ch == ' ') {
                            spaces_to_remove += 1;
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
            }
        }

        if (spaces_to_remove > 0) {
            const deleted = try e.extractText(line_start, spaces_to_remove);
            defer e.allocator.free(deleted);

            try buffer.delete(line_start, spaces_to_remove);
            try e.recordDelete(line_start, deleted, view.getCursorBufferPos());
            any_modified = true;
        }
    }

    if (any_modified) {
        buffer_state.editing_ctx.modified = true;
        markDirtyAll(e, start_line, end_line);
    }

    // マークをクリア
    window.mark_pos = null;
}

/// 全選択（C-x h）：バッファの先頭にマークを設定し、終端にカーソルを移動
pub fn selectAll(e: *Editor) !void {
    // バッファの先頭（位置0）にマークを設定
    const window = e.getCurrentWindow();
    window.mark_pos = 0;
    // カーソルをバッファの終端に移動
    e.getCurrentView().moveToBufferEnd();
}

// ========================================
// UI
// ========================================

/// C-g: エラーメッセージをクリア
pub fn clearError(e: *Editor) !void {
    e.getCurrentView().clearError();
}

// ========================================
// ヘルパー関数
// ========================================

/// インデントスタイルを検出（タブ優先かスペース優先か）
fn detectIndentStyle(e: *Editor) u8 {
    const buffer = e.getCurrentBufferContent();
    var iter = PieceIterator.init(buffer);

    var tab_lines: usize = 0; // タブでインデントされた行数
    var space_lines: usize = 0; // スペースでインデントされた行数
    var line_spaces: usize = 0; // 現在行のスペース数
    var at_line_start = true;

    while (iter.next()) |ch| {
        if (ch == '\n') {
            at_line_start = true;
            line_spaces = 0; // 改行ごとにリセット
        } else if (at_line_start) {
            if (ch == '\t') {
                tab_lines += 1;
                at_line_start = false;
            } else if (ch == ' ') {
                line_spaces += 1;
                // 4スペース連続でスペースインデント行としてカウント
                if (line_spaces >= 4) {
                    space_lines += 1;
                    at_line_start = false;
                }
            } else {
                at_line_start = false;
            }
        }
    }

    // タブ行が多ければタブ、そうでなければスペース
    if (tab_lines > space_lines) {
        return '\t';
    }
    return ' ';
}

/// 現在行のインデント（先頭の空白）を取得
/// Enter時の自動インデントに使用
pub fn getCurrentLineIndent(e: *Editor) []const u8 {
    const buffer = e.getCurrentBufferContent();
    const cursor_pos = e.getCurrentView().getCursorBufferPos();

    // バイト位置から行番号を取得し、その行の開始位置を取得
    const line_num = buffer.findLineByPos(cursor_pos);
    const line_start = buffer.getLineStart(line_num) orelse return "";

    // バッファからテキストを取得してインデント部分を抽出
    // 静的バッファを使用して安全にスライスを返す
    const max_indent = 256;
    const Static = struct {
        var buf: [max_indent]u8 = undefined;
    };
    var indent_len: usize = 0;

    // PieceIteratorで行頭からイテレート
    var iter = PieceIterator.init(buffer);
    iter.seek(line_start);

    while (iter.next()) |byte| {
        if (byte == ' ' or byte == '\t') {
            if (indent_len < max_indent) {
                Static.buf[indent_len] = byte;
                indent_len += 1;
            }
        } else {
            break;
        }
    }

    return Static.buf[0..indent_len];
}
