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
};

/// UTF-8関連の定数
pub const UTF8 = struct {
    /// 継続バイトのマスク
    pub const CONTINUATION_MASK: u8 = 0b10000000;

    /// ASCIIの最大値
    pub const ASCII_MAX: u8 = 0b01111111;

    /// 最大codepoint（Unicode上限）
    pub const MAX_CODEPOINT: u21 = 0x10FFFF;

    /// 最大バイト長
    pub const MAX_BYTE_LEN: usize = 4;
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

    /// Escapeキー
    pub const ESC: u8 = 27;

    /// DELキー
    pub const DEL: u8 = 127;

    /// Ctrl+キーのマスク
    pub const CTRL_MASK: u8 = 0x1f;
};

/// バッファ関連の定数
pub const Buffer = struct {
    /// 初期piece配列のキャパシティ
    pub const INITIAL_PIECES_CAPACITY: usize = 16;

    /// 初期add_bufferのキャパシティ
    pub const INITIAL_ADD_CAPACITY: usize = 1024;
};
