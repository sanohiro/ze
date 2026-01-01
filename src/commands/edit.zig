// 編集コマンド
// deleteChar, backspace, killLine, undo, redo, yank, killRegion, copyRegion
// joinLine, toggleComment, moveLineUp, moveLineDown, deleteWord, setMark, clearError

const std = @import("std");
const config = @import("config");
const Editor = @import("editor").Editor;
const buffer_mod = @import("buffer");
const Buffer = buffer_mod.Buffer;
const PieceIterator = buffer_mod.PieceIterator;
const unicode = @import("unicode");

// ========================================
// 共通ヘルパー関数
// ========================================

/// 範囲削除の共通処理
/// readonly check、extract、delete、record、modified、dirty markを一括処理
/// 戻り値: 削除したテキスト（呼び出し側でfree必要）、またはnull（削除なし/readonly）
fn deleteRangeCommon(e: *Editor, start: usize, len: usize, cursor_pos_for_undo: usize) !?[]const u8 {
    if (e.isReadOnly()) return null;
    if (len == 0) return null;

    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    // 削除開始位置の行番号を取得（カーソル位置ではなく実際の編集位置から）
    const start_line = buffer.findLineByPos(start);

    const deleted = try e.extractText(start, len);
    errdefer e.allocator.free(deleted);

    try buffer.delete(start, len);
    errdefer buffer.insertSlice(start, deleted) catch {};
    try e.recordDelete(start, deleted, cursor_pos_for_undo);

    buffer_state.editing_ctx.modified = true;
    // 削除開始行からdirtyマークを設定（カーソル位置ではなく実際の編集位置を使用）
    e.markCurrentBufferDirtyForText(start_line, deleted);

    // カーソル位置キャッシュを無効化（削除後はposが変わる）
    e.getCurrentView().invalidateCursorPosCache();

    return deleted;
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
    const buffer = e.getCurrentBufferContent();
    const pos = e.getCurrentView().getCursorBufferPos();
    if (pos >= buffer.len()) return;

    // ASCII高速パス: 1バイト文字ならイテレータ作成をスキップ
    const delete_len: usize = blk: {
        if (buffer.getByteAt(pos)) |byte| {
            if (unicode.isAsciiByte(byte)) break :blk 1;
        }
        // 非ASCII: grapheme clusterのバイト数を取得
        var iter = PieceIterator.init(buffer);
        iter.seek(pos);
        const cluster = iter.nextGraphemeCluster() catch break :blk 1;
        break :blk if (cluster) |gc| gc.byte_len else 1;
    };

    // deleteRangeCommonで削除（戻り値は削除したテキスト、nullなら削除なし）
    if (try deleteRangeCommon(e, pos, delete_len, pos)) |deleted| {
        e.allocator.free(deleted);
    }
}

/// Backspace: カーソル前の文字を削除
pub fn backspace(e: *Editor) !void {
    if (e.isReadOnly()) {
        e.getCurrentView().setError(config.Messages.BUFFER_READONLY);
        return;
    }

    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const pos = view.getCursorBufferPos();
    if (pos == 0) {
        view.setError(config.Messages.BEGINNING_OF_BUFFER);
        return;
    }

    // 削除するgrapheme clusterのバイト数と幅を取得
    const char_start = buffer.findUtf8CharStart(pos);
    var iter = PieceIterator.init(buffer);
    iter.seek(char_start);

    var char_base: u21 = 0;
    var char_len: usize = pos - char_start; // デフォルト

    if (iter.nextGraphemeCluster() catch null) |gc| {
        char_base = gc.base;
        char_len = gc.byte_len;
    }

    // deleteRangeCommonで削除
    const deleted = try deleteRangeCommon(e, char_start, char_len, pos);
    if (deleted == null) return;
    defer e.allocator.free(deleted.?);

    const is_newline = std.mem.indexOfScalar(u8, deleted.?, '\n') != null;
    const is_tab = char_base == '\t';

    // カーソル移動（タブや改行は位置再計算が必要）
    if (is_tab or is_newline) {
        e.setCursorToPos(char_start);
    } else {
        const char_width = unicode.displayWidth(char_base);
        if (view.cursor_x >= char_width) {
            view.cursor_x -= char_width;
            if (view.cursor_x < view.top_col) {
                view.top_col = view.cursor_x;
                view.markFullRedraw();
            }
        }
    }
}

/// C-k: 行末まで削除（kill-whole-line モード）
/// - 行頭にいる場合: 行全体（改行含む）を削除
/// - 行中にいる場合: カーソルから行末まで削除（改行は残す）
/// - 行末にいる場合: 改行を削除（次の行と結合）
pub fn killLine(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const pos = e.getCurrentView().getCursorBufferPos();
    const next_line_pos = buffer.findNextLineFromPos(pos);

    // 行頭かどうか判定（pos==0 または前の文字が改行）
    const at_line_start = pos == 0 or buffer.getByteAt(pos - 1) == '\n';

    // 改行があるかどうか
    const has_newline = next_line_pos > pos and buffer.getByteAt(next_line_pos - 1) == '\n';
    const text_end = if (has_newline) next_line_pos - 1 else next_line_pos;

    // カーソルから行末までのテキストの長さ
    const text_len = text_end - pos;

    // 削除範囲を決定
    const delete_len: usize = if (at_line_start and text_len > 0 and has_newline)
        // 行頭: テキスト + 改行を削除
        text_len + 1
    else if (text_len > 0)
        // 行中: テキストのみ削除
        text_len
    else if (has_newline)
        // 行末: 改行のみ削除
        1
    else
        0;

    if (delete_len == 0) return;

    if (try deleteRangeCommon(e, pos, delete_len, pos)) |deleted| {
        // kill ringに保存（KillRingの再利用バッファにコピー）
        defer e.allocator.free(deleted);
        try e.kill_ring.store(deleted);
    }
}

// ========================================
// Undo/Redo
// ========================================

/// C-u: 元に戻す
pub fn undo(e: *Editor) !void {
    // 読み取り専用バッファではUndoも禁止（バッファを変更するため）
    if (e.isReadOnly()) return;

    const buffer_state = e.getCurrentBuffer();

    const result = try buffer_state.editing_ctx.undoWithCursor();
    if (result == null) return;

    // markCurrentBufferFullRedraw → markFullRedraw でキャッシュ無効化
    // restoreCursorPos → setCursorToPos でキャッシュ再設定
    e.markCurrentBufferFullRedraw();
    e.restoreCursorPos(result.?.cursor_pos);
}

/// C-/ or C-_: やり直し
pub fn redo(e: *Editor) !void {
    // 読み取り専用バッファではRedoも禁止（バッファを変更するため）
    if (e.isReadOnly()) return;

    const buffer_state = e.getCurrentBuffer();

    const result = try buffer_state.editing_ctx.redoWithCursor();
    if (result == null) return;

    // markCurrentBufferFullRedraw → markFullRedraw でキャッシュ無効化
    // restoreCursorPos → setCursorToPos でキャッシュ再設定
    e.markCurrentBufferFullRedraw();
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
    const text = e.kill_ring.get() orelse {
        e.getCurrentView().setError(config.Messages.KILL_RING_EMPTY);
        return;
    };

    const pos = e.getCurrentView().getCursorBufferPos();

    try buffer.insertSlice(pos, text);
    errdefer buffer.delete(pos, text.len) catch {};
    try e.recordInsert(pos, text, pos);

    buffer_state.editing_ctx.modified = true;

    // setCursorToPosでキャッシュが再設定されるため、事前の無効化は不要
    e.setCursorToPos(pos + text.len);

    e.markCurrentBufferDirtyForText(current_line, text);

    e.getCurrentView().setError(config.Messages.YANKED_TEXT);
}

/// C-w: 選択範囲を削除してkill ringに保存
pub fn killRegion(e: *Editor) !void {
    const window = e.getCurrentWindow();
    const region = e.getRegion() orelse {
        e.getCurrentView().setError(config.Messages.NO_ACTIVE_REGION);
        return;
    };

    const deleted = try deleteRangeCommon(e, region.start, region.len, e.getCurrentView().getCursorBufferPos()) orelse return;

    // kill ringに保存（KillRingの再利用バッファにコピー）
    defer e.allocator.free(deleted);
    try e.kill_ring.store(deleted);

    e.setCursorToPos(region.start);
    window.mark_pos = null;
    e.getCurrentView().setError(config.Messages.KILLED_REGION);
}

/// M-w: 選択範囲をkill ringにコピー
pub fn copyRegion(e: *Editor) !void {
    const window = e.getCurrentWindow();
    const region = e.getRegion() orelse {
        e.getCurrentView().setError(config.Messages.NO_ACTIVE_REGION);
        return;
    };

    // 新しいテキストを先に取得してkill ringに保存
    const new_text = try e.extractText(region.start, region.len);
    defer e.allocator.free(new_text);
    try e.kill_ring.store(new_text);

    window.mark_pos = null;

    e.getCurrentView().setError(config.Messages.SAVED_TEXT);
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
        view.setError(config.Messages.BEGINNING_OF_BUFFER);
        return;
    }

    const line_start = buffer.getLineStart(current_line) orelse return;

    var iter = PieceIterator.init(buffer);
    iter.seek(line_start);
    var first_non_space = line_start;
    while (iter.next()) |ch| {
        // 改行に達した場合は、行全体が空白（first_non_spaceは行頭のまま）
        if (ch == '\n') {
            first_non_space = iter.global_pos - 1;
            break;
        }
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
        defer e.allocator.free(deleted);

        try buffer.delete(delete_start, delete_len);
        // 削除後のロールバック用errdefer（recordDeleteが失敗した場合）
        errdefer buffer.insertSlice(delete_start, deleted) catch {};
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
            // 挿入後のロールバック用errdefer（recordInsertが失敗した場合）
            errdefer buffer.delete(delete_start, 1) catch {};
            try e.recordInsert(delete_start, " ", view.getCursorBufferPos());
        }

        buffer_state.editing_ctx.modified = true;
        // joinLineは行数が減るため全画面再描画が必要
        e.markCurrentBufferFullRedraw();

        e.setCursorToPos(delete_start);
    }
}

/// M-;: コメント切り替え
pub fn toggleComment(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();

    // line_commentがない言語（HTML/XMLなど）ではブロックコメントのみ対応
    // block_commentがある場合は警告を出す（行コメントトグルは未対応）
    const line_comment = view.language.line_comment orelse blk: {
        if (view.language.block_comment != null) {
            view.setError(config.Messages.LINE_COMMENT_NOT_SUPPORTED);
            return;
        }
        break :blk "#"; // 両方ともnullの場合のみフォールバック
    };
    var comment_buf: [config.Editor.COMMENT_BUF_SIZE]u8 = undefined;
    const comment_str = std.fmt.bufPrint(&comment_buf, "{s} ", .{line_comment}) catch "# ";

    const current_line = e.getCurrentLine();
    const line_start = buffer.getLineStart(current_line) orelse return;

    const line_range = buffer.getLineRange(current_line) orelse return;
    const range_len = line_range.end - line_range.start;
    if (range_len == 0) return;

    // 行の内容を一括で取得（バイトごとのappendより50-100倍高速）
    const full_line = try e.extractText(line_range.start, range_len);
    defer e.allocator.free(full_line);

    // 改行を除外した内容を取得（スライスなのでコピーなし）
    const line_content = if (full_line.len > 0 and full_line[full_line.len - 1] == '\n')
        full_line[0 .. full_line.len - 1]
    else
        full_line;

    // コメント行かどうか判定（言語定義がない場合もフォールバックの # をチェック）
    const is_comment = if (view.language.line_comment != null)
        view.language.isCommentLine(line_content)
    else
        isCommentWithPrefix(line_content, line_comment);

    if (is_comment) {
        // コメント開始位置を取得（言語定義がない場合もフォールバック）
        const comment_start = if (view.language.line_comment != null)
            view.language.findCommentStart(line_content) orelse return
        else
            findCommentStartWithPrefix(line_content, line_comment) orelse return;
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
        // 削除後のロールバック用errdefer（recordDeleteが失敗した場合）
        errdefer buffer.insertSlice(comment_pos, deleted) catch {};
        try e.recordDelete(comment_pos, deleted, view.getCursorBufferPos());
    } else {
        try buffer.insertSlice(line_start, comment_str);
        // 挿入後のロールバック用errdefer（recordInsertが失敗した場合）
        errdefer buffer.delete(line_start, comment_str.len) catch {};
        try e.recordInsert(line_start, comment_str, view.getCursorBufferPos());
    }

    buffer_state.editing_ctx.modified = true;
    e.markCurrentBufferDirty(current_line, current_line);

    // 選択範囲は維持（連続操作のため）
}

/// 行を上下に移動する共通処理
fn moveLineImpl(e: *Editor, direction: enum { up, down }) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();
    const current_line = e.getCurrentLine();

    // 境界チェック
    if (direction == .up) {
        if (current_line == 0) {
            view.setError(config.Messages.BEGINNING_OF_BUFFER);
            return;
        }
    } else {
        if (current_line + 1 >= buffer.lineCount()) {
            view.setError(config.Messages.END_OF_BUFFER);
            return;
        }
    }

    const line_start = buffer.getLineStart(current_line) orelse return;
    const line_end = buffer.findNextLineFromPos(line_start);
    const line_len = line_end - line_start;

    // 移動先の位置を計算
    const insert_pos = if (direction == .up)
        buffer.getLineStart(current_line - 1) orelse return
    else
        buffer.findNextLineFromPos(line_end) - line_len;

    const line_content = try e.extractText(line_start, line_len);
    defer e.allocator.free(line_content);

    // 行移動は1操作としてUndoグループ化（delete + insertを一括でUndo）
    _ = buffer_state.editing_ctx.beginUndoGroup();
    defer buffer_state.editing_ctx.endUndoGroup();

    try buffer.delete(line_start, line_len);
    errdefer buffer.insertSlice(line_start, line_content) catch {};

    try buffer.insertSlice(insert_pos, line_content);
    errdefer buffer.delete(insert_pos, line_len) catch {};

    try e.recordDelete(line_start, line_content, view.getCursorBufferPos());
    try e.recordInsert(insert_pos, line_content, view.getCursorBufferPos());

    buffer_state.editing_ctx.modified = true;
    e.markCurrentBufferFullRedraw();

    if (direction == .up) view.moveCursorUp() else view.moveCursorDown();
}

/// Alt+Up: 行を上に移動
pub fn moveLineUp(e: *Editor) !void {
    try moveLineImpl(e, .up);
}

/// Alt+Down: 行を下に移動
pub fn moveLineDown(e: *Editor) !void {
    try moveLineImpl(e, .down);
}

// ========================================
// 単語操作
// ========================================

/// M-d: カーソル位置から次の単語までを削除
/// Emacsスタイル：空白を飛ばして次の単語全体を削除
pub fn deleteWord(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    if (start_pos >= buffer.len()) return;

    var iter = PieceIterator.init(buffer);
    iter.seek(start_pos);

    var end_pos = start_pos;
    var in_word = false;
    var word_type: ?unicode.CharType = null;

    while (iter.nextCodepoint() catch null) |cp| {
        const current_type = unicode.getCharType(cp);

        if (current_type == .space) {
            if (in_word) {
                // 単語中から空白に出たら終了
                break;
            }
            // 空白スキップ（単語開始前）
        } else {
            if (!in_word) {
                // 単語開始
                in_word = true;
                word_type = current_type;
            } else if (word_type != null and current_type != word_type.?) {
                // 文字種が変わったら終了
                break;
            }
        }

        end_pos = iter.global_pos;
    }

    // deleteRangeCommon内でmarkDirtyForTextが呼ばれる
    if (try deleteRangeCommon(e, start_pos, end_pos - start_pos, start_pos)) |deleted| {
        // Emacsのkill-wordと同様、削除したテキストをkill ringに保存
        // deferでfreeし、storeでkill ringにコピー
        defer e.allocator.free(deleted);
        try e.kill_ring.store(deleted);
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
        window.shift_select = false;
        e.getCurrentView().setError(config.Messages.MARK_DEACTIVATED);
    } else {
        window.mark_pos = e.getCurrentView().getCursorBufferPos();
        window.shift_select = false; // C-Spaceで設定したマークは矢印キーで解除しない
        e.getCurrentView().setError(config.Messages.MARK_SET);
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
        // ファイル末尾の場合
        // 行内容が既に改行で終わっているかチェック
        if (line_len > 0 and line_content[line_len - 1] == '\n') {
            // 改行で終わっている場合はそのまま挿入
            to_insert = line_content;
        } else {
            // 改行で終わっていない場合は先頭に改行を追加
            const with_newline = try e.allocator.alloc(u8, line_len + 1);
            with_newline[0] = '\n';
            @memcpy(with_newline[1..], line_content);
            to_insert = with_newline;
            allocated = true;
        }
    }
    defer if (allocated) e.allocator.free(to_insert);

    try buffer.insertSlice(insert_pos, to_insert);
    // 挿入後のロールバック用errdefer（recordInsertが失敗した場合）
    errdefer buffer.delete(insert_pos, to_insert.len) catch {};
    try e.recordInsert(insert_pos, to_insert, view.getCursorBufferPos());

    buffer_state.editing_ctx.modified = true;
    // duplicateLineは行数が増えるため全画面再描画が必要
    e.markCurrentBufferFullRedraw();

    // カーソルを複製した行に移動
    view.moveCursorDown();
}

/// 選択範囲または現在行をインデント
pub fn indentRegion(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();

    // Viewの設定からインデント文字列を取得
    const indent_style = view.getIndentStyle();
    const tab_width = view.getTabWidth();
    const spaces = "        "; // 8 spaces max
    const indent_str: []const u8 = if (indent_style == .tab) "\t" else spaces[0..@min(tab_width, spaces.len)];

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
        // 挿入後のロールバック用errdefer（recordInsertが失敗した場合）
        errdefer buffer.delete(line_start, indent_str.len) catch {};
        try e.recordInsert(line_start, indent_str, view.getCursorBufferPos());
    }

    buffer_state.editing_ctx.modified = true;
    e.markCurrentBufferDirty(start_line, end_line);

    // インデント後は選択範囲をクリア（バイト位置がずれるため）
    e.getCurrentWindow().mark_pos = null;
}

/// 選択範囲または現在行をアンインデント
pub fn unindentRegion(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const buffer_state = e.getCurrentBuffer();
    const buffer = e.getCurrentBufferContent();
    const view = e.getCurrentView();

    // Viewの設定からタブ幅を取得
    const tab_width = view.getTabWidth();

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
                // タブ幅分のスペースを削除
                var count: usize = 1;
                while (count < tab_width) : (count += 1) {
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
            // スタックバッファを使用（タブ幅は最大でもINDENT_BUF_SIZEなのでヒープアロケーション不要）
            var stack_buf: [config.Editor.INDENT_BUF_SIZE]u8 = undefined;
            const deleted = blk: {
                // イテレータを再利用（seek()キャッシュにより高速）
                iter.seek(line_start);
                for (0..spaces_to_remove) |i| {
                    stack_buf[i] = iter.next() orelse break;
                }
                break :blk stack_buf[0..spaces_to_remove];
            };

            try buffer.delete(line_start, spaces_to_remove);
            // 削除後のロールバック用errdefer（recordDeleteが失敗した場合）
            errdefer buffer.insertSlice(line_start, deleted) catch {};
            try e.recordDelete(line_start, deleted, view.getCursorBufferPos());
            any_modified = true;
        }
    }

    if (any_modified) {
        buffer_state.editing_ctx.modified = true;
        e.markCurrentBufferDirty(start_line, end_line);
    }

    // アンインデント後は選択範囲をクリア（バイト位置がずれるため）
    e.getCurrentWindow().mark_pos = null;
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

/// C-g: キャンセル（マークをクリアし、エラーメッセージも消す）
pub fn keyboardQuit(e: *Editor) !void {
    const window = e.getCurrentWindow();
    // マークがあればクリア（Emacsと同じ挙動）
    if (window.mark_pos != null) {
        window.mark_pos = null;
        e.getCurrentView().markFullRedraw(); // 選択ハイライトを消すため
        e.getCurrentView().setError(config.Messages.MARK_DEACTIVATED);
    } else {
        e.getCurrentView().clearError();
    }
}

// ========================================
// ヘルパー関数
// ========================================


/// 現在行のインデント（先頭の空白）を取得
/// Enter時の自動インデントに使用
/// buf: 呼び出し元が提供するバッファ（スレッドセーフ）
pub fn getCurrentLineIndent(e: *Editor, buf: []u8) []const u8 {
    const buffer = e.getCurrentBufferContent();
    const cursor_pos = e.getCurrentView().getCursorBufferPos();

    // バイト位置から行番号を取得し、その行の開始位置を取得
    const line_num = buffer.findLineByPos(cursor_pos);
    const line_start = buffer.getLineStart(line_num) orelse return "";

    var indent_len: usize = 0;

    // PieceIteratorで行頭からイテレート
    var iter = PieceIterator.init(buffer);
    iter.seek(line_start);

    while (iter.next()) |byte| {
        if (byte == ' ' or byte == '\t') {
            if (indent_len < buf.len) {
                buf[indent_len] = byte;
                indent_len += 1;
            }
        } else {
            break;
        }
    }

    return buf[0..indent_len];
}

/// 行頭の空白（スペース/タブ）をスキップした位置を返す
fn skipLeadingWhitespace(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
        i += 1;
    }
    return i;
}

/// 指定のプレフィックスでコメント行かどうか判定（言語定義がない場合のフォールバック用）
fn isCommentWithPrefix(line: []const u8, prefix: []const u8) bool {
    const i = skipLeadingWhitespace(line);
    return i + prefix.len <= line.len and std.mem.startsWith(u8, line[i..], prefix);
}

/// 指定のプレフィックスでコメント開始位置を検索（言語定義がない場合のフォールバック用）
fn findCommentStartWithPrefix(line: []const u8, prefix: []const u8) ?usize {
    const i = skipLeadingWhitespace(line);
    return if (i + prefix.len <= line.len and std.mem.startsWith(u8, line[i..], prefix)) i else null;
}
