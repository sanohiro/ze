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
const regex = @import("regex");
const unicode = @import("unicode");

// ANSIエスケープシーケンス定数（config.ANSIを参照）
const ANSI = config.ANSI;
const ASCII = config.ASCII;

/// ブロックコメント状態キャッシュエントリ
const BlockStateEntry = struct {
    line_num: usize, // 行番号
    in_block: bool, // その行の開始時点でブロックコメント内か
};

/// ブロックコメント状態キャッシュサイズ（スクロール時の近傍行検索用）
const BLOCK_STATE_CACHE_SIZE: usize = 64;

/// LineAnalysisキャッシュエントリ（描画済み行のコメントスパンを保持）
const AnalysisCacheEntry = struct {
    line_num: usize,
    in_block: bool, // 入力パラメータ（結果に影響）
    analysis: syntax.LanguageDef.LineAnalysis,
};

/// LineAnalysisキャッシュサイズ（画面内の行数程度）
const ANALYSIS_CACHE_SIZE: usize = 64;

/// 制御文字（0x00-0x1F, 0x7F）の表示幅を返す
/// 制御文字は ^X 形式で表示されるため幅2、それ以外は0を返す
inline fn controlCharWidth(codepoint: u21) u3 {
    return if (unicode.isAsciiControl(codepoint)) 2 else 0;
}

/// ANSIエスケープシーケンス（CSI: \x1b[...X）をスキップして次の位置を返す
/// シーケンスでなければnullを返す
/// CSI終端文字: 0x40-0x7E (@A-Z[\]^_`a-z{|}~) - SGR(m)だけでなく全CSIコマンドに対応
inline fn skipAnsiSequence(line: []const u8, pos: usize) ?usize {
    if (pos + 1 >= line.len) return null;
    if (!unicode.isAnsiEscapeStart(line[pos], line[pos + 1])) return null;
    var i = pos + 2;
    // CSIパラメータバイト (0x30-0x3F) と中間バイト (0x20-0x2F) をスキップ
    while (i < line.len) : (i += 1) {
        const c = line[i];
        // 終端文字: 0x40-0x7E (@ through ~)
        if (c >= 0x40 and c <= 0x7E) {
            return i + 1;
        }
        // パラメータ/中間バイト以外が来たら不正なシーケンス
        if (c < 0x20 or c > 0x3F) {
            break;
        }
    }
    // 終端文字が見つからない場合は現在位置を返す（不正なシーケンス）
    return i;
}

/// 検索ハイライトの色ペア
const HighlightColors = struct {
    start: []const u8,
    end: []const u8,
};

/// カーソル位置かどうかでハイライト色を選択
inline fn getHighlightColors(is_current: bool) HighlightColors {
    return if (is_current)
        .{ .start = ANSI.HIGHLIGHT_CURRENT, .end = ANSI.HIGHLIGHT_OFF }
    else
        .{ .start = ANSI.INVERT, .end = ANSI.INVERT_OFF };
}

/// 全角空白（U+3000）のUTF-8バイト列 - config.UTF8から参照
const FULLWIDTH_SPACE: []const u8 = &config.UTF8.FULLWIDTH_SPACE;
/// 全角空白の視覚表示用（薄い背景色 + 全角空白自体で幅2を維持）
/// 注: RESETを含めないことで選択範囲の反転表示を壊さない
const FULLWIDTH_SPACE_VISUAL: []const u8 = ANSI.BG_DARK_GRAY ++ &config.UTF8.FULLWIDTH_SPACE ++ ANSI.BG_RESET;

/// 制御文字の表示用テーブル（0x00-0x1F → ^@ 〜 ^_）
/// 表示幅は2（^ + 文字）
/// comptimeでルックアップテーブルを生成して実行時コストを削減
const CONTROL_CHAR_TABLE: [32][2]u8 = blk: {
    var table: [32][2]u8 = undefined;
    for (0..32) |i| {
        table[i] = .{ '^', @intCast(i + '@') };
    }
    break :blk table;
};

inline fn renderControlChar(ch: u8) [2]u8 {
    return CONTROL_CHAR_TABLE[ch & 0x1F];
}

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
    // 境界チェック: end_byteがline.lenを超えないようにする
    const safe_end = @min(end_byte, line.len);
    const safe_start = @min(start_byte, safe_end);

    var screen_col: usize = initial_col;
    var b: usize = safe_start;
    var needs_grapheme_scan = false;

    // 第1パス: ASCII高速パス（エスケープシーケンスをスキップしながら）
    while (b < safe_end) {
        // ANSIエスケープシーケンスをスキップ
        if (skipAnsiSequence(line, b)) |new_pos| {
            b = new_pos;
            continue;
        }

        if (unicode.isAsciiByte(line[b])) {
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
        while (b < safe_end) {
            // ANSIエスケープシーケンスをスキップ
            if (skipAnsiSequence(line, b)) |new_pos| {
                b = new_pos;
                continue;
            }

            if (unicode.isAsciiByte(line[b])) {
                // ASCII文字: 幅1
                screen_col += 1;
                b += 1;
            } else {
                // グラフェムクラスタ単位で処理（ZWJ絵文字等を正しく扱う）
                const remaining = line[b..safe_end];
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

/// ANSIエスケープシーケンスの有無を一括チェック（グレーと反転を同時に検出）
/// 1回の走査で両方をチェックすることで効率化
const AnsiFlags = struct {
    has_gray: bool,
    has_invert: bool,
};

/// expandLineWithHighlightsの戻り値（列位置とANSIフラグを同時に返す）
const ExpandResult = struct {
    col: usize,
    flags: AnsiFlags,
    /// カーソルのexpanded_line内バイト位置（検索ハイライト用）
    /// nullの場合はカーソルがこの行にない
    cursor_expanded_pos: ?usize,
};

fn detectAnsiCodes(line: []const u8, content_start: usize) AnsiFlags {
    if (content_start >= line.len) return .{ .has_gray = false, .has_invert = false };
    const content = line[content_start..];

    // ESC文字（0x1b）がなければ即座にfalseを返す（SIMD最適化済みの高速検索）
    var has_gray = false;
    var has_invert = false;
    var search_start: usize = 0;

    while (std.mem.indexOfScalar(u8, content[search_start..], '\x1b')) |rel_pos| {
        const i = search_start + rel_pos;
        if (i + 1 < content.len and content[i + 1] == '[') {
            // GRAY = "\x1b[90m" (len=5), INVERT = "\x1b[7m" (len=4)
            if (i + 4 < content.len and content[i + 2] == '9' and content[i + 3] == '0' and content[i + 4] == 'm') {
                has_gray = true;
            } else if (i + 3 < content.len and content[i + 2] == '7' and content[i + 3] == 'm') {
                has_invert = true;
            }
            // 両方見つかったら早期終了
            if (has_gray and has_invert) break;
        }
        search_start = i + 1;
    }
    return .{ .has_gray = has_gray, .has_invert = has_invert };
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

/// カーソル移動キャッシュ（moveCursorLeft高速化用）
/// 前回のgetCursorPosWithPrevWidth結果を保持し、同じ行での連続左移動でO(1)化
const CursorPrevCache = struct {
    cursor_x: usize, // キャッシュ時のcursor_x
    cursor_y: usize, // キャッシュ時のcursor_y
    top_line: usize, // キャッシュ時のtop_line
    byte_pos: usize, // cursor_xに対応するバイト位置
    prev_byte_pos: usize, // 前の文字のバイト位置
    prev_width: usize, // 前の文字の表示幅
};

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
    status_bar_dirty: bool, // ステータスバーの再描画が必要か
    prev_screen: std.ArrayList(std.ArrayList(u8)), // 前フレームの各行の内容
    prev_top_line: usize, // 前回のtop_line（スクロール検出用）
    scroll_delta: i32, // スクロール量（将来のスクロール最適化用）

    // === 再利用バッファ（パフォーマンス最適化）===
    line_buffer: std.ArrayList(u8), // 行データの一時格納
    expanded_line: std.ArrayList(u8), // タブ展開後のデータ
    highlighted_line: std.ArrayList(u8), // ハイライト適用後のデータ
    regex_visible_text: std.ArrayList(u8), // 正規表現マッチ用可視テキスト
    regex_visible_to_raw: std.ArrayList(usize), // 可視位置→元位置マッピング

    // === UI表示用 ===
    error_msg_buf: [256]u8, // エラーメッセージ（固定バッファ）
    error_msg_len: usize,
    search_highlight_buf: [256]u8, // 検索パターン（固定バッファ）
    search_highlight_len: usize,
    is_regex_highlight: bool, // 正規表現ハイライトモード
    compiled_highlight_regex: ?regex.Regex, // コンパイル済み正規表現（キャッシュ）
    selection_start: ?usize, // 選択開始位置
    selection_end: ?usize, // 選択終了位置

    // === キャッシュ ===
    cached_line_num_width: usize, // 行番号の表示幅

    // ブロックコメント状態キャッシュ（複数行対応）
    // 各エントリは (行番号, in_block状態) のペア
    // スクロール時に近傍の行から状態を取得可能
    block_state_cache: [BLOCK_STATE_CACHE_SIZE]?BlockStateEntry,
    block_state_cache_mod_count: usize, // キャッシュ有効時のbuffer.modification_count

    // LineAnalysisキャッシュ（コメントスパン結果を保持）
    // 同じ行を再描画する際に解析をスキップ
    analysis_cache: [ANALYSIS_CACHE_SIZE]?AnalysisCacheEntry,

    cached_cursor_byte_pos: ?usize, // カーソル展開位置キャッシュ：バイト位置
    cached_cursor_expanded_pos: usize, // カーソル展開位置キャッシュ：展開後位置
    block_comment_temp_buf: std.ArrayList(u8), // ブロックコメント解析用一時バッファ（再利用）

    // === 行幅キャッシュ（カーソル移動高速化）===
    // 画面内の各行の表示幅をキャッシュ。上下移動時の再計算を回避
    line_width_cache: [config.View.LINE_WIDTH_CACHE_SIZE]?u16, // null=未計算
    line_width_cache_top_line: usize, // キャッシュの基準top_line

    // === カーソルバイト位置キャッシュ（文字入力高速化）===
    // getCursorBufferPos()の結果をキャッシュ。文字入力後に差分更新
    cursor_byte_pos_cache: ?usize, // キャッシュされたバイト位置（nullなら無効）
    cursor_byte_pos_cache_x: usize, // キャッシュ時のcursor_x
    cursor_byte_pos_cache_y: usize, // キャッシュ時のcursor_y
    cursor_byte_pos_cache_top_line: usize, // キャッシュ時のtop_line

    // === カーソル移動キャッシュ（moveCursorLeft高速化）===
    // getCursorPosWithPrevWidthの結果をキャッシュ。連続左移動でO(1)化
    cursor_prev_cache: ?CursorPrevCache, // nullなら無効

    // === 言語・設定 ===
    language: *const syntax.LanguageDef,
    tab_width: ?u8, // nullなら言語デフォルト
    indent_style: ?syntax.IndentStyle, // nullなら言語デフォルト
    show_line_numbers: bool, // 行番号表示（M-x lnでトグル）

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, buffer: *Buffer) !View {
        // レンダリング用バッファを事前確保（初回フレームのアロケーション削減）
        var line_buffer = try std.ArrayList(u8).initCapacity(allocator, config.View.LINE_BUFFER_INITIAL_CAPACITY);
        errdefer line_buffer.deinit(allocator);
        var expanded_line = try std.ArrayList(u8).initCapacity(allocator, config.View.EXPANDED_LINE_INITIAL_CAPACITY);
        errdefer expanded_line.deinit(allocator);
        var highlighted_line = try std.ArrayList(u8).initCapacity(allocator, config.View.HIGHLIGHTED_LINE_INITIAL_CAPACITY);
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
            .status_bar_dirty = true,
            .line_buffer = line_buffer,
            .error_msg_buf = undefined,
            .error_msg_len = 0,
            .prev_screen = .{},
            .search_highlight_buf = undefined,
            .search_highlight_len = 0,
            .is_regex_highlight = false,
            .compiled_highlight_regex = null,
            .cached_line_num_width = 0,
            .language = syntax.getTextLanguage(), // デフォルトはテキストモード
            .tab_width = null, // 言語デフォルトを使用
            .indent_style = null, // 言語デフォルトを使用
            .show_line_numbers = config.Editor.SHOW_LINE_NUMBERS, // デフォルト設定
            .block_state_cache = .{null} ** BLOCK_STATE_CACHE_SIZE,
            .block_state_cache_mod_count = 0,
            .analysis_cache = .{null} ** ANALYSIS_CACHE_SIZE,
            .cached_cursor_byte_pos = null, // キャッシュ無効
            .cached_cursor_expanded_pos = 0,
            .block_comment_temp_buf = .{}, // 遅延初期化
            .line_width_cache = .{null} ** config.View.LINE_WIDTH_CACHE_SIZE, // 全てnull（未計算）
            .line_width_cache_top_line = 0,
            .cursor_byte_pos_cache = null, // キャッシュ無効
            .cursor_byte_pos_cache_x = 0,
            .cursor_byte_pos_cache_y = 0,
            .cursor_byte_pos_cache_top_line = 0,
            .cursor_prev_cache = null, // カーソル移動キャッシュ無効
            .expanded_line = expanded_line,
            .highlighted_line = highlighted_line,
            .regex_visible_text = .{},
            .regex_visible_to_raw = .{},
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

        // prev_screenを事前確保（レンダリング中のアロケーションを回避）
        // ステータスバー分を除いた行数を確保
        const needed_lines = height -| 1;
        self.ensurePrevScreenCapacity(needed_lines, width) catch {};

        // カーソルがビューポート外にならないよう制約
        self.constrainCursor();
        self.markFullRedraw();
    }

    /// prev_screenの容量を事前確保（バッファプール化）
    /// レンダリング中のアロケーションを最小化
    fn ensurePrevScreenCapacity(self: *View, lines: usize, width_hint: usize) !void {
        // 必要な行数分のArrayListを確保
        const line_capacity = width_hint * 4; // UTF-8 + ANSIエスケープ用に4倍
        while (self.prev_screen.items.len < lines) {
            var new_line = try std.ArrayList(u8).initCapacity(self.allocator, line_capacity);
            errdefer new_line.deinit(self.allocator);
            try self.prev_screen.append(self.allocator, new_line);
        }
        // 既存の行も容量を確保
        for (self.prev_screen.items) |*line| {
            try line.ensureTotalCapacity(self.allocator, line_capacity);
        }
    }

    /// カーソルをビューポート内に制約
    /// スクロールが発生した場合は再描画をマークする
    pub fn constrainCursor(self: *View) void {
        var needs_redraw = false;

        // ステータスバー分を除いた最大行
        const max_cursor_y = self.viewport_height -| 2;
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

    /// タブ幅を取得（設定値がなければ言語デフォルト、最小1）
    pub inline fn getTabWidth(self: *const View) u8 {
        const width = self.tab_width orelse self.language.indent_width;
        // ゼロ除算を防ぐため、最小値は1
        return if (width == 0) 4 else width;
    }

    /// 次のタブストップ位置を計算
    pub inline fn nextTabStop(current_col: usize, tab_width: usize) usize {
        return (current_col / tab_width + 1) * tab_width;
    }

    /// タブ幅を設定（0は無効、最小1）
    pub fn setTabWidth(self: *View, width: u8) void {
        self.tab_width = if (width == 0) 1 else width;
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

    /// 前フレームバッファの行を更新（既存なら更新、新規なら追加）
    fn updatePrevScreenBuffer(self: *View, screen_row: usize, line_content: []const u8) !void {
        if (screen_row < self.prev_screen.items.len) {
            self.prev_screen.items[screen_row].clearRetainingCapacity();
            try self.prev_screen.items[screen_row].appendSlice(self.allocator, line_content);
        } else {
            const line_capacity = @max(line_content.len, self.viewport_width * 4);
            var new_prev_line = try std.ArrayList(u8).initCapacity(self.allocator, line_capacity);
            errdefer new_prev_line.deinit(self.allocator);
            try new_prev_line.appendSlice(self.allocator, line_content);
            try self.prev_screen.append(self.allocator, new_prev_line);
        }
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
        self.regex_visible_text.deinit(allocator);
        self.regex_visible_to_raw.deinit(allocator);
        self.block_comment_temp_buf.deinit(allocator);
        // 正規表現キャッシュのクリーンアップ
        if (self.compiled_highlight_regex) |*r| {
            r.deinit();
        }
    }

    // エラーメッセージを設定（固定バッファにコピー）
    pub fn setError(self: *View, msg: []const u8) void {
        const len = @min(msg.len, self.error_msg_buf.len);
        @memcpy(self.error_msg_buf[0..len], msg[0..len]);
        self.error_msg_len = len;
        // ステータスバーを再描画するためにdirtyをマーク
        self.status_bar_dirty = true;
    }

    // エラーメッセージを取得
    pub inline fn getError(self: *const View) ?[]const u8 {
        if (self.error_msg_len == 0) return null;
        return self.error_msg_buf[0..self.error_msg_len];
    }

    // エラーメッセージをクリア
    pub fn clearError(self: *View) void {
        if (self.error_msg_len > 0) {
            self.error_msg_len = 0;
            // ステータスバーを再描画するためにdirtyをマーク
            self.status_bar_dirty = true;
        }
    }

    // 検索ハイライトを設定（固定バッファにコピー）
    pub fn setSearchHighlight(self: *View, search_str: ?[]const u8) void {
        self.setSearchHighlightEx(search_str, false);
    }

    /// 正規表現フラグ付きの検索ハイライト設定
    pub fn setSearchHighlightEx(self: *View, search_str: ?[]const u8, is_regex: bool) void {
        // 前の正規表現キャッシュをクリア
        if (self.compiled_highlight_regex) |*r| {
            r.deinit();
            self.compiled_highlight_regex = null;
        }

        if (search_str) |str| {
            const len = @min(str.len, self.search_highlight_buf.len);
            @memcpy(self.search_highlight_buf[0..len], str[0..len]);
            self.search_highlight_len = len;
            self.is_regex_highlight = is_regex;

            // 正規表現モードならコンパイル
            if (is_regex and len > 0) {
                self.compiled_highlight_regex = regex.Regex.compile(self.allocator, self.search_highlight_buf[0..len]) catch null;
            }
        } else {
            self.search_highlight_len = 0;
            self.is_regex_highlight = false;
        }
        // ハイライトが変わったので全画面再描画
        self.markFullRedraw();
    }

    // 検索ハイライト文字列を取得
    pub inline fn getSearchHighlight(self: *const View) ?[]const u8 {
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
    /// スペースをバッチ書き込み（高速化）
    fn writeSpaces(term: anytype, count: usize) !void {
        const SPACES_32 = "                                "; // 32 spaces
        const SPACES_8 = "        "; // 8 spaces
        var remaining = count;
        // 32スペースずつバッチ書き込み
        while (remaining >= 32) : (remaining -= 32) {
            try term.write(SPACES_32);
        }
        // 8スペースずつバッチ書き込み
        while (remaining >= 8) : (remaining -= 8) {
            try term.write(SPACES_8);
        }
        // 残り1-7スペースはスライスで一括書き込み
        if (remaining > 0) {
            try term.write(SPACES_8[0..remaining]);
        }
    }

    // 行番号の表示幅を計算（999行まで固定、1000行以上で動的拡張）
    pub fn getLineNumberWidth(self: *const View) usize {
        if (!self.show_line_numbers) return 0;

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

    /// 行番号表示をトグル（M-x lnで呼び出し）
    pub fn toggleLineNumbers(self: *View) void {
        self.show_line_numbers = !self.show_line_numbers;
        self.markFullRedraw();
    }

    pub fn markDirty(self: *View, start_line: usize, end_line: ?usize) void {
        self.status_bar_dirty = true; // バッファ変更はステータスバーにも影響

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

        // ブロックコメントキャッシュの無効化はcomputeBlockCommentState内で
        // buffer.modification_count を使って自動的に行われる

        // 行幅キャッシュの無効化（変更された行範囲）
        if (end_line) |e| {
            // キャッシュ範囲内に収まる行のみループ（O(n)→O(cache_size)に最適化）
            const cache_size = config.View.LINE_WIDTH_CACHE_SIZE;
            const cache_start = @max(start_line, self.top_line);
            const cache_end = @min(e, self.top_line + cache_size - 1);
            if (cache_start <= cache_end) {
                var line = cache_start;
                while (line <= cache_end) : (line += 1) {
                    self.invalidateLineWidthCacheAt(line);
                }
            }
        } else {
            // 改行を含む変更の場合は全キャッシュを無効化
            self.invalidateLineWidthCache();
        }

        // カーソル位置キャッシュの無効化
        // バッファ内容が変わったら、カーソルのバイトオフセットも変わる可能性がある
        // 変更がカーソル行以前なら確実に無効、以降でも保守的に無効化する
        if (start_line <= self.top_line + self.cursor_y) {
            self.invalidateCursorPosCache();
        }
    }

    pub fn markFullRedraw(self: *View) void {
        self.needs_full_redraw = true;
        self.status_bar_dirty = true;
        self.dirty_start = null;
        self.dirty_end = null;
        self.scroll_delta = 0; // スクロール最適化をリセット

        // 前フレームバッファをクリア（全画面再描画なので差分計算不要）
        for (self.prev_screen.items) |*line| {
            line.deinit(self.allocator);
        }
        self.prev_screen.clearRetainingCapacity();

        // 全キャッシュを無効化（バッファ内容が大きく変わった可能性）
        self.invalidateCursorPosCache();
        self.invalidateLineWidthCache();
    }

    /// 垂直スクロールをマーク
    /// ターミナルスクロール（ESC [S / ESC [T）を使って差分描画を最適化
    /// lines: 正=下方向（内容が上へ）、負=上方向（内容が下へ）
    pub fn markScroll(self: *View, lines: i32) void {
        if (lines == 0) return;

        // スクロール量を累積（複数回のスクロールをまとめる）
        self.scroll_delta += lines;
        self.status_bar_dirty = true; // スクロールでカーソル行が変わる

        // 新しく表示される行をdirty範囲として設定
        // prev_screenのシフトとターミナルスクロールは renderInBounds で実行
    }

    /// 水平スクロールをマーク（セル差分描画を維持）
    /// prev_screenをクリアせず、全行を再描画対象にする
    /// これにより変更のあるセルのみ出力される
    pub fn markHorizontalScroll(self: *View) void {
        self.needs_full_redraw = true;
        self.status_bar_dirty = true; // カーソル列が変わる可能性
        self.dirty_start = null;
        self.dirty_end = null;
        self.scroll_delta = 0; // 水平スクロール時は垂直スクロール最適化を無効化
        // 注意: prev_screenはクリアしない（セル比較を維持）
        // 行幅キャッシュも維持（水平位置が変わっても行幅は不変）
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
        return self.needs_full_redraw or self.dirty_start != null or self.scroll_delta != 0 or self.status_bar_dirty;
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

        // modification_countが変わったらキャッシュ無効化
        if (self.block_state_cache_mod_count != self.buffer.modification_count) {
            self.block_state_cache = .{null} ** BLOCK_STATE_CACHE_SIZE;
            self.block_state_cache_mod_count = self.buffer.modification_count;
        }

        // キャッシュから最も近いエントリを検索（target_line以下で最大のもの）
        var best_line: usize = 0;
        var best_in_block: bool = false;
        var best_found = false;

        for (self.block_state_cache) |entry_opt| {
            if (entry_opt) |entry| {
                if (entry.line_num == target_line) {
                    // 完全一致：即座に返す
                    return entry.in_block;
                }
                if (entry.line_num < target_line and (!best_found or entry.line_num > best_line)) {
                    best_line = entry.line_num;
                    best_in_block = entry.in_block;
                    best_found = true;
                }
            }
        }

        // スキャン開始位置と状態を決定
        var start_line: usize = 0;
        var in_block: bool = false;
        if (best_found) {
            start_line = best_line;
            in_block = best_in_block;
        }

        // start_lineからtarget_lineまでスキャン
        var iter = PieceIterator.init(self.buffer);

        // start_lineまでスキップ
        var current_line: usize = 0;
        while (current_line < start_line) : (current_line += 1) {
            while (iter.next()) |ch| {
                if (ch == '\n') break;
            }
        }

        // start_lineからtarget_lineまでスキャン（再利用バッファを使用）
        while (current_line < target_line) : (current_line += 1) {
            // 行を読み取る（View構造体の再利用バッファを使用）
            self.block_comment_temp_buf.clearRetainingCapacity();
            while (iter.next()) |ch| {
                if (ch == '\n') break;
                self.block_comment_temp_buf.append(self.allocator, ch) catch break;
            }

            // 行を解析
            const analysis = self.language.analyzeLine(self.block_comment_temp_buf.items, in_block);
            in_block = analysis.ends_in_block;

            // 中間結果もキャッシュ（次回のスクロール時に活用）
            const cache_idx = (current_line + 1) % BLOCK_STATE_CACHE_SIZE;
            self.block_state_cache[cache_idx] = .{
                .line_num = current_line + 1,
                .in_block = in_block,
            };
        }

        // 最終結果をキャッシュ
        const cache_idx = target_line % BLOCK_STATE_CACHE_SIZE;
        self.block_state_cache[cache_idx] = .{
            .line_num = target_line,
            .in_block = in_block,
        };

        return in_block;
    }

    /// LineAnalysisをキャッシュから取得または計算
    /// modification_countが変わったらキャッシュ全体を無効化
    fn getOrComputeAnalysis(self: *View, line_num: usize, line_content: []const u8, in_block: bool) syntax.LanguageDef.LineAnalysis {
        // modification_countが変わったらキャッシュ無効化（block_state_cacheと同期）
        if (self.block_state_cache_mod_count != self.buffer.modification_count) {
            // block_state_cacheは computeBlockCommentState で無効化される
            // analysis_cacheもここで無効化
            self.analysis_cache = .{null} ** ANALYSIS_CACHE_SIZE;
        }

        // キャッシュからルックアップ
        const cache_idx = line_num % ANALYSIS_CACHE_SIZE;
        if (self.analysis_cache[cache_idx]) |entry| {
            if (entry.line_num == line_num and entry.in_block == in_block) {
                return entry.analysis;
            }
        }

        // キャッシュミス: 解析を実行
        const analysis = self.language.analyzeLine(line_content, in_block);

        // キャッシュに保存
        self.analysis_cache[cache_idx] = .{
            .line_num = line_num,
            .in_block = in_block,
            .analysis = analysis,
        };

        return analysis;
    }

    /// ANSIエスケープシーケンス(\x1b[...m)をスキップ
    fn skipAnsiEscape(line: []const u8, pos: *usize) void {
        while (pos.* < line.len and line[pos.*] == ASCII.ESC) {
            if (pos.* + 1 < line.len and line[pos.* + 1] == ASCII.CSI_BRACKET) {
                pos.* += 2;
                while (pos.* < line.len and line[pos.*] != 'm') : (pos.* += 1) {}
                if (pos.* < line.len) pos.* += 1; // 'm' をスキップ
            } else {
                break;
            }
        }
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
            skipAnsiEscape(line, &line_pos);

            if (line_pos + search_str.len > line.len) return null;

            // この位置でマッチを試みる
            const match_start = line_pos;
            var search_idx: usize = 0;

            while (search_idx < search_str.len) {
                skipAnsiEscape(line, &line_pos);

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
    /// リテラル検索ではfindSkippingAnsi()を使用してANSI色コード内でマッチしないようにする。
    /// 正規表現検索では生テキストに対して直接マッチング。
    ///
    /// 【戻り値】
    /// - マッチなし: 入力lineをそのまま返す（アロケーションなし）
    /// - マッチあり: self.highlighted_line.itemsを返す（要再利用バッファ）
    ///
    /// 【is_cursor_line】
    /// カーソル位置のマッチのみマゼンタ、それ以外は反転で強調
    ///
    /// 【cursor_in_content】
    /// カーソルのexpanded_line内バイト位置（タブ展開後）。nullなら全て反転。
    ///
    /// 【content_start】
    /// 検索対象の開始バイト位置（行番号等のプレフィックスをスキップ）
    fn applySearchHighlight(self: *View, line: []const u8, cursor_in_content: ?usize, content_start: usize) ![]const u8 {
        const search_str = self.getSearchHighlight() orelse return line;
        if (search_str.len == 0 or line.len == 0) return line;

        // 正規表現モードか確認
        if (self.is_regex_highlight) {
            return self.applyRegexHighlight(line, cursor_in_content, content_start);
        }

        // リテラルモード: visible_textとvisible_to_rawを構築（正規表現と同じ手法でO(n)化）
        // これにより、複数マッチ時のfindSkippingAnsi繰り返し呼び出しを回避
        try self.buildVisibleText(line, content_start);

        if (self.regex_visible_text.items.len == 0) return line;

        // visible_textに対して単純な文字列検索（ANSI考慮不要）
        const first_match_vis = std.mem.indexOf(u8, self.regex_visible_text.items, search_str) orelse return line;

        // マッチがあるのでバッファを使用
        self.highlighted_line.clearRetainingCapacity();

        // 元の行位置にマッピングしてハイライトを適用
        var visible_pos: usize = 0;
        var last_raw_pos: usize = 0;

        // 最初のマッチを処理
        var match_start_vis = first_match_vis;
        var match_end_vis = first_match_vis + search_str.len;
        // 境界チェック: match_start_visおよびmatch_end_visがitems範囲内か確認
        if (self.regex_visible_to_raw.items.len == 0) return line;
        if (match_start_vis >= self.regex_visible_to_raw.items.len) {
            match_start_vis = self.regex_visible_to_raw.items.len - 1;
        }
        if (match_end_vis >= self.regex_visible_to_raw.items.len) {
            match_end_vis = self.regex_visible_to_raw.items.len - 1;
        }
        // match_start_vis > match_end_vis の場合はハイライトをスキップ
        if (match_start_vis > match_end_vis) return line;
        var match_start_raw = self.regex_visible_to_raw.items[match_start_vis];
        var match_end_raw = self.regex_visible_to_raw.items[match_end_vis];
        // match_start_raw > match_end_raw の場合もスキップ
        if (match_start_raw > match_end_raw) return line;

        // マッチ前の部分をコピー
        try self.highlighted_line.appendSlice(self.allocator, line[0..match_start_raw]);
        // カーソル位置を含むマッチかどうかで色を変える（expanded_line座標で比較）
        // カーソルはマッチ終端に置かれる: (start, end] の範囲で判定（開始を除外、終端を含む）
        const is_current = if (cursor_in_content) |cursor| cursor > match_start_raw and cursor <= match_end_raw else false;
        const hl = getHighlightColors(is_current);
        try self.highlighted_line.appendSlice(self.allocator, hl.start);
        try self.highlighted_line.appendSlice(self.allocator, line[match_start_raw..match_end_raw]);
        try self.highlighted_line.appendSlice(self.allocator, hl.end);

        visible_pos = match_end_vis;
        last_raw_pos = match_end_raw;

        // 残りのマッチを処理（上限付き）
        var match_count: usize = 1;
        while (visible_pos < self.regex_visible_text.items.len and match_count < config.View.MAX_MATCHES_PER_LINE) {
            if (std.mem.indexOf(u8, self.regex_visible_text.items[visible_pos..], search_str)) |rel_match| {
                match_count += 1;
                match_start_vis = visible_pos + rel_match;
                match_end_vis = match_start_vis + search_str.len;
                // 境界チェック
                if (match_start_vis >= self.regex_visible_to_raw.items.len) break;
                if (match_end_vis >= self.regex_visible_to_raw.items.len) {
                    match_end_vis = self.regex_visible_to_raw.items.len - 1;
                }
                // match_start_vis > match_end_vis の場合はスキップ
                if (match_start_vis > match_end_vis) break;
                match_start_raw = self.regex_visible_to_raw.items[match_start_vis];
                match_end_raw = self.regex_visible_to_raw.items[match_end_vis];
                // スライス範囲チェック: raw位置が逆転している場合はスキップ
                if (match_start_raw > match_end_raw or last_raw_pos > match_start_raw) break;

                // マッチ前の部分をコピー
                try self.highlighted_line.appendSlice(self.allocator, line[last_raw_pos..match_start_raw]);
                // カーソル位置を含むマッチかどうかで色を変える（expanded_line座標で比較）
                const is_cur = if (cursor_in_content) |cursor| cursor > match_start_raw and cursor <= match_end_raw else false;
                const hl_cur = getHighlightColors(is_cur);
                try self.highlighted_line.appendSlice(self.allocator, hl_cur.start);
                try self.highlighted_line.appendSlice(self.allocator, line[match_start_raw..match_end_raw]);
                try self.highlighted_line.appendSlice(self.allocator, hl_cur.end);

                visible_pos = match_end_vis;
                last_raw_pos = match_end_raw;
            } else {
                break;
            }
        }

        // 残りをコピー
        if (last_raw_pos < line.len) {
            try self.highlighted_line.appendSlice(self.allocator, line[last_raw_pos..]);
        }

        return self.highlighted_line.items;
    }

    /// ANSIエスケープを除いた可視テキストと位置マッピングを構築
    /// リテラル検索と正規表現検索の両方で使用
    fn buildVisibleText(self: *View, line: []const u8, content_start: usize) !void {
        self.regex_visible_text.clearRetainingCapacity();
        try self.regex_visible_text.ensureTotalCapacity(self.allocator, line.len);
        self.regex_visible_to_raw.clearRetainingCapacity();
        try self.regex_visible_to_raw.ensureTotalCapacity(self.allocator, line.len + 1);

        var raw_pos: usize = content_start;
        while (raw_pos < line.len) {
            // ANSIエスケープシーケンスをスキップ
            if (skipAnsiSequence(line, raw_pos)) |new_pos| {
                raw_pos = new_pos;
            } else {
                // 可視文字を追加
                self.regex_visible_to_raw.appendAssumeCapacity(raw_pos);
                self.regex_visible_text.appendAssumeCapacity(line[raw_pos]);
                raw_pos += 1;
            }
        }
        // 終端位置を追加（マッチ末尾の計算用）
        self.regex_visible_to_raw.appendAssumeCapacity(line.len);
    }

    /// content_startからend_posまでの表示幅を計算（ANSIエスケープを除く、UTF-8の表示幅を考慮）
    fn countDisplayWidth(line: []const u8, content_start: usize, end_pos: usize) usize {
        // 境界チェック: end_posがline.lenを超えないようにする
        const safe_end = @min(end_pos, line.len);
        const safe_start = @min(content_start, safe_end);

        var display_width: usize = 0;
        var i: usize = safe_start;
        while (i < safe_end) {
            // ANSIエスケープシーケンスをスキップ
            if (skipAnsiSequence(line, i)) |new_pos| {
                i = new_pos;
            } else {
                // UTF-8文字の表示幅を計算
                const remaining = line[i..safe_end];
                if (unicode.nextGraphemeCluster(remaining)) |cluster| {
                    display_width += cluster.display_width;
                    i += cluster.byte_len;
                } else {
                    // フォールバック：ASCII幅1
                    display_width += 1;
                    i += 1;
                }
            }
        }
        return display_width;
    }

    /// 正規表現検索ハイライトを適用
    ///
    /// 【処理フロー】
    /// 1. コンパイル済み正規表現がなければ元を返す
    /// 2. ANSIエスケープを除いた可視テキストを抽出（content_start以降のみ）
    /// 3. 可視テキストに対して正規表現マッチ
    /// 4. マッチ位置を元の行位置にマッピングしてハイライト
    ///
    /// 【cursor_in_content】
    /// カーソルのexpanded_line内バイト位置（タブ展開後）。nullなら全て反転。
    ///
    /// 【content_start】
    /// 検索対象の開始バイト位置（行番号等のプレフィックスをスキップ）
    fn applyRegexHighlight(self: *View, line: []const u8, cursor_in_content: ?usize, content_start: usize) ![]const u8 {
        // コンパイル済み正規表現がなければ元を返す
        var re = self.compiled_highlight_regex orelse return line;

        // ANSIエスケープを除いた可視テキストと位置マッピングを構築（共通関数を使用）
        try self.buildVisibleText(line, content_start);

        if (self.regex_visible_text.items.len == 0) return line;

        // 可視テキストに対して正規表現マッチ
        const first_match_result = re.search(self.regex_visible_text.items, 0) orelse return line;

        // 空マッチの場合はスキップ
        if (first_match_result.end == first_match_result.start) return line;

        // マッチがあるのでバッファを使用
        self.highlighted_line.clearRetainingCapacity();

        // 元の行位置にマッピングしてハイライトを適用
        var visible_pos: usize = 0;
        var last_raw_pos: usize = 0;

        // 最初のマッチを処理
        var match_start_vis = first_match_result.start;
        var match_end_vis = first_match_result.end;
        // 境界チェック: regex_visible_to_rawの範囲外アクセスを防止
        if (match_start_vis >= self.regex_visible_to_raw.items.len or match_end_vis >= self.regex_visible_to_raw.items.len) {
            return line;
        }
        var match_start_raw = self.regex_visible_to_raw.items[match_start_vis];
        var match_end_raw = self.regex_visible_to_raw.items[match_end_vis];

        // マッチ前の部分をコピー
        try self.highlighted_line.appendSlice(self.allocator, line[0..match_start_raw]);
        // カーソル位置を含むマッチかどうかで色を変える（expanded_line座標で比較）
        // カーソルはマッチ終端に置かれる: (start, end] の範囲で判定（開始を除外、終端を含む）
        const is_current = if (cursor_in_content) |cursor| cursor > match_start_raw and cursor <= match_end_raw else false;
        const hl = getHighlightColors(is_current);
        try self.highlighted_line.appendSlice(self.allocator, hl.start);
        try self.highlighted_line.appendSlice(self.allocator, line[match_start_raw..match_end_raw]);
        try self.highlighted_line.appendSlice(self.allocator, hl.end);

        visible_pos = match_end_vis;
        last_raw_pos = match_end_raw;

        // 残りのマッチを処理（上限付きで過剰なマッチによる遅延を防止）
        var match_count: usize = 1; // 最初のマッチをカウント
        while (visible_pos < self.regex_visible_text.items.len and match_count < config.View.MAX_MATCHES_PER_LINE) {
            if (re.search(self.regex_visible_text.items, visible_pos)) |match_result| {
                match_count += 1;
                if (match_result.end == match_result.start) {
                    // グラフェムクラスタ境界を考慮して進める（ZWJ絵文字等の途中で止まらないように）
                    const remaining = self.regex_visible_text.items[visible_pos..];
                    const cluster_len = if (unicode.nextGraphemeCluster(remaining)) |gc|
                        gc.byte_len
                    else blk: {
                        const first_byte = remaining[0];
                        break :blk std.unicode.utf8ByteSequenceLength(first_byte) catch 1;
                    };
                    visible_pos += @min(cluster_len, remaining.len);
                    continue;
                }

                match_start_vis = match_result.start;
                match_end_vis = match_result.end;
                // 境界チェック: regex_visible_to_rawの範囲外アクセスを防止
                if (match_start_vis >= self.regex_visible_to_raw.items.len or match_end_vis >= self.regex_visible_to_raw.items.len) {
                    break;
                }
                match_start_raw = self.regex_visible_to_raw.items[match_start_vis];
                match_end_raw = self.regex_visible_to_raw.items[match_end_vis];

                // マッチ前の部分をコピー
                try self.highlighted_line.appendSlice(self.allocator, line[last_raw_pos..match_start_raw]);
                // カーソル位置を含むマッチかどうかで色を変える（expanded_line座標で比較）
                const is_cur = if (cursor_in_content) |cursor| cursor > match_start_raw and cursor <= match_end_raw else false;
                const hl_cur = getHighlightColors(is_cur);
                try self.highlighted_line.appendSlice(self.allocator, hl_cur.start);
                try self.highlighted_line.appendSlice(self.allocator, line[match_start_raw..match_end_raw]);
                try self.highlighted_line.appendSlice(self.allocator, hl_cur.end);

                visible_pos = match_end_vis;
                last_raw_pos = match_end_raw;
            } else {
                break;
            }
        }

        // 残りをコピー
        if (last_raw_pos < line.len) {
            try self.highlighted_line.appendSlice(self.allocator, line[last_raw_pos..]);
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
    ///
    /// 【display_width最適化】
    /// 事前計算されたdisplay_widthを受け取ることで、padToWidth()での重複計算を回避。
    fn renderLineDiff(self: *View, term: *Terminal, new_line: []const u8, screen_row: usize, abs_row: usize, viewport_x: usize, viewport_width: usize, display_width: usize, new_flags_opt: ?AnsiFlags) !void {
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
            // 1回の走査でグレーと反転を同時検出（4回→2回に削減）
            // new_flags_optが渡されていれば再計算不要（expandLineWithHighlightsで既に検出済み）
            const old_flags = detectAnsiCodes(old_line, line_num_byte_end);
            const new_flags = new_flags_opt orelse detectAnsiCodes(new_line, line_num_byte_end);
            // グレーまたは反転がある場合は行全体を再描画（差分描画だとカラーが途切れる問題を回避）
            if (old_flags.has_gray or new_flags.has_gray or old_flags.has_invert or new_flags.has_invert) {
                // 内容が異なる場合のみ再描画
                if (!std.mem.eql(u8, old_line, new_line)) {
                    try term.moveCursor(abs_row, viewport_x);
                    try term.write(new_line);
                    // 残りをスペースで埋める（事前計算のdisplay_widthを使用、再計算なし）
                    if (display_width < viewport_width) {
                        try writeSpaces(term, viewport_width - display_width);
                    }
                }
            } else {
                // 差分を検出（双方向走査で高速化）
                const min_len = @min(old_line.len, new_line.len);
                var diff_start: ?usize = null;
                var diff_end: usize = 0;

                // 前方から最初の差分位置を探す（見つかったらbreak）
                for (0..min_len) |i| {
                    if (old_line[i] != new_line[i]) {
                        diff_start = i;
                        break;
                    }
                }

                if (diff_start) |start| {
                    // 後方から最後の差分位置を探す
                    var i = min_len;
                    while (i > start) {
                        i -= 1;
                        if (old_line[i] != new_line[i]) {
                            diff_end = i + 1;
                            break;
                        }
                    }
                    // 長さが違う場合は末尾まで差分
                    if (old_line.len != new_line.len) {
                        diff_end = @max(old_line.len, new_line.len);
                    }
                } else if (old_line.len != new_line.len) {
                    // 共通部分は同じだが長さが違う
                    diff_start = min_len;
                    diff_end = @max(old_line.len, new_line.len);
                }

                if (diff_start) |start_raw| {
                    // 差分が行番号部分にかかっている場合は行全体を再描画
                    if (line_num_display_width > 0 and start_raw < line_num_byte_end) {
                        // 行頭から全体を再描画
                        try term.moveCursor(abs_row, viewport_x);
                        try term.write(new_line);
                        // 残りをスペースで埋める（事前計算のdisplay_widthを使用）
                        if (display_width < viewport_width) {
                            try writeSpaces(term, viewport_width - display_width);
                        }
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
                            if (display_width < viewport_width) {
                                try writeSpaces(term, viewport_width - display_width);
                            }
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
                            if (display_width < viewport_width) {
                                try writeSpaces(term, viewport_width - display_width);
                            }
                        }
                    }
                }
            }
        } else {
            // 新しい行：全体を描画
            try term.moveCursor(abs_row, viewport_x);
            try term.write(new_line);
            // 残りをスペースで埋める（事前計算のdisplay_widthを使用）
            if (display_width < viewport_width) {
                try writeSpaces(term, viewport_width - display_width);
            }
        }

        // 前フレームバッファを更新
        try self.updatePrevScreenBuffer(screen_row, new_line);
    }

    /// 行データを読み取る（イテレータから改行まで）
    fn readLineData(iter: *PieceIterator, line_buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) !struct { start_pos: usize, end_pos: usize } {
        const line_start_pos = iter.global_pos;
        line_buffer.clearRetainingCapacity();
        while (iter.next()) |ch| {
            if (ch == '\n') break;
            try line_buffer.append(allocator, ch);
        }
        const line_end_pos = line_start_pos + line_buffer.items.len;
        return .{ .start_pos = line_start_pos, .end_pos = line_end_pos };
    }

    /// 行番号を expanded_line に追加
    fn renderLineNumber(self: *View, file_line: usize) !usize {
        const line_num_width = self.getLineNumberWidth();
        if (line_num_width > 0) {
            var num_buf: [64]u8 = undefined;
            const num_width = if (line_num_width >= 2) line_num_width - 2 else 1;
            const line_num_str = std.fmt.bufPrint(&num_buf, "\x1b[90m{d: >[1]}\x1b[m  ", .{ file_line + 1, num_width }) catch "";
            try self.expanded_line.appendSlice(self.allocator, line_num_str);
        }
        return self.expanded_line.items.len;
    }

    /// 選択範囲情報
    const SelectionBounds = struct {
        has_selection: bool,
        start: ?usize,
        end: ?usize,
    };

    /// 選択範囲の行内位置を計算
    fn calculateSelectionBounds(self: *View, line_start_pos: usize, line_end_pos: usize, line_buffer_len: usize) SelectionBounds {
        const has_selection = self.selection_start != null and self.selection_end != null;
        if (!has_selection) return .{ .has_selection = false, .start = null, .end = null };

        const sel_start_in_line: ?usize = blk: {
            const sel_start = self.selection_start.?;
            if (sel_start >= line_end_pos) break :blk null;
            if (sel_start <= line_start_pos) break :blk 0;
            break :blk sel_start - line_start_pos;
        };
        const sel_end_in_line: ?usize = blk: {
            const sel_end = self.selection_end.?;
            if (sel_end <= line_start_pos) break :blk null;
            if (sel_end >= line_end_pos) break :blk line_buffer_len;
            break :blk sel_end - line_start_pos;
        };
        return .{ .has_selection = has_selection, .start = sel_start_in_line, .end = sel_end_in_line };
    }

    /// タブ展開と水平スクロール処理（ハイライト適用）
    /// 戻り値にANSIフラグを含めることで、renderLineDiffでの再走査を回避
    /// cursor_byte_in_buffer: カーソルのバッファ内オフセット（検索ハイライトでexpanded位置が必要）
    fn expandLineWithHighlights(
        self: *View,
        line_buffer: []const u8,
        analysis: syntax.LanguageDef.LineAnalysis,
        selection: SelectionBounds,
        viewport_width: usize,
        line_num_width: usize,
        cursor_byte_in_buffer: ?usize,
    ) !ExpandResult {
        var byte_idx: usize = 0;
        var col: usize = 0;
        var emitted_gray = false;
        var emitted_invert = false;
        const visible_width = if (viewport_width > line_num_width) viewport_width - line_num_width else 1;
        const visible_end = self.top_col + visible_width;
        const tab_width = self.getTabWidth();

        // カーソルのexpanded_line内位置を追跡（検索ハイライト用）
        var cursor_expanded_pos: ?usize = null;

        // コメントスパン追跡
        const has_spans = analysis.span_count > 0;
        var in_comment = false;
        var current_span_idx: usize = 0;
        var current_span: ?syntax.LanguageDef.CommentSpan = if (has_spans) analysis.spans[0] else null;

        // 選択範囲追跡（ループ外で事前計算）
        const has_valid_selection = selection.has_selection and selection.start != null and selection.end != null;
        const sel_start = if (has_valid_selection) selection.start.? else 0;
        const sel_end = if (has_valid_selection) selection.end.? else 0;
        var in_selection = false;

        while (byte_idx < line_buffer.len and col < visible_end) {
            // カーソル位置を追跡（検索ハイライトでの正確な位置比較に使用）
            if (cursor_byte_in_buffer) |cursor_pos| {
                if (cursor_expanded_pos == null and byte_idx >= cursor_pos) {
                    cursor_expanded_pos = self.expanded_line.items.len;
                }
            }

            // 選択範囲チェック（事前計算済みの値を使用）
            if (has_valid_selection) {
                if (!in_selection and byte_idx >= sel_start and byte_idx < sel_end) {
                    try self.expanded_line.appendSlice(self.allocator, ANSI.INVERT);
                    emitted_invert = true;
                    in_selection = true;
                }
                if (in_selection and byte_idx >= sel_end) {
                    try self.expanded_line.appendSlice(self.allocator, ANSI.INVERT_OFF);
                    // コメント内の場合はグレーを再適用
                    if (in_comment) {
                        try self.expanded_line.appendSlice(self.allocator, ANSI.GRAY);
                        emitted_gray = true;
                    }
                    in_selection = false;
                }
            }

            // コメントスパンチェック
            if (has_spans) {
                if (current_span) |span| {
                    if (!in_comment and byte_idx == span.start) {
                        try self.expanded_line.appendSlice(self.allocator, ANSI.GRAY);
                        emitted_gray = true;
                        in_comment = true;
                    }
                    if (in_comment) {
                        if (span.end) |end| {
                            if (byte_idx == end) {
                                try self.expanded_line.appendSlice(self.allocator, ANSI.FG_RESET);
                                // 選択範囲内の場合は反転を維持
                                if (in_selection) {
                                    try self.expanded_line.appendSlice(self.allocator, ANSI.INVERT);
                                    emitted_invert = true;
                                }
                                in_comment = false;
                                current_span_idx += 1;
                                current_span = if (current_span_idx < analysis.span_count) analysis.spans[current_span_idx] else null;
                            }
                        }
                    }
                }
            }

            const ch = line_buffer[byte_idx];
            if (ch < config.UTF8.CONTINUATION_MASK) {
                // ASCII処理
                if (ch == '\t') {
                    const next_tab_stop = nextTabStop(col, tab_width);
                    const tab_start = col;
                    const tab_end = next_tab_stop;
                    if (tab_end > self.top_col and tab_start < visible_end) {
                        const visible_start = if (tab_start >= self.top_col) tab_start else self.top_col;
                        const visible_stop = if (tab_end <= visible_end) tab_end else visible_end;
                        const visible_spaces = visible_stop - visible_start;

                        // タブの先頭位置が見える場合は » を表示
                        var remaining = visible_spaces;
                        if (tab_start >= self.top_col and remaining > 0) {
                            try self.expanded_line.appendSlice(self.allocator, ANSI.GRAY);
                            emitted_gray = true;
                            try self.expanded_line.appendSlice(self.allocator, &config.UTF8.TAB_CHAR);
                            try self.expanded_line.appendSlice(self.allocator, ANSI.FG_RESET);
                            // 選択範囲内の場合は反転を再適用
                            if (in_selection) {
                                try self.expanded_line.appendSlice(self.allocator, ANSI.INVERT);
                                emitted_invert = true;
                            }
                            remaining -= 1;
                        }
                        // 残りはスペースで埋める
                        const spaces8: []const u8 = "        ";
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
                } else if (ch < ASCII.PRINTABLE_MIN or ch == ASCII.DEL) {
                    // 制御文字は2文字幅（^X形式）なので、両方収まるか確認
                    if (col >= self.top_col and col + 2 <= visible_end) {
                        // 文字全体がビューポート内に収まる
                        try self.expanded_line.appendSlice(self.allocator, ANSI.GRAY);
                        emitted_gray = true;
                        const ctrl = if (ch == ASCII.DEL) [2]u8{ '^', '?' } else renderControlChar(ch);
                        try self.expanded_line.appendSlice(self.allocator, &ctrl);
                        try self.expanded_line.appendSlice(self.allocator, ANSI.FG_RESET);
                        // 選択範囲内の場合は反転を再適用
                        if (in_selection) {
                            try self.expanded_line.appendSlice(self.allocator, ANSI.INVERT);
                            emitted_invert = true;
                        }
                    } else if (col < self.top_col and col + 2 > self.top_col) {
                        // 左端で切れる場合: はみ出した分（右半分）をスペースで埋める
                        const overhang = col + 2 - self.top_col;
                        const fill_width = @min(overhang, visible_end - self.top_col);
                        for (0..fill_width) |_| {
                            try self.expanded_line.append(self.allocator, ' ');
                        }
                    } else if (col >= self.top_col and col < visible_end) {
                        // 右端で切れる場合: 残り幅分のスペースで埋める（選択状態を維持）
                        const remaining_width = visible_end - col;
                        for (0..remaining_width) |_| {
                            try self.expanded_line.append(self.allocator, ' ');
                        }
                    }
                    byte_idx += 1;
                    col += 2;
                } else {
                    if (col >= self.top_col) {
                        try self.expanded_line.append(self.allocator, ch);
                    }
                    byte_idx += 1;
                    col += 1;
                }
            } else {
                // UTF-8処理
                const remaining = line_buffer[byte_idx..];
                if (unicode.nextGraphemeCluster(remaining)) |cluster| {
                    // 全角文字がウィンドウ境界をまたぐ場合はスペースで埋める
                    if (col >= self.top_col and col + cluster.display_width <= visible_end) {
                        // 文字全体がビューポート内に収まる
                        if (cluster.byte_len == 3 and
                            remaining[0] == config.UTF8.FULLWIDTH_SPACE[0] and
                            remaining[1] == config.UTF8.FULLWIDTH_SPACE[1] and
                            remaining[2] == config.UTF8.FULLWIDTH_SPACE[2])
                        {
                            try self.expanded_line.appendSlice(self.allocator, FULLWIDTH_SPACE_VISUAL);
                        } else {
                            try self.expanded_line.appendSlice(self.allocator, line_buffer[byte_idx .. byte_idx + cluster.byte_len]);
                        }
                    } else if (col < self.top_col and col + cluster.display_width > self.top_col) {
                        // 左端で切れる場合: はみ出した分（右半分）をスペースで埋める
                        const overhang = col + cluster.display_width - self.top_col;
                        const fill_width = @min(overhang, visible_end - self.top_col);
                        for (0..fill_width) |_| {
                            try self.expanded_line.append(self.allocator, ' ');
                        }
                    } else if (col >= self.top_col and col < visible_end) {
                        // 右端で切れる場合: 残り幅分のスペースで埋める（選択状態を維持）
                        const remaining_width = visible_end - col;
                        for (0..remaining_width) |_| {
                            try self.expanded_line.append(self.allocator, ' ');
                        }
                    }
                    byte_idx += cluster.byte_len;
                    col += cluster.display_width;
                } else {
                    byte_idx += 1;
                }
            }
        }

        // ハイライトのクリーンアップ
        if (in_selection) {
            try self.expanded_line.appendSlice(self.allocator, ANSI.RESET);
        }
        if (has_spans and in_comment) {
            try self.expanded_line.appendSlice(self.allocator, ANSI.RESET);
        }

        return .{
            .col = col,
            .flags = .{ .has_gray = emitted_gray, .has_invert = emitted_invert },
            .cursor_expanded_pos = cursor_expanded_pos,
        };
    }

    /// カーソル位置の展開後位置を計算（キャッシュ対応）
    /// カーソルの行内バイトオフセットを計算（検索ハイライト用）
    /// 検索ハイライトはバイト位置で比較するため、表示幅ではなくバイト位置を返す
    fn calculateCursorByteOffset(self: *View, screen_row: usize) ?usize {
        if (screen_row != self.cursor_y) return null;

        const cursor_pos = self.getCursorBufferPos();
        const line_start = self.buffer.getLineStart(self.top_line + self.cursor_y) orelse 0;
        if (cursor_pos < line_start) return 0;

        return cursor_pos - line_start;
    }

    fn calculateCursorExpandedPos(self: *View, line_buffer: []const u8, screen_row: usize, tab_width: usize) ?usize {
        if (screen_row != self.cursor_y) return null;

        const cursor_pos = self.getCursorBufferPos();
        if (self.cached_cursor_byte_pos) |cached_pos| {
            if (cached_pos == cursor_pos) {
                return self.cached_cursor_expanded_pos;
            }
        }

        const line_start = self.buffer.getLineStart(self.top_line + self.cursor_y) orelse 0;
        if (cursor_pos < line_start) {
            self.cached_cursor_byte_pos = cursor_pos;
            self.cached_cursor_expanded_pos = 0;
            return 0;
        }

        var expanded_pos: usize = 0;
        var byte_offset: usize = 0;
        const cursor_offset = cursor_pos - line_start;
        while (byte_offset < cursor_offset and byte_offset < line_buffer.len) {
            const byte = line_buffer[byte_offset];
            if (byte == '\t') {
                expanded_pos = nextTabStop(expanded_pos, tab_width);
                byte_offset += 1;
            } else if (unicode.isAsciiByte(byte)) {
                // 制御文字は ^X 形式で幅2、それ以外のASCIIは幅1
                expanded_pos += if (unicode.isAsciiControl(byte)) 2 else 1;
                byte_offset += 1;
            } else {
                const remaining = line_buffer[byte_offset..];
                if (unicode.nextGraphemeCluster(remaining)) |cluster| {
                    expanded_pos += cluster.display_width;
                    byte_offset += cluster.byte_len;
                } else {
                    expanded_pos += 1;
                    byte_offset += 1;
                }
            }
        }
        self.cached_cursor_byte_pos = cursor_pos;
        self.cached_cursor_expanded_pos = expanded_pos;
        return expanded_pos;
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

        // 1. 行データを読み取る
        const positions = try readLineData(iter, line_buffer, self.allocator);

        // 2. コメント解析（キャッシュ活用）
        const analysis = if (self.language.hasComments() or in_block)
            self.getOrComputeAnalysis(file_line, line_buffer.items, in_block)
        else
            syntax.LanguageDef.LineAnalysis.init();

        // 3. expanded_lineをクリアして行番号を追加
        self.expanded_line.clearRetainingCapacity();
        const content_start_byte = try self.renderLineNumber(file_line);

        // 4. 選択範囲の境界を計算
        const selection = self.calculateSelectionBounds(positions.start_pos, positions.end_pos, line_buffer.items.len);

        // 5. カーソル位置計算（タブ展開前に必要）
        const cursor_byte_in_buffer = self.calculateCursorByteOffset(screen_row);

        // 6. タブ展開とハイライト適用
        // cursor_byte_in_bufferを渡してexpanded_line内でのカーソル位置を追跡
        const line_num_width = self.getLineNumberWidth();
        const expand_result = try self.expandLineWithHighlights(line_buffer.items, analysis, selection, viewport_width, line_num_width, cursor_byte_in_buffer);

        // 7. 検索ハイライト
        // expand_result.cursor_expanded_posを使用（タブ展開後の正確な位置）
        const new_line = try self.applySearchHighlight(self.expanded_line.items, expand_result.cursor_expanded_pos, content_start_byte);

        // 7. 表示幅計算と差分描画
        const visible_width = if (viewport_width > line_num_width) viewport_width - line_num_width else 1;
        const visible_end = self.top_col + visible_width;
        const content_visible = if (expand_result.col > self.top_col) @min(expand_result.col, visible_end) - self.top_col else 0;
        const final_display_width = line_num_width + content_visible;
        try self.renderLineDiff(term, new_line, screen_row, abs_row, viewport_x, viewport_width, final_display_width, expand_result.flags);

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

        // 前フレームと比較して変更がなければスキップ
        if (screen_row < self.prev_screen.items.len) {
            const old_line = self.prev_screen.items[screen_row].items;
            if (old_line.len == 1 and old_line[0] == '~') {
                return; // 変更なし
            }
        }

        // 描画
        try term.moveCursor(abs_row, viewport_x);
        try term.write(empty_line);
        // "~" は表示幅1なので、残りをスペースで埋める
        if (viewport_width > 1) {
            try writeSpaces(term, viewport_width - 1);
        }

        // 前フレームバッファを更新
        try self.updatePrevScreenBuffer(screen_row, empty_line);
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

        // ターミナルスクロール最適化
        // scroll_delta が設定されている場合、ターミナルのスクロール機能を使って
        // prev_screen をシフトし、新しく表示される行のみを描画対象にする
        if (self.scroll_delta != 0 and !self.needs_full_redraw) {
            // 符号付き→符号なし変換: @abs()を使用（minIntも安全に処理）
            const abs_delta: usize = @abs(self.scroll_delta);

            // ターミナルスクロールは行全体（全列）に影響するため、
            // 垂直分割（左右並び）のウィンドウでは使用不可
            // viewport_x > 0 なら左に別ウィンドウあり、
            // viewport_x + viewport_width < term.width なら右に別ウィンドウあり
            const is_full_width = (viewport_x == 0 and viewport_x + viewport_width >= term.width);

            // スクロール量が画面の半分を超えたら全画面再描画の方が効率的
            if (abs_delta >= max_lines / 2) {
                self.markFullRedraw();
            } else if (self.prev_screen.items.len == max_lines and is_full_width) {
                // スクロールリージョンを設定（ステータスバーを除外）
                try term.setScrollRegion(viewport_y, viewport_y + max_lines - 1);

                if (self.scroll_delta > 0) {
                    // 下方向スクロール（内容が上へ移動）
                    // ターミナルに上スクロールを指示
                    try term.scrollUp(abs_delta);

                    // prev_screen をシフト: 上位行を削除、下位行を追加
                    // [0..abs_delta] を捨てて [abs_delta..] を [0..] にシフト
                    for (0..abs_delta) |i| {
                        // 古い行をクリア
                        self.prev_screen.items[i].clearRetainingCapacity();
                    }
                    // 行をシフト
                    for (abs_delta..max_lines) |i| {
                        std.mem.swap(
                            std.ArrayList(u8),
                            &self.prev_screen.items[i - abs_delta],
                            &self.prev_screen.items[i],
                        );
                    }
                    // 新しい行（画面下部）をクリア
                    for ((max_lines - abs_delta)..max_lines) |i| {
                        self.prev_screen.items[i].clearRetainingCapacity();
                    }

                    // line_width_cache をシフト
                    self.shiftLineWidthCacheUp(abs_delta);

                    // 新しく表示される行をdirty範囲に設定
                    const new_start = self.top_line + max_lines - abs_delta;
                    const new_end = self.top_line + max_lines;
                    self.dirty_start = new_start;
                    self.dirty_end = new_end;
                } else {
                    // 上方向スクロール（内容が下へ移動）
                    // ターミナルに下スクロールを指示
                    try term.scrollDown(abs_delta);

                    // prev_screen をシフト: 下位行を削除、上位行を追加
                    // 末尾から処理して上書きを防ぐ
                    var i: usize = max_lines;
                    while (i > abs_delta) {
                        i -= 1;
                        std.mem.swap(
                            std.ArrayList(u8),
                            &self.prev_screen.items[i],
                            &self.prev_screen.items[i - abs_delta],
                        );
                    }
                    // 新しい行（画面上部）をクリア
                    for (0..abs_delta) |j| {
                        self.prev_screen.items[j].clearRetainingCapacity();
                    }

                    // line_width_cache をシフト
                    self.shiftLineWidthCacheDown(abs_delta);

                    // 新しく表示される行をdirty範囲に設定
                    self.dirty_start = self.top_line;
                    self.dirty_end = self.top_line + abs_delta;
                }

                // スクロールリージョンをリセット
                try term.resetScrollRegion();

                self.scroll_delta = 0;
            } else {
                // prev_screenのサイズが合わない場合は全画面再描画
                self.markFullRedraw();
            }
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
            const next_line = last_rendered_file_line + 1;
            const cache_idx = next_line % BLOCK_STATE_CACHE_SIZE;
            self.block_state_cache[cache_idx] = .{
                .line_num = next_line,
                .in_block = in_block,
            };

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
                const next_line = last_rendered_file_line + 1;
                const cache_idx = next_line % BLOCK_STATE_CACHE_SIZE;
                self.block_state_cache[cache_idx] = .{
                    .line_num = next_line,
                    .in_block = in_block,
                };
            }

            self.clearDirty();
        }

        // ステータスバーの描画（dirty時のみ）
        if (self.status_bar_dirty) {
            try self.renderStatusBarAt(term, viewport_x, viewport_y + viewport_height - 1, viewport_width, modified, readonly, overwrite, line_ending, file_encoding, filename);
            self.status_bar_dirty = false;
        }
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
            try writeSpaces(term, padding);
            try term.write(config.ANSI.RESET);
            return;
        }

        // 左側: ファイル名（変更/読み取り専用フラグ付き）
        var left_buf: [1024]u8 = undefined;
        const modified_char: u8 = if (modified) '*' else ' ';
        const readonly_str = if (readonly) "[RO] " else "";
        const fname = filename orelse "[No Name]";
        const left_part = std.fmt.bufPrint(&left_buf, " {c}{s}{s}", .{ modified_char, readonly_str, fname }) catch " [path too long]";

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
                try writeSpaces(term, pad);
                try term.write(trunc_right.slice);
            }
        } else {
            // 通常表示: 左 + パディング + 右
            try term.write(left_part);
            const padding = viewport_width - total_content;
            try writeSpaces(term, padding);
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
        // キャッシュが有効かチェック（cursor位置が変わっていなければ再利用）
        if (self.cursor_byte_pos_cache) |cached_pos| {
            if (self.cursor_byte_pos_cache_x == self.cursor_x and
                self.cursor_byte_pos_cache_y == self.cursor_y and
                self.cursor_byte_pos_cache_top_line == self.top_line)
            {
                return cached_pos;
            }
        }

        // getLineWidthWithBytePosを使用（重複ロジック削減）
        const target_line = self.top_line + self.cursor_y;
        const info = self.getLineWidthWithBytePos(target_line, self.cursor_x);
        self.setCursorPosCache(info.byte_pos);
        return info.byte_pos;
    }

    /// カーソルバイト位置キャッシュを無効化
    /// バッファが編集された場合（削除、ペースト等）に呼び出す
    pub fn invalidateCursorPosCache(self: *View) void {
        self.cursor_byte_pos_cache = null;
        self.cursor_prev_cache = null; // 移動キャッシュも無効化
    }

    /// カーソルバイト位置キャッシュを設定（4行セットの共通化）
    fn setCursorPosCache(self: *View, byte_pos: usize) void {
        self.cursor_byte_pos_cache = byte_pos;
        self.cursor_byte_pos_cache_x = self.cursor_x;
        self.cursor_byte_pos_cache_y = self.cursor_y;
        self.cursor_byte_pos_cache_top_line = self.top_line;
    }

    /// 文字入力後にカーソルバイト位置キャッシュを直接更新
    /// getCursorBufferPos()の再計算を回避
    pub fn updateCursorPosCacheAfterInsert(self: *View, old_pos: usize, inserted_len: usize) void {
        self.setCursorPosCache(old_pos + inserted_len);
    }

    /// カーソル位置のバイトオフセットと直前の文字幅を同時に取得
    /// moveCursorLeftで2回走査を回避するための最適化版
    const CursorPosWithPrevWidth = struct {
        pos: usize,
        prev_width: usize,
        prev_byte_pos: usize, // 直前の文字のバイト位置（キャッシュ更新用）
    };

    fn getCursorPosWithPrevWidth(self: *View) CursorPosWithPrevWidth {
        // キャッシュチェック: 完全一致ならそのまま返す
        if (self.cursor_prev_cache) |cache| {
            if (cache.cursor_x == self.cursor_x and
                cache.cursor_y == self.cursor_y and
                cache.top_line == self.top_line)
            {
                return .{ .pos = cache.byte_pos, .prev_width = cache.prev_width, .prev_byte_pos = cache.prev_byte_pos };
            }

            // 同じ行でcursor_xが1文字分左に移動した場合、キャッシュのprev情報がそのまま「現在位置」になる
            // さらに1文字前を探すだけでO(1)で済む
            if (cache.cursor_y == self.cursor_y and
                cache.top_line == self.top_line and
                self.cursor_x == cache.cursor_x - cache.prev_width)
            {
                // cache.prev_byte_posが現在位置。さらに前の1文字を探す
                return self.scanPrevFromPos(cache.prev_byte_pos, self.cursor_x);
            }
        }

        // キャッシュミス: 行頭から走査
        const target_line = self.top_line + self.cursor_y;

        const line_start = self.buffer.getLineStart(target_line) orelse {
            return .{ .pos = self.buffer.len(), .prev_width = 1, .prev_byte_pos = 0 };
        };

        return self.scanFromLineStart(line_start, self.cursor_x);
    }

    /// 行頭から指定カラムまで走査してprev情報を取得
    fn scanFromLineStart(self: *View, line_start: usize, target_x: usize) CursorPosWithPrevWidth {
        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        var display_col: usize = 0;
        var prev_width: usize = 1; // 前の文字の幅（デフォルト1）
        var prev_byte_pos: usize = line_start; // 直前の文字のバイト位置

        while (display_col < target_x) {
            const start_pos = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster == null) break;
            const gc = cluster.?;
            // 改行を検出したら、その位置（改行文字の前）を返す
            if (gc.base == '\n') {
                return .{
                    .pos = @min(start_pos, self.buffer.len()),
                    .prev_width = prev_width,
                    .prev_byte_pos = prev_byte_pos,
                };
            }

            // タブ文字の場合は文脈依存の幅を計算
            const char_width = if (gc.base == '\t')
                nextTabStop(display_col, self.getTabWidth()) - display_col
            else if (unicode.isAsciiControl(gc.base))
                2 // 制御文字は ^X 形式で表示幅2
            else
                gc.width;

            // 目標カーソル位置を超える場合は手前で止まる（prev_width/prev_byte_posは更新しない）
            if (display_col + char_width > target_x) {
                iter.global_pos = start_pos;
                break;
            }

            // 現在の文字の幅と位置を記録（次の文字の「前の文字」情報となる）
            prev_width = char_width;
            prev_byte_pos = start_pos;
            display_col += char_width;
        }

        return .{
            .pos = @min(iter.global_pos, self.buffer.len()),
            .prev_width = prev_width,
            .prev_byte_pos = prev_byte_pos,
        };
    }

    /// 指定位置から1文字前を探してprev情報を取得（O(1)版）
    /// キャッシュ活用時に使用。行頭からではなく、既知の位置から逆方向に1文字分のみ走査
    fn scanPrevFromPos(self: *View, current_byte_pos: usize, current_x: usize) CursorPosWithPrevWidth {
        if (current_byte_pos == 0 or current_x == 0) {
            // 行頭の場合、前の文字はない
            return .{ .pos = current_byte_pos, .prev_width = 1, .prev_byte_pos = 0 };
        }

        // current_byte_posから逆方向にUTF-8開始バイトを探す
        // PieceTableでは効率的な逆走査が難しいため、行頭から走査する
        // ただしcurrent_xが小さい場合のみ行頭から走査（そうでなければ全体走査と変わらない）
        const target_line = self.top_line + self.cursor_y;
        const line_start = self.buffer.getLineStart(target_line) orelse {
            return .{ .pos = self.buffer.len(), .prev_width = 1, .prev_byte_pos = 0 };
        };

        // current_xまで行頭から走査（これ自体はO(current_x)だが、通常は短い）
        return self.scanFromLineStart(line_start, current_x);
    }

    /// カーソル位置のバイトオフセットと次の文字情報を同時に取得
    /// moveCursorRightで2回走査を回避するための最適化版
    const CursorPosWithNextInfo = struct {
        pos: usize, // 現在のカーソルバイト位置
        next_byte_pos: usize, // 次の文字のバイト位置（キャッシュ更新用）
        next_width: usize, // 次の文字の幅（タブ考慮）
        is_newline: bool, // 次の文字が改行か
        is_eof: bool, // EOFに到達したか
    };

    fn getCursorPosWithNextInfo(self: *View) CursorPosWithNextInfo {
        const target_line = self.top_line + self.cursor_y;

        // getLineWidthWithBytePosを使用してカーソル位置を取得（重複削減）
        const info = self.getLineWidthWithBytePos(target_line, self.cursor_x);
        const cursor_pos = info.byte_pos;
        const display_col = info.clamped_x;

        // 次の文字を取得
        if (cursor_pos >= self.buffer.len()) {
            return .{ .pos = cursor_pos, .next_byte_pos = cursor_pos, .next_width = 0, .is_newline = false, .is_eof = true };
        }

        var iter = PieceIterator.init(self.buffer);
        iter.seek(cursor_pos);
        const next_cluster = iter.nextGraphemeCluster() catch {
            return .{ .pos = cursor_pos, .next_byte_pos = cursor_pos, .next_width = 0, .is_newline = false, .is_eof = true };
        };

        const next_byte_pos = iter.global_pos;

        if (next_cluster) |gc| {
            if (gc.base == '\n') {
                return .{ .pos = cursor_pos, .next_byte_pos = next_byte_pos, .next_width = 0, .is_newline = true, .is_eof = false };
            }
            const next_width = if (gc.base == '\t')
                nextTabStop(display_col, self.getTabWidth()) - display_col
            else if (unicode.isAsciiControl(gc.base))
                2 // 制御文字は ^X 形式で表示幅2
            else
                gc.width;
            return .{ .pos = cursor_pos, .next_byte_pos = next_byte_pos, .next_width = next_width, .is_newline = false, .is_eof = false };
        }

        return .{ .pos = cursor_pos, .next_byte_pos = cursor_pos, .next_width = 0, .is_newline = false, .is_eof = true };
    }

    // 現在行の表示幅を取得（grapheme cluster単位）
    /// 行幅キャッシュを無効化
    pub fn invalidateLineWidthCache(self: *View) void {
        self.line_width_cache = .{null} ** config.View.LINE_WIDTH_CACHE_SIZE;
    }

    /// 特定行の行幅キャッシュを無効化
    fn invalidateLineWidthCacheAt(self: *View, file_line: usize) void {
        if (self.line_width_cache_top_line != self.top_line) {
            // top_lineが変わったらキャッシュ全体を無効化
            self.line_width_cache = .{null} ** config.View.LINE_WIDTH_CACHE_SIZE;
            self.line_width_cache_top_line = self.top_line;
            return;
        }
        if (file_line >= self.top_line) {
            const cache_idx = file_line - self.top_line;
            if (cache_idx < config.View.LINE_WIDTH_CACHE_SIZE) {
                self.line_width_cache[cache_idx] = null;
            }
        }
    }

    /// 行幅キャッシュを上方向にシフト（下スクロール時）
    /// 上位 n 行分を破棄し、残りを上にシフト、末尾を null で埋める
    fn shiftLineWidthCacheUp(self: *View, n: usize) void {
        const CACHE_SIZE = config.View.LINE_WIDTH_CACHE_SIZE;
        if (n >= CACHE_SIZE) {
            self.line_width_cache = .{null} ** CACHE_SIZE;
            return;
        }
        // シフト: [n..] -> [0..]
        for (n..CACHE_SIZE) |i| {
            self.line_width_cache[i - n] = self.line_width_cache[i];
        }
        // 末尾を null で埋める
        for ((CACHE_SIZE - n)..CACHE_SIZE) |i| {
            self.line_width_cache[i] = null;
        }
        // top_line は呼び出し元で既に更新されている想定
        self.line_width_cache_top_line = self.top_line;
    }

    /// 行幅キャッシュを下方向にシフト（上スクロール時）
    /// 下位 n 行分を破棄し、残りを下にシフト、先頭を null で埋める
    fn shiftLineWidthCacheDown(self: *View, n: usize) void {
        const CACHE_SIZE = config.View.LINE_WIDTH_CACHE_SIZE;
        if (n >= CACHE_SIZE) {
            self.line_width_cache = .{null} ** CACHE_SIZE;
            return;
        }
        // シフト: [0..CACHE_SIZE-n] -> [n..CACHE_SIZE]（末尾から処理して上書きを防ぐ）
        var i: usize = CACHE_SIZE;
        while (i > n) {
            i -= 1;
            self.line_width_cache[i] = self.line_width_cache[i - n];
        }
        // 先頭を null で埋める
        for (0..n) |j| {
            self.line_width_cache[j] = null;
        }
        // top_line は呼び出し元で既に更新されている想定
        self.line_width_cache_top_line = self.top_line;
    }

    /// 文字入力後に行幅キャッシュを差分更新
    /// 再計算せずに直接幅を加算（高速化）
    pub fn updateLineWidthCacheAfterInsert(self: *View, char_width: usize) void {
        if (self.line_width_cache_top_line != self.top_line) {
            // top_lineが変わったらキャッシュ全体を無効化（差分更新不可）
            self.line_width_cache = .{null} ** config.View.LINE_WIDTH_CACHE_SIZE;
            self.line_width_cache_top_line = self.top_line;
            return;
        }

        // cache_idx = (top_line + cursor_y) - top_line = cursor_y
        const cache_idx = self.cursor_y;
        if (cache_idx >= config.View.LINE_WIDTH_CACHE_SIZE) return;

        if (self.line_width_cache[cache_idx]) |cached| {
            // キャッシュに幅を加算（u16オーバーフロー時は無効化）
            const new_width = @as(usize, cached) + char_width;
            if (new_width <= std.math.maxInt(u16)) {
                self.line_width_cache[cache_idx] = @intCast(new_width);
            } else {
                self.line_width_cache[cache_idx] = null;
            }
        }
        // キャッシュがnull（未計算）の場合はそのまま（次回アクセス時に計算）
    }

    /// 行幅を取得（キャッシュ使用）
    fn getLineWidthCached(self: *View, file_line: usize) usize {
        // top_lineが変わったらキャッシュをリセット
        if (self.line_width_cache_top_line != self.top_line) {
            self.line_width_cache = .{null} ** config.View.LINE_WIDTH_CACHE_SIZE;
            self.line_width_cache_top_line = self.top_line;
        }

        // キャッシュインデックス計算
        if (file_line < self.top_line) return self.calculateLineWidth(file_line);
        const cache_idx = file_line - self.top_line;
        if (cache_idx >= config.View.LINE_WIDTH_CACHE_SIZE) return self.calculateLineWidth(file_line);

        // キャッシュヒット
        if (self.line_width_cache[cache_idx]) |cached| {
            return cached;
        }

        // キャッシュミス: 計算してキャッシュ
        const width = self.calculateLineWidth(file_line);
        // u16に収まる場合のみキャッシュ（65535カラム超は稀）
        if (width <= std.math.maxInt(u16)) {
            self.line_width_cache[cache_idx] = @intCast(width);
        }
        return width;
    }

    /// 行幅を計算（キャッシュなし）
    fn calculateLineWidth(self: *View, file_line: usize) usize {
        const line_start = self.buffer.getLineStart(file_line) orelse return 0;

        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        var line_width: usize = 0;
        while (true) {
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                const char_width = if (gc.base == '\t')
                    nextTabStop(line_width, self.getTabWidth()) - line_width
                else if (unicode.isAsciiControl(gc.base))
                    2 // 制御文字は ^X 形式で表示幅2
                else
                    gc.width;
                line_width += char_width;
            } else {
                break;
            }
        }
        return line_width;
    }

    pub fn getCurrentLineWidth(self: *View) usize {
        return self.getLineWidthCached(self.top_line + self.cursor_y);
    }

    /// 行幅を取得し、指定カラムまでのバイト位置も返す
    /// cursor_x が行幅を超える場合は行末のバイト位置を返す
    pub const LineWidthWithBytePos = struct {
        width: usize, // 行の総表示幅
        byte_pos: usize, // 指定カラム（またはクランプ後）のバイト位置
        clamped_x: usize, // クランプ後のcursor_x
    };

    /// 行幅とバイト位置を取得（早期終了最適化版）
    /// target_xに到達したら残りのスキャンをスキップ
    pub fn getLineWidthWithBytePos(self: *View, file_line: usize, target_x: usize) LineWidthWithBytePos {
        const line_start = self.buffer.getLineStart(file_line) orelse {
            return .{ .width = 0, .byte_pos = self.buffer.len(), .clamped_x = 0 };
        };

        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        var line_width: usize = 0;

        while (true) {
            const current_pos = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster) |gc| {
                // 改行を検出したら、その位置（改行文字の前）を返す
                // iter.global_posは改行を読んだ後なので、current_posを使う
                if (gc.base == '\n') {
                    return .{ .width = line_width, .byte_pos = current_pos, .clamped_x = @min(target_x, line_width) };
                }

                const char_width = if (gc.base == '\t')
                    nextTabStop(line_width, self.getTabWidth()) - line_width
                else if (unicode.isAsciiControl(gc.base))
                    2 // 制御文字は ^X 形式で表示幅2
                else
                    gc.width;

                // target_xに到達したら早期終了（残りのスキャン不要）
                if (line_width + char_width > target_x) {
                    // target_xはこの文字の途中なので、この文字の開始位置を返す
                    // clamped_xは文字の開始位置にクランプ（全角文字の途中にカーソルを置かない）
                    return .{ .width = line_width + char_width, .byte_pos = current_pos, .clamped_x = line_width };
                }

                line_width += char_width;

                // ちょうどtarget_xに到達した場合も早期終了可能
                if (line_width == target_x) {
                    return .{ .width = line_width, .byte_pos = iter.global_pos, .clamped_x = target_x };
                }
            } else {
                break;
            }
        }

        // 行末に到達（target_xが行幅を超えている）
        // clamped_xは行幅にクランプ
        return .{ .width = line_width, .byte_pos = iter.global_pos, .clamped_x = line_width };
    }

    pub fn moveCursorLeft(self: *View) void {
        self.status_bar_dirty = true;
        if (self.cursor_x > 0) {
            // ヘルパーで1回の走査でバイト位置と直前の文字幅を同時取得
            const info = self.getCursorPosWithPrevWidth();
            if (info.pos == 0) {
                self.cursor_x = 0;
                self.cursor_prev_cache = null;
                return;
            }

            // キャッシュ更新（次回の左移動で活用）
            self.cursor_prev_cache = .{
                .cursor_x = self.cursor_x,
                .cursor_y = self.cursor_y,
                .top_line = self.top_line,
                .byte_pos = info.pos,
                .prev_byte_pos = info.prev_byte_pos,
                .prev_width = info.prev_width,
            };

            // 直前の文字幅だけカーソルを戻す
            if (self.cursor_x >= info.prev_width) {
                self.cursor_x -= info.prev_width;
            } else {
                self.cursor_x = 0;
            }

            self.setCursorPosCache(info.prev_byte_pos);

            // 水平スクロール: カーソルが左端より左に行った場合
            if (self.cursor_x < self.top_col) {
                self.top_col = self.cursor_x;
                self.markHorizontalScroll();
            }
        } else {
            // cursor_x == 0、前の行に移動
            if (self.cursor_y > 0) {
                self.cursor_y -= 1;
                self.invalidateCursorPosCache();
                self.moveToLineEnd(); // 行末に移動（水平スクロールも設定される）
            } else if (self.top_line > 0) {
                // 画面最上部で、さらに上にスクロール可能
                self.top_line -= 1;
                self.invalidateCursorPosCache();
                self.moveToLineEnd(); // 行末に移動（水平スクロールも設定される）
                self.markScroll(-1); // スクロール最適化（markFullRedrawの代わり）
            }
            // 注: moveToLineEnd()が水平スクロールを適切に設定するので、ここでtop_colをリセットしない
        }
    }

    pub fn moveCursorRight(self: *View) void {
        self.status_bar_dirty = true;
        // ヘルパーで1回の走査でバイト位置と次の文字情報を同時取得
        const info = self.getCursorPosWithNextInfo();
        if (info.is_eof) return;

        // ステータスバー分を除いた最大行
        const max_cursor_y = self.viewport_height -| 2;

        if (info.is_newline) {
            // 改行の場合は次の行の先頭へ
            var scrolled = false;
            if (self.cursor_y < max_cursor_y and self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
                self.cursor_y += 1;
                self.cursor_x = 0;
            } else if (self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
                self.top_line += 1;
                self.cursor_x = 0;
                self.markScroll(1); // スクロール最適化（markFullRedrawの代わり）
                scrolled = true;
            }
            // 行移動時は水平スクロールをリセット
            if (self.top_col != 0) {
                self.top_col = 0;
                if (!scrolled) {
                    self.markHorizontalScroll();
                }
            }
            // 行が変わったのでキャッシュを無効化
            self.invalidateCursorPosCache();
        } else {
            // 次の文字の幅分進める
            self.cursor_x += info.next_width;
            self.setCursorPosCache(info.next_byte_pos);

            // 水平スクロール: カーソルが右端を超えた場合（行番号幅を除く）
            const visible_width = if (self.viewport_width > self.getLineNumberWidth())
                self.viewport_width - self.getLineNumberWidth()
            else
                1;
            if (self.cursor_x >= self.top_col + visible_width) {
                self.top_col = self.cursor_x - visible_width + 1;
                self.markHorizontalScroll();
            }
        }
    }

    pub fn moveCursorUp(self: *View) void {
        self.status_bar_dirty = true;
        if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        } else if (self.top_line > 0) {
            self.top_line -= 1;
            self.markScroll(-1); // 上スクロール（ターミナルスクロール最適化）
        } else {
            return;
        }

        // 行幅とバイト位置を同時に取得（1回の走査で完了）
        const target_line = self.top_line + self.cursor_y;
        const info = self.getLineWidthWithBytePos(target_line, self.cursor_x);

        // カーソル位置をクランプし、キャッシュを更新
        self.cursor_x = info.clamped_x;
        self.setCursorPosCache(info.byte_pos);

        // 水平スクロール位置もクランプ（短い行に移動した時の空白表示を防ぐ）
        if (self.top_col > self.cursor_x) {
            self.top_col = self.cursor_x;
            self.markHorizontalScroll();
        }
    }

    pub fn moveCursorDown(self: *View) void {
        self.status_bar_dirty = true;
        const max_cursor_y = self.viewport_height -| 2;
        if (self.cursor_y < max_cursor_y and self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
            self.cursor_y += 1;
        } else if (self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
            self.top_line += 1;
            self.markScroll(1); // 下スクロール（ターミナルスクロール最適化）
        } else {
            return;
        }

        // 行幅とバイト位置を同時に取得（1回の走査で完了）
        const target_line = self.top_line + self.cursor_y;
        const info = self.getLineWidthWithBytePos(target_line, self.cursor_x);

        // カーソル位置をクランプし、キャッシュを更新
        self.cursor_x = info.clamped_x;
        self.setCursorPosCache(info.byte_pos);

        // 水平スクロール位置もクランプ（短い行に移動した時の空白表示を防ぐ）
        if (self.top_col > self.cursor_x) {
            self.top_col = self.cursor_x;
            self.markHorizontalScroll();
        }
    }

    /// ビューポートをスクロール（カーソルの画面内位置は固定）
    /// lines: 正=下スクロール、負=上スクロール
    pub fn scrollViewport(self: *View, lines: i32) void {
        self.status_bar_dirty = true;
        const total_lines = self.buffer.lineCount();
        if (total_lines == 0) return;

        const old_top = self.top_line;

        if (lines > 0) {
            // 下スクロール
            const delta: usize = @intCast(lines);
            const max_top = if (total_lines > 1) total_lines - 1 else 0;
            if (self.top_line + delta <= max_top) {
                self.top_line += delta;
            } else {
                self.top_line = max_top;
            }
        } else if (lines < 0) {
            // 上スクロール
            // i64経由でキャストすることでi32.minでもオーバーフローしない
            const delta: usize = @intCast(-@as(i64, lines));
            if (self.top_line >= delta) {
                self.top_line -= delta;
            } else {
                self.top_line = 0;
            }
        }

        // 実際のスクロール量でマーク（クランプされた場合を考慮）
        // i64で差分を計算し、i32範囲にクランプ（巨大ファイルでのオーバーフロー防止）
        const new_top: i64 = @intCast(self.top_line);
        const old_top_i64: i64 = @intCast(old_top);
        const actual_delta_i64 = new_top - old_top_i64;
        const actual_delta: i32 = @intCast(std.math.clamp(actual_delta_i64, std.math.minInt(i32), std.math.maxInt(i32)));
        if (actual_delta != 0) {
            self.markScroll(actual_delta);
        }

        // カーソルがファイル末尾を超えないように調整
        const max_line = if (total_lines > 0) total_lines - 1 else 0;
        if (self.top_line + self.cursor_y > max_line) {
            if (self.top_line <= max_line) {
                self.cursor_y = max_line - self.top_line;
            } else {
                self.top_line = max_line;
                self.cursor_y = 0;
            }
        }

        // カーソル位置が行の幅を超えている場合は行末に移動
        const line_width = self.getCurrentLineWidth();
        if (self.cursor_x > line_width) {
            self.cursor_x = line_width;
        }
    }

    pub fn moveToLineStart(self: *View) void {
        self.status_bar_dirty = true;
        // 水平スクロールがあった場合は再描画が必要
        if (self.top_col != 0) {
            self.markHorizontalScroll();
        }
        self.cursor_x = 0;
        self.top_col = 0;

        // カーソルバイト位置キャッシュを更新（行頭 = line_start）
        const line = self.top_line + self.cursor_y;
        if (self.buffer.getLineStart(line)) |line_start| {
            self.setCursorPosCache(line_start);
        }
    }

    pub fn moveToLineEnd(self: *View) void {
        self.status_bar_dirty = true;
        // 行幅キャッシュを使用（キャッシュヒットならO(1)）
        const line_width = self.getCurrentLineWidth();
        self.cursor_x = line_width;

        // カーソルバイト位置キャッシュを更新（行末 = 改行位置 or EOF）
        const line = self.top_line + self.cursor_y;
        const byte_pos = if (self.buffer.getLineStart(line + 1)) |next_line_start|
            // 次の行がある場合、改行文字の位置
            if (next_line_start > 0) next_line_start - 1 else 0
        else
            // 最終行の場合、バッファ末尾
            self.buffer.len();
        self.setCursorPosCache(byte_pos);

        // 水平スクロール: カーソルが可視領域外なら調整
        const line_num_width = self.getLineNumberWidth();
        const visible_width = if (self.viewport_width > line_num_width) self.viewport_width - line_num_width else 1;
        if (self.cursor_x >= self.top_col + visible_width) {
            // カーソルが右端を超えたらスクロール
            self.top_col = if (self.cursor_x >= visible_width) self.cursor_x - visible_width + 1 else 0;
            self.markHorizontalScroll();
        } else if (self.cursor_x < self.top_col) {
            // カーソルが左端より左なら左にスクロール（短い行の場合）
            self.top_col = self.cursor_x;
            self.markHorizontalScroll();
        }
    }

    // M-< (beginning-of-buffer): ファイルの先頭に移動
    pub fn moveToBufferStart(self: *View) void {
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.top_line = 0;
        self.top_col = 0;
        self.setCursorPosCache(0);
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
            self.setCursorPosCache(0);
            self.markFullRedraw();
            return;
        }

        // 最終行の番号（0-indexed）
        const last_line = if (total_lines > 0) total_lines - 1 else 0;

        // ビューポートの表示可能行数
        const max_screen_lines = self.viewport_height -| 2;

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
