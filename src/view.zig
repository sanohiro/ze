// ============================================================================
// View - ウィンドウの表示状態管理
// ============================================================================
//
// 【責務】
// - バッファの表示位置（スクロール、カーソル）
// - ダーティ領域の追跡（差分描画の効率化）
// - ステータスバーとエラーメッセージの表示
// - 検索ハイライト
// - 言語別のタブ幅・インデント設定
//
// 【差分描画システム】
// 全画面再描画は遅いため、変更のあった行のみ再描画する:
// - dirty_start/dirty_end: 再描画が必要な行範囲
// - needs_full_redraw: サイズ変更時など全体再描画フラグ
// - prev_screen: 前フレームの画面状態（セルレベル差分用）
//
// 【1ウィンドウ = 1View】
// Windowが画面上の位置とサイズを持ち、Viewが表示内容を管理。
// 同じバッファを複数ウィンドウで開くと、それぞれ独立したViewを持つ。
// ============================================================================

const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const PieceIterator = @import("buffer.zig").PieceIterator;
const Terminal = @import("terminal.zig").Terminal;
const config = @import("config.zig");
const syntax = @import("syntax.zig");
const encoding = @import("encoding.zig");

/// UTF-8文字列をバイト数制限内でトランケート（文字境界を守る）
/// 日本語などマルチバイト文字を途中で切らないようにする
fn truncateUtf8(str: []const u8, max_bytes: usize) []const u8 {
    if (str.len <= max_bytes) return str;
    if (max_bytes == 0) return str[0..0];

    // max_bytesから後ろに戻って、継続バイト(10xxxxxx)でない位置を見つける
    var end = max_bytes;
    while (end > 0) {
        // UTF-8継続バイトは0x80-0xBF (10xxxxxx)
        if ((str[end] & 0xC0) != 0x80) break;
        end -= 1;
    }
    return str[0..end];
}

pub const View = struct {
    buffer: *Buffer,
    top_line: usize,
    top_col: usize, // 水平スクロールオフセット
    cursor_x: usize,
    cursor_y: usize,
    // ビューポートサイズ（ウィンドウ分割時に使用）
    viewport_width: usize,
    viewport_height: usize,
    // Dirty範囲追跡（差分描画用）
    dirty_start: ?usize,
    dirty_end: ?usize,
    needs_full_redraw: bool,
    // レンダリング用の再利用バッファ（メモリ確保を減らす）
    line_buffer: std.ArrayList(u8),
    // エラーメッセージ表示用（固定バッファでダングリングポインタを防止）
    error_msg_buf: [256]u8,
    error_msg_len: usize,
    // セルレベル差分描画用: 前フレームの画面状態
    prev_screen: std.ArrayList(std.ArrayList(u8)),
    // 検索ハイライト用（固定バッファでダングリングポインタを防止）
    search_highlight_buf: [256]u8,
    search_highlight_len: usize,
    // 行番号表示の幅キャッシュ（幅変更時に全画面再描画するため）
    cached_line_num_width: usize,
    // 言語定義（シンタックス情報）
    language: *const syntax.LanguageDef,
    // バッファ固有の設定（M-xコマンドで上書き可能）
    tab_width: ?u8, // nullなら言語デフォルト
    indent_style: ?syntax.IndentStyle, // nullなら言語デフォルト
    // ブロックコメント状態キャッシュ（O(n²)を避けるため）
    cached_block_state: ?bool, // top_lineでのブロックコメント状態
    cached_block_top_line: usize, // キャッシュが有効な行
    // レンダリング用スクラッチバッファ（毎行のalloc/freeを避ける）
    expanded_line: std.ArrayList(u8),
    highlighted_line: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, buffer: *Buffer) !View {
        var line_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer line_buffer.deinit(allocator);

        var prev_screen = try std.ArrayList(std.ArrayList(u8)).initCapacity(allocator, 0);
        errdefer prev_screen.deinit(allocator);

        var expanded_line = try std.ArrayList(u8).initCapacity(allocator, 256);
        errdefer expanded_line.deinit(allocator);

        var highlighted_line = try std.ArrayList(u8).initCapacity(allocator, 256);
        errdefer highlighted_line.deinit(allocator);

        return View{
            .buffer = buffer,
            .top_line = 0,
            .top_col = 0,
            .cursor_x = 0,
            .cursor_y = 0,
            .viewport_width = 80, // デフォルト、setViewportで更新
            .viewport_height = 24, // デフォルト、setViewportで更新
            .dirty_start = null,
            .dirty_end = null,
            .needs_full_redraw = true,
            .line_buffer = line_buffer,
            .error_msg_buf = undefined,
            .error_msg_len = 0,
            .prev_screen = prev_screen,
            .search_highlight_buf = undefined,
            .search_highlight_len = 0,
            .cached_line_num_width = 0,
            .language = &syntax.lang_text, // デフォルトはテキストモード
            .tab_width = null, // 言語デフォルトを使用
            .indent_style = null, // 言語デフォルトを使用
            .cached_block_state = null, // キャッシュ無効
            .cached_block_top_line = 0,
            .expanded_line = expanded_line,
            .highlighted_line = highlighted_line,
            .allocator = allocator,
        };
    }

    /// ファイル名とコンテンツから言語を検出して設定
    pub fn detectLanguage(self: *View, filename: ?[]const u8, content: ?[]const u8) void {
        self.language = syntax.detectLanguage(filename, content);
        self.markFullRedraw(); // 言語が変わったら再描画
    }

    /// 言語を直接設定
    pub fn setLanguage(self: *View, lang: *const syntax.LanguageDef) void {
        self.language = lang;
        self.markFullRedraw();
    }

    /// ビューポートサイズを設定し、カーソルを制約
    pub fn setViewport(self: *View, width: usize, height: usize) void {
        self.viewport_width = width;
        self.viewport_height = height;
        // カーソルがビューポート外にならないよう制約
        self.constrainCursor();
        self.markFullRedraw();
    }

    /// カーソルをビューポート内に制約
    pub fn constrainCursor(self: *View) void {
        // ステータスバー分を除いた最大行
        const max_cursor_y = if (self.viewport_height >= 2) self.viewport_height - 2 else 0;
        if (self.cursor_y > max_cursor_y) {
            // カーソルがビューポート外なら、スクロールして見えるようにする
            const overshoot = self.cursor_y - max_cursor_y;
            self.top_line += overshoot;
            self.cursor_y = max_cursor_y;
        }

        // 水平方向も制約（行番号幅を除いた可視幅）
        const line_num_width = self.getLineNumberWidth();
        const visible_width = if (self.viewport_width > line_num_width) self.viewport_width - line_num_width else 1;
        if (self.cursor_x >= self.top_col + visible_width) {
            // カーソルが右端を超えたらスクロール
            self.top_col = if (self.cursor_x >= visible_width) self.cursor_x - visible_width + 1 else 0;
        }
    }

    /// タブ幅を取得（設定値がなければ言語デフォルト）
    pub fn getTabWidth(self: *const View) u8 {
        return self.tab_width orelse self.language.indent_width;
    }

    /// タブ幅を設定
    pub fn setTabWidth(self: *View, width: u8) void {
        self.tab_width = width;
        self.markFullRedraw();
    }

    /// インデントスタイルを取得（設定値がなければ言語デフォルト）
    pub fn getIndentStyle(self: *const View) syntax.IndentStyle {
        return self.indent_style orelse self.language.indent_style;
    }

    /// インデントスタイルを設定
    pub fn setIndentStyle(self: *View, style: syntax.IndentStyle) void {
        self.indent_style = style;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.line_buffer.deinit(allocator);
        // 前フレームバッファのクリーンアップ
        for (self.prev_screen.items) |*line| {
            line.deinit(allocator);
        }
        self.prev_screen.deinit(allocator);
        // レンダリング用スクラッチバッファのクリーンアップ
        self.expanded_line.deinit(allocator);
        self.highlighted_line.deinit(allocator);
    }

    // エラーメッセージを設定（固定バッファにコピー）
    pub fn setError(self: *View, msg: []const u8) void {
        const len = @min(msg.len, self.error_msg_buf.len);
        @memcpy(self.error_msg_buf[0..len], msg[0..len]);
        self.error_msg_len = len;
    }

    // エラーメッセージを取得
    pub fn getError(self: *const View) ?[]const u8 {
        if (self.error_msg_len == 0) return null;
        return self.error_msg_buf[0..self.error_msg_len];
    }

    // エラーメッセージをクリア
    pub fn clearError(self: *View) void {
        self.error_msg_len = 0;
    }

    // 検索ハイライトを設定（固定バッファにコピー）
    pub fn setSearchHighlight(self: *View, search_str: ?[]const u8) void {
        if (search_str) |str| {
            const len = @min(str.len, self.search_highlight_buf.len);
            @memcpy(self.search_highlight_buf[0..len], str[0..len]);
            self.search_highlight_len = len;
        } else {
            self.search_highlight_len = 0;
        }
        // ハイライトが変わったので全画面再描画
        self.markFullRedraw();
    }

    // 検索ハイライト文字列を取得
    pub fn getSearchHighlight(self: *const View) ?[]const u8 {
        if (self.search_highlight_len == 0) return null;
        return self.search_highlight_buf[0..self.search_highlight_len];
    }

    /// 出力済み行をviewport_widthまでスペースでパディング
    /// ANSIエスケープシーケンスを除いた表示幅で計算
    fn padToWidth(self: *View, term: *Terminal, line: []const u8, viewport_width: usize) !void {
        _ = self;
        // 表示幅を計算（ANSIエスケープシーケンスを除外）
        var display_width: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            const c = line[i];
            if (c == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
                // ANSIエスケープシーケンスをスキップ
                i += 2;
                while (i < line.len and line[i] != 'm') : (i += 1) {}
                if (i < line.len) i += 1;
            } else if (c < 0x80) {
                // ASCII
                display_width += 1;
                i += 1;
            } else {
                // UTF-8: 幅を判定
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                if (i + len <= line.len) {
                    const cp = std.unicode.utf8Decode(line[i..][0..len]) catch {
                        i += 1;
                        continue;
                    };
                    // CJK文字などの全角幅判定（簡易版）
                    if (cp >= 0x1100 and cp <= 0x115F) display_width += 2 // Hangul Jamo
                    else if (cp >= 0x2E80 and cp <= 0x9FFF) display_width += 2 // CJK
                    else if (cp >= 0xAC00 and cp <= 0xD7AF) display_width += 2 // Hangul Syllables
                    else if (cp >= 0xF900 and cp <= 0xFAFF) display_width += 2 // CJK Compat
                    else if (cp >= 0xFE10 and cp <= 0xFE1F) display_width += 2 // Vertical Forms
                    else if (cp >= 0xFF00 and cp <= 0xFFEF) display_width += 2 // Halfwidth/Fullwidth
                    else if (cp >= 0x20000 and cp <= 0x2FFFF) display_width += 2 // CJK Extension
                    else display_width += 1;
                    i += len;
                } else {
                    i += 1;
                }
            }
        }
        // 残りをスペースで埋める
        if (display_width < viewport_width) {
            var padding = viewport_width - display_width;
            while (padding > 0) : (padding -= 1) {
                try term.write(" ");
            }
        }
    }

    // 行番号の表示幅を計算（999行まで固定、1000行以上で動的拡張）
    fn getLineNumberWidth(self: *View) usize {
        if (!config.Editor.SHOW_LINE_NUMBERS) return 0;

        const total_lines = self.buffer.lineCount();
        if (total_lines == 0) return 0;

        // 999行まで: 3桁 + スペース2個 = 5文字固定
        if (total_lines <= 999) {
            return 5;
        }

        // 1000行以上: 桁数を動的計算
        var width: usize = 1;
        var n = total_lines;
        while (n >= 10) {
            width += 1;
            n /= 10;
        }
        return width + 2; // 行番号 + スペース2個
    }

    pub fn markDirty(self: *View, start_line: usize, end_line: ?usize) void {
        if (self.dirty_start) |ds| {
            self.dirty_start = @min(ds, start_line);
        } else {
            self.dirty_start = start_line;
        }

        // end_line が null なら EOF まで
        if (end_line) |e| {
            if (self.dirty_end) |de| {
                self.dirty_end = @max(de, e);
            } else {
                self.dirty_end = e;
            }
        } else {
            // null が渡されたら dirty_end も null (EOF まで)
            self.dirty_end = null;
        }

        // ブロックコメントキャッシュの無効化
        // ブロックコメントがない言語ではキャッシュ不要、無効化もスキップ
        if (self.language.block_comment != null) {
            // 変更がキャッシュ対象行より前なら無効化
            if (self.cached_block_state != null and start_line < self.cached_block_top_line) {
                self.cached_block_state = null;
            }
        }
    }

    pub fn markFullRedraw(self: *View) void {
        self.needs_full_redraw = true;
        self.dirty_start = null;
        self.dirty_end = null;

        // 前フレームバッファをクリア（全画面再描画なので差分計算不要）
        for (self.prev_screen.items) |*line| {
            line.deinit(self.allocator);
        }
        self.prev_screen.clearRetainingCapacity();
    }

    pub fn clearDirty(self: *View) void {
        self.dirty_start = null;
        self.dirty_end = null;
        self.needs_full_redraw = false;
    }

    /// 指定行より前の行をスキャンして、ブロックコメント内で開始するかを判定
    /// キャッシュを使用してO(n)からO(1)に最適化（top_lineが変わらない場合）
    fn computeBlockCommentState(self: *View, target_line: usize) bool {
        // ブロックコメントがない言語なら常にfalse
        if (self.language.block_comment == null) return false;

        // キャッシュヒット: 同じ行の状態がキャッシュされている
        if (self.cached_block_state) |cached_state| {
            if (self.cached_block_top_line == target_line) {
                return cached_state;
            }
        }

        // キャッシュミス: 再計算
        var in_block = false;
        var iter = PieceIterator.init(self.buffer);
        var line_buf = std.ArrayList(u8){};
        defer line_buf.deinit(self.allocator);

        var current_line: usize = 0;
        while (current_line < target_line) : (current_line += 1) {
            // 行を読み取る
            line_buf.clearRetainingCapacity();
            while (iter.next()) |ch| {
                if (ch == '\n') break;
                line_buf.append(self.allocator, ch) catch break;
            }

            // 行を解析
            const analysis = self.language.analyzeLine(line_buf.items, in_block);
            in_block = analysis.ends_in_block;
        }

        // キャッシュを更新
        self.cached_block_state = in_block;
        self.cached_block_top_line = target_line;

        return in_block;
    }

    // イテレータを再利用して行を描画（セルレベル差分描画版）
    fn renderLineWithIter(self: *View, term: *Terminal, screen_row: usize, file_line: usize, iter: *PieceIterator, line_buffer: *std.ArrayList(u8)) !bool {
        return self.renderLineWithIterOffset(term, 0, screen_row, file_line, iter, line_buffer, false);
    }

    // イテレータを再利用して行を描画（オフセット付き）
    /// 行を描画し、次の行のブロックコメント状態を返す
    fn renderLineWithIterOffset(self: *View, term: *Terminal, viewport_x: usize, viewport_y: usize, viewport_width: usize, screen_row: usize, file_line: usize, iter: *PieceIterator, line_buffer: *std.ArrayList(u8), in_block: bool) !bool {
        const abs_row = viewport_y + screen_row;
        // 再利用バッファをクリア
        line_buffer.clearRetainingCapacity();

        // 行末まで読み取る
        while (iter.next()) |ch| {
            if (ch == '\n') break;
            try line_buffer.append(self.allocator, ch);
        }

        // コメント範囲を解析（ブロックコメント対応）
        // コメントがない言語では解析をスキップ（最適化）
        const analysis = if (self.language.hasComments() or in_block)
            self.language.analyzeLine(line_buffer.items, in_block)
        else
            syntax.LanguageDef.LineAnalysis.init();

        // Tab展開用スクラッチバッファをクリアして再利用
        self.expanded_line.clearRetainingCapacity();

        // 行番号を先に追加（グレー表示 + スペース2個）
        const line_num_width = self.getLineNumberWidth();
        if (line_num_width > 0) {
            var num_buf: [64]u8 = undefined;
            // グレー(\x1b[90m) + 右詰め行番号 + リセット(\x1b[m) + スペース2個
            // 注: getLineNumberWidthは最小5を返すが、防御的にサチュレート減算
            const num_width = if (line_num_width >= 2) line_num_width - 2 else 1;
            const line_num_str = std.fmt.bufPrint(&num_buf, "\x1b[90m{d: >[1]}\x1b[m  ", .{ file_line + 1, num_width }) catch "";
            try self.expanded_line.appendSlice(self.allocator, line_num_str);
        }

        // grapheme-aware rendering with tab expansion and horizontal scrolling
        var byte_idx: usize = 0;
        var col: usize = 0; // 論理カラム位置（行全体での位置）
        const visible_width = if (viewport_width > line_num_width) viewport_width - line_num_width else 1;
        const visible_end = self.top_col + visible_width; // 表示範囲の終端（行番号幅を除く）

        // コメントスパンがある場合のみ追跡（最適化：span_count==0なら完全スキップ）
        const has_spans = analysis.span_count > 0;
        var in_comment = false; // 現在コメント内かどうか
        var current_span_idx: usize = 0; // 現在のコメントスパンインデックス
        var current_span: ?syntax.LanguageDef.CommentSpan = if (has_spans) analysis.spans[0] else null;

        while (byte_idx < line_buffer.items.len and col < visible_end) {
            // コメントスパンの開始・終了をチェック（スパンがある場合のみ）
            if (has_spans) {
                if (current_span) |span| {
                    if (!in_comment and byte_idx == span.start) {
                        // コメント開始
                        try self.expanded_line.appendSlice(self.allocator, "\x1b[90m");
                        in_comment = true;
                    }
                    if (in_comment) {
                        if (span.end) |end| {
                            if (byte_idx == end) {
                                // コメント終了
                                try self.expanded_line.appendSlice(self.allocator, "\x1b[m");
                                in_comment = false;
                                // 次のスパンへ
                                current_span_idx += 1;
                                current_span = if (current_span_idx < analysis.span_count) analysis.spans[current_span_idx] else null;
                            }
                        }
                    }
                }
            }

            const ch = line_buffer.items[byte_idx];
            if (ch < config.UTF8.CONTINUATION_MASK) {
                // ASCII
                if (ch == '\t') {
                    // Tabを空白に展開
                    const next_tab_stop = (col / self.getTabWidth() + 1) * self.getTabWidth();
                    const spaces_needed = next_tab_stop - col;
                    var i: usize = 0;
                    while (i < spaces_needed) : (i += 1) {
                        // 水平スクロール範囲内なら追加
                        if (col + i >= self.top_col and col + i < visible_end) {
                            try self.expanded_line.append(self.allocator, ' ');
                        }
                    }
                    col = next_tab_stop;
                    byte_idx += 1;
                } else {
                    // 通常のASCII文字
                    if (col >= self.top_col) {
                        try self.expanded_line.append(self.allocator, ch);
                    }
                    byte_idx += 1;
                    col += 1;
                }
            } else {
                // UTF-8: calculate codepoint and width
                const len = std.unicode.utf8ByteSequenceLength(ch) catch break;
                if (byte_idx + len > line_buffer.items.len) break;
                const codepoint = std.unicode.utf8Decode(line_buffer.items[byte_idx .. byte_idx + len]) catch {
                    byte_idx += 1;
                    continue;
                };
                const width = Buffer.charWidth(codepoint);
                // 水平スクロール範囲内なら追加
                if (col >= self.top_col) {
                    // UTF-8文字をそのままコピー
                    var i: usize = 0;
                    while (i < len) : (i += 1) {
                        try self.expanded_line.append(self.allocator, line_buffer.items[byte_idx + i]);
                    }
                }
                byte_idx += len;
                col += width;
            }
        }

        // コメント内だった場合はリセット（スパンがある場合のみチェック）
        if (has_spans and in_comment) {
            try self.expanded_line.appendSlice(self.allocator, "\x1b[m");
        }

        var new_line = self.expanded_line.items;

        // 検索ハイライト用スクラッチバッファをクリアして再利用
        self.highlighted_line.clearRetainingCapacity();

        if (self.getSearchHighlight()) |search_str| {
            if (search_str.len > 0 and new_line.len > 0) {
                // 行内で検索文字列を探してハイライト
                var pos: usize = 0;
                while (pos < new_line.len) {
                    if (std.mem.indexOf(u8, new_line[pos..], search_str)) |match_offset| {
                        const match_pos = pos + match_offset;
                        // マッチ前の部分をコピー
                        try self.highlighted_line.appendSlice(self.allocator, new_line[pos..match_pos]);
                        // 反転表示開始
                        try self.highlighted_line.appendSlice(self.allocator, "\x1b[7m");
                        // マッチ部分をコピー
                        try self.highlighted_line.appendSlice(self.allocator, new_line[match_pos..match_pos + search_str.len]);
                        // 反転表示終了
                        try self.highlighted_line.appendSlice(self.allocator, "\x1b[27m");
                        // 次の検索位置へ
                        pos = match_pos + search_str.len;
                    } else {
                        // これ以上マッチなし：残りをコピー
                        try self.highlighted_line.appendSlice(self.allocator, new_line[pos..]);
                        break;
                    }
                }
                new_line = self.highlighted_line.items;
            }
        }

        // 前フレームと比較してセルレベル差分描画
        if (screen_row < self.prev_screen.items.len) {
            const old_line = self.prev_screen.items[screen_row].items;

            // 差分を検出
            const min_len = @min(old_line.len, new_line.len);
            var diff_start: ?usize = null;
            var diff_end: usize = 0;

            // 前方から差分を探す
            for (0..min_len) |i| {
                if (old_line[i] != new_line[i]) {
                    if (diff_start == null) diff_start = i;
                    diff_end = i + 1;
                }
            }

            // 長さが違う場合は後ろも差分
            if (old_line.len != new_line.len) {
                if (diff_start == null) diff_start = min_len;
                diff_end = @max(old_line.len, new_line.len);
            }

            if (diff_start) |start_raw| {
                // 行番号の表示幅を取得
                const line_num_display_width = self.getLineNumberWidth();

                // 行番号がある場合は常に行全体を再描画
                // （ANSIシーケンスの計算が複雑なため、シンプルな実装を優先）
                if (line_num_display_width > 0) {
                    // 行頭から全体を再描画
                    try term.moveCursor(abs_row, viewport_x);
                    try term.write(new_line);
                    // 残りをスペースで埋める（CLEAR_LINEの代わり）
                    try self.padToWidth(term, new_line, viewport_width);
                } else {
                    // UTF-8文字境界に調整（継続バイトの途中から始まらないように）
                    var start = start_raw;
                    while (start > 0 and start < new_line.len and new_line[start] >= 0x80 and new_line[start] < 0xC0) {
                        // 継続バイト（0x80-0xBF）の場合は前に戻る
                        start -= 1;
                    }

                    // バイト位置から画面カラム位置を計算
                    // ANSIエスケープシーケンスを除外して計算
                    var screen_col: usize = 0;
                    var b: usize = 0;
                    while (b < start) {
                        const c = new_line[b];
                        // ANSIエスケープシーケンスをスキップ（ESC [ ... m）
                        if (c == 0x1B and b + 1 < new_line.len and new_line[b + 1] == '[') {
                            // ESCシーケンスの終わり('m')まで読み飛ばす
                            b += 2;
                            while (b < new_line.len and new_line[b] != 'm') {
                                b += 1;
                            }
                            if (b < new_line.len) b += 1; // 'm'をスキップ
                            continue;
                        }

                        if (c < config.UTF8.CONTINUATION_MASK) {
                            b += 1;
                            screen_col += 1;
                        } else {
                            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                            if (b + len <= new_line.len) {
                                const cp = std.unicode.utf8Decode(new_line[b..b + len]) catch {
                                    b += 1;
                                    screen_col += 1;
                                    continue;
                                };
                                screen_col += Buffer.charWidth(cp);
                                b += len;
                            } else {
                                b += 1;
                                screen_col += 1;
                            }
                        }
                    }

                    // 差分部分のみ描画（viewport_xオフセットを加算）
                    try term.moveCursor(abs_row, viewport_x + screen_col);
                    try term.write(new_line[start..]);

                    // 古い行の方が長い場合は残りをスペースで埋める
                    if (old_line.len > new_line.len) {
                        try self.padToWidth(term, new_line, viewport_width);
                    }
                }
            }
        } else {
            // 新しい行：全体を描画
            try term.moveCursor(abs_row, viewport_x);
            try term.write(new_line);
            // 残りをスペースで埋める
            try self.padToWidth(term, new_line, viewport_width);
        }

        // 前フレームバッファを更新
        if (screen_row < self.prev_screen.items.len) {
            self.prev_screen.items[screen_row].clearRetainingCapacity();
            try self.prev_screen.items[screen_row].appendSlice(self.allocator, new_line);
        } else {
            // 新しい行を追加
            var new_prev_line = std.ArrayList(u8){};
            try new_prev_line.appendSlice(self.allocator, new_line);
            try self.prev_screen.append(self.allocator, new_prev_line);
        }

        // 次の行がブロックコメント内で開始するかを返す
        return analysis.ends_in_block;
    }

    // 空行（~）を描画（セルレベル差分版）
    fn renderEmptyLine(self: *View, term: *Terminal, screen_row: usize) !void {
        try self.renderEmptyLineOffset(term, 0, 0, term.width, screen_row);
    }

    // 空行（~）を描画（オフセット付き）
    fn renderEmptyLineOffset(self: *View, term: *Terminal, viewport_x: usize, viewport_y: usize, viewport_width: usize, screen_row: usize) !void {
        const empty_line = "~";
        const abs_row = viewport_y + screen_row;

        // 前フレームと比較
        if (screen_row < self.prev_screen.items.len) {
            const old_line = self.prev_screen.items[screen_row].items;
            if (old_line.len != 1 or old_line[0] != '~') {
                // 変更あり：描画
                try term.moveCursor(abs_row, viewport_x);
                try term.write(empty_line);
                // 残りをスペースで埋める
                try self.padToWidth(term, empty_line, viewport_width);

                // 前フレームバッファ更新
                self.prev_screen.items[screen_row].clearRetainingCapacity();
                try self.prev_screen.items[screen_row].appendSlice(self.allocator, empty_line);
            }
        } else {
            // 新しい行：描画
            try term.moveCursor(abs_row, viewport_x);
            try term.write(empty_line);
            // 残りをスペースで埋める
            try self.padToWidth(term, empty_line, viewport_width);

            // 前フレームバッファ追加
            var new_prev_line = std.ArrayList(u8){};
            try new_prev_line.appendSlice(self.allocator, empty_line);
            try self.prev_screen.append(self.allocator, new_prev_line);
        }
    }

    /// ウィンドウ境界内にレンダリング
    /// viewport_x: ウィンドウのX座標（画面左端からのオフセット）
    /// viewport_y: ウィンドウのY座標（画面上端からのオフセット）
    /// viewport_width: ウィンドウの幅
    /// viewport_height: ウィンドウの高さ（ステータスバー含む）
    /// is_active: アクティブウィンドウならtrue（カーソル表示）
    pub fn renderInBounds(
        self: *View,
        term: *Terminal,
        viewport_x: usize,
        viewport_y: usize,
        viewport_width: usize,
        viewport_height: usize,
        is_active: bool,
        modified: bool,
        readonly: bool,
        line_ending: anytype,
        file_encoding: encoding.Encoding,
        filename: ?[]const u8,
    ) !void {
        // 端末サイズが0の場合は何もしない
        if (term.height == 0 or term.width == 0 or viewport_height == 0 or viewport_width == 0) return;

        // 注意: hideCursor/showCursorは呼び出し元（renderAllWindows）で一括管理
        _ = is_active; // カーソル表示は呼び出し元で処理

        const max_lines = viewport_height - 1; // ステータスバー分を引く

        // 画面サイズ変更を検出（prev_screenの行数が変わった場合）
        if (self.prev_screen.items.len > 0 and self.prev_screen.items.len != max_lines) {
            self.markFullRedraw();
        }

        // 行番号幅の変更をチェック（999→1000行など）
        const current_width = self.getLineNumberWidth();
        if (current_width != self.cached_line_num_width) {
            self.cached_line_num_width = current_width;
            self.markFullRedraw();
        }

        // 全画面再描画が必要な場合
        if (self.needs_full_redraw) {
            // ウィンドウの開始位置に移動
            try term.moveCursor(viewport_y, viewport_x);

            // top_lineより前の行をスキャンしてブロックコメント状態を計算
            var in_block = self.computeBlockCommentState(self.top_line);

            // top_lineの開始位置を取得してイテレータを初期化
            const start_pos = self.buffer.getLineStart(self.top_line) orelse self.buffer.len();
            var iter = PieceIterator.init(self.buffer);
            iter.seek(start_pos);

            // 全画面描画 - イテレータを再利用して前進のみ
            var screen_row: usize = 0;
            while (screen_row < max_lines) : (screen_row += 1) {
                const file_line = self.top_line + screen_row;
                if (file_line < self.buffer.lineCount()) {
                    in_block = try self.renderLineWithIterOffset(term, viewport_x, viewport_y, viewport_width, screen_row, file_line, &iter, &self.line_buffer, in_block);
                } else {
                    try self.renderEmptyLineOffset(term, viewport_x, viewport_y, viewport_width, screen_row);
                }
            }

            self.clearDirty();
        } else if (self.dirty_start) |start| {
            // 差分描画: dirty範囲のみ再描画
            const end_line = self.dirty_end orelse (self.top_line + max_lines);
            const end = @min(end_line, self.top_line + max_lines);

            if (start < self.top_line + max_lines and end >= self.top_line) {
                const render_start = if (start > self.top_line) start - self.top_line else 0;
                const render_end = @min(
                    if (end >= self.top_line) end - self.top_line + 1 else 0,
                    max_lines,
                );

                // dirty範囲の開始位置を取得
                const start_file_line = self.top_line + render_start;
                const start_pos = self.buffer.getLineStart(start_file_line) orelse self.buffer.len();
                var iter = PieceIterator.init(self.buffer);
                iter.seek(start_pos);

                // start_file_lineより前の行をスキャンしてブロックコメント状態を計算
                var in_block = self.computeBlockCommentState(start_file_line);

                // dirty範囲を描画 - イテレータを再利用
                var screen_row = render_start;
                while (screen_row < render_end) : (screen_row += 1) {
                    const file_line = self.top_line + screen_row;
                    if (file_line < self.buffer.lineCount()) {
                        in_block = try self.renderLineWithIterOffset(term, viewport_x, viewport_y, viewport_width, screen_row, file_line, &iter, &self.line_buffer, in_block);
                    } else {
                        try self.renderEmptyLineOffset(term, viewport_x, viewport_y, viewport_width, screen_row);
                    }
                }
            }

            self.clearDirty();
        }

        // ステータスバーの描画
        try self.renderStatusBarAt(term, viewport_x, viewport_y + viewport_height - 1, viewport_width, modified, readonly, line_ending, file_encoding, filename);
        // 注意: flush()とカーソル表示は呼び出し元で一括して行う（複数ウィンドウ時の効率化のため）
    }

    /// アクティブウィンドウ用のカーソル位置を計算
    pub fn getCursorScreenPosition(self: *View, viewport_x: usize, viewport_y: usize, viewport_width: usize) struct { row: usize, col: usize } {
        const line_num_width = self.getLineNumberWidth();
        var screen_cursor_x = line_num_width + (if (self.cursor_x >= self.top_col) self.cursor_x - self.top_col else 0);
        // viewport幅を超えないようにクリップ（幅0の場合も考慮）
        if (viewport_width > 0 and screen_cursor_x >= viewport_width) {
            screen_cursor_x = viewport_width - 1;
        } else if (viewport_width == 0) {
            screen_cursor_x = 0;
        }
        return .{ .row = viewport_y + self.cursor_y, .col = viewport_x + screen_cursor_x };
    }

    /// 従来のrender（後方互換性のため）- 全画面レンダリング
    pub fn render(self: *View, term: *Terminal, modified: bool, readonly: bool, line_ending: anytype, file_encoding: encoding.Encoding, filename: ?[]const u8) !void {
        try self.renderInBounds(term, 0, 0, term.width, term.height, true, modified, readonly, line_ending, file_encoding, filename);
    }

    pub fn renderStatusBar(self: *View, term: *Terminal, modified: bool, readonly: bool, line_ending: anytype, file_encoding: encoding.Encoding, filename: ?[]const u8) !void {
        try self.renderStatusBarAt(term, 0, term.height - 1, term.width, modified, readonly, line_ending, file_encoding, filename);
    }

    /// 指定行にステータスバーを描画
    /// 新デザイン: " *filename                          L42 C8  UTF-8(LF)  Zig"
    pub fn renderStatusBarAt(self: *View, term: *Terminal, viewport_x: usize, row: usize, viewport_width: usize, modified: bool, readonly: bool, line_ending: anytype, file_encoding: encoding.Encoding, filename: ?[]const u8) !void {
        try term.moveCursor(row, viewport_x);

        // メッセージがあればそれを優先表示（従来通り）
        if (self.getError()) |msg| {
            try term.write(config.ANSI.INVERT);
            var msg_buf: [config.Editor.STATUS_BUF_SIZE]u8 = undefined;
            const status = try std.fmt.bufPrint(&msg_buf, " {s}", .{msg});
            const display_status = truncateUtf8(status, viewport_width);
            try term.write(display_status);
            const padding = if (display_status.len < viewport_width) viewport_width - display_status.len else 0;
            for (0..padding) |_| {
                try term.write(" ");
            }
            try term.write(config.ANSI.RESET);
            return;
        }

        // 左側: ファイル名（変更/読み取り専用フラグ付き）
        var left_buf: [256]u8 = undefined;
        const modified_char: u8 = if (modified) '*' else ' ';
        const readonly_str = if (readonly) "[RO] " else "";
        const fname = if (filename) |f| f else "[No Name]";
        const left_part = try std.fmt.bufPrint(&left_buf, " {c}{s}{s}", .{ modified_char, readonly_str, fname });

        // 右側: 位置 | エンコード(改行)
        var right_buf: [64]u8 = undefined;
        const current_line = self.top_line + self.cursor_y + 1;
        const current_col = self.cursor_x + 1;
        const le_str = line_ending.toString(); // LF, CRLF, CR を正しく表示
        const enc_str = file_encoding.toString();
        const right_part = try std.fmt.bufPrint(&right_buf, "L{d} C{d}  {s}({s}) ", .{ current_line, current_col, enc_str, le_str });

        // ステータスバーを反転表示で開始
        try term.write(config.ANSI.INVERT);

        // 左側を表示
        const left_len = left_part.len;
        const right_len = right_part.len;
        const total_content = left_len + right_len;

        if (total_content >= viewport_width) {
            // 幅が足りない場合は左側を優先して切り捨て
            const max_left = if (viewport_width > right_len) viewport_width - right_len else viewport_width;
            const display_left = truncateUtf8(left_part, max_left);
            try term.write(display_left);
            // 右側は表示できる分だけ
            if (viewport_width > display_left.len) {
                const remaining = viewport_width - display_left.len;
                const display_right = truncateUtf8(right_part, remaining);
                // パディング
                const pad = remaining - display_right.len;
                for (0..pad) |_| {
                    try term.write(" ");
                }
                try term.write(display_right);
            }
        } else {
            // 通常表示: 左 + パディング + 右
            try term.write(left_part);
            const padding = viewport_width - total_content;
            for (0..padding) |_| {
                try term.write(" ");
            }
            try term.write(right_part);
        }

        try term.write(config.ANSI.RESET);
    }

    pub fn getCursorBufferPos(self: *View) usize {
        const target_line = self.top_line + self.cursor_y;

        // LineIndexでO(1)行開始位置取得
        // 無効な場合はEOF（安全側に倒す）
        const line_start = self.buffer.getLineStart(target_line) orelse {
            // LineIndexが無効またはtarget_lineが範囲外
            // EOFを返すことで、編集操作が安全に失敗する
            return self.buffer.len();
        };

        // 行内のカーソル位置を計算
        // cursor_xは表示幅（絵文字=2, 通常文字=1）なので、
        // 表示幅を累積してcursor_xに到達するバイト位置を探す
        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        var display_col: usize = 0;
        while (display_col < self.cursor_x) {
            const start_pos = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster == null) break;
            const gc = cluster.?;
            if (gc.base == '\n') break;

            // タブ文字の場合は文脈依存の幅を計算
            const char_width = if (gc.base == '\t') blk: {
                const next_tab_stop = (display_col / self.getTabWidth() + 1) * self.getTabWidth();
                break :blk next_tab_stop - display_col;
            } else gc.width;

            display_col += char_width;

            // 目標カーソル位置を超えた場合は手前で止まる
            if (display_col > self.cursor_x) {
                // イテレータを元の位置に戻す
                iter.global_pos = start_pos;
                break;
            }
        }

        return @min(iter.global_pos, self.buffer.len());
    }

    // 現在行の表示幅を取得（grapheme cluster単位）
    pub fn getCurrentLineWidth(self: *View) usize {
        const target_line = self.top_line + self.cursor_y;

        // LineIndexでO(1)行開始位置取得
        // 無効な場合は幅0（安全側に倒す）
        const line_start = self.buffer.getLineStart(target_line) orelse {
            // LineIndexが無効またはtarget_lineが範囲外
            // 幅0を返すことで、カーソルが行頭にクランプされる
            return 0;
        };

        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        // 行の表示幅を計算
        var line_width: usize = 0;
        while (true) {
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster) |gc| {
                if (gc.base == '\n') break;

                // タブ文字の場合は文脈依存の幅を計算
                const char_width = if (gc.base == '\t') blk: {
                    const next_tab_stop = (line_width / self.getTabWidth() + 1) * self.getTabWidth();
                    break :blk next_tab_stop - line_width;
                } else gc.width;

                line_width += char_width;
            } else {
                break;
            }
        }

        return line_width;
    }

    pub fn moveCursorLeft(self: *View) void {
        if (self.cursor_x > 0) {
            // UTF-8文字幅を考慮して1文字分戻る
            const pos = self.getCursorBufferPos();
            if (pos == 0) {
                self.cursor_x = 0;
                return;
            }

            // 1つ前の文字の幅を取得
            var iter = PieceIterator.init(self.buffer);
            var line: usize = 0;
            const target_line = self.top_line + self.cursor_y;

            // 目標行まで進める
            while (line < target_line) {
                const ch = iter.next() orelse return;
                if (ch == '\n') line += 1;
            }

            // 行内でカーソル直前のgrapheme clusterを見つける
            var last_width: usize = 1;
            var display_col: usize = 0;
            while (iter.global_pos < pos) {
                const cluster = iter.nextGraphemeCluster() catch {
                    _ = iter.next();
                    last_width = 1;
                    display_col += 1;
                    continue;
                };
                if (cluster) |gc| {
                    if (gc.base == '\n') break;

                    // タブ文字の場合は文脈依存の幅を計算
                    last_width = if (gc.base == '\t') blk: {
                        const next_tab_stop = (display_col / self.getTabWidth() + 1) * self.getTabWidth();
                        break :blk next_tab_stop - display_col;
                    } else gc.width;

                    display_col += last_width;
                    if (iter.global_pos >= pos) break;
                }
            }

            if (self.cursor_x >= last_width) {
                self.cursor_x -= last_width;
            } else {
                self.cursor_x = 0;
            }

            // 水平スクロール: カーソルが左端より左に行った場合
            if (self.cursor_x < self.top_col) {
                self.top_col = self.cursor_x;
                self.markFullRedraw();
            }
        } else {
            // cursor_x == 0、前の行に移動
            if (self.cursor_y > 0) {
                self.cursor_y -= 1;
                self.moveToLineEnd();
            } else if (self.top_line > 0) {
                // 画面最上部で、さらに上にスクロール可能
                self.top_line -= 1;
                self.moveToLineEnd();
                self.markFullRedraw(); // スクロールで全画面再描画
            }
            // 行移動時は水平スクロールをリセット
            self.top_col = 0;
        }
    }

    pub fn moveCursorRight(self: *View) void {
        const pos = self.getCursorBufferPos();
        if (pos >= self.buffer.len()) return;

        // 現在位置のgrapheme clusterを取得（O(pieces)で直接ジャンプ）
        var iter = PieceIterator.init(self.buffer);
        iter.seek(pos);

        const cluster = iter.nextGraphemeCluster() catch {
            // エラー時は安全のため移動しない
            return;
        };

        // ステータスバー分を除いた最大行
        const max_cursor_y = if (self.viewport_height >= 2) self.viewport_height - 2 else 0;

        if (cluster) |gc| {
            if (gc.base == '\n') {
                // 改行の場合は次の行の先頭へ
                if (self.cursor_y < max_cursor_y and self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
                    self.cursor_y += 1;
                    self.cursor_x = 0;
                } else if (self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
                    self.top_line += 1;
                    self.cursor_x = 0;
                    self.markFullRedraw(); // スクロールで全画面再描画
                }
                // 行移動時は水平スクロールをリセット
                self.top_col = 0;
            } else {
                // タブ文字の場合は文脈依存の幅を計算
                const char_width = if (gc.base == '\t') blk: {
                    const next_tab_stop = (self.cursor_x / self.getTabWidth() + 1) * self.getTabWidth();
                    break :blk next_tab_stop - self.cursor_x;
                } else gc.width;

                // grapheme clusterの幅分進める
                self.cursor_x += char_width;

                // 水平スクロール: カーソルが右端を超えた場合（行番号幅を除く）
                const visible_width = if (self.viewport_width > self.getLineNumberWidth())
                    self.viewport_width - self.getLineNumberWidth()
                else
                    1;
                if (self.cursor_x >= self.top_col + visible_width) {
                    self.top_col = self.cursor_x - visible_width + 1;
                    self.markFullRedraw();
                }
            }
        }
    }

    pub fn moveCursorUp(self: *View) void {
        if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        } else if (self.top_line > 0) {
            self.top_line -= 1;
            self.markFullRedraw(); // スクロールで全画面再描画
        } else {
            return;
        }

        // カーソル位置が行の幅を超えている場合は行末に移動
        const line_width = self.getCurrentLineWidth();
        if (self.cursor_x > line_width) {
            self.cursor_x = line_width;
        }

        // 水平スクロール位置もクランプ（短い行に移動した時の空白表示を防ぐ）
        if (self.top_col > self.cursor_x) {
            self.top_col = self.cursor_x;
            self.markFullRedraw();
        }
    }

    pub fn moveCursorDown(self: *View) void {
        const max_cursor_y = if (self.viewport_height >= 2) self.viewport_height - 2 else 0;
        if (self.cursor_y < max_cursor_y and self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
            self.cursor_y += 1;
        } else if (self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
            self.top_line += 1;
            self.markFullRedraw(); // スクロールで全画面再描画
        } else {
            return;
        }

        // カーソル位置が行の幅を超えている場合は行末に移動
        const line_width = self.getCurrentLineWidth();
        if (self.cursor_x > line_width) {
            self.cursor_x = line_width;
        }

        // 水平スクロール位置もクランプ（短い行に移動した時の空白表示を防ぐ）
        if (self.top_col > self.cursor_x) {
            self.top_col = self.cursor_x;
            self.markFullRedraw();
        }
    }

    pub fn moveToLineStart(self: *View) void {
        self.cursor_x = 0;
        self.top_col = 0;
    }

    pub fn moveToLineEnd(self: *View) void {
        const target_line = self.top_line + self.cursor_y;

        // LineIndexでO(1)行開始位置取得
        // 無効な場合は行頭に留まる（安全側に倒す）
        const line_start = self.buffer.getLineStart(target_line) orelse {
            // LineIndexが無効またはtarget_lineが範囲外
            self.cursor_x = 0;
            return;
        };

        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        // 行の表示幅を計算
        var line_width: usize = 0;
        while (true) {
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                // タブ文字の場合は文脈依存の幅を計算
                const char_width = if (gc.base == '\t') blk: {
                    const next_tab_stop = (line_width / self.getTabWidth() + 1) * self.getTabWidth();
                    break :blk next_tab_stop - line_width;
                } else gc.width;
                line_width += char_width;
            } else {
                break;
            }
        }

        self.cursor_x = line_width;
    }

    // M-< (beginning-of-buffer): ファイルの先頭に移動
    pub fn moveToBufferStart(self: *View) void {
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.top_line = 0;
        self.top_col = 0;
        self.markFullRedraw();
    }

    // M-> (end-of-buffer): ファイルの終端に移動
    pub fn moveToBufferEnd(self: *View) void {
        const total_lines = self.buffer.lineCount();
        if (total_lines == 0) {
            self.cursor_x = 0;
            self.cursor_y = 0;
            self.top_line = 0;
            self.top_col = 0;
            self.markFullRedraw();
            return;
        }

        // 最終行の番号（0-indexed）
        const last_line = if (total_lines > 0) total_lines - 1 else 0;

        // ビューポートの表示可能行数
        const max_screen_lines = if (self.viewport_height >= 2) self.viewport_height - 2 else 0;

        // 最終行をできるだけ画面下部に表示
        if (last_line <= max_screen_lines) {
            // ファイルが画面に収まる場合
            self.top_line = 0;
            self.cursor_y = last_line;
        } else {
            // ファイルが長い場合は最終行が画面下部に来るようにスクロール
            self.top_line = last_line - max_screen_lines;
            self.cursor_y = max_screen_lines;
        }

        // 最終行の末尾にカーソルを移動
        self.moveToLineEnd();
        self.markFullRedraw();
    }
};
