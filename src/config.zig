// zeエディタの設定定数
// すべてのマジックナンバーをここに集約

const std = @import("std");

/// ターミナル関連の定数
pub const Terminal = struct {
    /// デフォルトの幅（cols）
    pub const DEFAULT_WIDTH: usize = 80;

    /// デフォルトの高さ（rows）
    pub const DEFAULT_HEIGHT: usize = 24;

    /// 出力バッファの初期容量
    pub const OUTPUT_BUFFER_CAPACITY: usize = 8192;
};

/// ANSIエスケープシーケンス
pub const ANSI = struct {
    // === 画面制御 ===
    /// 画面全体をクリア
    pub const CLEAR_SCREEN = "\x1b[2J";
    /// カーソルをホーム位置へ
    pub const CURSOR_HOME = "\x1b[H";
    /// 行末までクリア
    pub const CLEAR_LINE = "\x1b[K";
    /// カーソルを非表示
    pub const HIDE_CURSOR = "\x1b[?25l";
    /// カーソルを表示
    pub const SHOW_CURSOR = "\x1b[?25h";

    // === Alternate Screen Buffer ===
    /// 代替画面バッファを有効化（終了時に元の画面に戻る）
    pub const ENTER_ALT_SCREEN = "\x1b[?1049h";
    /// 代替画面バッファを無効化（元の画面に戻る）
    pub const EXIT_ALT_SCREEN = "\x1b[?1049l";

    // === ブラケットペーストモード ===
    /// ブラケットペーストモードを有効化
    pub const ENABLE_BRACKETED_PASTE = "\x1b[?2004h";
    /// ブラケットペーストモードを無効化
    pub const DISABLE_BRACKETED_PASTE = "\x1b[?2004l";

    // === 表示属性 ===
    /// 表示属性リセット
    pub const RESET = "\x1b[m";
    /// 反転表示
    pub const INVERT = "\x1b[7m";
    /// 反転表示解除
    pub const INVERT_OFF = "\x1b[27m";
    /// グレー（明るい黒）
    pub const GRAY = "\x1b[90m";

    // === カーソル位置の保存/復元 ===
    /// カーソル位置を保存（DECSC）
    pub const SAVE_CURSOR = "\x1b7";
    /// カーソル位置を復元（DECRC）
    pub const RESTORE_CURSOR = "\x1b8";

    // === スクロール制御 ===
    /// スクロール領域をリセット（注意：カーソルを(1,1)に移動する副作用あり）
    pub const RESET_SCROLL_REGION = "\x1b[r";
    /// 1行スクロールアップ
    pub const SCROLL_UP = "\x1b[S";
    /// 1行スクロールダウン
    pub const SCROLL_DOWN = "\x1b[T";

    // === 検索ハイライト ===
    /// 現在のマッチ（黄色背景、黒文字）
    pub const HIGHLIGHT_CURRENT = "\x1b[48;5;220m\x1b[30m";
    /// ハイライト解除（背景・前景リセット）
    pub const HIGHLIGHT_OFF = "\x1b[49m\x1b[39m";

    // === 前景色/背景色 ===
    /// 前景色リセット
    pub const FG_RESET = "\x1b[39m";
    /// 暗いグレー背景（全角スペース表示用）
    pub const BG_DARK_GRAY = "\x1b[48;5;236m";
    /// 背景色リセット
    pub const BG_RESET = "\x1b[49m";

    // === カーソル形状 (DECSCUSR) ===
    /// ブロックカーソル（点滅なし）
    pub const CURSOR_BLOCK = "\x1b[2 q";
    /// バーカーソル（点滅なし）
    pub const CURSOR_BAR = "\x1b[6 q";
    /// デフォルトカーソル（ターミナル設定に戻す）
    pub const CURSOR_DEFAULT = "\x1b[0 q";

    // === Synchronized Output (DEC Private Mode 2026) ===
    /// 同期更新開始（BSU: Begin Synchronized Update）
    pub const BEGIN_SYNC = "\x1b[?2026h";
    /// 同期更新終了（ESU: End Synchronized Update）
    pub const END_SYNC = "\x1b[?2026l";

    // === Focus Events (DEC Private Mode 1004) ===
    /// フォーカスイベント報告を有効化
    pub const ENABLE_FOCUS_EVENTS = "\x1b[?1004h";
    /// フォーカスイベント報告を無効化
    pub const DISABLE_FOCUS_EVENTS = "\x1b[?1004l";
};

/// ASCII関連の定数
pub const ASCII = struct {
    /// ASCII範囲の最大値（0x7F = 127）
    pub const MAX: u8 = 0x7F;
    /// 制御文字の最大値（0x1F = 31）
    pub const CTRL_MAX: u8 = 0x1F;
    /// 印字可能文字の最小値（スペース）
    pub const PRINTABLE_MIN: u8 = 0x20;
    /// ESCキー（エスケープシーケンス開始）
    pub const ESC: u8 = 0x1B;
    /// DELキー
    pub const DEL: u8 = 0x7F;
    /// Backspaceキー（Ctrl+H）
    pub const BACKSPACE: u8 = 0x08;
    /// CSI開始の2文字目（'['）
    pub const CSI_BRACKET: u8 = '[';
};

/// UTF-8関連の定数
pub const UTF8 = struct {
    /// 継続バイトのマスク（10xxxxxx）
    pub const CONTINUATION_MASK: u8 = 0b11000000;
    /// 継続バイトのパターン
    pub const CONTINUATION_PATTERN: u8 = 0b10000000;

    // === バイト範囲定数 ===
    /// 2バイト文字の先頭バイト最大値
    pub const BYTE2_MAX: u8 = 0xDF;
    /// 3バイト文字の先頭バイト範囲
    pub const BYTE3_MIN: u8 = 0xE0;
    pub const BYTE3_MAX: u8 = 0xEF;
    /// 4バイト文字の先頭バイト最小値
    pub const BYTE4_MIN: u8 = 0xF0;

    // === 特殊文字 ===
    /// 全角スペース (U+3000) の UTF-8 バイト列
    pub const FULLWIDTH_SPACE = [_]u8{ 0xE3, 0x80, 0x80 };
    /// タブ表示文字 » (U+00BB) の UTF-8 バイト列
    pub const TAB_CHAR = [_]u8{ 0xC2, 0xBB };
};

/// BOM (Byte Order Mark) 定数
pub const BOM = struct {
    /// UTF-8 BOM
    pub const UTF8 = [_]u8{ 0xEF, 0xBB, 0xBF };
    /// UTF-16LE BOM
    pub const UTF16LE = [_]u8{ 0xFF, 0xFE };
    /// UTF-16BE BOM
    pub const UTF16BE = [_]u8{ 0xFE, 0xFF };
};

/// ウィンドウ関連の定数
pub const Window = struct {
    /// 最小幅
    pub const MIN_WIDTH: usize = 10;
    /// 最小高さ
    pub const MIN_HEIGHT: usize = 3;
};

/// ビュー関連の定数
pub const View = struct {
    /// 行幅キャッシュのサイズ（行数）
    pub const LINE_WIDTH_CACHE_SIZE: usize = 128;
    /// 1行あたりの最大ハイライトマッチ数
    pub const MAX_MATCHES_PER_LINE: usize = 100;
    /// 行バッファの初期容量（UTF-8テキスト用、viewport_width * 4程度）
    pub const LINE_BUFFER_INITIAL_CAPACITY: usize = 512;
    /// 展開済み行バッファの初期容量（タブ展開 + ANSIコード用）
    pub const EXPANDED_LINE_INITIAL_CAPACITY: usize = 2048;
    /// ハイライト済み行バッファの初期容量
    pub const HIGHLIGHTED_LINE_INITIAL_CAPACITY: usize = 4096;
};

/// 検索関連の定数
pub const Search = struct {
    /// 後方スキャンのチャンクサイズ（バイト）
    pub const BACKWARD_CHUNK_SIZE: usize = 256;
};

/// Query Replaceプロンプト関連
pub const QueryReplace = struct {
    pub const PREFIX_REGEX = "Query replace regexp ";
    pub const PREFIX_LITERAL = "Query replace ";
    pub const PROMPT_REGEX = "Query replace regexp: ";
    pub const PROMPT_LITERAL = "Query replace: ";

    /// is_regex_replaceフラグに基づいてプレフィックスを返す
    pub inline fn getPrefix(is_regex: bool) []const u8 {
        return if (is_regex) PREFIX_REGEX else PREFIX_LITERAL;
    }

    /// is_regex_replaceフラグに基づいてプロンプトを返す
    pub inline fn getPrompt(is_regex: bool) []const u8 {
        return if (is_regex) PROMPT_REGEX else PROMPT_LITERAL;
    }
};

/// エディタ動作の定数
pub const Editor = struct {
    /// Undoグループ化のタイムアウト（ナノ秒）
    /// この時間以内の連続した同種の操作は1つのundoグループにまとめられる
    pub const UNDO_GROUP_TIMEOUT_NS: i128 = 300 * std.time.ns_per_ms;

    /// ステータスバーのバッファサイズ
    pub const STATUS_BUF_SIZE: usize = 256;

    /// タブ幅（空白文字数）
    pub const TAB_WIDTH: usize = 4;

    /// 行番号を表示するか
    pub const SHOW_LINE_NUMBERS: bool = true;

    /// 最大タブ幅
    pub const MAX_TAB_WIDTH: usize = 16;

    /// 最大インデント長（バイト）
    pub const MAX_INDENT_LENGTH: usize = 256;

    /// インデントバッファサイズ（タブ幅に対応）
    pub const INDENT_BUF_SIZE: usize = 16;

    /// コメントプレフィックス用バッファサイズ
    pub const COMMENT_BUF_SIZE: usize = 64;

    /// ビューポートの予約行数（ステータスバー + ミニバッファ）
    pub const VIEWPORT_RESERVED_LINES: usize = 2;
};

/// 入力処理の定数
pub const Input = struct {
    /// 入力バッファサイズ（1回の読み取り用）
    pub const BUF_SIZE: usize = 16;

    /// リングバッファサイズ（ペースト時等の大量入力に対応）
    pub const RING_BUF_SIZE: usize = 4096;
};

/// バッファ関連の定数
pub const Buffer = struct {
    /// searchBackward用スタックバッファの最大piece数
    pub const MAX_PIECES_STACK_BUFFER: usize = 256;

    /// add_buffer（追加バッファ）の初期容量
    /// 連続入力時のアロケーション回数を削減するため、起動時に事前確保
    pub const ADD_BUFFER_INITIAL_CAPACITY: usize = 64 * 1024; // 64KB
};

/// シェル関連の定数
pub const Shell = struct {
    /// 読み取りバッファサイズ
    pub const READ_BUFFER_SIZE: usize = 16 * 1024;

    /// 最大出力サイズ（10MB）
    pub const MAX_OUTPUT_SIZE: usize = 10 * 1024 * 1024;

    /// 大きなチャンクサイズ（64KB）
    pub const LARGE_CHUNK_SIZE: usize = 64 * 1024;

    /// Tab補完の最大出力サイズ（256KB）
    /// 巨大な$PATHやディレクトリでも候補が欠けにくいように余裕を持たせる
    pub const COMPLETION_MAX_OUTPUT: usize = 256 * 1024;
};

/// 正規表現関連の定数
pub const Regex = struct {
    /// 最大バックトラック位置数（病的パターンでの指数時間防止）
    pub const MAX_POSITIONS: usize = 10000;
};

/// ミニバッファ関連の定数
pub const Minibuffer = struct {
    /// プロンプトの最大長
    pub const MAX_PROMPT_LEN: usize = 256;
};

/// ユーザー向けメッセージ（一元管理）
pub const Messages = struct {
    // === エラーメッセージ ===
    pub const BUFFER_READONLY = "Buffer is read-only";
    pub const NO_MARK_SET = "No mark set";
    pub const NO_ACTIVE_REGION = "No active region";
    pub const UNKNOWN_COMMAND = "Unknown command";
    pub const MEMORY_ALLOCATION_FAILED = "Memory allocation failed";
    pub const NO_SEARCH_STRING = "Error: no search string";
    pub const COMMAND_START_FAILED = "Failed to start command";
    pub const COMMAND_FAILED = "Command failed";
    pub const NO_MATCH = "No match";
    pub const NO_COMMAND_SPECIFIED = "No command specified";
    pub const SHELL_RUNNING = "Running... (C-g to cancel)";
    pub const CANCELLED = "Cancelled";

    // === 確認メッセージ ===
    pub const CONFIRM_YES_NO = "Please answer: (y)es or (n)o";
    pub const CONFIRM_YES_NO_CANCEL = "Please answer: (y)es, (n)o, (c)ancel";
    pub const CONFIRM_REPLACE = "Please answer: (y)es, (n)ext, (!)all, (q)uit";
    pub const CONFIRM_OVERWRITE = "File exists. Overwrite? (y)es (n)o";
    pub const REPLACE_PROMPT = "Replace? (y)es (n)ext (!)all (q)uit";

    // === プロンプト ===
    pub const PROMPT_WRITE_FILE = "Write file: ";

    // === 警告メッセージ ===
    pub const WARNING_FILE_DELETED = "Warning: file deleted externally";
    pub const WARNING_FILE_MODIFIED = "Warning: file modified externally!";

    // === 状態メッセージ ===
    pub const SEARCH_WRAPPED = "Wrapped";
    pub const SEARCH_NOT_FOUND = "Not found";

    // === バッファ境界メッセージ ===
    pub const BEGINNING_OF_BUFFER = "Beginning of buffer";
    pub const END_OF_BUFFER = "End of buffer";

    // === キルリング/ヤンクメッセージ ===
    pub const KILL_RING_EMPTY = "Kill ring is empty";
    pub const YANKED_TEXT = "Yanked text";
    pub const KILLED_REGION = "Killed region";
    pub const SAVED_TEXT = "Saved text to kill ring";
    pub const MARK_SET = "Mark set";
    pub const MARK_DEACTIVATED = "Mark deactivated";

    // === 矩形操作メッセージ ===
    pub const RECTANGLE_COPIED = "Rectangle copied";
    pub const RECTANGLE_KILLED = "Rectangle killed";
    pub const RECTANGLE_YANKED = "Rectangle yanked";
    pub const NO_RECTANGLE_TO_YANK = "No rectangle to yank";
    pub const RECTANGLE_EMPTY = "Rectangle is empty";

    // === コメント操作メッセージ ===
    pub const LINE_COMMENT_NOT_SUPPORTED = "Line comment not supported for this language";

    // === マクロメッセージ ===
    pub const MACRO_ALREADY_RECORDING = "Already recording macro";
    pub const MACRO_CANNOT_RECORD_WHILE_PLAYING = "Cannot record while playing";
    pub const MACRO_DEFINING = "Defining kbd macro...";
    pub const MACRO_NOT_RECORDING = "Not recording macro";
    pub const MACRO_EMPTY = "Empty macro, previous kept";
    pub const MACRO_REPEAT_PROMPT = "Press e to repeat macro";
    pub const MACRO_NOT_DEFINED = "No kbd macro defined";

    // === キープレフィックス ===
    pub const KEY_PREFIX_CX = "C-x-";

    // === M-xコマンドメッセージ ===
    pub const MX_COMMANDS_HELP = "Commands: line ln tab indent mode revert key ro kill-buffer overwrite exit ?";
    pub const MX_LINE_NUMBERS_ON = "Line numbers: on";
    pub const MX_LINE_NUMBERS_OFF = "Line numbers: off";
    pub const MX_INVALID_LINE_NUMBER = "Invalid line number";
    pub const MX_LINE_MUST_BE_GE1 = "Line number must be >= 1";
    pub const MX_INVALID_TAB_WIDTH = "Invalid tab width";
    pub const MX_TAB_WIDTH_RANGE = "Tab width must be 1-16";
    pub const MX_INDENT_SPACE = "indent: space";
    pub const MX_INDENT_TAB = "indent: tab";
    pub const MX_INDENT_USAGE = "Usage: indent space|tab";
    pub const MX_NO_FILE_TO_REVERT = "No file to revert";
    pub const MX_BUFFER_MODIFIED = "Buffer modified. Save first or use C-x k";
    pub const MX_REVERTED = "Reverted";
    pub const MX_READONLY_ENABLED = "[RO] Read-only enabled";
    pub const MX_READONLY_DISABLED = "Read-only disabled";
    pub const MX_KEY_DESCRIBE_PROMPT = "Press key: ";
    pub const MX_EXIT_CONFIRM = "Exit? (y)es (n)o";

    // === 検索プロンプト ===
    pub const ISEARCH_FORWARD = "I-search: ";
    pub const ISEARCH_BACKWARD = "I-search backward: ";
    pub const ISEARCH_REGEX_FORWARD = "Regexp I-search: ";
    pub const ISEARCH_REGEX_BACKWARD = "Regexp I-search backward: ";

    // === 特殊バッファ名 ===
    pub const BUFFER_SCRATCH = "*scratch*";
    pub const BUFFER_LIST = "*Buffer List*";
    pub const BUFFER_COMMAND = "*Command*";
};
