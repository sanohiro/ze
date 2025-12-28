// zeエディタの設定定数
// すべてのマジックナンバーをここに集約

/// ターミナル関連の定数
pub const Terminal = struct {
    /// デフォルトの幅（cols）
    pub const DEFAULT_WIDTH: usize = 80;

    /// デフォルトの高さ（rows）
    pub const DEFAULT_HEIGHT: usize = 24;

    /// ステータスバーの高さ（行数）
    pub const STATUS_BAR_HEIGHT: usize = 1;

    /// カーソル移動のエスケープシーケンスバッファサイズ
    pub const CURSOR_BUF_SIZE: usize = 32;
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

    // === マウスイベント ===
    /// マウスボタンイベントを有効化（スクロールを含む）
    pub const ENABLE_MOUSE = "\x1b[?1000h";
    /// マウスボタンイベントを無効化
    pub const DISABLE_MOUSE = "\x1b[?1000l";

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
    /// 下線
    pub const UNDERLINE = "\x1b[4m";
    /// 下線解除
    pub const UNDERLINE_OFF = "\x1b[24m";
    /// 薄い表示（dim）
    pub const DIM = "\x1b[2m";
    /// グレー（明るい黒）
    pub const GRAY = "\x1b[90m";

    // === スクロール制御 ===
    /// スクロール領域をリセット
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
    /// CSI開始の2文字目（'['）
    pub const CSI_BRACKET: u8 = '[';
};

/// UTF-8関連の定数
pub const UTF8 = struct {
    /// 継続バイトのマスク（10xxxxxx）
    pub const CONTINUATION_MASK: u8 = 0b11000000;
    /// 継続バイトのパターン
    pub const CONTINUATION_PATTERN: u8 = 0b10000000;

    /// 最大codepoint（Unicode上限）
    pub const MAX_CODEPOINT: u21 = 0x10FFFF;

    /// 最大バイト長
    pub const MAX_BYTE_LEN: usize = 4;

    // === バイト範囲定数 ===
    /// 2バイト文字の先頭バイト範囲
    pub const BYTE2_MIN: u8 = 0xC0;
    pub const BYTE2_MAX: u8 = 0xDF;
    /// 3バイト文字の先頭バイト範囲
    pub const BYTE3_MIN: u8 = 0xE0;
    pub const BYTE3_MAX: u8 = 0xEF;
    /// 4バイト文字の先頭バイト範囲
    pub const BYTE4_MIN: u8 = 0xF0;
    pub const BYTE4_MAX: u8 = 0xF7;

    // === 特殊文字 ===
    /// 全角スペース (U+3000) の UTF-8 バイト列
    pub const FULLWIDTH_SPACE = [_]u8{ 0xE3, 0x80, 0x80 };
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

/// エディタ動作の定数
pub const Editor = struct {
    /// Undo/Redoスタックの最大エントリ数
    pub const MAX_UNDO_ENTRIES: usize = 1000;

    /// Undoコアレッシングのタイムアウト（ミリ秒）
    /// この時間以上間隔があいた操作は別のundoグループになる
    pub const UNDO_COALESCE_TIMEOUT_MS: u64 = 500;

    /// スクロールマージン（上下の余白行数）
    pub const SCROLL_MARGIN: usize = 3;

    /// ステータスバーのバッファサイズ
    pub const STATUS_BUF_SIZE: usize = 256;

    /// タブ幅（空白文字数）
    pub const TAB_WIDTH: usize = 4;

    /// 行番号を表示するか
    pub const SHOW_LINE_NUMBERS: bool = true;
};

/// 入力処理の定数
pub const Input = struct {
    /// 入力バッファサイズ（1回の読み取り用）
    pub const BUF_SIZE: usize = 16;

    /// リングバッファサイズ（ペースト時等の大量入力に対応）
    pub const RING_BUF_SIZE: usize = 4096;

    /// Ctrl+キーのマスク
    pub const CTRL_MASK: u8 = ASCII.CTRL_MAX;
};

/// バッファ関連の定数
pub const Buffer = struct {
    /// 初期piece配列のキャパシティ
    pub const INITIAL_PIECES_CAPACITY: usize = 16;

    /// 初期add_bufferのキャパシティ
    pub const INITIAL_ADD_CAPACITY: usize = 1024;
};

/// ユーザー向けメッセージ（一元管理）
pub const Messages = struct {
    // === エラーメッセージ ===
    pub const BUFFER_READONLY = "Buffer is read-only";
    pub const NO_MARK_SET = "No mark set";
    pub const NO_ACTIVE_REGION = "No active region";
    pub const UNKNOWN_COMMAND = "Unknown command";
    pub const FILE_NOT_FOUND = "File not found";
    pub const BINARY_FILE = "Binary file detected";
    pub const MEMORY_ALLOCATION_FAILED = "Memory allocation failed";
    pub const NO_SEARCH_STRING = "Error: no search string";
    pub const COMMAND_START_FAILED = "Failed to start command";
    pub const COMMAND_FAILED = "Command failed";
    pub const NO_MATCH = "No match";
    pub const NO_MATCH_FOUND = "No match found";
    pub const NO_COMMAND_SPECIFIED = "No command specified";
    pub const SHELL_RUNNING = "Running... (C-g to cancel)";
    pub const CANCELLED = "Cancelled";

    // === 確認メッセージ ===
    pub const CONFIRM_YES_NO = "Please answer: (y)es or (n)o";
    pub const CONFIRM_YES_NO_CANCEL = "Please answer: (y)es, (n)o, (c)ancel";

    // === 状態メッセージ ===
    pub const RUNNING_SHELL = "Running... (C-g to cancel)";
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

    // === キープレフィックス ===
    pub const KEY_PREFIX_CX = "C-x-";
    pub const KEY_PREFIX_CXR = "C-x r ";
};
