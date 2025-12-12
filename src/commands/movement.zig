// 移動コマンド
// カーソル移動、単語移動、段落移動、ページスクロール、ウィンドウ切り替え

const std = @import("std");
const Editor = @import("editor").Editor;
const buffer_mod = @import("buffer");
const Buffer = buffer_mod.Buffer;
const PieceIterator = buffer_mod.PieceIterator;
const unicode = @import("unicode");

// ========================================
// 基本カーソル移動
// ========================================

/// C-f / Right: 右に移動
pub fn cursorRight(e: *Editor) !void {
    e.getCurrentView().moveCursorRight();
}

/// C-b / Left: 左に移動
pub fn cursorLeft(e: *Editor) !void {
    e.getCurrentView().moveCursorLeft();
}

/// C-n / Down: 下に移動
pub fn cursorDown(e: *Editor) !void {
    e.getCurrentView().moveCursorDown();
}

/// C-p / Up: 上に移動
pub fn cursorUp(e: *Editor) !void {
    e.getCurrentView().moveCursorUp();
}

/// C-a / Home: 行頭に移動
pub fn lineStart(e: *Editor) !void {
    e.getCurrentView().moveToLineStart();
}

/// C-e / End: 行末に移動
pub fn lineEnd(e: *Editor) !void {
    e.getCurrentView().moveToLineEnd();
}

/// M-<: バッファの先頭に移動
pub fn bufferStart(e: *Editor) !void {
    e.getCurrentView().moveToBufferStart();
}

/// M->: バッファの末尾に移動
pub fn bufferEnd(e: *Editor) !void {
    e.getCurrentView().moveToBufferEnd();
}

// ========================================
// 単語移動
// ========================================

/// M-f: 次の単語へ移動
pub fn forwardWord(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    if (start_pos >= buffer.len()) return;

    var iter = PieceIterator.init(buffer);
    iter.seek(start_pos);

    var prev_type: ?unicode.CharType = null;

    while (iter.nextCodepoint() catch null) |cp| {
        const current_type = unicode.getCharType(cp);

        if (prev_type) |pt| {
            // 文字種が変わったら停止（ただし空白は飛ばす）
            if (current_type != .space and pt != .space and current_type != pt) {
                const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
                e.setCursorToPos(iter.global_pos - cp_len);
                return;
            }
            // 空白から非空白に変わる場合、その位置で停止
            if (pt == .space and current_type != .space) {
                const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
                e.setCursorToPos(iter.global_pos - cp_len);
                return;
            }
        }

        prev_type = current_type;
    }

    // EOFに到達
    e.setCursorToPos(iter.global_pos);
}

/// M-b: 前の単語へ移動
pub fn backwardWord(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    if (start_pos == 0) return;

    var pos = start_pos;
    var prev_type: ?unicode.CharType = null;
    var found_non_space = false;

    while (pos > 0) {
        // 1文字戻る（UTF-8先頭バイトを探す）
        const char_start = buffer.findUtf8CharStart(pos);

        // getByteAtでUTF-8バイト列を読み取り、コードポイントをデコード
        const cp = buffer.decodeCodepointAt(char_start) orelse break;

        const current_type = unicode.getCharType(cp);

        // 空白をスキップ
        if (!found_non_space and current_type == .space) {
            pos = char_start;
            continue;
        }

        found_non_space = true;

        if (prev_type) |pt| {
            // 文字種が変わったら停止
            if (current_type != pt) {
                break;
            }
        }

        prev_type = current_type;
        pos = char_start;
    }

    // カーソル位置を更新
    if (pos < start_pos) {
        e.setCursorToPos(pos);
    }
}

// ========================================
// 段落移動
// ========================================

/// M-}: 次の段落へ移動
pub fn forwardParagraph(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    const buf_len = buffer.len();
    if (start_pos >= buf_len) return;

    var iter = PieceIterator.init(buffer);
    iter.seek(start_pos);

    var pos = start_pos;
    var found_blank_section = false;

    // 現在行の終わりまで移動
    while (iter.next()) |byte| {
        pos += 1;
        if (byte == '\n') break;
    }

    // 空行のブロックを探し、その後の非空白行の先頭へ移動
    while (pos < buf_len) {
        iter = PieceIterator.init(buffer);
        iter.seek(pos);

        // 現在行が空行かチェック
        const line_start = pos;
        var is_blank = true;
        var line_end = pos;

        while (iter.next()) |byte| {
            line_end += 1;
            if (byte == '\n') break;
            if (byte != ' ' and byte != '\t' and byte != '\r') {
                is_blank = false;
            }
        }

        if (is_blank) {
            found_blank_section = true;
            pos = line_end;
        } else if (found_blank_section) {
            // 空行の後の最初の非空白行に到達
            e.setCursorToPos(line_start);
            return;
        } else {
            pos = line_end;
        }

        if (pos >= buf_len) break;
    }

    // バッファの終端に到達
    if (pos > start_pos) {
        e.setCursorToPos(pos);
    }
}

/// M-{: 前の段落へ移動
pub fn backwardParagraph(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    if (start_pos == 0) return;

    var pos = start_pos;
    var found_blank_section = false;

    // 現在行の先頭に移動
    while (pos > 0) {
        var iter = PieceIterator.init(buffer);
        iter.seek(pos - 1);
        const byte = iter.next() orelse break;
        if (byte == '\n') break;
        pos -= 1;
    }

    // 1つ前の行から開始
    if (pos > 0) pos -= 1;

    // 空行のブロックを見つけて、その前の段落の先頭へ移動
    while (pos > 0) {
        // 現在行の先頭を見つける
        var line_start = pos;
        while (line_start > 0) {
            var iter = PieceIterator.init(buffer);
            iter.seek(line_start - 1);
            const byte = iter.next() orelse break;
            if (byte == '\n') break;
            line_start -= 1;
        }

        // 現在行が空行かチェック
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);
        var is_blank = true;

        while (iter.next()) |byte| {
            if (byte == '\n') break;
            if (byte != ' ' and byte != '\t' and byte != '\r') {
                is_blank = false;
                break;
            }
        }

        if (is_blank) {
            found_blank_section = true;
            if (line_start > 0) {
                pos = line_start - 1;
            } else {
                break;
            }
        } else if (found_blank_section) {
            // 空行の前の非空白行に到達
            e.setCursorToPos(line_start);
            return;
        } else {
            if (line_start > 0) {
                pos = line_start - 1;
            } else {
                // バッファの先頭に到達
                e.setCursorToPos(0);
                return;
            }
        }
    }

    // バッファの先頭に到達
    e.setCursorToPos(0);
}

// ========================================
// ページスクロール
// ========================================

/// C-v / PageDown: 1ページ下にスクロール
pub fn pageDown(e: *Editor) !void {
    pageScroll(e, .down);
}

/// M-v / PageUp: 1ページ上にスクロール
pub fn pageUp(e: *Editor) !void {
    pageScroll(e, .up);
}

/// ページスクロールの共通実装
fn pageScroll(e: *Editor, direction: enum { up, down }) void {
    const view = e.getCurrentView();
    const page_size = if (view.viewport_height >= 3) view.viewport_height - 2 else 1;
    var i: usize = 0;
    while (i < page_size) : (i += 1) {
        switch (direction) {
            .up => view.moveCursorUp(),
            .down => view.moveCursorDown(),
        }
    }
}

// ========================================
// 画面操作
// ========================================

/// C-l: 画面を中央に再配置
pub fn recenter(e: *Editor) !void {
    const view = e.getCurrentView();
    const visible_lines = if (view.viewport_height >= 2) view.viewport_height - 2 else 1;
    const center = visible_lines / 2;
    const current_line = view.top_line + view.cursor_y;
    const old_top_line = view.top_line;
    if (current_line >= center) {
        view.top_line = current_line - center;
    } else {
        view.top_line = 0;
    }
    view.cursor_y = if (current_line >= view.top_line) current_line - view.top_line else 0;
    // top_lineが変わったら再描画
    if (view.top_line != old_top_line) {
        view.markFullRedraw();
    }
}

// ========================================
// ウィンドウ操作
// ========================================

/// Ctrl+Tab: 次のウィンドウに切り替え（WindowManager経由）
pub fn nextWindow(e: *Editor) !void {
    e.window_manager.nextWindow();
}

/// Ctrl+Shift+Tab: 前のウィンドウに切り替え（WindowManager経由）
pub fn prevWindow(e: *Editor) !void {
    e.window_manager.prevWindow();
}

// ========================================
// 選択移動（Shift+矢印キー）
// ========================================

/// マークがなければ現在位置に設定（選択開始）
fn ensureMark(e: *Editor) void {
    const window = e.getCurrentWindow();
    if (window.mark_pos == null) {
        window.mark_pos = e.getCurrentView().getCursorBufferPos();
    }
}

/// Shift+Up: 選択しながら上に移動
pub fn selectUp(e: *Editor) !void {
    ensureMark(e);
    e.getCurrentView().moveCursorUp();
}

/// Shift+Down: 選択しながら下に移動
pub fn selectDown(e: *Editor) !void {
    ensureMark(e);
    e.getCurrentView().moveCursorDown();
}

/// Shift+Left: 選択しながら左に移動
pub fn selectLeft(e: *Editor) !void {
    ensureMark(e);
    e.getCurrentView().moveCursorLeft();
}

/// Shift+Right: 選択しながら右に移動
pub fn selectRight(e: *Editor) !void {
    ensureMark(e);
    e.getCurrentView().moveCursorRight();
}

/// Shift+PageUp: 選択しながらページ上に移動
pub fn selectPageUp(e: *Editor) !void {
    ensureMark(e);
    pageScroll(e, .up);
}

/// Shift+PageDown: 選択しながらページ下に移動
pub fn selectPageDown(e: *Editor) !void {
    ensureMark(e);
    pageScroll(e, .down);
}

/// M-F (Alt+Shift+f): 選択しながら次の単語へ移動
pub fn selectForwardWord(e: *Editor) !void {
    ensureMark(e);
    try forwardWord(e);
}

/// M-B (Alt+Shift+b): 選択しながら前の単語へ移動
pub fn selectBackwardWord(e: *Editor) !void {
    ensureMark(e);
    try backwardWord(e);
}

/// M-V (Alt+Shift+v): 選択しながらページ上に移動
pub fn selectPageUpAlt(e: *Editor) !void {
    ensureMark(e);
    pageScroll(e, .up);
}

// ========================================
// ヘルパー関数
// ========================================
// decodeCodepointAt, findUtf8CharStart は Buffer に移動済み
