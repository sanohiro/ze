// ============================================================================
// Editor - zeエディタのコアモジュール
// ============================================================================
//
// 【責務】
// - 複数バッファの管理（BufferState）
// - 複数ウィンドウの管理（Window）
// - キー入力のディスパッチとコマンド実行
// - Undo/Redo、検索、置換などの編集操作
// - シェルコマンドの非同期実行
//
// 【マルチバッファ・マルチウィンドウ】
// zeはEmacs風のバッファ・ウィンドウモデルを採用:
// - Buffer: テキスト内容（ファイルに対応、または*scratch*）
// - Window: 画面上の表示領域（同じバッファを複数ウィンドウで表示可能）
// - 1つのウィンドウは1つのバッファを表示
// - バッファは複数のウィンドウで共有可能
//
// 【エディタモード】
// モードレスのEmacs風だが、内部的にはモード状態を持つ:
// - normal: 通常の編集
// - isearch: インクリメンタルサーチ
// - query_replace: 対話的置換
// - shell_command: シェルコマンド入力/実行
// など
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const Buffer = @import("buffer.zig").Buffer;
const Piece = @import("buffer.zig").Piece;
const PieceIterator = @import("buffer.zig").PieceIterator;
const View = @import("view.zig").View;
const Terminal = @import("terminal.zig").Terminal;
const input = @import("input.zig");
const config = @import("config.zig");
const regex = @import("regex.zig");
const History = @import("history.zig").History;
const HistoryType = @import("history.zig").HistoryType;
const unicode = @import("unicode.zig");

// サービス
const poller = @import("poller.zig");

const Minibuffer = @import("services/minibuffer.zig").Minibuffer;
const SearchService = @import("services/search_service.zig").SearchService;
const ShellService = @import("services/shell_service.zig").ShellService;
const BufferManager = @import("services/buffer_manager.zig").BufferManager;
const BufferState = @import("services/buffer_manager.zig").BufferState;
const WindowManager = @import("services/window_manager.zig").WindowManager;
const Window = @import("services/window_manager.zig").Window;
const SplitType = @import("services/window_manager.zig").SplitType;
const EditingContext = @import("editing_context.zig").EditingContext;
const Keymap = @import("keymap.zig").Keymap;
const edit = @import("commands/edit.zig");
const rectangle = @import("commands/rectangle.zig");
const mx = @import("commands/mx.zig");

/// エディタの状態遷移を管理するモード
///
/// zeは基本的にモードレス（Vimと違いモード切り替え不要）だが、
/// 内部的には特殊な入力状態を追跡する必要がある。
/// 例: ファイル名入力中はEnterで確定、C-gでキャンセル
const EditorMode = enum {
    normal, // 通常編集モード
    prefix_x, // C-xプレフィックス待ち（C-x C-s, C-x C-c等）
    prefix_r, // C-x rプレフィックス待ち（矩形選択コマンド）
    quit_confirm, // 終了確認中（y/n/cを待つ）
    filename_input, // ファイル名入力中（保存: C-x C-s）
    find_file_input, // ファイル名入力中（開く: C-x C-f）
    buffer_switch_input, // バッファ名入力中（切り替え: C-x b）
    kill_buffer_confirm, // バッファ閉じる確認中（y/nを待つ）
    isearch_forward, // インクリメンタルサーチ前方（C-s）
    isearch_backward, // インクリメンタルサーチ後方（C-r）
    query_replace_input_search, // 置換：検索文字列入力中（M-%）
    query_replace_input_replacement, // 置換：置換文字列入力中
    query_replace_confirm, // 置換：確認中（y/n/!/q）
    shell_command, // シェルコマンド入力中（M-|）
    shell_running, // シェルコマンド実行中（C-gでキャンセル可）
    mx_command, // M-xコマンド入力中
    mx_key_describe, // M-x key: 次のキー入力を待っている
};

/// シェルコマンド出力先
const ShellOutputDest = enum {
    command_buffer, // Command Bufferに表示（デフォルト）
    replace, // 入力元を置換 (>)
    insert, // カーソル位置に挿入 (+>)
    new_buffer, // 新規バッファ (n>)
};

/// シェルコマンド入力元
const ShellInputSource = enum {
    selection, // 選択範囲（なければ空）
    buffer_all, // バッファ全体 (%)
    current_line, // 現在行 (.)
};

/// シェルコマンドの非同期実行状態
///
/// 【非同期実行の仕組み】
/// 1. spawnAsync(): 子プロセスを起動、stdinにデータを書き込み
/// 2. pollShellCommand(): 毎フレームstdout/stderrをノンブロッキングで読み取り
/// 3. 完了時: 出力先に応じてバッファを更新（置換、挿入、新規バッファ）
///
/// 【キャンセル対応】
/// shell_running モード中に C-g でキャンセル可能。
/// 子プロセスをkillしてリソースをクリーンアップ。
///
/// 【パイプライン文法】
/// `[入力元] | コマンド [出力先]` 形式で、sed/awk/jq等と連携
// ========================================
// BufferState, Window: services/buffer_manager.zig, services/window_manager.zig に移動済み
// ShellCommandState: services/shell_service.zig に移動済み
// ========================================

// ========================================
// Editor: エディタ本体（複数バッファ・ウィンドウを管理）
// ========================================
pub const Editor = struct {
    // グローバルリソース
    terminal: Terminal,
    allocator: std.mem.Allocator,
    running: bool,

    // バッファとウィンドウの管理
    buffer_manager: BufferManager, // バッファマネージャー（全バッファを管理）
    window_manager: WindowManager, // ウィンドウマネージャー（全ウィンドウを管理）

    // エディタ状態
    mode: EditorMode,
    minibuffer: Minibuffer, // ミニバッファ入力用
    quit_after_save: bool,
    prompt_buffer: ?[]const u8, // allocPrintで作成したプロンプト文字列
    prompt_prefix_len: usize, // プロンプト文字列のプレフィックス長（カーソル位置計算用）

    // グローバルバッファ（全バッファで共有）
    kill_ring: ?[]const u8,
    rectangle_ring: ?std.ArrayList([]const u8),

    // 検索状態（グローバル）
    search_start_pos: ?usize,
    last_search: ?[]const u8,

    // 置換状態（グローバル）
    replace_search: ?[]const u8,
    replace_replacement: ?[]const u8,
    replace_current_pos: ?usize,
    replace_match_count: usize,

    // サービス
    shell_service: ShellService, // シェルコマンド実行サービス（履歴含む）
    search_service: SearchService, // 検索サービス（履歴含む）

    // キーマップ
    keymap: Keymap, // キーバインド設定（ランタイム変更可能）

    pub fn init(allocator: std.mem.Allocator) !Editor {
        // ターミナルを先に初期化（サイズ取得のため）
        const terminal = try Terminal.init(allocator);

        // BufferManagerを初期化し、最初のバッファを作成
        var buffer_manager = BufferManager.init(allocator);
        const first_buffer = try buffer_manager.createBuffer();

        // WindowManagerを初期化し、最初のウィンドウを作成
        var window_manager = WindowManager.init(allocator, terminal.width, terminal.height);
        const first_window = try window_manager.createWindow(first_buffer.id, 0, 0, terminal.width, terminal.height);
        first_window.view = try View.init(allocator, first_buffer.editing_ctx.buffer);
        // 言語検出（新規バッファなのでデフォルト、ファイルオープン時にmain.zigで再検出される）
        first_window.view.detectLanguage(null, null);
        // ビューポートサイズを設定（カーソル移動の境界判定に使用）
        first_window.view.setViewport(terminal.width, terminal.height);

        var editor = Editor{
            .terminal = terminal,
            .allocator = allocator,
            .running = true,
            .buffer_manager = buffer_manager,
            .window_manager = window_manager,
            .mode = .normal,
            .minibuffer = Minibuffer.init(allocator),
            .quit_after_save = false,
            .prompt_buffer = null,
            .prompt_prefix_len = 0,
            .kill_ring = null,
            .rectangle_ring = null,
            .search_start_pos = null,
            .last_search = null,
            .replace_search = null,
            .replace_replacement = null,
            .replace_current_pos = null,
            .replace_match_count = 0,
            .shell_service = ShellService.init(allocator),
            .search_service = SearchService.init(allocator),
            .keymap = try Keymap.init(allocator),
        };

        // デフォルトキーバインドを登録
        try editor.keymap.loadDefaults();

        return editor;
    }

    pub fn deinit(self: *Editor) void {
        // ウィンドウマネージャーを解放（全ウィンドウを含む）
        self.window_manager.deinit();

        // バッファマネージャーを解放（全バッファを含む）
        self.buffer_manager.deinit();

        // ターミナルを解放
        self.terminal.deinit();

        // キーマップを解放
        self.keymap.deinit();

        // グローバルバッファの解放
        if (self.kill_ring) |text| {
            self.allocator.free(text);
        }
        if (self.rectangle_ring) |*rect| {
            for (rect.items) |line| {
                self.allocator.free(line);
            }
            rect.deinit(self.allocator);
        }

        // 検索状態の解放
        if (self.last_search) |search| {
            self.allocator.free(search);
        }

        // 置換状態の解放
        if (self.replace_search) |search| {
            self.allocator.free(search);
        }
        if (self.replace_replacement) |replacement| {
            self.allocator.free(replacement);
        }

        // プロンプトバッファのクリーンアップ
        if (self.prompt_buffer) |prompt| {
            self.allocator.free(prompt);
        }

        // ミニバッファのクリーンアップ
        self.minibuffer.deinit();

        // サービスのクリーンアップ
        self.shell_service.deinit();
        self.search_service.deinit();
    }

    // ========================================
    // ヘルパーメソッド
    // ========================================

    /// 現在のウィンドウを取得（WindowManager経由）
    pub fn getCurrentWindow(self: *Editor) *Window {
        return self.window_manager.getCurrentWindow();
    }

    /// 現在のバッファを取得
    pub fn getCurrentBuffer(self: *Editor) *BufferState {
        const window = self.getCurrentWindow();
        return self.buffer_manager.findById(window.buffer_id) orelse unreachable;
    }

    /// 現在のビューを取得
    pub fn getCurrentView(self: *Editor) *View {
        return &self.getCurrentWindow().view;
    }

    /// 現在のバッファのBufferを取得
    pub fn getCurrentBufferContent(self: *Editor) *Buffer {
        return self.getCurrentBuffer().editing_ctx.buffer;
    }

    /// 読み取り専用チェック（編集前に呼ぶ）
    /// 読み取り専用ならエラー表示してtrueを返す
    pub fn isReadOnly(self: *Editor) bool {
        if (self.getCurrentBuffer().readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return true;
        }
        return false;
    }

    /// プロンプトを設定（古いバッファを自動解放）
    pub fn setPrompt(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        if (self.prompt_buffer) |old| {
            self.allocator.free(old);
        }
        self.prompt_buffer = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
        if (self.prompt_buffer) |prompt| {
            self.getCurrentView().setError(prompt);
        }
    }

    /// プロンプトを解放
    fn clearPrompt(self: *Editor) void {
        if (self.prompt_buffer) |old| {
            self.allocator.free(old);
            self.prompt_buffer = null;
        }
    }

    /// エラーを表示（anyerror対応）
    fn showError(self: *Editor, err: anyerror) void {
        self.getCurrentView().setError(@errorName(err));
    }

    /// ミニバッファ入力をキャンセルしてnormalモードに戻る
    fn cancelInput(self: *Editor) void {
        self.mode = .normal;
        self.clearInputBuffer();
        self.getCurrentView().clearError();
    }

    /// 保存モードのキャンセル（quit_after_saveもリセット）
    fn cancelSaveInput(self: *Editor) void {
        self.quit_after_save = false;
        self.cancelInput();
    }

    /// Query Replaceモードのキャンセル（replace_searchも解放）
    fn cancelQueryReplaceInput(self: *Editor) void {
        if (self.replace_search) |search| {
            self.allocator.free(search);
            self.replace_search = null;
        }
        self.cancelInput();
    }

    /// C-g または Escape キーかどうか判定
    fn isCancelKey(key: input.Key) bool {
        return switch (key) {
            .ctrl => |c| c == 'g',
            .escape => true,
            else => false,
        };
    }

    /// ミニバッファキー処理とプロンプト更新を一括実行
    fn processMinibufferKeyWithPrompt(self: *Editor, key: input.Key, prompt: []const u8) !void {
        _ = try self.handleMinibufferKey(key);
        self.updateMinibufferPrompt(prompt);
    }

    /// normalモードに戻りエラー表示をクリア
    fn resetToNormal(self: *Editor) void {
        self.mode = .normal;
        self.getCurrentView().clearError();
    }

    /// 検索モードを終了してnormalに戻る
    fn endSearch(self: *Editor) void {
        self.search_start_pos = null;
        self.mode = .normal;
        self.minibuffer.clear();
        self.search_service.resetHistoryNavigation();
        self.getCurrentView().setSearchHighlight(null);
        self.getCurrentView().clearError();
        self.getCurrentView().markFullRedraw();
    }

    /// インクリメンタルサーチを開始（C-s / C-r）
    fn startIsearch(self: *Editor, forward: bool) !void {
        if (self.last_search) |search_str| {
            // 前回の検索パターンがあれば、それで検索を実行
            self.minibuffer.setContent(search_str) catch {};
            self.getCurrentView().setSearchHighlight(search_str);
            try self.performSearch(forward, true);
            self.getCurrentView().clearError();
            self.getCurrentView().markFullRedraw();
        } else {
            // 新規検索モードに入る
            self.mode = if (forward) .isearch_forward else .isearch_backward;
            self.search_start_pos = self.getCurrentView().getCursorBufferPos();
            self.clearInputBuffer();
            if (forward) {
                self.prompt_prefix_len = 11;
                self.getCurrentView().setError("I-search: ");
            } else {
                self.prompt_prefix_len = 20;
                self.getCurrentView().setError("I-search backward: ");
            }
        }
    }

    /// バッファ閉じる確認モードの文字処理
    fn handleKillBufferConfirmChar(self: *Editor, cp: u21) void {
        const c = unicode.toAsciiChar(cp);
        switch (c) {
            'y', 'Y' => {
                const buffer_id = self.getCurrentBuffer().id;
                self.closeBuffer(buffer_id) catch |err| self.showError(err);
                self.mode = .normal;
            },
            'n', 'N' => {
                self.resetToNormal();
            },
            else => self.getCurrentView().setError("Please answer: (y)es or (n)o"),
        }
    }

    /// 終了確認モードの文字処理
    fn handleQuitConfirmChar(self: *Editor, cp: u21) void {
        const c = unicode.toAsciiChar(cp);
        switch (c) {
            'y', 'Y' => {
                const buffer_state = self.getCurrentBuffer();
                if (buffer_state.filename == null) {
                    self.mode = .filename_input;
                    self.quit_after_save = true;
                    self.minibuffer.clear();
                    self.getCurrentView().setError("Write file: ");
                } else {
                    self.saveFile() catch |err| {
                        self.showError(err);
                        self.mode = .normal;
                        return;
                    };
                    self.running = false;
                }
            },
            'n', 'N' => self.running = false,
            'c', 'C' => {
                self.resetToNormal();
            },
            else => self.getCurrentView().setError("Please answer: (y)es, (n)o, (c)ancel"),
        }
    }

    /// 置換完了メッセージを表示してノーマルモードに戻る
    fn finishReplace(self: *Editor) void {
        self.mode = .normal;
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace done";
        self.getCurrentView().setError(msg);
    }

    /// 次のマッチを検索し、見つかればプロンプトを表示、なければ完了
    fn findNextOrFinish(self: *Editor, search: []const u8, start_pos: usize) !void {
        const found = try self.findNextMatch(search, start_pos);
        if (!found) {
            self.finishReplace();
        } else {
            self.getCurrentView().setError("Replace? (y)es (n)ext (!)all (q)uit");
        }
    }

    /// 置換確認モードの文字処理
    fn handleReplaceConfirmChar(self: *Editor, cp: u21) !void {
        const c = unicode.toAsciiChar(cp);
        const search = self.replace_search orelse {
            self.mode = .normal;
            self.getCurrentView().setError("Error: no search string");
            return;
        };

        switch (c) {
            'y', 'Y' => {
                // この箇所を置換して次へ
                try self.replaceCurrentMatch();
                try self.findNextOrFinish(search, self.getCurrentView().getCursorBufferPos());
            },
            'n', 'N', ' ' => {
                // スキップして次へ
                const current_pos = self.getCurrentView().getCursorBufferPos();
                try self.findNextOrFinish(search, current_pos + 1);
            },
            '!' => {
                // 残りすべてを置換
                try self.replaceCurrentMatch();
                var pos = self.getCurrentView().getCursorBufferPos();
                while (true) {
                    const found = try self.findNextMatch(search, pos);
                    if (!found) break;
                    try self.replaceCurrentMatch();
                    pos = self.getCurrentView().getCursorBufferPos();
                }
                self.finishReplace();
            },
            'q', 'Q' => {
                // 終了
                self.finishReplace();
            },
            else => {
                // 無効な入力
                self.getCurrentView().setError("Please answer: (y)es, (n)ext, (!)all, (q)uit");
            },
        }
    }

    /// 検索文字列にコードポイントを追加して検索実行
    fn addSearchChar(self: *Editor, cp: u21, is_forward: bool) !void {
        // UTF-8にエンコードして追加
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.minibuffer.insertAtCursor(buf[0..len]);

        // プロンプトを更新
        const prefix = if (is_forward) "I-search: " else "I-search backward: ";
        self.setPrompt("{s}{s}", .{ prefix, self.minibuffer.getContent() });

        // 検索実行
        if (self.minibuffer.getContent().len > 0) {
            self.getCurrentView().setSearchHighlight(self.minibuffer.getContent());
            try self.performSearch(is_forward, false);
        }
    }

    /// 新しいバッファを作成（BufferManager経由）
    pub fn createNewBuffer(self: *Editor) !*BufferState {
        return try self.buffer_manager.createBuffer();
    }

    /// 指定されたIDのバッファを検索（BufferManager経由）
    fn findBufferById(self: *Editor, buffer_id: usize) ?*BufferState {
        return self.buffer_manager.findById(buffer_id);
    }

    /// 指定されたファイル名のバッファを検索（BufferManager経由）
    fn findBufferByFilename(self: *Editor, filename: []const u8) ?*BufferState {
        return self.buffer_manager.findByFilename(filename);
    }

    // ========================================
    // ミニバッファ（ステータスバー入力）操作
    // Minibufferサービスへの委譲
    // ========================================

    /// ミニバッファをクリア
    fn clearInputBuffer(self: *Editor) void {
        self.minibuffer.clear();
    }

    /// ミニバッファのカーソル位置に文字を挿入
    fn insertAtInputCursor(self: *Editor, text: []const u8) !void {
        try self.minibuffer.insertAtCursor(text);
    }

    /// ミニバッファにコードポイントを挿入（char/codepoint共通）
    fn insertCodepointAtInputCursor(self: *Editor, cp: u21) !void {
        try self.minibuffer.insertCodepointAtCursor(cp);
    }

    /// ミニバッファのカーソル前の1文字（グラフェム）を削除（バックスペース）
    fn backspaceAtInputCursor(self: *Editor) void {
        self.minibuffer.backspace();
    }

    /// ミニバッファのカーソル位置の1文字（グラフェム）を削除（デリート）
    fn deleteAtInputCursor(self: *Editor) void {
        self.minibuffer.delete();
    }

    /// ミニバッファでカーソルを1文字左に移動
    fn moveInputCursorLeft(self: *Editor) void {
        self.minibuffer.moveLeft();
    }

    /// ミニバッファでカーソルを1文字右に移動
    fn moveInputCursorRight(self: *Editor) void {
        self.minibuffer.moveRight();
    }

    /// ミニバッファでカーソルを先頭に移動
    fn moveInputCursorToStart(self: *Editor) void {
        self.minibuffer.moveToStart();
    }

    /// ミニバッファでカーソルを末尾に移動
    fn moveInputCursorToEnd(self: *Editor) void {
        self.minibuffer.moveToEnd();
    }

    /// ミニバッファでカーソルを1単語前に移動
    fn moveInputCursorWordBackward(self: *Editor) void {
        self.minibuffer.moveWordBackward();
    }

    /// ミニバッファでカーソルを1単語後に移動
    fn moveInputCursorWordForward(self: *Editor) void {
        self.minibuffer.moveWordForward();
    }

    /// ミニバッファで前の単語を削除（M-Backspace）
    fn deleteInputWordBackward(self: *Editor) void {
        self.minibuffer.deleteWordBackward();
    }

    /// ミニバッファで次の単語を削除（M-d）
    fn deleteInputWordForward(self: *Editor) void {
        self.minibuffer.deleteWordForward();
    }

    /// ミニバッファ入力モードかどうか
    fn isMinibufferMode(self: *Editor) bool {
        return switch (self.mode) {
            .filename_input,
            .find_file_input,
            .buffer_switch_input,
            .isearch_forward,
            .isearch_backward,
            .query_replace_input_search,
            .query_replace_input_replacement,
            .shell_command,
            .mx_command,
            => true,
            else => false,
        };
    }

    /// ミニバッファの共通キー処理
    /// カーソル移動、削除、文字入力などを処理
    /// 戻り値: キーが処理されたかどうか
    fn handleMinibufferKey(self: *Editor, key: input.Key) !bool {
        switch (key) {
            .char => |c| {
                try self.insertCodepointAtInputCursor(c);
                return true;
            },
            .codepoint => |cp| {
                try self.insertCodepointAtInputCursor(cp);
                return true;
            },
            .ctrl => |c| {
                switch (c) {
                    'f' => {
                        self.moveInputCursorRight();
                        return true;
                    },
                    'b' => {
                        self.moveInputCursorLeft();
                        return true;
                    },
                    'a' => {
                        self.moveInputCursorToStart();
                        return true;
                    },
                    'e' => {
                        self.moveInputCursorToEnd();
                        return true;
                    },
                    'd' => {
                        self.deleteAtInputCursor();
                        return true;
                    },
                    'k' => {
                        // カーソルから末尾まで削除
                        self.minibuffer.killLine();
                        return true;
                    },
                    else => return false,
                }
            },
            .alt => |c| {
                switch (c) {
                    'f' => {
                        self.moveInputCursorWordForward();
                        return true;
                    },
                    'b' => {
                        self.moveInputCursorWordBackward();
                        return true;
                    },
                    'd' => {
                        self.deleteInputWordForward();
                        return true;
                    },
                    else => return false,
                }
            },
            .alt_delete => {
                self.deleteInputWordBackward();
                return true;
            },
            .arrow_left => {
                self.moveInputCursorLeft();
                return true;
            },
            .arrow_right => {
                self.moveInputCursorRight();
                return true;
            },
            .backspace => {
                self.backspaceAtInputCursor();
                return true;
            },
            .delete => {
                self.deleteAtInputCursor();
                return true;
            },
            .home => {
                self.moveInputCursorToStart();
                return true;
            },
            .end_key => {
                self.moveInputCursorToEnd();
                return true;
            },
            else => return false,
        }
    }

    /// ミニバッファのプロンプトを更新（カーソル位置も保持）
    fn updateMinibufferPrompt(self: *Editor, prefix: []const u8) void {
        self.prompt_prefix_len = prefix.len;
        self.setPrompt("{s}{s}", .{ prefix, self.minibuffer.getContent() });
    }

    /// ミニバッファのカーソル位置を表示幅（列数）で計算
    fn getMinibufferCursorColumn(self: *Editor) usize {
        const items = self.minibuffer.getContent();
        var col: usize = 0;
        var pos: usize = 0;

        while (pos < self.minibuffer.cursor and pos < items.len) {
            const first_byte = items[pos];
            if (unicode.isAsciiByte(first_byte)) {
                // ASCII
                if (first_byte == '\t') {
                    col += 8 - (col % 8); // タブ展開
                } else {
                    col += 1;
                }
                pos += 1;
            } else {
                // UTF-8マルチバイト
                const len = unicode.utf8SeqLen(first_byte);
                const cp = std.unicode.utf8Decode(items[pos..@min(pos + len, items.len)]) catch {
                    col += 1;
                    pos += 1;
                    continue;
                };
                // 文字幅を取得（全角は2、半角は1）
                col += unicode.displayWidth(cp);
                pos += len;
            }
        }
        return col;
    }

    /// *Command* バッファを取得または作成
    fn getOrCreateCommandBuffer(self: *Editor) !*BufferState {
        // 既存の *Command* バッファを探す（BufferManager経由）
        for (self.buffer_manager.iterator()) |buf| {
            if (buf.filename) |name| {
                if (std.mem.eql(u8, name, "*Command*")) return buf;
            }
        }
        // なければ新規作成
        const new_buffer = try self.createNewBuffer();
        new_buffer.filename = try self.allocator.dupe(u8, "*Command*");
        new_buffer.readonly = true; // コマンド出力は読み取り専用
        return new_buffer;
    }

    /// *Command* バッファを表示するウィンドウを探す
    fn findCommandBufferWindow(self: *Editor) ?usize {
        const windows = self.window_manager.iterator();
        for (windows, 0..) |window, idx| {
            if (self.findBufferById(window.buffer_id)) |buf| {
                if (buf.filename) |name| {
                    if (std.mem.eql(u8, name, "*Command*")) return idx;
                }
            }
        }
        return null;
    }

    /// *Command* バッファウィンドウを開く（既に開いていればそれを使う）
    fn openCommandBufferWindow(self: *Editor) !usize {
        // 既にウィンドウがあればそれを返す
        if (self.findCommandBufferWindow()) |idx| {
            return idx;
        }

        // *Command* バッファを取得/作成
        const cmd_buffer = try self.getOrCreateCommandBuffer();

        // 画面下部に水平分割でウィンドウを開く
        // 現在のウィンドウの高さを縮める
        const current_window = self.window_manager.getCurrentWindow();
        const min_height: u16 = 5; // 最小高さ
        const cmd_height: u16 = 8; // コマンドバッファの高さ

        if (current_window.height < min_height + cmd_height) {
            // 画面が小さすぎる場合は現在のウィンドウに表示
            try self.switchToBuffer(cmd_buffer.id);
            return self.window_manager.current_window_idx;
        }

        // 現在のウィンドウを縮める
        const old_height = current_window.height;
        current_window.height = old_height - cmd_height;

        // 新しいウィンドウを下部に作成（WindowManager経由）
        const new_window = try self.window_manager.createWindow(
            cmd_buffer.id,
            current_window.x,
            current_window.y + current_window.height,
            current_window.width,
            cmd_height,
        );

        new_window.view = try View.init(self.allocator, cmd_buffer.editing_ctx.buffer);
        // 言語検出（*Command*バッファはプレーンテキストだが一貫性のため）
        const content_preview = cmd_buffer.editing_ctx.buffer.getContentPreview(512);
        new_window.view.detectLanguage(cmd_buffer.filename, content_preview);
        // ビューポートサイズを設定
        new_window.view.setViewport(new_window.width, new_window.height);

        return self.window_manager.windowCount() - 1;
    }

    /// 現在のウィンドウを指定されたバッファに切り替え
    pub fn switchToBuffer(self: *Editor, buffer_id: usize) !void {
        const buffer_state = self.findBufferById(buffer_id) orelse return error.BufferNotFound;
        const window = self.getCurrentWindow();

        // 新しいViewを先に作成（失敗時は古いViewを保持）
        const new_view = try View.init(self.allocator, buffer_state.editing_ctx.buffer);

        // 新しいViewの作成に成功したら古いViewを破棄
        window.view.deinit(self.allocator);
        window.view = new_view;
        window.buffer_id = buffer_id;

        // 言語検出（新しいViewに言語設定を適用）
        const content_preview = buffer_state.editing_ctx.buffer.getContentPreview(512);
        window.view.detectLanguage(buffer_state.filename, content_preview);
        // ビューポートサイズを設定（ウィンドウサイズは変わらないが新しいViewに必要）
        window.view.setViewport(window.width, window.height);
    }

    /// 指定されたバッファを閉じる（削除）
    pub fn closeBuffer(self: *Editor, buffer_id: usize) !void {
        // 最後のバッファは閉じられない
        if (self.buffer_manager.bufferCount() == 1) return error.CannotCloseLastBuffer;

        // バッファを検索
        const buffers = self.buffer_manager.iterator();
        var buf_idx: ?usize = null;
        for (buffers, 0..) |buf, i| {
            if (buf.id == buffer_id) {
                buf_idx = i;
                break;
            }
        }

        if (buf_idx == null) return error.BufferNotFound;
        const i = buf_idx.?;

        // このバッファを使用しているウィンドウを別のバッファに切り替え
        for (self.window_manager.iterator()) |*window| {
            if (window.buffer_id == buffer_id) {
                // 次のバッファに切り替え（削除するバッファ以外）
                // bufferCount >= 2 が保証されているので、i==0 なら items[1] が、i>0 なら items[i-1] が存在
                const next_buffer = if (i > 0) buffers[i - 1] else buffers[1];
                window.view.deinit(self.allocator);
                window.view = try View.init(self.allocator, next_buffer.editing_ctx.buffer);
                window.buffer_id = next_buffer.id;
                // 言語検出（コメント強調・タブ幅など）
                const content_preview = next_buffer.editing_ctx.buffer.getContentPreview(512);
                window.view.detectLanguage(next_buffer.filename, content_preview);
                // ビューポートサイズを設定
                window.view.setViewport(window.width, window.height);
            }
        }

        // バッファを削除（BufferManager経由）
        _ = self.buffer_manager.deleteBuffer(buffer_id);
    }

    /// バッファ一覧を表示（C-x C-b）
    pub fn showBufferList(self: *Editor) !void {
        // バッファ一覧のテキストを生成
        var list_text = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer list_text.deinit(self.allocator);

        const writer = list_text.writer(self.allocator);
        try writer.writeAll("  MR Buffer           Size  File\n");
        try writer.writeAll("  -- ------           ----  ----\n");

        for (self.buffer_manager.iterator()) |buf| {
            // 変更フラグ
            const mod_char: u8 = if (buf.editing_ctx.modified) '*' else '.';
            // 読み取り専用フラグ
            const ro_char: u8 = if (buf.readonly) '%' else '.';

            // バッファ名
            const buf_name = if (buf.filename) |fname| fname else "*scratch*";

            // サイズ
            const size = buf.editing_ctx.buffer.total_len;

            // フォーマットして追加
            try std.fmt.format(writer, "  {c}{c} {s:<16} {d:>6}  {s}\n", .{
                mod_char,
                ro_char,
                buf_name,
                size,
                if (buf.filename) |fname| fname else "",
            });
        }

        // "*Buffer List*"という名前のバッファを探す
        const buffer_list_name = "*Buffer List*";
        var buffer_list: ?*BufferState = null;

        for (self.buffer_manager.iterator()) |buf| {
            if (buf.filename) |fname| {
                if (std.mem.eql(u8, fname, buffer_list_name)) {
                    buffer_list = buf;
                    break;
                }
            }
        }

        if (buffer_list == null) {
            // 新しいバッファを作成
            const new_buffer = try self.createNewBuffer();
            new_buffer.filename = try self.allocator.dupe(u8, buffer_list_name);
            new_buffer.readonly = true; // バッファ一覧は読み取り専用
            buffer_list = new_buffer;
        }

        const buf = buffer_list.?; // ここでは必ず値が設定されている

        // バッファの内容をクリアして新しい一覧を挿入
        if (buf.editing_ctx.buffer.total_len > 0) {
            try buf.editing_ctx.buffer.delete(0, buf.editing_ctx.buffer.total_len);
        }
        try buf.editing_ctx.buffer.insertSlice(0, list_text.items);
        buf.editing_ctx.modified = false; // バッファ一覧は変更扱いにしない

        // バッファ一覧に切り替え
        try self.switchToBuffer(buf.id);
    }

    /// *Buffer List*からバッファを選択して切り替え
    fn selectBufferFromList(self: *Editor) !void {
        const view = self.getCurrentView();
        const buffer = self.getCurrentBufferContent();

        // 現在行を取得
        const cursor_line = view.top_line + view.cursor_y;

        // ヘッダ行（0, 1行目）は無視
        if (cursor_line < 2) {
            self.getCurrentView().setError("Select a buffer from the list");
            return;
        }

        // 現在行の開始位置を取得
        const line_start = buffer.getLineStart(cursor_line) orelse {
            self.getCurrentView().setError("Invalid line");
            return;
        };

        // 次の行の開始位置を取得（行の終わりを知るため）
        const next_line_start = buffer.getLineStart(cursor_line + 1) orelse buffer.total_len;

        // 行の長さを計算（改行を除く）
        var line_len = if (next_line_start > line_start) next_line_start - line_start else 0;
        if (line_len > 0 and next_line_start <= buffer.total_len) {
            // 改行文字を除く
            line_len = if (line_len > 0) line_len - 1 else 0;
        }

        if (line_len == 0) {
            self.getCurrentView().setError("Empty line");
            return;
        }

        // 行のテキストを取得
        const line = try buffer.getRange(self.allocator, line_start, line_len);
        defer self.allocator.free(line);

        // バッファ名を抽出
        // フォーマット: "  {c}{c} {s:<16} {d:>6}  {s}\n"
        // 長いファイル名は16文字を超える場合がある
        if (line.len < 5) {
            self.getCurrentView().setError("Invalid line format");
            return;
        }

        // バッファ名は位置5から始まる
        const name_start: usize = 5;

        // バッファ名の終端を探す（複数のスペース + 数字 = サイズ列の開始）
        var name_end: usize = name_start;
        var i: usize = name_start;
        while (i < line.len) : (i += 1) {
            if (line[i] == ' ') {
                // スペースの連続を探す
                var space_count: usize = 0;
                var j = i;
                while (j < line.len and line[j] == ' ') : (j += 1) {
                    space_count += 1;
                }
                // スペースの後に数字があればサイズ列
                if (space_count >= 2 and j < line.len and line[j] >= '0' and line[j] <= '9') {
                    name_end = i;
                    break;
                }
            }
            name_end = i + 1;
        }

        var buf_name = line[name_start..name_end];

        // 末尾の空白を除去
        while (buf_name.len > 0 and buf_name[buf_name.len - 1] == ' ') {
            buf_name = buf_name[0 .. buf_name.len - 1];
        }

        if (buf_name.len == 0) {
            self.getCurrentView().setError("No buffer name found");
            return;
        }

        // バッファを検索
        for (self.buffer_manager.iterator()) |buf| {
            const name = if (buf.filename) |fname| fname else "*scratch*";
            if (std.mem.eql(u8, name, buf_name)) {
                try self.switchToBuffer(buf.id);
                return;
            }
        }

        self.getCurrentView().setError("Buffer not found");
    }

    /// ウィンドウ分割の共通処理
    fn splitWindowCommon(self: *Editor, comptime is_horizontal: bool) !void {
        const current_window = self.window_manager.getCurrentWindow();

        // バッファを取得
        const buffer_state = self.findBufferById(current_window.buffer_id) orelse return error.BufferNotFound;

        // 新しいウィンドウのViewを先に初期化（失敗時は何も変更しない）
        var new_view = try View.init(self.allocator, buffer_state.editing_ctx.buffer);
        errdefer new_view.deinit(self.allocator);

        // WindowManagerで分割（ウィンドウのサイズ調整とリスト追加）
        const result = if (is_horizontal)
            try self.window_manager.splitHorizontally()
        else
            try self.window_manager.splitVertically();

        // 新しいウィンドウにViewを設定
        result.new_window.view = new_view;

        // 言語検出（新しいViewに言語設定を適用）
        const content_preview = buffer_state.editing_ctx.buffer.getContentPreview(512);
        result.new_window.view.detectLanguage(buffer_state.filename, content_preview);

        // ビューポートサイズを設定（カーソル制約も行う）
        result.new_window.view.setViewport(result.new_window.width, result.new_window.height);
        // 元のウィンドウもサイズが変わったのでビューポートを更新
        result.original_window.view.setViewport(result.original_window.width, result.original_window.height);

        // 新しいウィンドウをアクティブにする
        self.window_manager.setActiveWindow(result.new_window_idx);
    }

    /// 現在のウィンドウを横（上下）に分割
    pub fn splitWindowHorizontally(self: *Editor) !void {
        return self.splitWindowCommon(true);
    }

    /// 現在のウィンドウを縦（左右）に分割
    pub fn splitWindowVertically(self: *Editor) !void {
        return self.splitWindowCommon(false);
    }

    /// 現在のウィンドウを閉じる
    pub fn closeCurrentWindow(self: *Editor) !void {
        // WindowManagerに委譲（サイズ再計算も含む）
        try self.window_manager.closeCurrentWindow();
    }

    /// 他のウィンドウをすべて閉じる (C-x 1)
    pub fn deleteOtherWindows(self: *Editor) !void {
        // WindowManagerに委譲（サイズ再計算も含む）
        try self.window_manager.deleteOtherWindows();
    }

    pub fn loadFile(self: *Editor, path: []const u8) !void {
        const buffer_state = self.getCurrentBuffer();
        const view = self.getCurrentView();

        // 読み込み中メッセージを表示（大きなファイルでのフィードバック）
        {
            var msg_buf: [config.Editor.STATUS_BUF_SIZE]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Loading {s}...", .{path}) catch "Loading...";
            view.setError(msg);
            // メッセージを即座に表示するため、ステータスバーを描画してフラッシュ
            try self.renderAllWindows();
        }

        // 新しいバッファを先にロード（失敗しても古いバッファは残る）
        var new_buffer = try Buffer.loadFromFile(self.allocator, path);
        errdefer new_buffer.deinit();

        // ファイル名を先に複製（失敗したら新バッファを解放して終了）
        const new_filename = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(new_filename);

        // ここから先は失敗しない操作のみ

        // 古いバッファの内容を解放して新しい内容で上書き
        buffer_state.editing_ctx.buffer.deinit();
        buffer_state.editing_ctx.buffer.* = new_buffer;
        // viewは同じバッファポインタを参照しているのでそのまま

        // View状態をリセット（新しいファイルを開いた時に前のカーソル位置が残らないように）
        view.top_line = 0;
        view.top_col = 0;
        view.cursor_x = 0;
        view.cursor_y = 0;

        // 古いファイル名を解放して新しいファイル名を設定
        if (buffer_state.filename) |old_name| {
            self.allocator.free(old_name);
        }
        buffer_state.filename = new_filename;

        // Undo/Redoスタックをクリア
        buffer_state.editing_ctx.clearUndoHistory();
        buffer_state.editing_ctx.modified = false;

        // 言語検出（ファイル名とコンテンツ先頭から判定）
        const content_preview = buffer_state.editing_ctx.buffer.getContentPreview(512);
        view.detectLanguage(path, content_preview);

        // ファイルの最終更新時刻を記録（外部変更検知用）
        const file = std.fs.cwd().openFile(path, .{}) catch {
            buffer_state.file_mtime = null;
            return;
        };
        defer file.close();
        const stat = file.stat() catch {
            buffer_state.file_mtime = null;
            return;
        };
        buffer_state.file_mtime = stat.mtime;
    }

    pub fn saveFile(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        const view = self.getCurrentView();

        if (buffer_state.filename) |path| {
            // 外部変更チェック（新規ファイルの場合はスキップ）
            if (buffer_state.file_mtime) |original_mtime| {
                const maybe_file = std.fs.cwd().openFile(path, .{}) catch |err| blk: {
                    // ファイルが存在しない場合は外部で削除された
                    if (err == error.FileNotFound) {
                        view.setError("Warning: file deleted externally");
                        // 続行して保存する（再作成）
                        break :blk null;
                    } else {
                        return err;
                    }
                };

                if (maybe_file) |f| {
                    defer f.close();
                    const stat = try f.stat();
                    if (stat.mtime != original_mtime) {
                        view.setError("Warning: file modified externally!");
                        // 続行して上書きする（ユーザーの編集を優先）
                    }
                }
            }

            try buffer_state.editing_ctx.buffer.saveToFile(path);
            buffer_state.markSaved(); // 保存時点を記録

            // 保存後に新しい mtime を記録
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            const stat = try file.stat();
            buffer_state.file_mtime = stat.mtime;
        }
    }

    /// 全ウィンドウをレンダリング
    fn renderAllWindows(self: *Editor) !void {
        // 描画中はカーソルを非表示（ちらつき防止）
        try self.terminal.hideCursor();

        // アクティブウィンドウの情報を保存（後でカーソル表示に使用）
        var active_cursor_row: usize = 0;
        var active_cursor_col: usize = 0;
        var has_active: bool = false;

        for (self.window_manager.iterator(), 0..) |*window, idx| {
            const is_active = (idx == self.window_manager.current_window_idx);
            const buffer_state = self.findBufferById(window.buffer_id) orelse continue;
            const buffer = buffer_state.editing_ctx.buffer;

            try window.view.renderInBounds(
                &self.terminal,
                window.x,
                window.y,
                window.width,
                window.height,
                is_active,
                buffer_state.editing_ctx.modified,
                buffer_state.readonly,
                buffer.detected_line_ending,
                buffer.detected_encoding,
                buffer_state.filename,
            );

            // アクティブウィンドウのカーソル位置を記録
            if (is_active) {
                const pos = window.view.getCursorScreenPosition(window.x, window.y, window.width);
                active_cursor_row = pos.row;
                active_cursor_col = pos.col;
                has_active = true;
            }
        }

        // アクティブウィンドウのカーソルを表示
        if (has_active) {
            try self.terminal.moveCursor(active_cursor_row, active_cursor_col);
            try self.terminal.showCursor();
        }

        // 全ウィンドウの描画後に一括でflush（複数回のwrite()を避ける）
        try self.terminal.flush();
    }

    /// 端末サイズ変更時にウィンドウサイズを再計算
    /// ウィンドウの現在のレイアウト（比率）を維持しつつ新しいサイズに調整
    fn recalculateWindowSizes(self: *Editor) !void {
        // WindowManagerに委譲
        self.window_manager.updateScreenSize(self.terminal.width, self.terminal.height);
        self.window_manager.recalculateWindowSizes();
    }

    /// メインイベントループ
    ///
    /// 【ループの流れ】
    /// 1. 端末サイズ変更をチェック（ウィンドウリサイズ対応）
    /// 2. カーソル位置を有効範囲にクランプ
    /// 3. 全ウィンドウをレンダリング
    /// 4. シェルコマンド実行中ならポーリング
    /// 5. キー入力を待ち、処理
    ///
    /// running が false になるまで繰り返し（C-x C-c で終了）
    pub fn run(self: *Editor) !void {
        const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
        // バッファ付き入力リーダー（ペースト時等の大量入力でシステムコールを削減）
        var input_reader = input.InputReader.init(stdin);

        // 効率的なI/O待機（epoll/kqueue）
        // ポーリングではなくイベント駆動で、入力待機中はCPUを消費しない
        var poll = poller.Poller.init(stdin.handle) catch {
            // Poller初期化失敗: 従来のVTIMEポーリングにフォールバック
            return self.runWithoutPoller(&input_reader);
        };
        defer poll.deinit();

        while (self.running) {
            // 終了シグナルチェック
            if (self.terminal.checkTerminate()) break;

            // リサイズチェック
            if (try self.terminal.checkResize()) {
                try self.recalculateWindowSizes();
            }

            // カーソル位置補正と画面描画
            self.clampCursorPosition();
            try self.renderAllWindows();

            // ミニバッファ入力中はカーソル位置を調整
            if (self.isMinibufferMode()) {
                const cursor_col = self.prompt_prefix_len + self.getMinibufferCursorColumn();
                const status_row = self.terminal.height - 1;
                try self.terminal.moveCursor(status_row, cursor_col);
                try self.terminal.showCursor();
                try self.terminal.flush();
            }

            // シェルコマンド実行中はその出力をポーリング
            if (self.mode == .shell_running) {
                try self.pollShellCommand();
            }

            // 入力を待機
            // 重要: InputReaderのバッファにデータがあればkqueueをスキップ
            // （バッファリングにより、カーネルバッファは空でもデータが残っている可能性がある）
            if (!input_reader.hasData()) {
                // 100msタイムアウトで待機
                // 注意: 無限待機(null)だとPTY環境で問題が発生することがある
                const poll_result = poll.wait(100);
                if (poll_result == .signal) {
                    // SIGWINCH等のシグナル: ループ先頭に戻ってリサイズチェック
                    continue;
                }
                // タイムアウトでも入力チェックは行う（VTIMEモードで読み取り可能な場合がある）
            }

            // キー入力を処理
            if (try input.readKeyFromReader(&input_reader)) |key| {
                self.getCurrentView().clearError();
                self.processKey(key) catch |err| {
                    const err_name = @errorName(err);
                    self.getCurrentView().setError(err_name);
                };
            }
        }
    }

    /// Poller初期化失敗時のフォールバック（従来のVTIMEポーリング）
    fn runWithoutPoller(self: *Editor, input_reader: *input.InputReader) !void {
        while (self.running) {
            if (self.terminal.checkTerminate()) break;

            if (try self.terminal.checkResize()) {
                try self.recalculateWindowSizes();
            }

            self.clampCursorPosition();
            try self.renderAllWindows();

            if (self.isMinibufferMode()) {
                const cursor_col = self.prompt_prefix_len + self.getMinibufferCursorColumn();
                const status_row = self.terminal.height - 1;
                try self.terminal.moveCursor(status_row, cursor_col);
                try self.terminal.showCursor();
                try self.terminal.flush();
            }

            if (self.mode == .shell_running) {
                try self.pollShellCommand();
            }

            if (try input.readKeyFromReader(input_reader)) |key| {
                self.getCurrentView().clearError();
                self.processKey(key) catch |err| {
                    const err_name = @errorName(err);
                    self.getCurrentView().setError(err_name);
                };
            }
        }
    }

    // バッファから指定範囲のテキストを取得（削除前に使用）
    // PieceIterator.seekを使ってO(pieces + len)で効率的に取得
    pub fn extractText(self: *Editor, pos: usize, len: usize) ![]u8 {
        const buffer = self.getCurrentBufferContent();
        const buf_len = buffer.len();

        // posがバッファ末尾を超えている場合は空の配列を返す（アンダーフロー防止）
        if (pos >= buf_len) {
            return try self.allocator.alloc(u8, 0);
        }

        // 実際に読み取れるバイト数を計算（buffer末尾を超えないように）
        const actual_len = @min(len, buf_len - pos);
        var result = try self.allocator.alloc(u8, actual_len);
        errdefer self.allocator.free(result);

        var iter = PieceIterator.init(buffer);
        iter.seek(pos); // O(pieces)で直接ジャンプ

        // actual_len分読み取る（保証されている）
        var i: usize = 0;
        while (i < actual_len) : (i += 1) {
            result[i] = iter.next() orelse {
                // Piece table の不整合が発生した場合
                // メモリリークを防ぐため、エラーを返す（errdefer が解放する）
                return error.BufferInconsistency;
            };
        }

        return result;
    }

    // 現在のカーソル位置の行番号を取得（dirty tracking用）
    pub fn getCurrentLine(self: *const Editor) usize {
        const view = &self.window_manager.getCurrentWindowConst().view;
        return view.top_line + view.cursor_y;
    }

    // カーソル位置をバッファの有効範囲にクランプ（大量削除後の対策）
    fn clampCursorPosition(self: *Editor) void {
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();

        const total_lines = buffer.lineCount();
        if (total_lines == 0) return;

        // ビューポート高さが0の場合は何もしない
        if (view.viewport_height == 0) return;

        // ビューポートの表示可能行数（ステータスバー分を引く）
        const max_screen_lines = if (view.viewport_height >= 1) view.viewport_height - 1 else 0;

        // top_lineが範囲外の場合は調整
        if (view.top_line >= total_lines) {
            if (total_lines > max_screen_lines) {
                view.top_line = total_lines - max_screen_lines;
            } else {
                view.top_line = 0;
            }
            view.markFullRedraw();
        }

        // cursor_yが範囲外の場合は調整
        const current_line = view.top_line + view.cursor_y;
        if (current_line >= total_lines) {
            if (total_lines > view.top_line) {
                view.cursor_y = total_lines - view.top_line - 1;
            } else {
                view.cursor_y = 0;
            }

            // cursor_xも行末にクランプ
            const line_width = view.getCurrentLineWidth();
            if (view.cursor_x > line_width) {
                view.cursor_x = line_width;
            }
        }
    }

    // 編集操作を記録（EditingContextに委譲）
    pub fn recordInsert(self: *Editor, pos: usize, text: []const u8, cursor_pos_before_edit: usize) !void {
        const buffer_state = self.getCurrentBuffer();
        try buffer_state.editing_ctx.recordInsertOp(pos, text, cursor_pos_before_edit);
    }

    pub fn recordDelete(self: *Editor, pos: usize, text: []const u8, cursor_pos_before_edit: usize) !void {
        const buffer_state = self.getCurrentBuffer();
        try buffer_state.editing_ctx.recordDeleteOp(pos, text, cursor_pos_before_edit);
    }

    /// 置換操作を記録（deleteとinsertを1つの原子的な操作として）
    fn recordReplace(self: *Editor, pos: usize, old_text: []const u8, new_text: []const u8, cursor_pos_before_edit: usize) !void {
        const buffer_state = self.getCurrentBuffer();
        try buffer_state.editing_ctx.recordReplaceOp(pos, old_text, new_text, cursor_pos_before_edit);
    }

    // バイト位置からカーソル座標を計算して設定（grapheme cluster考慮）
    pub fn setCursorToPos(self: *Editor, target_pos: usize) void {
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();
        const clamped_pos = @min(target_pos, buffer.len());

        // LineIndexでO(log N)行番号計算
        const line = buffer.findLineByPos(clamped_pos);
        const line_start = buffer.getLineStart(line) orelse 0;

        // 画面内の行位置を計算（ビューポート高さを使用）
        const max_screen_lines = if (view.viewport_height >= 1) view.viewport_height - 1 else 0;
        if (max_screen_lines == 0 or line < max_screen_lines) {
            view.top_line = 0;
            view.cursor_y = line;
        } else {
            view.top_line = line - max_screen_lines / 2; // 中央に表示
            view.cursor_y = line - view.top_line;
        }

        // カーソルX位置を計算（grapheme clusterの表示幅）
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        var display_col: usize = 0;
        while (iter.global_pos < clamped_pos) {
            const cluster = iter.nextGraphemeCluster() catch {
                _ = iter.next();
                display_col += 1;
                continue;
            };
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                display_col += gc.width; // 絵文字は2、通常文字は1
            } else {
                break;
            }
        }

        view.cursor_x = display_col;

        // 水平スクロールを調整
        const line_num_width = view.getLineNumberWidth();
        const visible_width = if (view.viewport_width > line_num_width) view.viewport_width - line_num_width else 1;
        if (view.cursor_x >= view.top_col + visible_width) {
            // カーソルが右端を超えている
            view.top_col = view.cursor_x - visible_width + 1;
        } else if (view.cursor_x < view.top_col) {
            // カーソルが左端より左
            view.top_col = view.cursor_x;
        }
        view.markFullRedraw();
    }

    // エイリアス: restoreCursorPosはsetCursorToPosと同じ
    pub fn restoreCursorPos(self: *Editor, target_pos: usize) void {
        self.setCursorToPos(target_pos);
    }

    // ========================================
    // キー処理：モードハンドラー
    // ========================================

    /// ファイル名入力モード（C-x C-s で新規ファイル保存時）
    fn handleFilenameInputKey(self: *Editor, key: input.Key) !bool {
        if (isCancelKey(key)) {
            self.cancelSaveInput();
            return true;
        }
        if (key == .enter) {
            if (self.minibuffer.getContent().len > 0) {
                const buffer_state = self.getCurrentBuffer();
                if (buffer_state.filename) |old| {
                    self.allocator.free(old);
                }
                buffer_state.filename = try self.allocator.dupe(u8, self.minibuffer.getContent());
                self.clearInputBuffer();
                try self.saveFile();
                self.mode = .normal;
                if (self.quit_after_save) {
                    self.quit_after_save = false;
                    self.running = false;
                }
            }
            return true;
        }
        try self.processMinibufferKeyWithPrompt(key, "Write file: ");
        return true;
    }

    /// ファイルを開くモード（C-x C-f）
    fn handleFindFileInputKey(self: *Editor, key: input.Key) !bool {
        if (isCancelKey(key)) {
            self.cancelInput();
            return true;
        }
        if (key == .enter) {
            if (self.minibuffer.getContent().len > 0) {
                const filename = self.minibuffer.getContent();
                const existing_buffer = self.findBufferByFilename(filename);
                if (existing_buffer) |buf| {
                    try self.switchToBuffer(buf.id);
                } else {
                    const new_buffer = try self.createNewBuffer();
                    const filename_copy = try self.allocator.dupe(u8, filename);

                    const loaded_buffer = Buffer.loadFromFile(self.allocator, filename_copy) catch |err| {
                        self.allocator.free(filename_copy);
                        if (err == error.FileNotFound) {
                            new_buffer.filename = try self.allocator.dupe(u8, filename);
                            try self.switchToBuffer(new_buffer.id);
                            self.cancelInput();
                            return true;
                        } else if (err == error.BinaryFile) {
                            _ = try self.closeBuffer(new_buffer.id);
                            self.getCurrentView().setError("Cannot open binary file");
                            self.cancelInput();
                            return true;
                        } else {
                            _ = try self.closeBuffer(new_buffer.id);
                            self.showError(err);
                            self.cancelInput();
                            return true;
                        }
                    };

                    new_buffer.editing_ctx.buffer.deinit();
                    new_buffer.editing_ctx.buffer.* = loaded_buffer;
                    new_buffer.filename = filename_copy;
                    new_buffer.editing_ctx.modified = false;

                    const file = std.fs.cwd().openFile(filename_copy, .{}) catch null;
                    if (file) |f| {
                        defer f.close();
                        const stat = f.stat() catch null;
                        if (stat) |s| {
                            new_buffer.file_mtime = s.mtime;
                        }
                    }
                    try self.switchToBuffer(new_buffer.id);
                }
                self.cancelInput();
            }
            return true;
        }
        try self.processMinibufferKeyWithPrompt(key, "Find file: ");
        return true;
    }

    /// バッファ切り替えモード（C-x b）
    fn handleBufferSwitchInputKey(self: *Editor, key: input.Key) !bool {
        if (isCancelKey(key)) {
            self.cancelInput();
            return true;
        }
        if (key == .enter) {
            if (self.minibuffer.getContent().len > 0) {
                const buffer_name = self.minibuffer.getContent();
                const found_buffer = self.findBufferByFilename(buffer_name);
                if (found_buffer) |buf| {
                    try self.switchToBuffer(buf.id);
                    self.cancelInput();
                } else {
                    self.getCurrentView().setError("No such buffer");
                    self.cancelInput();
                }
            }
            return true;
        }
        try self.processMinibufferKeyWithPrompt(key, "Switch to buffer: ");
        return true;
    }

    /// インクリメンタルサーチモード（C-s / C-r）
    fn handleIsearchKey(self: *Editor, key: input.Key, is_forward: bool) !bool {
        switch (key) {
            .char => |c| try self.addSearchChar(c, is_forward),
            .codepoint => |cp| try self.addSearchChar(cp, is_forward),
            .ctrl => |c| {
                switch (c) {
                    'g' => {
                        if (self.search_start_pos) |start_pos| {
                            self.setCursorToPos(start_pos);
                        }
                        self.endSearch();
                    },
                    's' => {
                        if (self.minibuffer.getContent().len > 0) {
                            self.getCurrentView().setSearchHighlight(self.minibuffer.getContent());
                            try self.performSearch(true, true);
                        }
                    },
                    'r' => {
                        if (self.minibuffer.getContent().len > 0) {
                            self.getCurrentView().setSearchHighlight(self.minibuffer.getContent());
                            try self.performSearch(false, true);
                        }
                    },
                    'p' => try self.navigateSearchHistory(true, is_forward),
                    'n' => try self.navigateSearchHistory(false, is_forward),
                    else => {},
                }
            },
            .arrow_up => try self.navigateSearchHistory(true, is_forward),
            .arrow_down => try self.navigateSearchHistory(false, is_forward),
            .backspace => {
                if (self.minibuffer.getContent().len > 0) {
                    self.minibuffer.moveToEnd();
                    self.minibuffer.backspace();
                    const prefix = if (is_forward) "I-search: " else "I-search backward: ";
                    self.setPrompt("{s}{s}", .{ prefix, self.minibuffer.getContent() });
                    if (self.minibuffer.getContent().len > 0) {
                        self.getCurrentView().setSearchHighlight(self.minibuffer.getContent());
                        if (self.search_start_pos) |start_pos| {
                            self.setCursorToPos(start_pos);
                        }
                        try self.performSearch(is_forward, false);
                    } else {
                        self.getCurrentView().setSearchHighlight(null);
                        if (self.search_start_pos) |start_pos| {
                            self.setCursorToPos(start_pos);
                        }
                    }
                }
            },
            .enter => {
                if (self.minibuffer.getContent().len > 0) {
                    try self.search_service.addToHistory(self.minibuffer.getContent());
                    if (self.last_search) |old_search| {
                        self.allocator.free(old_search);
                    }
                    self.last_search = self.allocator.dupe(u8, self.minibuffer.getContent()) catch null;
                }
                self.endSearch();
            },
            else => {},
        }
        return true;
    }

    /// C-xプレフィックスモード
    fn handlePrefixXKey(self: *Editor, key: input.Key) !bool {
        self.mode = .normal;
        switch (key) {
            .ctrl => |c| {
                switch (c) {
                    'g' => self.getCurrentView().clearError(),
                    'b' => self.showBufferList() catch |err| self.showError(err),
                    'f' => {
                        self.mode = .find_file_input;
                        self.clearInputBuffer();
                        self.prompt_prefix_len = 12;
                        self.getCurrentView().setError("Find file: ");
                    },
                    's' => {
                        const buffer_state = self.getCurrentBuffer();
                        if (buffer_state.filename == null) {
                            self.mode = .filename_input;
                            self.quit_after_save = false;
                            self.minibuffer.clear();
                            self.minibuffer.cursor = 0;
                            self.prompt_prefix_len = 13;
                            self.getCurrentView().setError("Write file: ");
                        } else {
                            try self.saveFile();
                        }
                    },
                    'w' => {
                        self.mode = .filename_input;
                        self.quit_after_save = false;
                        self.clearInputBuffer();
                        self.prompt_prefix_len = 13;
                        self.getCurrentView().setError("Write file: ");
                    },
                    'c' => {
                        var modified_count: usize = 0;
                        var first_modified_name: ?[]const u8 = null;
                        for (self.buffer_manager.iterator()) |buf| {
                            if (buf.editing_ctx.modified) {
                                modified_count += 1;
                                if (first_modified_name == null) {
                                    first_modified_name = buf.filename;
                                }
                            }
                        }
                        if (modified_count > 0) {
                            if (modified_count == 1) {
                                const name = first_modified_name orelse "*scratch*";
                                self.setPrompt("Save changes to {s}? (y/n/c): ", .{name});
                            } else {
                                self.setPrompt("{d} buffers modified; exit anyway? (y/n): ", .{modified_count});
                            }
                            self.mode = .quit_confirm;
                        } else {
                            self.running = false;
                        }
                    },
                    else => self.getCurrentView().setError("Unknown command"),
                }
            },
            .char => |c| {
                switch (c) {
                    'h' => edit.selectAll(self) catch {},
                    'r' => {
                        self.mode = .prefix_r;
                        return true;
                    },
                    'b' => {
                        self.mode = .buffer_switch_input;
                        self.clearInputBuffer();
                        self.prompt_prefix_len = 19;
                        self.getCurrentView().setError("Switch to buffer: ");
                    },
                    'k' => {
                        const buffer_state = self.getCurrentBuffer();
                        if (buffer_state.editing_ctx.modified) {
                            const name = buffer_state.filename orelse "*scratch*";
                            self.setPrompt("Buffer {s} modified; kill anyway? (y/n): ", .{name});
                            self.mode = .kill_buffer_confirm;
                        } else {
                            const buffer_id = buffer_state.id;
                            self.closeBuffer(buffer_id) catch |err| self.showError(err);
                        }
                    },
                    '2' => self.splitWindowHorizontally() catch |err| self.showError(err),
                    '3' => self.splitWindowVertically() catch |err| self.showError(err),
                    'o' => {
                        self.window_manager.nextWindow();
                    },
                    '0' => self.closeCurrentWindow() catch |err| self.showError(err),
                    '1' => self.deleteOtherWindows() catch |err| self.showError(err),
                    else => self.getCurrentView().setError("Unknown command"),
                }
            },
            else => self.getCurrentView().setError("Expected C-x C-[key]"),
        }
        return true;
    }

    /// C-x rプレフィックスモード（矩形操作）
    fn handlePrefixRKey(self: *Editor, key: input.Key) bool {
        self.mode = .normal;
        switch (key) {
            .char => |c| {
                switch (c) {
                    'k' => rectangle.killRectangle(self) catch |err| {
                        self.getCurrentView().setError(@errorName(err));
                    },
                    'y' => rectangle.yankRectangle(self),
                    't' => self.getCurrentView().setError("C-x r t not implemented yet"),
                    else => self.getCurrentView().setError("Unknown rectangle command"),
                }
            },
            .ctrl => |c| {
                if (c == 'g') {
                    self.getCurrentView().clearError();
                } else {
                    self.getCurrentView().setError("Unknown rectangle command");
                }
            },
            else => self.getCurrentView().setError("Unknown rectangle command"),
        }
        return true;
    }

    /// Query Replace: 検索文字列入力モード
    fn handleQueryReplaceInputSearchKey(self: *Editor, key: input.Key) !bool {
        if (isCancelKey(key)) {
            self.cancelInput();
            return true;
        }
        if (key == .enter) {
            if (self.minibuffer.getContent().len > 0) {
                if (self.replace_search) |old| {
                    self.allocator.free(old);
                }
                self.replace_search = try self.allocator.dupe(u8, self.minibuffer.getContent());
                self.clearInputBuffer();
                self.mode = .query_replace_input_replacement;
                self.setPrompt("Query replace {s} with: ", .{self.replace_search.?});
                self.prompt_prefix_len = 1 + 14 + self.replace_search.?.len + 7;
            }
            return true;
        }
        try self.processMinibufferKeyWithPrompt(key, "Query replace: ");
        return true;
    }

    /// Query Replace: 置換文字列入力モード
    fn handleQueryReplaceInputReplacementKey(self: *Editor, key: input.Key) !bool {
        if (isCancelKey(key)) {
            self.cancelQueryReplaceInput();
            return true;
        }
        if (key == .enter) {
            if (self.replace_replacement) |old| {
                self.allocator.free(old);
            }
            self.replace_replacement = try self.allocator.dupe(u8, self.minibuffer.getContent());
            self.minibuffer.clear();

            if (self.replace_search) |search| {
                const found = try self.findNextMatch(search, self.getCurrentView().getCursorBufferPos());
                if (found) {
                    self.mode = .query_replace_confirm;
                    self.setPrompt("Replace? (y)es (n)ext (!)all (q)uit", .{});
                } else {
                    self.mode = .normal;
                    self.getCurrentView().setError("No match found");
                }
            } else {
                self.mode = .normal;
                self.getCurrentView().setError("No search string");
            }
            return true;
        }
        _ = try self.handleMinibufferKey(key);
        if (self.replace_search) |search| {
            self.setPrompt("Query replace {s} with: {s}", .{ search, self.minibuffer.getContent() });
        } else {
            self.setPrompt("Query replace with: {s}", .{self.minibuffer.getContent()});
        }
        return true;
    }

    /// Query Replace: 確認モード
    fn handleQueryReplaceConfirmKey(self: *Editor, key: input.Key) !bool {
        switch (key) {
            .char => |c| try self.handleReplaceConfirmChar(c),
            .codepoint => |cp| try self.handleReplaceConfirmChar(unicode.normalizeFullwidth(cp)),
            .ctrl => |c| {
                if (c == 'g') {
                    self.mode = .normal;
                    self.setPrompt("Replaced {d} occurrence(s)", .{self.replace_match_count});
                }
            },
            else => {},
        }
        return true;
    }

    /// シェルコマンド入力モード（M-|）
    fn handleShellCommandKey(self: *Editor, key: input.Key) !bool {
        switch (key) {
            .ctrl => |c| {
                switch (c) {
                    'g' => {
                        self.mode = .normal;
                        self.clearInputBuffer();
                        self.shell_service.resetHistoryNavigation();
                        self.getCurrentView().clearError();
                        return true;
                    },
                    'p' => {
                        try self.navigateShellHistory(true);
                        return true;
                    },
                    'n' => {
                        try self.navigateShellHistory(false);
                        return true;
                    },
                    else => {},
                }
            },
            .arrow_up => {
                try self.navigateShellHistory(true);
                return true;
            },
            .arrow_down => {
                try self.navigateShellHistory(false);
                return true;
            },
            .escape => {
                self.mode = .normal;
                self.clearInputBuffer();
                self.shell_service.resetHistoryNavigation();
                self.getCurrentView().clearError();
                return true;
            },
            .enter => {
                if (self.minibuffer.getContent().len > 0) {
                    try self.shell_service.addToHistory(self.minibuffer.getContent());
                    self.shell_service.resetHistoryNavigation();
                    try self.startShellCommand();
                }
                if (self.mode != .shell_running) {
                    self.mode = .normal;
                    self.clearInputBuffer();
                }
                return true;
            },
            else => {},
        }
        _ = try self.handleMinibufferKey(key);
        self.updateMinibufferPrompt("| ");
        return true;
    }

    /// M-xコマンド入力モード
    fn handleMxCommandKey(self: *Editor, key: input.Key) !bool {
        switch (key) {
            .ctrl => |c| {
                if (c == 'g') {
                    self.cancelInput();
                    return true;
                }
            },
            .escape => {
                self.cancelInput();
                return true;
            },
            .enter => {
                try mx.execute(self);
                return true;
            },
            else => {},
        }
        _ = try self.handleMinibufferKey(key);
        self.updateMinibufferPrompt(": ");
        return true;
    }

    /// 通常モードのキー処理
    fn handleNormalKey(self: *Editor, key: input.Key) !void {
        switch (key) {
            .ctrl => |c| {
                // keymapから検索
                if (self.keymap.findCtrl(c)) |handler| {
                    try handler(self);
                    return;
                }
                // keymapにない特殊処理
                switch (c) {
                    'x' => {
                        self.mode = .prefix_x;
                        self.getCurrentView().setError("C-x-");
                    },
                    's' => try self.startIsearch(true),
                    'r' => try self.startIsearch(false),
                    else => {},
                }
            },
            .alt => |c| {
                // keymapから検索
                if (self.keymap.findAlt(c)) |handler| {
                    try handler(self);
                    return;
                }
                // keymapにない特殊処理
                switch (c) {
                    '%' => {
                        self.mode = .query_replace_input_search;
                        self.clearInputBuffer();
                        self.prompt_prefix_len = 16;
                        self.replace_match_count = 0;
                        self.getCurrentView().setError("Query replace: ");
                    },
                    '|' => {
                        self.mode = .shell_command;
                        self.clearInputBuffer();
                        self.prompt_prefix_len = 3;
                        self.getCurrentView().setError("| ");
                    },
                    'x' => {
                        self.mode = .mx_command;
                        self.clearInputBuffer();
                        self.prompt_prefix_len = 3;
                        self.getCurrentView().setError(": ");
                    },
                    else => {},
                }
            },
            .enter => {
                const buffer_state = self.getCurrentBuffer();
                if (buffer_state.filename) |fname| {
                    if (std.mem.eql(u8, fname, "*Buffer List*")) {
                        try self.selectBufferFromList();
                        return;
                    }
                }
                const indent = edit.getCurrentLineIndent(self);
                try self.insertChar('\n');
                if (indent.len > 0) {
                    for (indent) |ch| {
                        try self.insertChar(ch);
                    }
                }
            },
            .tab => {
                const window = self.getCurrentWindow();
                if (window.mark_pos != null) {
                    try edit.indentRegion(self);
                } else {
                    try self.insertChar('\t');
                }
            },
            .shift_tab => try edit.unindentRegion(self),
            .char => |c| if (c >= 32 and c < 127) try self.insertCodepoint(c),
            .codepoint => |cp| try self.insertCodepoint(cp),
            else => {
                // 特殊キーをkeymapで検索
                if (Keymap.toSpecialKey(key)) |special_key| {
                    if (self.keymap.findSpecial(special_key)) |handler| {
                        try handler(self);
                    }
                }
            },
        }
    }

    /// キー入力を処理するメインディスパッチャ
    fn processKey(self: *Editor, key: input.Key) !void {
        // 古いプロンプトバッファを解放
        if (self.prompt_buffer) |old_prompt| {
            self.allocator.free(old_prompt);
            self.prompt_buffer = null;
        }

        // モード別に処理を分岐
        switch (self.mode) {
            .filename_input => {
                _ = try self.handleFilenameInputKey(key);
                return;
            },
            .find_file_input => {
                _ = try self.handleFindFileInputKey(key);
                return;
            },
            .buffer_switch_input => {
                _ = try self.handleBufferSwitchInputKey(key);
                return;
            },
            .isearch_forward => {
                _ = try self.handleIsearchKey(key, true);
                return;
            },
            .isearch_backward => {
                _ = try self.handleIsearchKey(key, false);
                return;
            },
            .prefix_x => {
                _ = try self.handlePrefixXKey(key);
                return;
            },
            .quit_confirm => {
                switch (key) {
                    .char => |c| self.handleQuitConfirmChar(c),
                    .codepoint => |cp| self.handleQuitConfirmChar(unicode.normalizeFullwidth(cp)),
                    .ctrl => |c| {
                        if (c == 'g') self.resetToNormal();
                    },
                    else => {},
                }
                return;
            },
            .kill_buffer_confirm => {
                switch (key) {
                    .char => |c| self.handleKillBufferConfirmChar(c),
                    .codepoint => |cp| self.handleKillBufferConfirmChar(unicode.normalizeFullwidth(cp)),
                    .ctrl => |c| {
                        if (c == 'g') self.resetToNormal();
                    },
                    .escape => self.resetToNormal(),
                    else => {},
                }
                return;
            },
            .prefix_r => {
                _ = self.handlePrefixRKey(key);
                return;
            },
            .query_replace_input_search => {
                _ = try self.handleQueryReplaceInputSearchKey(key);
                return;
            },
            .query_replace_input_replacement => {
                _ = try self.handleQueryReplaceInputReplacementKey(key);
                return;
            },
            .query_replace_confirm => {
                _ = try self.handleQueryReplaceConfirmKey(key);
                return;
            },
            .shell_command => {
                _ = try self.handleShellCommandKey(key);
                return;
            },
            .shell_running => {
                switch (key) {
                    .ctrl => |c| {
                        if (c == 'g') {
                            self.cancelShellCommand();
                            self.minibuffer.clear();
                        }
                    },
                    else => {},
                }
                return;
            },
            .mx_command => {
                _ = try self.handleMxCommandKey(key);
                return;
            },
            .mx_key_describe => {
                const key_desc = self.describeKey(key);
                self.getCurrentView().setError(key_desc);
                self.mode = .normal;
                return;
            },
            .normal => {},
        }

        // 通常モード
        try self.handleNormalKey(key);
    }

    fn insertChar(self: *Editor, ch: u8) !void {
        return self.insertCodepoint(@as(u21, ch));
    }

    fn insertCodepoint(self: *Editor, codepoint: u21) !void {
        if (self.isReadOnly()) return;
        const buffer_state = self.getCurrentBuffer();
        const buffer = self.getCurrentBufferContent();
        const current_line = self.getCurrentLine();

        // UTF-8にエンコード
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidUtf8;

        const pos = self.getCurrentView().getCursorBufferPos();

        // バッファ変更を先に実行
        try buffer.insertSlice(pos, buf[0..len]);
        errdefer buffer.delete(pos, len) catch unreachable; // rollback失敗は致命的
        try self.recordInsert(pos, buf[0..len], pos); // 編集前のカーソル位置を記録
        buffer_state.editing_ctx.modified = true;

        if (codepoint == '\n') {
            // 改行処理
            const view = self.getCurrentView();
            const max_screen_line = if (view.viewport_height >= 2) view.viewport_height - 2 else 0;
            if (view.cursor_y < max_screen_line) {
                view.cursor_y += 1;
                view.markDirty(current_line, null); // EOF まで再描画
            } else {
                // 画面の最下部の場合はスクロール
                view.top_line += 1;
                view.markFullRedraw(); // スクロール時は全画面再描画
            }
            view.cursor_x = 0;
            view.top_col = 0; // 水平スクロールもリセット
        } else {
            // 通常文字
            const view = self.getCurrentView();
            view.markDirty(current_line, current_line);

            // カーソル移動（タブは特別扱い）
            if (codepoint == '\t') {
                const tab_width = view.getTabWidth();
                const next_tab_stop = (view.cursor_x / tab_width + 1) * tab_width;
                view.cursor_x = next_tab_stop;
            } else {
                view.cursor_x += unicode.displayWidth(codepoint);
            }

            // 水平スクロール: カーソルが右端を超えた場合
            const line_num_width = view.getLineNumberWidth();
            const visible_width = if (view.viewport_width > line_num_width) view.viewport_width - line_num_width else 1;
            if (view.cursor_x >= view.top_col + visible_width) {
                view.top_col = view.cursor_x - visible_width + 1;
                view.markFullRedraw();
            }
        }
    }

    // マーク位置とカーソル位置から範囲を取得（開始位置と長さを返す）
    pub fn getRegion(self: *Editor) ?struct { start: usize, len: usize } {
        const window = self.getCurrentWindow();
        const raw_mark = window.mark_pos orelse return null;
        const buffer = self.getCurrentBufferContent();
        const cursor = self.getCurrentView().getCursorBufferPos();

        // マーク位置がバッファ範囲を超えている場合はクランプ（バッファ編集後の安全対策）
        const mark = @min(raw_mark, buffer.len());

        if (mark < cursor) {
            return .{ .start = mark, .len = cursor - mark };
        } else if (cursor < mark) {
            return .{ .start = cursor, .len = mark - cursor };
        } else {
            return null; // 範囲が空
        }
    }

    // インクリメンタルサーチ実行
    // forward: true=前方検索、false=後方検索
    // skip_current: true=現在位置をスキップして次を検索、false=現在位置から検索
    fn performSearch(self: *Editor, forward: bool, skip_current: bool) !void {
        const buffer = self.getCurrentBufferContent();
        const search_str = self.minibuffer.getContent();
        if (search_str.len == 0) return;

        const start_pos = self.getCurrentView().getCursorBufferPos();
        const is_regex = SearchService.isRegexPattern(search_str);

        // まずコピーなしのBuffer直接検索を試みる（リテラルパターンのみ）
        if (self.search_service.searchBuffer(buffer, search_str, start_pos, forward, skip_current)) |match| {
            self.setCursorToPos(match.start);
            return;
        }

        // 正規表現パターンの場合のみ、バッファ全体をコピーして検索
        if (is_regex) {
            const content = try self.extractText(0, buffer.total_len);
            defer self.allocator.free(content);

            if (self.search_service.search(content, search_str, start_pos, forward, skip_current)) |match| {
                self.setCursorToPos(match.start);
                return;
            }
        }

        // 見つからなかった場合のエラーメッセージ
        if (forward) {
            if (is_regex) {
                self.getCurrentView().setError("Failing I-search (regex)");
            } else {
                self.getCurrentView().setError("Failing I-search");
            }
        } else {
            if (is_regex) {
                self.getCurrentView().setError("Failing I-search backward (regex)");
            } else {
                self.getCurrentView().setError("Failing I-search backward");
            }
        }
    }

    // 置換：次の一致を検索してカーソルを移動
    fn findNextMatch(self: *Editor, search: []const u8, start_pos: usize) !bool {
        if (search.len == 0) return false;

        const buffer = self.getCurrentBufferContent();
        const buf_len = buffer.len();
        if (start_pos >= buf_len) return false;

        // バッファを検索
        var iter = PieceIterator.init(buffer);
        iter.seek(start_pos);

        var match_start: ?usize = null;
        var match_len: usize = 0;

        while (iter.global_pos < buf_len) {
            const start = iter.global_pos;

            // 一致を確認
            var temp_iter = PieceIterator.init(buffer);
            temp_iter.seek(start);

            var matched = true;
            for (search) |ch| {
                const next_byte = temp_iter.next();
                if (next_byte == null or next_byte.? != ch) {
                    matched = false;
                    break;
                }
            }

            if (matched) {
                match_start = start;
                match_len = search.len;
                break;
            }

            _ = iter.next();
        }

        if (match_start) |pos| {
            // 一致が見つかった：カーソルを移動
            self.setCursorToPos(pos);
            self.replace_current_pos = pos;
            return true;
        }

        return false;
    }

    // 置換：現在の一致を置換
    fn replaceCurrentMatch(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const buffer_state = self.getCurrentBuffer();
        const search = self.replace_search orelse return error.NoSearchString;
        const replacement = self.replace_replacement orelse return error.NoReplacementString;
        const match_pos = self.replace_current_pos orelse return error.NoMatchPosition;

        // Undo記録のために現在のカーソル位置を保存
        const cursor_pos_before = match_pos;

        // 一致部分のテキストを保存（Undo用）
        const old_text = try self.extractText(match_pos, search.len);
        defer self.allocator.free(old_text);

        // 置換を実行（削除してから挿入）
        try buffer.delete(match_pos, search.len);
        if (replacement.len > 0) {
            try buffer.insertSlice(match_pos, replacement);
        }

        // 原子的な置換操作として記録（1回のundoで元に戻る）
        try self.recordReplace(match_pos, old_text, replacement, cursor_pos_before);

        buffer_state.editing_ctx.modified = true;
        self.replace_match_count += 1;

        // カーソルを置換後の位置に移動
        self.setCursorToPos(match_pos + replacement.len);

        // 全画面再描画
        self.getCurrentView().markFullRedraw();
    }

    // ========================================
    // Shell Integration
    // ========================================

    /// シェルコマンド履歴をナビゲート
    fn navigateShellHistory(self: *Editor, prev: bool) !void {
        // 最初のナビゲーションなら現在の入力を保存
        if (!self.shell_service.isNavigating()) {
            try self.shell_service.startHistoryNavigation(self.minibuffer.getContent());
        }

        const entry = if (prev) self.shell_service.historyPrev() else self.shell_service.historyNext();
        if (entry) |text| {
            // ミニバッファを履歴エントリで置き換え
            try self.minibuffer.setContent(text);
            self.updateMinibufferPrompt("| ");
        }
    }

    /// 検索履歴をナビゲート
    fn navigateSearchHistory(self: *Editor, prev: bool, is_forward: bool) !void {
        // 最初のナビゲーションなら現在の入力を保存
        if (!self.search_service.isNavigating()) {
            try self.search_service.startHistoryNavigation(self.minibuffer.getContent());
        }

        const entry = if (prev) self.search_service.historyPrev() else self.search_service.historyNext();
        if (entry) |text| {
            // ミニバッファを履歴エントリで置き換え
            try self.minibuffer.setContent(text);

            // プロンプトを更新
            const prefix = if (is_forward) "I-search: " else "I-search backward: ";
            self.setPrompt("{s}{s}", .{ prefix, text });

            // 検索を実行
            if (text.len > 0) {
                self.getCurrentView().setSearchHighlight(text);
                if (self.search_start_pos) |start_pos| {
                    self.setCursorToPos(start_pos);
                }
                try self.performSearch(is_forward, false);
            }
        }
    }

    /// シェルコマンドを非同期で開始
    fn startShellCommand(self: *Editor) !void {
        const cmd_input = self.minibuffer.getContent();
        if (cmd_input.len == 0) return;

        // コマンドをパースして入力元を取得
        const parsed = ShellService.parseCommand(cmd_input);

        if (parsed.command.len == 0) {
            self.getCurrentView().setError("No command specified");
            return;
        }

        // 入力データを取得
        var stdin_data: ?[]const u8 = null;
        var stdin_allocated = false;

        const window = self.window_manager.getCurrentWindow();

        switch (parsed.input_source) {
            .selection => {
                // 選択範囲（マークがあれば）
                if (window.mark_pos) |mark| {
                    const cursor_pos = self.getCurrentView().getCursorBufferPos();
                    const sel_start = @min(mark, cursor_pos);
                    const sel_end = @max(mark, cursor_pos);
                    if (sel_end > sel_start) {
                        stdin_data = try self.getCurrentBufferContent().getRange(self.allocator, sel_start, sel_end - sel_start);
                        stdin_allocated = true;
                    }
                }
                // 選択なければ stdin は空
            },
            .buffer_all => {
                // バッファ全体
                const total_len = self.getCurrentBufferContent().total_len;
                if (total_len > 0) {
                    stdin_data = try self.getCurrentBufferContent().getRange(self.allocator, 0, total_len);
                    stdin_allocated = true;
                }
            },
            .current_line => {
                // 現在行
                const line_num = self.getCurrentView().top_line + self.getCurrentView().cursor_y;
                var buffer = self.getCurrentBufferContent();
                const line_start = buffer.getLineStart(line_num) orelse 0;
                const next_line_start = buffer.getLineStart(line_num + 1);
                const line_end = if (next_line_start) |ns| ns else buffer.total_len;
                if (line_end > line_start) {
                    stdin_data = try buffer.getRange(self.allocator, line_start, line_end - line_start);
                    stdin_allocated = true;
                }
            },
        }

        // ShellServiceにコマンド実行を委譲
        self.shell_service.start(cmd_input, stdin_data, stdin_allocated) catch |err| {
            // エラー時は入力データを解放
            if (stdin_allocated) {
                if (stdin_data) |data| {
                    self.allocator.free(data);
                }
            }
            switch (err) {
                error.EmptyCommand, error.NoCommand => {
                    self.getCurrentView().setError("No command specified");
                },
                else => {
                    self.getCurrentView().setError("Failed to start command");
                },
            }
            return;
        };

        self.mode = .shell_running;
        self.getCurrentView().setError("Running... (C-g to cancel)");
    }

    /// シェルコマンドの完了をポーリング
    fn pollShellCommand(self: *Editor) !void {
        // ShellServiceにポーリングを委譲
        if (try self.shell_service.poll()) |result| {
            // コマンド完了 - 結果を処理
            defer self.shell_service.finish();

            // ShellServiceの型をエディタの型に変換
            const input_source: ShellInputSource = switch (result.input_source) {
                .selection => .selection,
                .buffer_all => .buffer_all,
                .current_line => .current_line,
            };
            const output_dest: ShellOutputDest = switch (result.output_dest) {
                .command_buffer => .command_buffer,
                .replace => .replace,
                .insert => .insert,
                .new_buffer => .new_buffer,
            };

            try self.processShellResult(result.stdout, result.stderr, result.exit_status, input_source, output_dest);
            self.mode = .normal;
        }
        // まだ実行中の場合は何もしない
    }

    /// シェルコマンドをキャンセル
    fn cancelShellCommand(self: *Editor) void {
        self.shell_service.cancel();
        self.mode = .normal;
        self.getCurrentView().setError("Cancelled");
    }

    /// シェル実行結果を処理
    fn processShellResult(self: *Editor, stdout: []const u8, stderr: []const u8, exit_status: ?u32, input_source: ShellInputSource, output_dest: ShellOutputDest) !void {
        const window = self.window_manager.getCurrentWindow();

        // 結果を処理
        switch (output_dest) {
            .command_buffer => {
                // *Command* バッファに出力を表示（stdout + stderrを結合）
                var output_list: std.ArrayList(u8) = .{};
                defer output_list.deinit(self.allocator);

                if (stdout.len > 0) {
                    try output_list.appendSlice(self.allocator, stdout);
                }
                if (stderr.len > 0) {
                    if (stdout.len > 0 and stdout[stdout.len - 1] != '\n') {
                        try output_list.append(self.allocator, '\n');
                    }
                    try output_list.appendSlice(self.allocator, stderr);
                }
                const output = output_list.items;
                if (output.len == 0) {
                    if (exit_status) |status| {
                        if (status != 0) {
                            var msg_buf: [64]u8 = undefined;
                            const msg = std.fmt.bufPrint(&msg_buf, "Exit status: {d}", .{status}) catch "(exit error)";
                            self.getCurrentView().setError(msg);
                        } else {
                            self.getCurrentView().setError("(no output)");
                        }
                    } else {
                        self.getCurrentView().setError("(no output)");
                    }
                    return;
                }

                // コマンドバッファを取得/作成
                const cmd_buffer = try self.getOrCreateCommandBuffer();

                // バッファをクリアして新しい内容を設定
                if (cmd_buffer.editing_ctx.buffer.total_len > 0) {
                    cmd_buffer.editing_ctx.buffer.delete(0, cmd_buffer.editing_ctx.buffer.total_len) catch {};
                }

                // 出力を挿入
                cmd_buffer.editing_ctx.buffer.insertSlice(0, output) catch {};

                // *Command* バッファがどこかのウィンドウに表示されているか確認
                const windows = self.window_manager.iterator();
                var cmd_window_idx: ?usize = null;
                for (windows, 0..) |*win, idx| {
                    if (win.buffer_id == cmd_buffer.id) {
                        cmd_window_idx = idx;
                        break;
                    }
                }

                if (cmd_window_idx) |idx| {
                    // 既に表示されている：そのウィンドウを更新
                    var win = &self.window_manager.iterator()[idx];
                    win.view.markFullRedraw();
                    win.view.cursor_x = 0;
                    win.view.cursor_y = 0;
                    win.view.top_line = 0;
                    win.view.top_col = 0;
                } else {
                    // 表示されていない：ウィンドウを分割して下に *Command* を表示
                    const new_win_idx = try self.openCommandBufferWindow();
                    // 新しいウィンドウのビューを更新（バッファが更新されているため）
                    var new_win = &self.window_manager.iterator()[new_win_idx];
                    new_win.view.buffer = cmd_buffer.editing_ctx.buffer;
                    new_win.view.markFullRedraw();
                    new_win.view.cursor_x = 0;
                    new_win.view.cursor_y = 0;
                    new_win.view.top_line = 0;
                    new_win.view.top_col = 0;
                }

                // カレントウィンドウはそのまま（移動しない）
                // ステータス表示
                if (exit_status) |status| {
                    if (status != 0) {
                        var msg_buf: [64]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "Exit {d} (see below)", .{status}) catch "Exit error";
                        self.getCurrentView().setError(msg);
                    } else if (stderr.len > 0) {
                        self.getCurrentView().setError("Done with warnings (see below)");
                    } else {
                        self.getCurrentView().setError("Done (see below)");
                    }
                } else if (stderr.len > 0) {
                    self.getCurrentView().setError("Done with warnings (see below)");
                } else {
                    self.getCurrentView().setError("Done (see below)");
                }
            },
            .replace => {
                // 入力元を置換
                switch (input_source) {
                    .selection => {
                        if (window.mark_pos) |mark| {
                            const cursor_pos = self.getCurrentView().getCursorBufferPos();
                            const start = @min(mark, cursor_pos);
                            const end_pos = @max(mark, cursor_pos);
                            if (end_pos > start) {
                                // 削除してから挿入
                                const buf = self.getCurrentBufferContent();
                                const deleted = try buf.getRange(self.allocator, start, end_pos - start);
                                defer self.allocator.free(deleted);
                                try buf.delete(start, end_pos - start);
                                try self.recordDelete(start, deleted, cursor_pos);

                                if (stdout.len > 0) {
                                    try buf.insertSlice(start, stdout);
                                    try self.recordInsert(start, stdout, start);
                                }
                                self.getCurrentBuffer().editing_ctx.modified = true;
                                self.setCursorToPos(start);
                                self.window_manager.getCurrentWindow().mark_pos = null; // マークをクリア
                                self.getCurrentView().markDirty(0, null);
                            }
                        } else {
                            self.getCurrentView().setError("No selection");
                        }
                    },
                    .buffer_all => {
                        // バッファ全体を置換
                        const buf = self.getCurrentBufferContent();
                        const total_len = buf.total_len;
                        if (total_len > 0) {
                            const old_content = try buf.getRange(self.allocator, 0, total_len);
                            defer self.allocator.free(old_content);
                            try buf.delete(0, total_len);
                            try self.recordDelete(0, old_content, self.getCurrentView().getCursorBufferPos());
                        }
                        if (stdout.len > 0) {
                            try buf.insertSlice(0, stdout);
                            try self.recordInsert(0, stdout, 0);
                        }
                        self.getCurrentBuffer().editing_ctx.modified = true;
                        self.setCursorToPos(0);
                        self.getCurrentView().markDirty(0, null);
                    },
                    .current_line => {
                        // 現在行を置換
                        const line_num = self.getCurrentView().top_line + self.getCurrentView().cursor_y;
                        var buf = self.getCurrentBufferContent();
                        const line_start = buf.getLineStart(line_num) orelse 0;
                        const next_line_start = buf.getLineStart(line_num + 1);
                        const line_end = if (next_line_start) |ns| ns else buf.total_len;
                        if (line_end > line_start) {
                            const old_line = try buf.getRange(self.allocator, line_start, line_end - line_start);
                            defer self.allocator.free(old_line);
                            try buf.delete(line_start, line_end - line_start);
                            try self.recordDelete(line_start, old_line, self.getCurrentView().getCursorBufferPos());
                        }
                        if (stdout.len > 0) {
                            try buf.insertSlice(line_start, stdout);
                            try self.recordInsert(line_start, stdout, line_start);
                        }
                        self.getCurrentBuffer().editing_ctx.modified = true;
                        self.setCursorToPos(line_start);
                        self.getCurrentView().markDirty(line_num, null);
                    },
                }
            },
            .insert => {
                // カーソル位置に挿入
                if (stdout.len > 0) {
                    const pos = self.getCurrentView().getCursorBufferPos();
                    const buf = self.getCurrentBufferContent();
                    try buf.insertSlice(pos, stdout);
                    try self.recordInsert(pos, stdout, pos);
                    self.getCurrentBuffer().editing_ctx.modified = true;
                    self.getCurrentView().markDirty(0, null);
                }
            },
            .new_buffer => {
                // 新規バッファに出力
                if (stdout.len > 0) {
                    const new_buffer = try self.createNewBuffer();
                    try new_buffer.editing_ctx.buffer.insertSlice(0, stdout);
                    new_buffer.filename = try self.allocator.dupe(u8, "*shell output*");
                    try self.switchToBuffer(new_buffer.id);
                } else if (stderr.len > 0) {
                    const new_buffer = try self.createNewBuffer();
                    try new_buffer.editing_ctx.buffer.insertSlice(0, stderr);
                    new_buffer.filename = try self.allocator.dupe(u8, "*shell error*");
                    try self.switchToBuffer(new_buffer.id);
                }
            },
        }
    }

    /// キーの説明を返す
    fn describeKey(self: *Editor, key: input.Key) []const u8 {
        _ = self;
        return switch (key) {
            .ctrl => |c| switch (c) {
                0, '@' => "C-Space/C-@: set-mark",
                'a' => "C-a: beginning-of-line",
                'b' => "C-b: backward-char",
                'd' => "C-d: delete-char",
                'e' => "C-e: end-of-line",
                'f' => "C-f: forward-char",
                'g' => "C-g: cancel",
                'h' => "C-h: backspace",
                'k' => "C-k: kill-line",
                'l' => "C-l: recenter",
                'n' => "C-n: next-line",
                'p' => "C-p: previous-line",
                'r' => "C-r: isearch-backward",
                's' => "C-s: isearch-forward",
                'u' => "C-u: undo",
                'v' => "C-v: scroll-down",
                'w' => "C-w: kill-region",
                'x' => "C-x: prefix",
                'y' => "C-y: yank",
                '/' => "C-/: redo",
                else => "Unknown key",
            },
            .alt => |c| switch (c) {
                '%' => "M-%: query-replace",
                ';' => "M-;: comment-toggle",
                '<' => "M-<: beginning-of-buffer",
                '>' => "M->: end-of-buffer",
                '^' => "M-^: join-line",
                'b' => "M-b: backward-word",
                'd' => "M-d: kill-word",
                'f' => "M-f: forward-word",
                'v' => "M-v: scroll-up",
                'w' => "M-w: copy-region",
                'x' => "M-x: command",
                '{' => "M-{: backward-paragraph",
                '}' => "M-}: forward-paragraph",
                '|' => "M-|: shell-command",
                else => "Unknown key",
            },
            .enter => "Enter: newline",
            .backspace => "Backspace: delete-backward-char",
            .tab => "Tab: indent / insert-tab",
            .shift_tab => "S-Tab: unindent",
            .arrow_up => "Up: previous-line",
            .arrow_down => "Down: next-line",
            .arrow_left => "Left: backward-char",
            .arrow_right => "Right: forward-char",
            .home => "Home: beginning-of-line",
            .end_key => "End: end-of-line",
            .page_up => "PageUp: scroll-up",
            .page_down => "PageDown: scroll-down",
            .delete => "Delete: delete-char",
            .escape => "Escape: cancel",
            .alt_delete => "M-Delete: kill-word",
            .alt_arrow_up => "M-Up: move-line-up",
            .alt_arrow_down => "M-Down: move-line-down",
            .ctrl_tab => "C-Tab: next-window",
            .ctrl_shift_tab => "C-S-Tab: previous-window",
            else => "Unknown key",
        };
    }
};
