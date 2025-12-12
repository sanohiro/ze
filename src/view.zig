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
const buffer_mod = @import("buffer");
const Buffer = buffer_mod.Buffer;
const PieceIterator = buffer_mod.PieceIterator;
const Terminal = @import("terminal").Terminal;
const config = @import("config");
const syntax = @import("syntax");
const encoding = @import("encoding");
const unicode = @import("unicode");

// ANSIエスケープシーケンス定数（config.ANSIを参照）
const ANSI = config.ANSI;

/// 全角空白（U+3000）のUTF-8バイト列
const FULLWIDTH_SPACE: []const u8 = "\u{3000}"; // 0xE3 0x80 0x80
/// 全角空白の視覚表示用（薄いグレーの「□」+ リセット）
const FULLWIDTH_SPACE_VISUAL: []const u8 = ANSI.DIM ++ "□" ++ ANSI.RESET;

/// truncateUtf8の戻り値
const TruncateResult = struct {
    slice: []const u8,
    display_width: usize,
};

/// UTF-8文字列を表示幅（カラム数）制限内でトランケート
/// グラフェムクラスタ単位で処理し、ZWJシーケンス等を途中で分断しない
/// スライスと表示幅の両方を返す（二重デコード回避）
fn truncateUtf8(str: []const u8, max_columns: usize) TruncateResult {
    if (max_columns == 0) return .{ .slice = str[0..0], .display_width = 0 };

    var col: usize = 0;
    var byte_pos: usize = 0;

    while (byte_pos < str.len) {
        // グラフェムクラスタ単位で処理
        const cluster = unicode.nextGraphemeCluster(str[byte_pos..]) orelse break;

        // このクラスタを追加すると制限を超える場合は終了
        if (col + cluster.display_width > max_columns) break;

        col += cluster.display_width;
        byte_pos += cluster.byte_len;
    }

    return .{ .slice = str[0..byte_pos], .display_width = col };
}

/// UTF-8文字列の表示幅（カラム数）を計算
const stringDisplayWidth = unicode.stringDisplayWidth;

/// バイト位置から画面カラム位置を計算
///
/// 【目的】
/// 差分描画で「バイト位置X」を「画面カラム位置Y」に変換する。
/// ANSIエスケープシーケンス（色コード等）は幅0として扱う。
///
/// 【2段階処理（ASCII高速パス）】
/// 1. 第1パス: ASCII文字（< 0x80）のみ幅1として高速カウント
///    - ANSIエスケープシーケンス(\x1b[...m)をスキップ
///    - 非ASCII文字を見つけたら第2パスへ
/// 2. 第2パス: グラフェムクラスタ単位で処理（ZWJ絵文字等対応）
///
/// 【パラメータ】
/// - line: 対象の行データ
/// - start_byte: 開始バイト位置
/// - end_byte: 終了バイト位置
/// - initial_col: 初期カラム位置（行番号表示幅など）
fn calculateScreenColumn(line: []const u8, start_byte: usize, end_byte: usize, initial_col: usize) usize {
    var screen_col: usize = initial_col;
    var b: usize = start_byte;
    var needs_grapheme_scan = false;

    // 第1パス: ASCII高速パス（エスケープシーケンスをスキップしながら）
    while (b < end_byte) {
        const c = line[b];
        // ANSIエスケープシーケンスをスキップ
        if (c == 0x1b and b + 1 < line.len and line[b + 1] == '[') {
            b += 2;
            while (b < line.len and line[b] != 'm') : (b += 1) {}
            if (b < line.len) b += 1;
            continue;
        }

        if (c < 0x80) {
            // ASCII文字: 幅1
            screen_col += 1;
            b += 1;
        } else {
            // 非ASCII文字: グラフェムスキャンが必要
            needs_grapheme_scan = true;
            break;
        }
    }

    // 非ASCII文字が見つかった場合は残りをグラフェムクラスタ単位で処理
    if (needs_grapheme_scan) {
        while (b < end_byte) {
            const c = line[b];
            // ANSIエスケープシーケンスをスキップ
            if (c == 0x1b and b + 1 < line.len and line[b + 1] == '[') {
                b += 2;
                while (b < line.len and line[b] != 'm') : (b += 1) {}
                if (b < line.len) b += 1;
                continue;
            }

            if (c < 0x80) {
                // ASCII文字: 幅1
                screen_col += 1;
                b += 1;
            } else {
                // グラフェムクラスタ単位で処理（ZWJ絵文字等を正しく扱う）
                const remaining = line[b..@min(end_byte, line.len)];
                if (unicode.nextGraphemeCluster(remaining)) |cluster| {
                    screen_col += cluster.display_width;
                    b += cluster.byte_len;
                } else {
                    // フォールバック: 1バイト進める
                    b += 1;
                    screen_col += 1;
                }
            }
        }
    }
    return screen_col;
}

/// 行の本文部分（行番号の後）にANSIグレーコード(\x1b[90m)が含まれているかチェック
/// コメントハイライトの有無を判定するために使用
fn hasAnsiGray(line: []const u8, content_start: usize) bool {
    // 行番号の後ろの部分のみチェック
    if (content_start >= line.len) return false;
    const content = line[content_start..];
    // グレーのANSIコード \x1b[90m を探す
    return std.mem.indexOf(u8, content, "\x1b[90m") != null;
}

/// 行の本文部分（行番号の後）にANSI反転コード(\x1b[7m)が含まれているかチェック
/// 選択範囲ハイライトの有無を判定するために使用
fn hasAnsiInvert(line: []const u8, content_start: usize) bool {
    // 行番号の後ろの部分のみチェック
    if (content_start >= line.len) return false;
    const content = line[content_start..];
    // 反転のANSIコード \x1b[7m を探す
    return std.mem.indexOf(u8, content, "\x1b[7m") != null;
}

/// View: バッファの表示状態を管理する構造体
///
/// 【差分描画（Differential Rendering）】
/// 全画面再描画は遅いため、以下の最適化を実装:
///
/// 1. 行レベル差分: dirty_start〜dirty_endの範囲のみ再描画
/// 2. セルレベル差分: prev_screenと比較して変更セルのみ出力
///    → ターミナルへのwrite()バイト数を40-90%削減
///
/// 【レンダリングパイプライン】
/// ```
/// Buffer → 行抽出 → タブ展開 → コメント着色 → 選択ハイライト → 差分検出 → Terminal
///          (line_buffer) (expanded_line) (highlighted_line)    (prev_screen)
/// ```
/// 各段階で再利用バッファを使い、毎行のアロケーションを回避。
///
/// 【ブロックコメントキャッシュ】
/// 複数行コメント（/* */）の状態追跡はO(n)だが、
/// cached_block_state/cached_block_top_lineでキャッシュして
/// スクロール時のO(n²)を回避。
pub const View = struct {
    // === バッファ参照 ===
    buffer: *Buffer,

    // === スクロール・カーソル位置 ===
    top_line: usize, // 表示先頭行（垂直スクロール）
    top_col: usize, // 表示先頭カラム（水平スクロール）
    cursor_x: usize, // カーソルX位置（表示カラム）
    cursor_y: usize, // カーソルY位置（画面上の行）
    viewport_width: usize, // ビューポート幅
    viewport_height: usize, // ビューポート高さ

    // === 差分描画用の状態 ===
    dirty_start: ?usize, // 再描画が必要な開始行
    dirty_end: ?usize, // 再描画が必要な終了行
    needs_full_redraw: bool, // 全画面再描画が必要か
    prev_screen: std.ArrayList(std.ArrayList(u8)), // 前フレームの各行の内容
    prev_top_line: usize, // 前回のtop_line（スクロール検出用）
    scroll_delta: i32, // スクロール量（将来のスクロール最適化用）

    // === 再利用バッファ（パフォーマンス最適化）===
    line_buffer: std.ArrayList(u8), // 行データの一時格納
    expanded_line: std.ArrayList(u8), // タブ展開後のデータ
    highlighted_line: std.ArrayList(u8), // ハイライト適用後のデータ

    // === UI表示用 ===
    error_msg_buf: [256]u8, // エラーメッセージ（固定バッファ）
    error_msg_len: usize,
    search_highlight_buf: [256]u8, // 検索パターン（固定バッファ）
    search_highlight_len: usize,
    selection_start: ?usize, // 選択開始位置
    selection_end: ?usize, // 選択終了位置

    // === キャッシュ ===
    cached_line_num_width: usize, // 行番号の表示幅
    cached_block_state: ?bool, // ブロックコメント状態
    cached_block_top_line: usize, // キャッシュが有効な行

    // === 言語・設定 ===
    language: *const syntax.LanguageDef,
    tab_width: ?u8, // nullなら言語デフォルト
    indent_style: ?syntax.IndentStyle, // nullなら言語デフォルト

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, buffer: *Buffer) !View {
        // 典型的なライン幅（256バイト）で事前確保してリアロケーションを削減
        var line_buffer = try std.ArrayList(u8).initCapacity(allocator, 256);
        errdefer line_buffer.deinit(allocator);

        // prev_screen: 24行分を事前確保（典型的なターミナルサイズ）
        var prev_screen = try std.ArrayList(std.ArrayList(u8)).initCapacity(allocator, 24);
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
            .prev_top_line = 0, // スクロール追跡用
            .scroll_delta = 0, // スクロール差分
            .selection_start = null, // 選択範囲なし
            .selection_end = null,
            .allocator = allocator,
        };
    }

    /// 選択範囲を設定（Emacsのmark/pointに対応）
    /// 注: カーソル移動のたびに呼ばれるため、常に再描画をトリガーする
    pub fn setSelection(self: *View, start: ?usize, end: ?usize) void {
        self.selection_start = start;
        self.selection_end = end;
        // 選択範囲がある場合は常に再描画（カーソル移動で範囲が変わるため）
        if (start != null and end != null) {
            self.markFullRedraw();
        }
    }

    /// 選択範囲をクリア
    pub fn clearSelection(self: *View) void {
        if (self.selection_start != null or self.selection_end != null) {
            self.selection_start = null;
            self.selection_end = null;
            self.markFullRedraw();
        }
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
    /// スクロールが発生した場合は再描画をマークする
    pub fn constrainCursor(self: *View) void {
        var needs_redraw = false;

        // ステータスバー分を除いた最大行
        const max_cursor_y = if (self.viewport_height >= 2) self.viewport_height - 2 else 0;
        if (self.cursor_y > max_cursor_y) {
            // カーソルがビューポート外なら、スクロールして見えるようにする
            const overshoot = self.cursor_y - max_cursor_y;
            self.top_line += overshoot;
            self.cursor_y = max_cursor_y;
            needs_redraw = true;
        }

        // 水平方向も制約（行番号幅を除いた可視幅）
        const line_num_width = self.getLineNumberWidth();
        const visible_width = if (self.viewport_width > line_num_width) self.viewport_width - line_num_width else 1;
        if (self.cursor_x >= self.top_col + visible_width) {
            // カーソルが右端を超えたらスクロール
            self.top_col = if (self.cursor_x >= visible_width) self.cursor_x - visible_width + 1 else 0;
            needs_redraw = true;
        }

        if (needs_redraw) {
            self.markFullRedraw();
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
        // ステータスバーを再描画するためにdirtyをマーク
        self.needs_full_redraw = true;
    }

    // エラーメッセージを取得
    pub fn getError(self: *const View) ?[]const u8 {
        if (self.error_msg_len == 0) return null;
        return self.error_msg_buf[0..self.error_msg_len];
    }

    // エラーメッセージをクリア
    pub fn clearError(self: *View) void {
        if (self.error_msg_len > 0) {
            self.error_msg_len = 0;
            // ステータスバーを再描画するためにdirtyをマーク
            self.needs_full_redraw = true;
        }
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

    /// 行末をスペースでパディング（CLEAR_LINEの代替）
    ///
    /// 【なぜCLEAR_LINE(\x1b[K)を使わないか】
    /// 差分描画と相性が悪い:
    /// - CLEAR_LINEは「カーソル位置から行末まで消去」
    /// - 前フレームと内容が同じでも毎回実行される
    /// - スペースパディングなら差分検出で完全にスキップできる
    ///
    /// 【バッチ最適化】
    /// 8スペースずつまとめてwrite()することでシステムコール回数を削減。
    ///
    /// 【ASCII高速パス】
    /// ASCII文字のみの行は幅1として簡易計算（グラフェム処理をスキップ）。
    fn padToWidth(self: *View, term: *Terminal, line: []const u8, viewport_width: usize) !void {
        _ = self;
        // 表示幅を計算（ANSIエスケープシーケンスを除外）
        var display_width: usize = 0;
        var i: usize = 0;
        var needs_grapheme_scan = false;

        // 第1パス: ASCII高速パス（エスケープシーケンスをスキップしながら）
        while (i < line.len) {
            const c = line[i];
            if (c == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
                // ANSIエスケープシーケンスをスキップ
                i += 2;
                while (i < line.len and line[i] != 'm') : (i += 1) {}
                if (i < line.len) i += 1;
            } else if (c < 0x80) {
                // ASCII文字: 幅1
                display_width += 1;
                i += 1;
            } else {
                // 非ASCII文字: グラフェムスキャンが必要
                needs_grapheme_scan = true;
                break;
            }
        }

        // 非ASCII文字が見つかった場合は残りをグラフェムクラスタ単位で処理
        if (needs_grapheme_scan) {
            while (i < line.len) {
                const c = line[i];
                if (c == 0x1b and i + 1 < line.len and line[i + 1] == '[') {
                    // ANSIエスケープシーケンスをスキップ
                    i += 2;
                    while (i < line.len and line[i] != 'm') : (i += 1) {}
                    if (i < line.len) i += 1;
                } else if (c < 0x80) {
                    // ASCII文字: 幅1
                    display_width += 1;
                    i += 1;
                } else {
                    // グラフェムクラスタ単位で処理（ZWJ絵文字等を正しく扱う）
                    if (unicode.nextGraphemeCluster(line[i..])) |cluster| {
                        display_width += cluster.display_width;
                        i += cluster.byte_len;
                    } else {
                        i += 1;
                        display_width += 1;
                    }
                }
            }
        }

        // 残りをスペースで埋める（バッファリングで効率化）
        if (display_width < viewport_width) {
            const padding = viewport_width - display_width;
            // 8スペースずつバッチで書き込み
            const batch: []const u8 = "        "; // 8 spaces
            var remaining = padding;
            while (remaining >= 8) {
                try term.write(batch);
                remaining -= 8;
            }
            // 残りを1文字ずつ
            while (remaining > 0) : (remaining -= 1) {
                try term.write(" ");
            }
        }
    }

    // 行番号の表示幅を計算（999行まで固定、1000行以上で動的拡張）
    pub fn getLineNumberWidth(self: *const View) usize {
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
        self.scroll_delta = 0; // スクロール最適化をリセット

        // 前フレームバッファをクリア（全画面再描画なので差分計算不要）
        for (self.prev_screen.items) |*line| {
            line.deinit(self.allocator);
        }
        self.prev_screen.clearRetainingCapacity();
    }

    /// 垂直スクロールをマーク
    /// 現在の実装では全画面再描画（ターミナルスクロール最適化は未実装）
    /// lines: 正=下方向（内容が上へ）、負=上方向（内容が下へ）
    pub fn markScroll(self: *View, lines: i32) void {
        _ = lines;
        // TODO: ターミナルスクロール（ESC [S / ESC [T）を使った最適化
        // 現在は prev_screen との整合性の問題があるため全画面再描画
        self.markFullRedraw();
    }

    pub fn clearDirty(self: *View) void {
        self.dirty_start = null;
        self.dirty_end = null;
        self.needs_full_redraw = false;
        self.scroll_delta = 0;
        self.prev_top_line = self.top_line;
    }

    /// 再描画が必要かどうか
    pub fn needsRedraw(self: *const View) bool {
        return self.needs_full_redraw or self.dirty_start != null;
    }

    /// ブロックコメント状態の計算（キャッシュ付き）
    ///
    /// 【目的】
    /// 複数行コメント（/* */）の状態を追跡し、行の描画時に
    /// コメント内かどうかを判定する。
    ///
    /// 【キャッシュ最適化】
    /// 全行スキャンはO(n)だが、cached_block_state/cached_block_top_lineで
    /// 前回の計算結果をキャッシュし、差分のみスキャン:
    /// - スクロール時: O(k) where k = |current_line - cached_line|
    /// - ジャンプ時: O(n) (キャッシュミス)
    ///
    /// 【無効化タイミング】
    /// markDirty()でキャッシュより前の行が変更された場合に無効化。
    fn computeBlockCommentState(self: *View, target_line: usize) bool {
        // ブロックコメントがない言語なら常にfalse
        if (self.language.block_comment == null) return false;

        // キャッシュヒット: 同じ行の状態がキャッシュされている
        if (self.cached_block_state) |cached_state| {
            if (self.cached_block_top_line == target_line) {
                return cached_state;
            }
        }

        // キャッシュからスタートできるか確認（キャッシュ行 <= target_line の場合のみ）
        var start_line: usize = 0;
        var in_block: bool = false;
        if (self.cached_block_state) |cached_state| {
            if (self.cached_block_top_line < target_line) {
                // キャッシュ位置からスキャン開始
                start_line = self.cached_block_top_line;
                in_block = cached_state;
            }
        }

        // start_lineからtarget_lineまでスキャン
        var iter = PieceIterator.init(self.buffer);
        // 行バッファを事前に確保（再アロケーション削減）
        var line_buf = std.ArrayList(u8).initCapacity(self.allocator, 256) catch return false;
        defer line_buf.deinit(self.allocator);

        // start_lineまでスキップ
        var current_line: usize = 0;
        while (current_line < start_line) : (current_line += 1) {
            while (iter.next()) |ch| {
                if (ch == '\n') break;
            }
        }

        // start_lineからtarget_lineまでスキャン
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

    /// ANSIエスケープシーケンスをスキップして検索
    ///
    /// 【目的】
    /// ハイライト済みの行（ANSIカラーコード付き）から
    /// 実際のテキスト部分のみを対象に検索する。
    ///
    /// 【アルゴリズム】
    /// 1. start位置から走査開始
    /// 2. ESC([...m)シーケンスを見つけたらスキップ
    /// 3. 通常文字でsearch_strとマッチを試みる
    /// 4. マッチ中もANSIシーケンスをスキップ
    ///
    /// 【計算量】O(n) where n = line.len
    ///
    /// 【戻り値】
    /// マッチ開始のバイト位置（ANSIエスケープ込みの位置）、またはnull
    fn findSkippingAnsi(line: []const u8, start: usize, search_str: []const u8) ?usize {
        if (search_str.len == 0) return null;
        if (line.len < start + search_str.len) return null;

        // ANSIを除いたテキスト位置を追跡するシンプルな検索
        // startからスキャンし、ANSIシーケンスを飛ばしながら検索
        var line_pos = start;

        outer: while (line_pos + search_str.len <= line.len) {
            // ANSIエスケープシーケンスをスキップ (\x1b[...m)
            while (line_pos < line.len and line[line_pos] == 0x1b) {
                if (line_pos + 1 < line.len and line[line_pos + 1] == '[') {
                    line_pos += 2;
                    while (line_pos < line.len and line[line_pos] != 'm') : (line_pos += 1) {}
                    if (line_pos < line.len) line_pos += 1; // 'm' をスキップ
                } else {
                    break;
                }
            }

            if (line_pos + search_str.len > line.len) return null;

            // この位置でマッチを試みる
            const match_start = line_pos;
            var search_idx: usize = 0;

            while (search_idx < search_str.len) {
                // ANSIシーケンスをスキップ
                while (line_pos < line.len and line[line_pos] == 0x1b) {
                    if (line_pos + 1 < line.len and line[line_pos + 1] == '[') {
                        line_pos += 2;
                        while (line_pos < line.len and line[line_pos] != 'm') : (line_pos += 1) {}
                        if (line_pos < line.len) line_pos += 1;
                    } else {
                        break;
                    }
                }

                if (line_pos >= line.len) return null;

                if (line[line_pos] == search_str[search_idx]) {
                    search_idx += 1;
                    line_pos += 1;
                } else {
                    // マッチ失敗：開始位置の次から再試行
                    line_pos = match_start + 1;
                    continue :outer;
                }
            }

            // 全文字マッチ成功
            return match_start;
        }

        return null;
    }

    /// 検索ハイライトを適用（反転表示）
    ///
    /// 【処理フロー】
    /// 1. 検索パターンがなければ即リターン（コピーなし）
    /// 2. 最初のマッチを事前チェック（マッチなしならコピーなし）
    /// 3. マッチがあればhighlighted_lineバッファを使用してハイライト付き行を構築
    ///
    /// 【ANSIエスケープシーケンス対応】
    /// findSkippingAnsi()を使用してANSI色コード内でマッチしないようにする。
    /// 例: "\x1b[90mhello\x1b[m" で "hello" を検索すると、
    /// ANSIコード部分ではなくテキスト部分のみマッチ。
    ///
    /// 【戻り値】
    /// - マッチなし: 入力lineをそのまま返す（アロケーションなし）
    /// - マッチあり: self.highlighted_line.itemsを返す（要再利用バッファ）
    ///
    /// 【is_cursor_line】
    /// カーソル行の場合、マッチに下線を追加して現在位置を強調
    fn applySearchHighlight(self: *View, line: []const u8, is_cursor_line: bool) ![]const u8 {
        const search_str = self.getSearchHighlight() orelse return line;
        if (search_str.len == 0 or line.len == 0) return line;

        // 最初のマッチを事前チェック（マッチがなければコピーせず元を返す）
        const first_match = findSkippingAnsi(line, 0, search_str) orelse return line;

        // カーソル行は反転+下線、それ以外は反転のみ
        const highlight_start = if (is_cursor_line) ANSI.INVERT ++ ANSI.UNDERLINE else ANSI.INVERT;
        const highlight_end = if (is_cursor_line) ANSI.UNDERLINE_OFF ++ ANSI.INVERT_OFF else ANSI.INVERT_OFF;

        // マッチがあるのでバッファを使用
        self.highlighted_line.clearRetainingCapacity();

        // 最初のマッチ前の部分をコピー
        try self.highlighted_line.appendSlice(self.allocator, line[0..first_match]);
        // ハイライト開始
        try self.highlighted_line.appendSlice(self.allocator, highlight_start);
        // マッチ部分をコピー
        try self.highlighted_line.appendSlice(self.allocator, line[first_match .. first_match + search_str.len]);
        // ハイライト終了
        try self.highlighted_line.appendSlice(self.allocator, highlight_end);
        var pos: usize = first_match + search_str.len;

        // 残りのマッチを処理
        while (pos < line.len) {
            if (findSkippingAnsi(line, pos, search_str)) |match_pos| {
                // マッチ前の部分をコピー
                try self.highlighted_line.appendSlice(self.allocator, line[pos..match_pos]);
                // ハイライト開始
                try self.highlighted_line.appendSlice(self.allocator, highlight_start);
                // マッチ部分をコピー
                try self.highlighted_line.appendSlice(self.allocator, line[match_pos .. match_pos + search_str.len]);
                // ハイライト終了
                try self.highlighted_line.appendSlice(self.allocator, highlight_end);
                pos = match_pos + search_str.len;
            } else {
                // これ以上マッチなし：残りをコピー
                try self.highlighted_line.appendSlice(self.allocator, line[pos..]);
                break;
            }
        }
        return self.highlighted_line.items;
    }

    /// セルレベル差分描画
    ///
    /// 【目的】
    /// ターミナルへの出力バイト数を最小化し、描画を高速化する。
    /// 変更がない行は完全にスキップし、変更がある行も差分のみ出力。
    ///
    /// 【最適化の段階】
    /// 1. 長さ比較: old_line.len != new_line.len → 行全体再描画
    /// 2. 先頭/末尾8バイト比較: 高速な部分比較で変更を検出
    /// 3. 全体比較: 上記を通過した場合のみ実行
    /// 4. 差分出力: 変更開始位置からのみ描画（カーソル移動を最小化）
    ///
    /// 【効果】
    /// 通常の編集操作で write() バイト数が 40-90% 削減される。
    fn renderLineDiff(self: *View, term: *Terminal, new_line: []const u8, screen_row: usize, abs_row: usize, viewport_x: usize, viewport_width: usize) !void {
        if (screen_row < self.prev_screen.items.len) {
            const old_line = self.prev_screen.items[screen_row].items;

            // 高速パス: 長さが同じで内容も同じなら描画をスキップ
            if (old_line.len == new_line.len) {
                // 長さが同じ場合、先頭8バイトと末尾8バイトで高速チェック
                const quick_check_len = 8;
                if (old_line.len <= quick_check_len * 2) {
                    // 短い行: 全体比較
                    if (std.mem.eql(u8, old_line, new_line)) return;
                } else {
                    // 先頭と末尾をチェック
                    const head_same = std.mem.eql(u8, old_line[0..quick_check_len], new_line[0..quick_check_len]);
                    const tail_start = old_line.len - quick_check_len;
                    const tail_same = std.mem.eql(u8, old_line[tail_start..], new_line[tail_start..]);
                    if (head_same and tail_same) {
                        // 先頭と末尾が同じなら全体比較
                        if (std.mem.eql(u8, old_line, new_line)) return;
                    }
                }
            }

            // 行番号の表示幅を取得
            const line_num_display_width = self.getLineNumberWidth();

            // 行番号がある場合、行番号部分のバイト範囲を推定
            // 行番号フォーマット: "\x1b[90m  N\x1b[m  " (ANSIエスケープ付き)
            const line_num_byte_end = if (line_num_display_width > 0) blk: {
                // 行番号部分のバイト終端を探す（最初のリセットエスケープ \x1b[m の後のスペース2つ）
                if (std.mem.indexOf(u8, new_line, "\x1b[m  ")) |pos| {
                    break :blk pos + 5; // "\x1b[m  ".len
                }
                // フォールバック：行全体を再描画
                break :blk 0;
            } else 0;

            // シンタックスハイライト（ANSIエスケープ）の変化をチェック
            // コメント色のANSIコードがある場合は行全体を再描画（差分描画ではカラーが正しく適用されない）
            const old_has_gray = hasAnsiGray(old_line, line_num_byte_end);
            const new_has_gray = hasAnsiGray(new_line, line_num_byte_end);
            // 選択範囲の反転表示があるかチェック
            const old_has_invert = hasAnsiInvert(old_line, line_num_byte_end);
            const new_has_invert = hasAnsiInvert(new_line, line_num_byte_end);
            // グレーまたは反転がある場合は行全体を再描画（差分描画だとカラーが途切れる問題を回避）
            if (old_has_gray or new_has_gray or old_has_invert or new_has_invert) {
                // 内容が異なる場合のみ再描画
                if (!std.mem.eql(u8, old_line, new_line)) {
                    try term.moveCursor(abs_row, viewport_x);
                    try term.write(new_line);
                    try self.padToWidth(term, new_line, viewport_width);
                }
            } else {
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
                    // 差分が行番号部分にかかっている場合は行全体を再描画
                    if (line_num_display_width > 0 and start_raw < line_num_byte_end) {
                        // 行頭から全体を再描画
                        try term.moveCursor(abs_row, viewport_x);
                        try term.write(new_line);
                        // 残りをスペースで埋める（CLEAR_LINEの代わり）
                        try self.padToWidth(term, new_line, viewport_width);
                    } else if (line_num_display_width > 0) {
                        // 行番号があるが本文部分のみの差分
                        // UTF-8文字境界に調整
                        var start = start_raw;
                        while (start > 0 and start < new_line.len and unicode.isUtf8Continuation(new_line[start])) {
                            start -= 1;
                        }

                        // バイト位置から画面カラム位置を計算（行番号部分をスキップ）
                        const screen_col = calculateScreenColumn(new_line, line_num_byte_end, start, line_num_display_width);

                        // 差分部分のみ描画
                        try term.moveCursor(abs_row, viewport_x + screen_col);
                        try term.write(new_line[start..]);

                        // 古い行の方が長い場合は残りをスペースで埋める
                        if (old_line.len > new_line.len) {
                            try self.padToWidth(term, new_line, viewport_width);
                        }
                    } else {
                        // UTF-8文字境界に調整（継続バイトの途中から始まらないように）
                        var start = start_raw;
                        while (start > 0 and start < new_line.len and unicode.isUtf8Continuation(new_line[start])) {
                            start -= 1;
                        }

                        // バイト位置から画面カラム位置を計算（ANSIエスケープシーケンスをスキップ）
                        const screen_col = calculateScreenColumn(new_line, 0, start, 0);

                        // 差分部分のみ描画（viewport_xオフセットを加算）
                        try term.moveCursor(abs_row, viewport_x + screen_col);
                        try term.write(new_line[start..]);

                        // 古い行の方が長い場合は残りをスペースで埋める
                        if (old_line.len > new_line.len) {
                            try self.padToWidth(term, new_line, viewport_width);
                        }
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
            // 新しい行を追加（事前に容量確保してアロケーション回数を削減）
            const line_capacity = @max(new_line.len, self.viewport_width * 4);
            var new_prev_line = try std.ArrayList(u8).initCapacity(self.allocator, line_capacity);
            try new_prev_line.appendSlice(self.allocator, new_line);
            try self.prev_screen.append(self.allocator, new_prev_line);
        }
    }

    // イテレータを再利用して行を描画（セルレベル差分描画版）
    fn renderLineWithIter(self: *View, term: *Terminal, screen_row: usize, file_line: usize, iter: *PieceIterator, line_buffer: *std.ArrayList(u8)) !bool {
        return self.renderLineWithIterOffset(term, 0, screen_row, file_line, iter, line_buffer, false);
    }

    /// 1行をレンダリング（メインのレンダリング関数）
    ///
    /// 【処理パイプライン】
    /// 1. イテレータから行データを読み取り → line_buffer
    /// 2. タブ展開 + 水平スクロール処理 → expanded_line
    /// 3. コメントハイライト（グレー表示）を適用
    /// 4. 選択範囲ハイライト（反転表示）を適用
    /// 5. 検索ハイライトを適用 → highlighted_line
    /// 6. renderLineDiff()で差分描画
    ///
    /// 【最適化ポイント】
    /// - 再利用バッファ: line_buffer, expanded_line, highlighted_lineは毎行クリア&再利用
    /// - ASCII高速パス: タブ展開時、ASCII文字は分岐なしで処理
    /// - コメントスパン: has_spans=falseならスパン処理を完全スキップ
    ///
    /// 【戻り値】
    /// 次の行がブロックコメント内で開始するかどうか（キャッシュ用）
    fn renderLineWithIterOffset(self: *View, term: *Terminal, viewport_x: usize, viewport_y: usize, viewport_width: usize, screen_row: usize, file_line: usize, iter: *PieceIterator, line_buffer: *std.ArrayList(u8), in_block: bool) !bool {
        const abs_row = viewport_y + screen_row;
        // 再利用バッファをクリア
        line_buffer.clearRetainingCapacity();

        // 行のバッファ開始位置を記録（選択範囲ハイライト用）
        const line_start_pos = iter.global_pos;

        // 行末まで読み取る
        while (iter.next()) |ch| {
            if (ch == '\n') break;
            try line_buffer.append(self.allocator, ch);
        }

        // 行のバッファ終了位置（改行の直前）
        const line_end_pos = line_start_pos + line_buffer.items.len;

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
        const tab_width = self.getTabWidth(); // ループ前にホイスト（最適化）

        // コメントスパンがある場合のみ追跡（最適化：span_count==0なら完全スキップ）
        const has_spans = analysis.span_count > 0;
        var in_comment = false; // 現在コメント内かどうか
        var current_span_idx: usize = 0; // 現在のコメントスパンインデックス
        var current_span: ?syntax.LanguageDef.CommentSpan = if (has_spans) analysis.spans[0] else null;

        // 選択範囲ハイライト用（バッファ位置で比較）
        const has_selection = self.selection_start != null and self.selection_end != null;
        var in_selection = false; // 現在選択範囲内かどうか
        // この行での選択開始・終了バイト位置を計算
        const sel_start_in_line: ?usize = if (has_selection) blk: {
            const sel_start = self.selection_start.?;
            if (sel_start >= line_end_pos) break :blk null; // 選択がこの行より後
            if (sel_start <= line_start_pos) break :blk 0; // 選択がこの行より前から開始
            break :blk sel_start - line_start_pos;
        } else null;
        const sel_end_in_line: ?usize = if (has_selection) blk: {
            const sel_end = self.selection_end.?;
            if (sel_end <= line_start_pos) break :blk null; // 選択がこの行より前で終了
            if (sel_end >= line_end_pos) break :blk line_buffer.items.len; // 選択がこの行より後まで続く
            break :blk sel_end - line_start_pos;
        } else null;

        while (byte_idx < line_buffer.items.len and col < visible_end) {
            // 選択範囲の開始・終了をチェック
            if (has_selection and sel_start_in_line != null and sel_end_in_line != null) {
                if (!in_selection and byte_idx >= sel_start_in_line.? and byte_idx < sel_end_in_line.?) {
                    // 選択開始（反転表示）
                    try self.expanded_line.appendSlice(self.allocator, ANSI.INVERT);
                    in_selection = true;
                }
                if (in_selection and byte_idx >= sel_end_in_line.?) {
                    // 選択終了（リセット）
                    try self.expanded_line.appendSlice(self.allocator, ANSI.RESET);
                    in_selection = false;
                }
            }

            // コメントスパンの開始・終了をチェック（スパンがある場合のみ）
            if (has_spans) {
                if (current_span) |span| {
                    if (!in_comment and byte_idx == span.start) {
                        // コメント開始
                        try self.expanded_line.appendSlice(self.allocator, ANSI.GRAY);
                        in_comment = true;
                    }
                    if (in_comment) {
                        if (span.end) |end| {
                            if (byte_idx == end) {
                                // コメント終了
                                try self.expanded_line.appendSlice(self.allocator, ANSI.RESET);
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
                    // Tabを空白に展開（バッチ処理で高速化）
                    const next_tab_stop = (col / tab_width + 1) * tab_width;

                    // 水平スクロール範囲内の空白数を計算
                    const tab_start = col;
                    const tab_end = next_tab_stop;
                    if (tab_end > self.top_col and tab_start < visible_end) {
                        // 範囲内の空白数を計算
                        const visible_start = if (tab_start >= self.top_col) tab_start else self.top_col;
                        const visible_stop = if (tab_end <= visible_end) tab_end else visible_end;
                        const visible_spaces = visible_stop - visible_start;

                        // 8スペースのバッチで追加（事前定義の定数を使用）
                        const spaces8: []const u8 = "        "; // 8 spaces
                        var remaining = visible_spaces;
                        while (remaining >= 8) {
                            try self.expanded_line.appendSlice(self.allocator, spaces8);
                            remaining -= 8;
                        }
                        if (remaining > 0) {
                            try self.expanded_line.appendSlice(self.allocator, spaces8[0..remaining]);
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
                // UTF-8: グラフェムクラスタ単位で処理（ZWJ絵文字等を正しく扱う）
                const remaining = line_buffer.items[byte_idx..];
                if (unicode.nextGraphemeCluster(remaining)) |cluster| {
                    // 水平スクロール範囲内なら追加
                    if (col >= self.top_col) {
                        // 全角空白（U+3000）を視覚的に表示
                        if (cluster.byte_len == 3 and
                            remaining[0] == 0xE3 and remaining[1] == 0x80 and remaining[2] == 0x80)
                        {
                            // 全角空白 → 薄い「□」に置換（幅2）
                            try self.expanded_line.appendSlice(self.allocator, FULLWIDTH_SPACE_VISUAL);
                        } else {
                            // グラフェムクラスタ全体をコピー
                            var i: usize = 0;
                            while (i < cluster.byte_len) : (i += 1) {
                                try self.expanded_line.append(self.allocator, line_buffer.items[byte_idx + i]);
                            }
                        }
                    }
                    byte_idx += cluster.byte_len;
                    col += cluster.display_width;
                } else {
                    // フォールバック: 1バイト進める
                    byte_idx += 1;
                }
            }
        }

        // 選択範囲内だった場合はリセット
        if (in_selection) {
            try self.expanded_line.appendSlice(self.allocator, ANSI.RESET);
        }

        // コメント内だった場合はリセット（スパンがある場合のみチェック）
        if (has_spans and in_comment) {
            try self.expanded_line.appendSlice(self.allocator, ANSI.RESET);
        }

        // 検索ハイライトを適用（カーソル行は下線で強調）
        const is_cursor_line = (screen_row == self.cursor_y);
        const new_line = try self.applySearchHighlight(self.expanded_line.items, is_cursor_line);

        // 差分描画と前フレームバッファ更新
        try self.renderLineDiff(term, new_line, screen_row, abs_row, viewport_x, viewport_width);

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

            // 前フレームバッファ追加（事前に容量確保）
            const line_capacity = @max(empty_line.len, self.viewport_width * 4);
            var new_prev_line = try std.ArrayList(u8).initCapacity(self.allocator, line_capacity);
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
        overwrite: bool,
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
            var last_rendered_file_line: usize = self.top_line;
            while (screen_row < max_lines) : (screen_row += 1) {
                const file_line = self.top_line + screen_row;
                if (file_line < self.buffer.lineCount()) {
                    in_block = try self.renderLineWithIterOffset(term, viewport_x, viewport_y, viewport_width, screen_row, file_line, &iter, &self.line_buffer, in_block);
                    last_rendered_file_line = file_line;
                } else {
                    try self.renderEmptyLineOffset(term, viewport_x, viewport_y, viewport_width, screen_row);
                }
            }

            // キャッシュを更新: 最後に描画した行の次の行の状態を保持
            // これにより、次のレンダリングでスキャン範囲を削減
            self.cached_block_state = in_block;
            self.cached_block_top_line = last_rendered_file_line + 1;

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
                var last_rendered_file_line: usize = start_file_line;
                while (screen_row < render_end) : (screen_row += 1) {
                    const file_line = self.top_line + screen_row;
                    if (file_line < self.buffer.lineCount()) {
                        in_block = try self.renderLineWithIterOffset(term, viewport_x, viewport_y, viewport_width, screen_row, file_line, &iter, &self.line_buffer, in_block);
                        last_rendered_file_line = file_line;
                    } else {
                        try self.renderEmptyLineOffset(term, viewport_x, viewport_y, viewport_width, screen_row);
                    }
                }

                // キャッシュを更新: 描画した最後の行の次の行の状態を保持
                self.cached_block_state = in_block;
                self.cached_block_top_line = last_rendered_file_line + 1;
            }

            self.clearDirty();
        }

        // ステータスバーの描画
        try self.renderStatusBarAt(term, viewport_x, viewport_y + viewport_height - 1, viewport_width, modified, readonly, overwrite, line_ending, file_encoding, filename);
        // 注意: flush()とカーソル表示は呼び出し元で一括して行う（複数ウィンドウ時の効率化のため）
    }

    /// アクティブウィンドウ用のカーソル位置を計算
    pub fn getCursorScreenPosition(self: *const View, viewport_x: usize, viewport_y: usize, viewport_width: usize) struct { row: usize, col: usize } {
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
    pub fn render(self: *View, term: *Terminal, modified: bool, readonly: bool, overwrite: bool, line_ending: anytype, file_encoding: encoding.Encoding, filename: ?[]const u8) !void {
        try self.renderInBounds(term, 0, 0, term.width, term.height, true, modified, readonly, overwrite, line_ending, file_encoding, filename);
    }

    pub fn renderStatusBar(self: *View, term: *Terminal, modified: bool, readonly: bool, overwrite: bool, line_ending: anytype, file_encoding: encoding.Encoding, filename: ?[]const u8) !void {
        try self.renderStatusBarAt(term, 0, term.height - 1, term.width, modified, readonly, overwrite, line_ending, file_encoding, filename);
    }

    /// 指定行にステータスバーを描画
    /// 新デザイン: " *filename                          L42 C8  UTF-8(LF)  Zig"
    pub fn renderStatusBarAt(self: *View, term: *Terminal, viewport_x: usize, row: usize, viewport_width: usize, modified: bool, readonly: bool, overwrite: bool, line_ending: anytype, file_encoding: encoding.Encoding, filename: ?[]const u8) !void {
        try term.moveCursor(row, viewport_x);

        // メッセージがあればそれを優先表示（従来通り）
        if (self.getError()) |msg| {
            try term.write(config.ANSI.INVERT);
            var msg_buf: [config.Editor.STATUS_BUF_SIZE]u8 = undefined;
            const status = try std.fmt.bufPrint(&msg_buf, " {s}", .{msg});
            const truncated = truncateUtf8(status, viewport_width);
            try term.write(truncated.slice);
            const padding = if (truncated.display_width < viewport_width) viewport_width - truncated.display_width else 0;
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

        // 右側: 位置 | エンコード(改行) | OVR
        var right_buf: [64]u8 = undefined;
        const current_line = self.top_line + self.cursor_y + 1;
        const current_col = self.cursor_x + 1;
        const le_str = line_ending.toString(); // LF, CRLF, CR を正しく表示
        const enc_str = file_encoding.toString();
        const ovr_str = if (overwrite) " OVR" else "";
        const right_part = try std.fmt.bufPrint(&right_buf, "L{d} C{d}  {s}({s}){s} ", .{ current_line, current_col, enc_str, le_str, ovr_str });

        // ステータスバーを反転表示で開始
        try term.write(config.ANSI.INVERT);

        // 左側・右側の表示幅を計算（バイト数ではなく表示幅）
        const left_width = stringDisplayWidth(left_part);
        const right_width = stringDisplayWidth(right_part);
        const total_content = left_width + right_width;

        if (total_content >= viewport_width) {
            // 幅が足りない場合は左側を優先して切り捨て
            const max_left = if (viewport_width > right_width) viewport_width - right_width else viewport_width;
            const trunc_left = truncateUtf8(left_part, max_left);
            try term.write(trunc_left.slice);
            // 右側は表示できる分だけ
            if (viewport_width > trunc_left.display_width) {
                const remaining = viewport_width - trunc_left.display_width;
                const trunc_right = truncateUtf8(right_part, remaining);
                // パディング
                const pad = if (remaining > trunc_right.display_width) remaining - trunc_right.display_width else 0;
                for (0..pad) |_| {
                    try term.write(" ");
                }
                try term.write(trunc_right.slice);
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

    /// 画面上のカーソル位置をバッファ内のバイトオフセットに変換
    ///
    /// 【変換処理】
    /// 1. (top_line + cursor_y) から対象行を特定
    /// 2. LineIndexでO(1)で行開始位置を取得
    /// 3. cursor_x（表示幅）まで文字を走査してバイト位置を特定
    ///
    /// 【cursor_xの意味】
    /// cursor_xは「表示幅」（カラム数）であり、バイト位置ではない:
    /// - ASCII文字: 幅1
    /// - 日本語/CJK: 幅2
    /// - 絵文字: 幅2
    /// - タブ: 文脈依存（次のタブストップまで）
    ///
    /// 【注意】
    /// 絵文字やZWJシーケンスの途中でカーソルが止まらないよう、
    /// グラフェムクラスタ単位で走査する。
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
                self.moveToLineEnd(); // 行末に移動（水平スクロールも設定される）
            } else if (self.top_line > 0) {
                // 画面最上部で、さらに上にスクロール可能
                self.top_line -= 1;
                self.moveToLineEnd(); // 行末に移動（水平スクロールも設定される）
                self.markFullRedraw(); // スクロールで全画面再描画
            }
            // 注: moveToLineEnd()が水平スクロールを適切に設定するので、ここでtop_colをリセットしない
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
                // 行移動時は水平スクロールをリセット（再描画が必要）
                if (self.top_col != 0) {
                    self.top_col = 0;
                    self.markFullRedraw();
                }
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
            self.markScroll(-1); // 上スクロール（ターミナルスクロール最適化）
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
            self.markScroll(1); // 下スクロール（ターミナルスクロール最適化）
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
        // 水平スクロールがあった場合は再描画が必要
        if (self.top_col != 0) {
            self.markFullRedraw();
        }
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

        // 水平スクロール: カーソルが可視領域外なら調整
        const line_num_width = self.getLineNumberWidth();
        const visible_width = if (self.viewport_width > line_num_width) self.viewport_width - line_num_width else 1;
        if (self.cursor_x >= self.top_col + visible_width) {
            // カーソルが右端を超えたらスクロール
            self.top_col = if (self.cursor_x >= visible_width) self.cursor_x - visible_width + 1 else 0;
            self.markFullRedraw();
        } else if (self.cursor_x < self.top_col) {
            // カーソルが左端より左なら左にスクロール（短い行の場合）
            self.top_col = self.cursor_x;
            self.markFullRedraw();
        }
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
