// 移動コマンド
// カーソル移動、単語移動、段落移動、ページスクロール、ウィンドウ切り替え

const std = @import("std");
const config = @import("config");
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
/// PieceIteratorを使用してO(1)で順次読み取り（getByteAtのO(pieces)を回避）
pub fn forwardWord(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    if (start_pos >= buffer.len()) return;

    var iter = PieceIterator.init(buffer);
    iter.seek(start_pos);

    var prev_type: ?unicode.CharType = null;
    var prev_pos: usize = start_pos;

    while (true) {
        const current_pos = iter.global_pos;
        const byte = iter.next() orelse break;

        // 非ASCIIバイトならコードポイント処理にフォールバック
        if (!unicode.isAsciiByte(byte)) {
            // 現在位置に戻してコードポイント単位で処理
            iter.seek(current_pos);
            while (iter.nextCodepoint() catch null) |cp| {
                const current_type = unicode.getCharType(cp);
                if (prev_type) |pt| {
                    if (current_type != .space and pt != .space and current_type != pt) {
                        e.setCursorToPos(prev_pos);
                        return;
                    }
                    if (pt == .space and current_type != .space) {
                        e.setCursorToPos(prev_pos);
                        return;
                    }
                }
                prev_type = current_type;
                prev_pos = iter.global_pos;
            }
            e.setCursorToPos(iter.global_pos);
            return;
        }

        // ASCIIバイト: 直接文字種判定（u8→u21変換はコスト0）
        const current_type = unicode.getCharType(@intCast(byte));

        if (prev_type) |pt| {
            if (current_type != .space and pt != .space and current_type != pt) {
                e.setCursorToPos(prev_pos);
                return;
            }
            if (pt == .space and current_type != .space) {
                e.setCursorToPos(prev_pos);
                return;
            }
        }

        prev_type = current_type;
        prev_pos = iter.global_pos;
    }

    // EOFに到達
    e.setCursorToPos(iter.global_pos);
}

/// M-b: 前の単語へ移動
/// PieceIteratorでチャンク読み込み→後方処理（getByteAtのO(pieces)を回避）
pub fn backwardWord(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    if (start_pos == 0) return;

    // 後方スキャン用にチャンクを読み込む
    const chunk_size = config.Search.BACKWARD_CHUNK_SIZE;
    const raw_scan_start = start_pos -| @min(start_pos, chunk_size);

    // PieceIteratorでチャンクを読み込み（1回のseek + 順次読み）
    var iter = PieceIterator.init(buffer);

    // scan_start がUTF-8文字の途中であれば、先頭まで戻る
    const scan_start = iter.alignToUtf8Start(raw_scan_start);
    iter.seek(scan_start);

    // scan_start 調整後の実際の読み込みサイズを計算
    const look_back = start_pos - scan_start;
    var chunk: [chunk_size + 4]u8 = undefined; // 最大4バイトの追加に対応
    var chunk_len: usize = 0;
    while (chunk_len < look_back) {
        if (iter.next()) |byte| {
            chunk[chunk_len] = byte;
            chunk_len += 1;
        } else break;
    }

    // チャンクを後方から処理
    var pos = start_pos;
    var prev_type: ?unicode.CharType = null;
    var found_non_space = false;
    var i = chunk_len;

    while (i > 0) {
        const byte = chunk[i - 1];

        // 非ASCII: UTF-8の先頭バイトを探す
        if (!unicode.isAsciiByte(byte)) {
            // continuation byte (10xxxxxx) をスキップして先頭を探す
            var char_start_idx = i - 1;
            while (char_start_idx > 0 and unicode.isUtf8Continuation(chunk[char_start_idx])) {
                char_start_idx -= 1;
            }

            // コードポイントをデコード
            const cp = decodeUtf8FromChunk(chunk[char_start_idx..i]) orelse break;
            const current_type = unicode.getCharType(cp);

            if (!found_non_space and current_type == .space) {
                i = char_start_idx;
                pos = scan_start + char_start_idx;
                continue;
            }
            found_non_space = true;

            if (prev_type) |pt| {
                if (current_type != pt) break;
            }
            prev_type = current_type;
            i = char_start_idx;
            pos = scan_start + char_start_idx;
            continue;
        }

        // ASCIIバイト
        const current_type = unicode.getCharType(@intCast(byte));

        if (!found_non_space and current_type == .space) {
            i -= 1;
            pos -= 1;
            continue;
        }
        found_non_space = true;

        if (prev_type) |pt| {
            if (current_type != pt) break;
        }
        prev_type = current_type;
        i -= 1;
        pos -= 1;
    }

    // チャンク先頭に到達した場合、さらに後方を処理
    // 追加チャンクを読み込んで継続（getByteAtのO(pieces)を回避）
    while (i == 0 and pos > 0 and found_non_space) {
        // 次のチャンクを読み込む（UTF-8境界を調整）
        const raw_next_scan_start = pos -| @min(pos, chunk_size);
        const next_scan_start = iter.alignToUtf8Start(raw_next_scan_start);
        const next_look_back = pos - next_scan_start;
        iter.seek(next_scan_start);
        chunk_len = 0;
        while (chunk_len < next_look_back) {
            if (iter.next()) |byte| {
                chunk[chunk_len] = byte;
                chunk_len += 1;
            } else break;
        }

        // 新しいチャンクを後方から処理
        i = chunk_len;
        while (i > 0) {
            const byte = chunk[i - 1];

            // 非ASCII: UTF-8の先頭バイトを探す
            if (!unicode.isAsciiByte(byte)) {
                var char_start_idx = i - 1;
                while (char_start_idx > 0 and unicode.isUtf8Continuation(chunk[char_start_idx])) {
                    char_start_idx -= 1;
                }

                const cp = decodeUtf8FromChunk(chunk[char_start_idx..i]) orelse break;
                const current_type = unicode.getCharType(cp);

                if (prev_type) |pt| {
                    if (current_type != pt) {
                        // 単語境界を見つけた - ループ終了
                        i = 1; // 外側のwhileを終了させる
                        break;
                    }
                }
                prev_type = current_type;
                i = char_start_idx;
                pos = next_scan_start + char_start_idx;
                continue;
            }

            // ASCIIバイト
            const current_type = unicode.getCharType(@intCast(byte));

            if (prev_type) |pt| {
                if (current_type != pt) {
                    // 単語境界を見つけた - ループ終了
                    i = 1; // 外側のwhileを終了させる
                    break;
                }
            }
            prev_type = current_type;
            i -= 1;
            pos = next_scan_start + i;
        }
    }

    if (pos < start_pos) {
        e.setCursorToPos(pos);
    }
}

/// チャンクからUTF-8コードポイントをデコード（標準ライブラリを使用）
inline fn decodeUtf8FromChunk(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    return std.unicode.utf8Decode(bytes) catch null;
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
        // イテレータは既に正しい位置にある（前のループから継続）
        // seek削除により大きなファイルで2-5倍高速化

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

        // 進捗がない場合は無限ループ防止
        if (line_end == line_start) break;
        if (pos >= buf_len) break;
    }

    // バッファの終端に到達
    if (pos > start_pos) {
        e.setCursorToPos(pos);
    }
}

/// 指定位置を含む行の先頭を見つける（O(log N) - 行インデックス使用）
fn findLineStart(buffer: *Buffer, pos: usize) usize {
    if (pos == 0) return 0;
    const line_num = buffer.findLineByPos(pos);
    return buffer.getLineStart(line_num) orelse 0;
}

/// M-{: 前の段落へ移動
pub fn backwardParagraph(e: *Editor) !void {
    const buffer = e.getCurrentBufferContent();
    const start_pos = e.getCurrentView().getCursorBufferPos();
    if (start_pos == 0) return;

    // 現在行の先頭に移動し、1つ前の行から開始
    var pos = findLineStart(buffer, start_pos);
    if (pos > 0) pos -= 1;

    var found_blank_section = false;

    // 空行のブロックを見つけて、その前の段落の先頭へ移動
    var iter = PieceIterator.init(buffer);
    while (pos > 0) {
        const line_start = findLineStart(buffer, pos);

        // 現在行が空行かチェック（イテレータを再利用）
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

/// ページスクロールの共通実装（最適化版）
/// scrollViewportとキャッシュシフトを活用してmarkFullRedrawを回避
fn pageScroll(e: *Editor, direction: enum { up, down }) void {
    const view = e.getCurrentView();
    const buffer = e.getCurrentBufferContent();
    const total_lines = buffer.lineCount();
    if (total_lines == 0) return;

    const reserved = config.Editor.VIEWPORT_RESERVED_LINES;
    const page_size = if (view.viewport_height >= reserved + 1) view.viewport_height - reserved else 1;
    const max_cursor_y = if (view.viewport_height >= reserved) view.viewport_height - reserved else 0;
    const max_line = if (total_lines > 0) total_lines - 1 else 0;

    const current_line = view.top_line + view.cursor_y;
    const old_top_line = view.top_line;

    switch (direction) {
        .down => {
            // 下スクロール：page_size行下に移動
            const target_line = @min(current_line + page_size, max_line);
            if (target_line == current_line) return; // 移動なし

            // top_lineとcursor_yを計算
            if (target_line <= max_cursor_y) {
                // 画面上部に収まる
                view.top_line = 0;
                view.cursor_y = target_line;
            } else {
                // スクロールが必要
                view.top_line = target_line - view.cursor_y;
                // top_lineが最大を超えないように
                if (view.top_line + max_cursor_y > max_line) {
                    view.top_line = if (max_line >= max_cursor_y) max_line - max_cursor_y else 0;
                    view.cursor_y = target_line - view.top_line;
                }
            }
        },
        .up => {
            // 上スクロール：page_size行上に移動
            const target_line = if (current_line >= page_size) current_line - page_size else 0;
            if (target_line == current_line) return; // 移動なし

            // top_lineとcursor_yを計算
            if (target_line < view.top_line) {
                // 上にスクロールが必要
                view.top_line = target_line;
                view.cursor_y = 0;
            } else {
                // 画面内で移動
                view.cursor_y = target_line - view.top_line;
            }
        },
    }

    // スクロール量を計算してmarkScroll（ターミナルスクロール最適化）
    const scroll_delta: i32 = @intCast(@as(i64, @intCast(view.top_line)) - @as(i64, @intCast(old_top_line)));
    if (scroll_delta != 0) {
        view.markScroll(scroll_delta);
    }

    // 行幅とバイト位置を同時に取得（1回の走査で完了）
    const target_line = view.top_line + view.cursor_y;
    const info = view.getLineWidthWithBytePos(target_line, view.cursor_x);

    // カーソル位置をクランプし、キャッシュを更新
    view.cursor_x = info.clamped_x;
    view.cursor_byte_pos_cache = info.byte_pos;
    view.cursor_byte_pos_cache_x = view.cursor_x;
    view.cursor_byte_pos_cache_y = view.cursor_y;
    view.cursor_byte_pos_cache_top_line = view.top_line;

    // 水平スクロール位置もクランプ
    if (view.top_col > view.cursor_x) {
        view.top_col = view.cursor_x;
        view.markHorizontalScroll();
    }
}

// ========================================
// 画面操作
// ========================================

/// C-l: 画面を中央に再配置
pub fn recenter(e: *Editor) !void {
    const view = e.getCurrentView();
    const reserved = config.Editor.VIEWPORT_RESERVED_LINES;
    const visible_lines = if (view.viewport_height >= reserved) view.viewport_height - reserved else 1;
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
    // Shift+矢印で選択したことを記録（通常矢印で解除される）
    window.shift_select = true;
}

/// Shift+Up: 選択しながら上に移動
pub fn selectUp(e: *Editor) !void {
    ensureMark(e);
    try cursorUp(e);
}

/// Shift+Down: 選択しながら下に移動
pub fn selectDown(e: *Editor) !void {
    ensureMark(e);
    try cursorDown(e);
}

/// Shift+Left: 選択しながら左に移動
pub fn selectLeft(e: *Editor) !void {
    ensureMark(e);
    try cursorLeft(e);
}

/// Shift+Right: 選択しながら右に移動
pub fn selectRight(e: *Editor) !void {
    ensureMark(e);
    try cursorRight(e);
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

// ========================================
// ヘルパー関数
// ========================================
// decodeCodepointAt, findUtf8CharStart は Buffer に移動済み
