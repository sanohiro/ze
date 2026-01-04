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
const buffer_mod = @import("buffer");
const Buffer = buffer_mod.Buffer;
const PieceIterator = buffer_mod.PieceIterator;
const View = @import("view").View;
const Terminal = @import("terminal").Terminal;
const input = @import("input");
const config = @import("config");
const unicode = @import("unicode");

// サービス
const poller = @import("poller");

const Minibuffer = @import("minibuffer").Minibuffer;
const SearchService = @import("search_service").SearchService;
const shell_service_mod = @import("shell_service");
const ShellService = shell_service_mod.ShellService;

// コマンド
const help = @import("commands_help");
const ShellOutputDest = shell_service_mod.OutputDest;
const ShellInputSource = shell_service_mod.InputSource;
const buffer_manager_mod = @import("buffer_manager");
const BufferManager = buffer_manager_mod.BufferManager;
const BufferState = buffer_manager_mod.BufferState;
const window_manager_mod = @import("window_manager");
const WindowManager = window_manager_mod.WindowManager;
const Window = window_manager_mod.Window;
const Keymap = @import("keymap").Keymap;
const MacroService = @import("macro_service").MacroService;
const edit = @import("commands_edit");
const movement = @import("commands_movement");
const rectangle = @import("commands_rectangle");
const mx = @import("commands_mx");

/// キルリング - 連続kill操作でのメモリ再利用を実現
/// 毎回alloc/freeする代わりに、容量を確保して再利用する。
pub const KillRing = struct {
    data: ?[]u8,
    capacity: usize,
    len: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KillRing {
        return .{
            .data = null,
            .capacity = 0,
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KillRing) void {
        if (self.data) |d| {
            self.allocator.free(d);
        }
    }

    /// テキストを保存（容量が足りなければ拡大、足りていれば再利用）
    pub fn store(self: *KillRing, text: []const u8) !void {
        if (self.capacity < text.len) {
            // サイズ拡大時のみrealloc（+50%予備で再アロケーション頻度を削減）
            const new_capacity = text.len + (text.len / 2) + 64; // 最低64バイトは余裕を持つ
            if (self.data) |old| {
                // reallocで効率的にサイズ変更
                if (self.allocator.resize(old, new_capacity)) {
                    // resizeが成功した場合（インプレース拡張）
                    // 重要: スライスの長さも更新する必要がある
                    self.data = old.ptr[0..new_capacity];
                    self.capacity = new_capacity;
                } else {
                    // resizeが失敗した場合は新規アロケーション
                    const new_data = try self.allocator.alloc(u8, new_capacity);
                    self.allocator.free(old);
                    self.data = new_data;
                    self.capacity = new_capacity;
                }
            } else {
                self.data = try self.allocator.alloc(u8, new_capacity);
                self.capacity = new_capacity;
            }
        }
        @memcpy(self.data.?[0..text.len], text);
        self.len = text.len;
    }

    /// 保存されたテキストを取得
    pub fn get(self: *const KillRing) ?[]const u8 {
        if (self.data) |d| {
            if (self.len > 0) {
                return d[0..self.len];
            }
        }
        return null;
    }
};

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
    macro_repeat, // マクロ再生後の連打待機（eで再実行）
    exit_confirm, // M-x exit: 終了確認中（y/nを待つ）
    overwrite_confirm, // ファイル上書き確認中（y/nを待つ）
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

/// Editor: zeエディタのコアとなる構造体
///
/// 【マルチバッファ・マルチウィンドウ】
/// Emacs風のアーキテクチャを採用:
/// - BufferManager: 全バッファを管理（複数ファイルを同時に開ける）
/// - WindowManager: 全ウィンドウを管理（画面分割に対応）
/// - 同じバッファを複数ウィンドウで表示可能（編集は共有）
///
/// 【メインループ】
/// ```
/// while (running) {
///     processKey()        // キー入力処理
///     pollShellCommand()  // シェルコマンドの非同期ポーリング
///     render()            // 画面描画（差分描画）
/// }
/// ```
///
/// 【パフォーマンス最適化】
/// - 差分描画: View.renderInBounds()で変更部分のみ描画
/// - マルチウィンドウ: markAllViewsDirtyForBuffer()で同一バッファの全Viewを更新
/// - 非同期シェル: UIをブロックせずにコマンド実行
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
    prompt_prefix_len: usize, // プロンプト文字列のプレフィックス長（カーソル位置計算用）
    cached_prompt_prefix: ?[]const u8, // プレフィックスキャッシュ（再計算回避）

    // グローバルバッファ（全バッファで共有）
    kill_ring: KillRing,
    rectangle_ring: ?std.ArrayList([]const u8),

    // 検索状態（グローバル）
    search_start_pos: ?usize,
    last_search: ?[]const u8,
    is_regex_search: bool, // 正規表現検索モード（C-M-s / C-M-r）

    // 置換状態（グローバル）
    is_regex_replace: bool, // 正規表現置換モード（C-M-%）
    replace_search: ?[]const u8,
    replace_replacement: ?[]const u8,
    replace_current_pos: ?usize,
    replace_match_len: ?usize, // 正規表現の場合、パターン長 != マッチ長
    replace_match_count: usize,

    // サービス
    shell_service: ShellService, // シェルコマンド実行サービス（履歴含む）
    search_service: SearchService, // 検索サービス（履歴含む）
    macro_service: MacroService, // キーボードマクロサービス

    // UI状態
    spinner_frame: u8, // シェル実行中のスピナーフレーム
    overwrite_mode: bool, // 上書きモード（Insertキーでトグル）
    completion_shown: bool, // 補完候補表示中フラグ
    pending_filename: ?[]const u8, // overwrite確認待ちのファイル名

    // ブラケットペーストモード
    paste_mode: bool, // ペースト中フラグ（ESC[200~とESC[201~の間）
    paste_buffer: std.ArrayList(u8), // ペースト内容を蓄積するバッファ

    // 検索チャンクバッファ（正規表現検索で再利用、alloc/free削減）
    search_chunk_buffer: ?[]u8,
    search_chunk_capacity: usize,

    // シェルコマンドストリーミング状態（メモリ効率化）
    streaming_range: ?struct {
        start: usize, // 読み取り開始位置
        end: usize, // 読み取り終了位置
        current_pos: usize, // 現在の読み取り位置
    },

    // キーマップ
    keymap: Keymap, // キーバインド設定（ランタイム変更可能）

    // 入力ソース（stdin以外からの入力用、例: パイプ入力時の/dev/tty）
    tty_file: ?std.fs.File,

    pub fn init(allocator: std.mem.Allocator, tty_file: ?std.fs.File) !Editor {
        // ターミナルを先に初期化（サイズ取得のため）
        // パイプ入力時はtty_fileを使用してtermios操作
        var terminal = try Terminal.init(allocator, tty_file);
        errdefer terminal.deinit(); // 以降の初期化失敗時にターミナルをクリーンアップ

        // BufferManagerを初期化し、最初のバッファを作成
        var buffer_manager = BufferManager.init(allocator);
        const first_buffer = try buffer_manager.createBuffer();

        // WindowManagerを初期化し、最初のウィンドウを作成
        var window_manager = WindowManager.init(allocator, terminal.width, terminal.height);
        const first_window = try window_manager.createWindow(first_buffer.id, 0, 0, terminal.width, terminal.height);
        first_window.view = try View.init(allocator, first_buffer.editing_ctx.buffer);
        // 空バッファは言語検出スキップ（View.initでデフォルト言語が設定済み）
        // ファイルオープン時にmain.zigで再検出される
        // ビューポートサイズを設定（カーソル移動の境界判定に使用）
        first_window.view.setViewport(terminal.width, terminal.height);

        const editor = Editor{
            .terminal = terminal,
            .allocator = allocator,
            .running = true,
            .buffer_manager = buffer_manager,
            .window_manager = window_manager,
            .mode = .normal,
            .minibuffer = Minibuffer.init(allocator),
            .quit_after_save = false,
            .prompt_prefix_len = 0,
            .cached_prompt_prefix = null,
            .kill_ring = KillRing.init(allocator),
            .rectangle_ring = null,
            .search_start_pos = null,
            .last_search = null,
            .is_regex_search = false,
            .is_regex_replace = false,
            .replace_search = null,
            .replace_replacement = null,
            .replace_current_pos = null,
            .replace_match_len = null,
            .replace_match_count = 0,
            .shell_service = ShellService.init(allocator),
            .search_service = SearchService.init(allocator),
            .macro_service = MacroService.init(allocator),
            .spinner_frame = 0,
            .overwrite_mode = false,
            .completion_shown = false,
            .pending_filename = null,
            .paste_mode = false,
            .paste_buffer = std.ArrayList(u8){},
            .search_chunk_buffer = null,
            .search_chunk_capacity = 0,
            .streaming_range = null,
            .keymap = try Keymap.init(allocator),
            .tty_file = tty_file,
        };

        return editor;
    }

    /// メモリ上のコンテンツをバッファに読み込む（stdin入力用）
    pub fn loadFromMemory(self: *Editor, content: []const u8, name: []const u8) !void {
        const buffer_state = self.getCurrentBuffer();
        const view = self.getCurrentView();

        // 新しいバッファを作成
        var new_buffer = try Buffer.loadFromSlice(self.allocator, content);
        errdefer new_buffer.deinit();

        // ファイル名を複製
        const new_filename = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(new_filename);

        // 古いバッファを解放して新しいバッファで上書き
        buffer_state.editing_ctx.buffer.deinit();
        buffer_state.editing_ctx.buffer.* = new_buffer;

        // ファイル名を設定
        buffer_state.file.setFilenameOwned(new_filename);

        // Undo/Redoスタックをクリア
        buffer_state.editing_ctx.clearUndoHistory();
        buffer_state.editing_ctx.modified = false; // 読み込み直後は未変更

        // ビューをリセット
        view.top_line = 0;
        view.top_col = 0;
        view.cursor_x = 0;
        view.cursor_y = 0;
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
        self.kill_ring.deinit();
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

        // pending_filenameのクリーンアップ
        if (self.pending_filename) |pending| {
            self.allocator.free(pending);
        }

        // ペーストバッファのクリーンアップ
        self.paste_buffer.deinit(self.allocator);

        // 検索チャンクバッファのクリーンアップ
        if (self.search_chunk_buffer) |buf| {
            self.allocator.free(buf);
        }

        // ミニバッファのクリーンアップ
        self.minibuffer.deinit();

        // サービスのクリーンアップ
        self.shell_service.deinit();
        self.search_service.deinit();
        self.macro_service.deinit();
    }

    // ========================================
    // ヘルパーメソッド
    // ========================================

    /// 現在のウィンドウを取得（WindowManager経由）
    pub fn getCurrentWindow(self: *Editor) *Window {
        return self.window_manager.getCurrentWindow();
    }

    /// 現在のバッファを取得
    /// 不変条件: ウィンドウは常に有効なバッファを参照する（closeBuffer時に検証）
    pub fn getCurrentBuffer(self: *Editor) *BufferState {
        const window = self.getCurrentWindow();
        return self.buffer_manager.findById(window.buffer_id) orelse {
            // バッファが見つからない場合は不変条件違反
            // デバッグ用に情報を出力
            std.log.err("Buffer not found: window.buffer_id={d}", .{window.buffer_id});
            unreachable;
        };
    }

    /// 現在のビューを取得
    pub fn getCurrentView(self: *Editor) *View {
        return &self.getCurrentWindow().view;
    }

    /// 現在のバッファのBufferを取得
    pub fn getCurrentBufferContent(self: *Editor) *Buffer {
        return self.getCurrentBuffer().editing_ctx.buffer;
    }

    /// ウィンドウのViewを指定バッファ用に設定（言語検出とビューポート設定）
    /// 注意: Viewは呼び出し側で事前にセットしておくこと
    fn setupWindowView(window: *Window, buffer_state: *BufferState) void {
        var preview_buf: [512]u8 = undefined;
        const content_preview = buffer_state.editing_ctx.buffer.getContentPreview(&preview_buf);
        window.view.detectLanguage(buffer_state.file.filename, content_preview);
        window.view.setViewport(window.width, window.height);
    }

    /// 指定バッファを表示している全ウィンドウをdirtyにマーク
    /// 同一バッファを複数ウィンドウで開いている場合に使用
    pub fn markAllViewsDirtyForBuffer(self: *Editor, buffer_id: usize, start_line: usize, end_line: ?usize) void {
        for (self.window_manager.iterator()) |*window| {
            if (window.buffer_id == buffer_id) {
                window.view.markDirty(start_line, end_line);
            }
        }
    }

    /// 指定バッファを表示している全ウィンドウを全画面再描画にマーク
    pub fn markAllViewsFullRedrawForBuffer(self: *Editor, buffer_id: usize) void {
        for (self.window_manager.iterator()) |*window| {
            if (window.buffer_id == buffer_id) {
                window.view.markFullRedraw();
            }
        }
    }

    /// 現在のバッファの指定範囲をdirtyにマーク（現在のバッファIDを自動取得）
    pub fn markCurrentBufferDirty(self: *Editor, start_line: usize, end_line: ?usize) void {
        const buffer_id = self.getCurrentBuffer().id;
        self.markAllViewsDirtyForBuffer(buffer_id, start_line, end_line);
    }

    /// テキスト変更後のdirtyマークを適切に設定
    /// 改行を含む場合は現在行以降全体、そうでなければ現在行のみ
    pub fn markCurrentBufferDirtyForText(self: *Editor, current_line: usize, text: []const u8) void {
        const buffer_id = self.getCurrentBuffer().id;
        if (std.mem.indexOfScalar(u8, text, '\n') != null) {
            self.markAllViewsDirtyForBuffer(buffer_id, current_line, null);
        } else {
            self.markAllViewsDirtyForBuffer(buffer_id, current_line, current_line);
        }
    }

    /// 現在のバッファの全画面再描画をマーク
    pub fn markCurrentBufferFullRedraw(self: *Editor) void {
        const buffer_id = self.getCurrentBuffer().id;
        self.markAllViewsFullRedrawForBuffer(buffer_id);
    }

    /// 指定バッファを表示している全ウィンドウをdirtyにマーク（現在のビューを除く）
    /// 文字入力時に現在のビューのキャッシュを保持したまま他のビューを更新するために使用
    pub fn markAllViewsDirtyForBufferExceptCurrent(self: *Editor, buffer_id: usize, start_line: usize, end_line: ?usize) void {
        const current_view = self.getCurrentView();
        for (self.window_manager.iterator()) |*window| {
            if (window.buffer_id == buffer_id and &window.view != current_view) {
                window.view.markDirty(start_line, end_line);
            }
        }
        // 現在のビューはdirty範囲だけ設定（キャッシュは無効化しない）
        if (current_view.dirty_start) |ds| {
            current_view.dirty_start = @min(ds, start_line);
        } else {
            current_view.dirty_start = start_line;
        }
        if (end_line) |e| {
            if (current_view.dirty_end) |de| {
                current_view.dirty_end = @max(de, e);
            } else {
                current_view.dirty_end = e;
            }
        } else {
            current_view.dirty_end = null;
        }
    }

    /// 読み取り専用チェック（編集前に呼ぶ）
    /// 読み取り専用ならエラー表示してtrueを返す
    pub fn isReadOnly(self: *Editor) bool {
        if (self.getCurrentBuffer().file.readonly) {
            self.getCurrentView().setError(config.Messages.BUFFER_READONLY);
            return true;
        }
        return false;
    }

    /// プロンプトを設定（スタックバッファ使用でヒープ確保を回避）
    pub fn setPrompt(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        // 固定バッファでフォーマット（View.setErrorも固定バッファにコピーするため、ヒープ確保不要）
        var buf: [512]u8 = undefined;
        const prompt = std.fmt.bufPrint(&buf, fmt, args) catch {
            // バッファが足りない場合はフォールバック
            self.getCurrentView().setError("...");
            return;
        };
        self.getCurrentView().setError(prompt);
    }

    /// エラーを表示（anyerror対応）
    fn showError(self: *Editor, err: anyerror) void {
        self.getCurrentView().setError(@errorName(err));
    }

    /// ミニバッファ入力をキャンセルしてnormalモードに戻る
    fn cancelInput(self: *Editor) void {
        self.mode = .normal;
        self.clearInputBuffer();
        self.clearPendingFilename(); // メモリリーク防止
        self.completion_shown = false; // 補完表示フラグをリセット
        self.getCurrentView().clearError();
    }

    /// 保存モードのキャンセル（quit_after_saveもリセット）
    fn cancelSaveInput(self: *Editor) void {
        self.quit_after_save = false;
        self.cancelInput();
    }

    /// Query Replaceモードのキャンセル（履歴は保持）
    fn cancelQueryReplaceInput(self: *Editor) void {
        self.cancelInput();
    }

    /// 置換文字列入力モードのプロンプト設定
    fn enterReplacementMode(self: *Editor) void {
        const search = self.replace_search orelse return;
        const prefix = config.QueryReplace.getPrefix(self.is_regex_replace);
        const prefix_len = prefix.len; // ASCII only
        if (self.replace_replacement) |prev| {
            self.setPrompt("{s}{s} with (default {s}): ", .{ prefix, search, prev });
            // prefix + search + " with (default " + prev + "): "
            self.prompt_prefix_len = prefix_len + stringDisplayWidth(search) + 15 + stringDisplayWidth(prev) + 3;
        } else {
            self.setPrompt("{s}{s} with: ", .{ prefix, search });
            self.prompt_prefix_len = prefix_len + stringDisplayWidth(search) + 7;
        }
    }

    /// C-g または Escape キーかどうか判定
    inline fn isCancelKey(key: input.Key) bool {
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
        self.search_service.history.resetNavigation();
        self.getCurrentView().setSearchHighlight(null);
        self.getCurrentView().clearError();
        self.getCurrentView().markFullRedraw();
    }

    /// インクリメンタルサーチを開始（C-s / C-r）
    fn startIsearch(self: *Editor, forward: bool) !void {
        self.is_regex_search = false; // リテラル検索
        self.startIsearchCommon(forward);
    }

    /// 正規表現インクリメンタルサーチを開始（C-M-s / C-M-r）
    fn startRegexIsearch(self: *Editor, forward: bool) !void {
        self.is_regex_search = true; // 正規表現検索
        self.startIsearchCommon(forward);
    }

    /// Query Replace開始（M-%）
    fn startQueryReplace(self: *Editor) void {
        // 読み取り専用バッファでは置換を禁止
        if (self.isReadOnly()) {
            self.getCurrentView().setError(config.Messages.BUFFER_READONLY);
            return;
        }
        self.is_regex_replace = false;
        self.startQueryReplaceCommon();
    }

    /// 正規表現Query Replace開始（C-M-%）
    fn startRegexQueryReplace(self: *Editor) !void {
        // 読み取り専用バッファでは置換を禁止
        if (self.isReadOnly()) {
            self.getCurrentView().setError(config.Messages.BUFFER_READONLY);
            return;
        }
        self.is_regex_replace = true;
        self.startQueryReplaceCommon();
    }

    /// Query Replace共通処理
    fn startQueryReplaceCommon(self: *Editor) void {
        self.mode = .query_replace_input_search;
        self.clearInputBuffer();
        self.replace_match_count = 0;

        const prompt = config.QueryReplace.getPrompt(self.is_regex_replace);
        const prompt_base = prompt[0 .. prompt.len - 2]; // ": "を除去

        // 前回の値があればデフォルトとして表示
        if (self.replace_search) |prev| {
            self.setPrompt("{s} (default {s}): ", .{ prompt_base, prev });
            // " (default ": 10文字 + "): ": 3文字 + 1(末尾調整) = 14
            self.prompt_prefix_len = prompt_base.len + 14 + stringDisplayWidth(prev);
        } else {
            self.prompt_prefix_len = prompt.len;
            self.setPrompt("{s}", .{prompt});
        }
    }

    /// I-search共通処理
    fn startIsearchCommon(self: *Editor, forward: bool) void {
        // 検索モードに入る
        self.mode = if (forward) .isearch_forward else .isearch_backward;
        self.search_start_pos = self.getCurrentView().getCursorBufferPos();

        const prefix = self.getIsearchPrefix(forward);
        const prefix_len = stringDisplayWidth(prefix);

        if (self.last_search) |search_str| {
            // 前回の検索パターンがあれば、それで検索を実行
            self.minibuffer.setContent(search_str) catch |err| {
                self.showError(err);
                return;
            };
            self.getCurrentView().setSearchHighlightEx(search_str, self.is_regex_search);
            self.performSearch(forward, true) catch |err| {
                self.showError(err);
            };
            self.prompt_prefix_len = prefix_len;
            self.setPrompt("{s}{s}", .{ prefix, search_str });
        } else {
            // 新規検索モードに入る
            self.clearInputBuffer();
            self.prompt_prefix_len = prefix_len;
            self.getCurrentView().setError(prefix);
        }
    }

    /// I-searchプロンプトのプレフィックスを取得
    fn getIsearchPrefix(self: *const Editor, forward: bool) []const u8 {
        return if (self.is_regex_search)
            (if (forward) config.Messages.ISEARCH_REGEX_FORWARD else config.Messages.ISEARCH_REGEX_BACKWARD)
        else
            (if (forward) config.Messages.ISEARCH_FORWARD else config.Messages.ISEARCH_BACKWARD);
    }

    /// I-searchプロンプトを更新（ミニバッファ内容付き）
    fn updateIsearchPrompt(self: *Editor, forward: bool) void {
        const prefix = self.getIsearchPrefix(forward);
        self.prompt_prefix_len = stringDisplayWidth(prefix);
        self.setPrompt("{s}{s}", .{ prefix, self.minibuffer.getContent() });
    }

    /// I-searchハイライトを更新
    fn updateIsearchHighlight(self: *Editor) void {
        const content = self.minibuffer.getContent();
        if (content.len > 0) {
            self.getCurrentView().setSearchHighlightEx(content, self.is_regex_search);
        } else {
            self.getCurrentView().setSearchHighlight(null);
        }
    }

    /// last_searchを更新（古い値があれば解放）
    fn updateLastSearch(self: *Editor, new_value: []const u8) void {
        const new_search = self.allocator.dupe(u8, new_value) catch return;
        if (self.last_search) |old_search| {
            self.allocator.free(old_search);
        }
        self.last_search = new_search;
    }

    /// バッファ閉じる確認モードの文字処理
    fn handleKillBufferConfirmChar(self: *Editor, cp: u21) void {
        const c = unicode.toAsciiChar(cp);
        switch (c) {
            'y', 'Y' => {
                const buffer_id = self.getCurrentBuffer().id;
                self.closeBuffer(buffer_id) catch |err| self.showError(err);
                self.resetToNormal();
            },
            'n', 'N' => {
                self.resetToNormal();
            },
            else => self.getCurrentView().setError(config.Messages.CONFIRM_YES_NO),
        }
    }

    /// 確認モードの共通キーディスパッチ
    /// C-gとEscapeでキャンセル、それ以外はハンドラーに委譲
    fn dispatchConfirmKey(self: *Editor, key: input.Key, handler: *const fn (*Editor, u21) void) void {
        switch (key) {
            .char => |c| handler(self, c),
            .codepoint => |cp| handler(self, unicode.normalizeFullwidth(cp)),
            .ctrl => |c| {
                if (c == 'g') self.resetToNormal();
            },
            .escape => self.resetToNormal(),
            else => {},
        }
    }

    /// 終了確認モードの文字処理
    fn handleQuitConfirmChar(self: *Editor, cp: u21) void {
        const c = unicode.toAsciiChar(cp);
        switch (c) {
            'y', 'Y' => {
                const buffer_state = self.getCurrentBuffer();
                if (buffer_state.file.filename == null) {
                    self.mode = .filename_input;
                    self.quit_after_save = true;
                    self.minibuffer.clear();
                    self.getCurrentView().setError(config.Messages.PROMPT_WRITE_FILE);
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
            else => self.getCurrentView().setError(config.Messages.CONFIRM_YES_NO_CANCEL),
        }
    }

    /// M-x exit確認モードの文字処理
    fn handleExitConfirmChar(self: *Editor, cp: u21) void {
        const c = unicode.toAsciiChar(cp);
        switch (c) {
            'y', 'Y' => self.running = false,
            'n', 'N' => self.resetToNormal(),
            else => self.getCurrentView().setError("Exit? (y)es (n)o"),
        }
    }

    /// ファイル上書き確認モードの文字処理
    fn handleOverwriteConfirmChar(self: *Editor, cp: u21) void {
        const c = unicode.toAsciiChar(cp);
        switch (c) {
            'y', 'Y' => {
                // pending_filenameをbuffer_state.file.filenameに設定
                if (self.pending_filename) |pending| {
                    const buffer_state = self.getCurrentBuffer();
                    buffer_state.file.setFilename(pending) catch {
                        self.getCurrentView().setError(config.Messages.MEMORY_ALLOCATION_FAILED);
                        self.clearPendingFilename();
                        self.mode = .normal;
                        return;
                    };
                    self.clearPendingFilename();
                }
                self.saveFile() catch |err| {
                    self.showError(err);
                    self.mode = .normal;
                    return;
                };
                self.resetToNormal();
                if (self.quit_after_save) {
                    self.quit_after_save = false;
                    self.running = false;
                }
            },
            'n', 'N' => {
                // キャンセル時はpending_filenameをクリア
                self.clearPendingFilename();
                self.resetToNormal();
            },
            else => self.getCurrentView().setError(config.Messages.CONFIRM_OVERWRITE),
        }
    }

    /// pending_filenameをクリアする
    fn clearPendingFilename(self: *Editor) void {
        if (self.pending_filename) |pending| {
            self.allocator.free(pending);
            self.pending_filename = null;
        }
    }

    /// 置換完了メッセージを表示してノーマルモードに戻る
    fn finishReplace(self: *Editor) void {
        self.mode = .normal;
        self.getCurrentView().setSearchHighlight(null); // 検索ハイライトをクリア
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
            self.getCurrentView().setError(config.Messages.REPLACE_PROMPT);
        }
    }

    /// 置換確認モードの文字処理
    fn handleReplaceConfirmChar(self: *Editor, cp: u21) !void {
        const c = unicode.toAsciiChar(cp);
        const search = self.replace_search orelse {
            self.mode = .normal;
            self.getCurrentView().setError(config.Messages.NO_SEARCH_STRING);
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
                // 残りすべてを置換（Undoグループ化）
                // 注意：「残り」は現在位置以降のみ。ラップアラウンドして
                // 先頭に戻った場合は終了（スキップした箇所を置換しない）
                const editing_ctx = self.getCurrentBuffer().editing_ctx;
                _ = editing_ctx.beginUndoGroup();
                defer editing_ctx.endUndoGroup();

                // 開始位置を記録（ラップアラウンド検出用）
                const start_pos = self.getCurrentView().getCursorBufferPos();

                try self.replaceCurrentMatch();
                var pos = self.getCurrentView().getCursorBufferPos();
                var prev_pos = start_pos;

                var loop_count: usize = 0;
                const buf_len = self.getCurrentBufferContent().len();
                const max_iterations = buf_len + 1; // 安全上限
                while (loop_count < max_iterations) : (loop_count += 1) {
                    const found = try self.findNextMatch(search, pos);
                    if (!found) break;

                    const new_pos = self.getCurrentView().getCursorBufferPos();
                    // ラップアラウンドで開始位置より前に戻った場合は終了
                    if (new_pos < prev_pos and new_pos < start_pos) {
                        break;
                    }
                    // 位置が進まない場合は無限ループ防止（空マッチ等）
                    if (new_pos == prev_pos and loop_count > 0) {
                        break;
                    }

                    try self.replaceCurrentMatch();
                    prev_pos = new_pos;
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
                self.getCurrentView().setError(config.Messages.CONFIRM_REPLACE);
            },
        }
    }

    /// 検索文字列にコードポイントを追加して検索実行
    fn addSearchChar(self: *Editor, cp: u21, is_forward: bool) !void {
        // UTF-8にエンコードして追加
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.minibuffer.insertAtCursor(buf[0..len]);

        // プロンプトとハイライトを更新
        self.updateIsearchPrompt(is_forward);
        self.updateIsearchHighlight();

        // 検索開始位置からやり直す（パターンが変わったので最初から検索）
        if (self.minibuffer.hasContent()) {
            if (self.search_start_pos) |start_pos| {
                self.setCursorToPos(start_pos);
            }
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

    /// ベース名（ファイル名部分のみ）でバッファを検索
    /// C-x bでの補完用：test.txtと入力して/path/to/test.txtにマッチさせる
    fn findBufferByBasename(self: *Editor, basename: []const u8) ?*BufferState {
        for (self.buffer_manager.iterator()) |buf| {
            if (buf.file.filename) |filename| {
                // パスからファイル名部分を抽出（クロスプラットフォーム対応）
                const buf_basename = std.fs.path.basename(filename);
                if (std.mem.eql(u8, buf_basename, basename)) {
                    return buf;
                }
            }
        }
        return null;
    }

    /// 特殊バッファ（*Command*, *Buffer List*, *Help*等）を名前で検索
    fn findBufferBySpecialName(self: *Editor, name: []const u8) ?*BufferState {
        for (self.buffer_manager.iterator()) |buf| {
            if (buf.file.filename) |fname| {
                if (std.mem.eql(u8, fname, name)) {
                    return buf;
                }
            }
        }
        return null;
    }

    /// 特殊バッファを取得または作成
    /// 既存バッファがあればそれを返し、なければ新規作成
    fn getOrCreateSpecialBuffer(self: *Editor, name: []const u8) !*BufferState {
        if (self.findBufferBySpecialName(name)) |buf| {
            return buf;
        }
        const new_buffer = try self.createNewBuffer();
        new_buffer.file.filename = try self.allocator.dupe(u8, name);
        new_buffer.file.readonly = true;
        return new_buffer;
    }

    // ========================================
    // ミニバッファ（ステータスバー入力）操作
    // Minibufferサービスへの委譲
    // ========================================

    /// ミニバッファをクリア
    fn clearInputBuffer(self: *Editor) void {
        self.minibuffer.clear();
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
            .query_replace_confirm,
            .shell_command,
            .mx_command,
            .mx_key_describe,
            // macro_repeat はミニバッファ入力モードではない（eキー待機のみ）
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
                    'y' => {
                        // kill ringからペースト
                        if (self.kill_ring.get()) |text| {
                            try self.minibuffer.insertAtCursor(text);
                        }
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
    /// プレフィックスが同じ場合はstringDisplayWidth計算をスキップ（最適化）
    fn updateMinibufferPrompt(self: *Editor, prefix: []const u8) void {
        // プレフィックスが変わった場合のみ再計算
        if (self.cached_prompt_prefix == null or self.cached_prompt_prefix.?.ptr != prefix.ptr) {
            self.prompt_prefix_len = stringDisplayWidth(prefix);
            self.cached_prompt_prefix = prefix;
        }
        self.setPrompt("{s}{s}", .{ prefix, self.minibuffer.getContent() });
    }

    /// ミニバッファのカーソル位置を表示幅（列数）で計算
    fn getMinibufferCursorColumn(self: *Editor) usize {
        const items = self.minibuffer.getContent();
        const tab_width: usize = self.getCurrentView().getTabWidth();
        var col: usize = 0;
        var pos: usize = 0;

        while (pos < self.minibuffer.cursor and pos < items.len) {
            const first_byte = items[pos];
            if (unicode.isAsciiByte(first_byte)) {
                // ASCII
                if (first_byte == '\t') {
                    col = (col / tab_width + 1) * tab_width; // タブ展開
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

    /// 文字列の表示幅（カラム数）を計算
    const stringDisplayWidth = unicode.stringDisplayWidth;

    /// Query Replace プロンプトの表示幅を計算
    /// "Query replace (regexp) <search> with: " の表示幅を返す
    fn calculateReplacementPromptWidth(self: *Editor) usize {
        const prefix = config.QueryReplace.getPrefix(self.is_regex_replace);
        const prefix_width = stringDisplayWidth(prefix);
        if (self.replace_search) |search| {
            return prefix_width + stringDisplayWidth(search) + 7; // " with: " = 7
        } else {
            return prefix_width + 6; // "with: " = 6
        }
    }

    /// *Command* バッファを取得または作成
    fn getOrCreateCommandBuffer(self: *Editor) !*BufferState {
        return self.getOrCreateSpecialBuffer(config.Messages.BUFFER_COMMAND);
    }

    /// *Command* バッファを表示するウィンドウを探す
    fn findCommandBufferWindow(self: *Editor) ?usize {
        const windows = self.window_manager.iterator();
        for (windows, 0..) |window, idx| {
            if (self.findBufferById(window.buffer_id)) |buf| {
                if (buf.file.filename) |name| {
                    if (std.mem.eql(u8, name, config.Messages.BUFFER_COMMAND)) return idx;
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
        // 縮めたウィンドウのViewにビューポート変更を通知
        current_window.view.setViewport(current_window.width, current_window.height);
        current_window.view.markFullRedraw();

        // 新しいウィンドウを下部に作成（WindowManager経由）
        const new_window = try self.window_manager.createWindow(
            cmd_buffer.id,
            current_window.x,
            current_window.y + current_window.height,
            current_window.width,
            cmd_height,
        );
        // View.init失敗時にウィンドウを削除して元の高さを復元
        errdefer {
            _ = self.window_manager.windows.pop();
            current_window.height = old_height;
            current_window.view.setViewport(current_window.width, old_height);
        }

        new_window.view = try View.init(self.allocator, cmd_buffer.editing_ctx.buffer);
        // 言語検出とビューポートを設定
        setupWindowView(new_window, cmd_buffer);

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
        window.mark_pos = null; // 前のバッファのマークをクリア

        // 言語検出とビューポートを設定
        setupWindowView(window, buffer_state);
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
                // 新しいViewを先に作成（失敗時に古いViewを無効にしない）
                const new_view = try View.init(self.allocator, next_buffer.editing_ctx.buffer);
                // 成功したら古いViewを解放
                window.view.deinit(self.allocator);
                window.view = new_view;
                window.buffer_id = next_buffer.id;
                window.mark_pos = null; // 前のバッファのマークをクリア
                // 言語検出とビューポートを設定
                setupWindowView(window, next_buffer);
            }
        }

        // バッファを削除（BufferManager経由）
        _ = self.buffer_manager.deleteBuffer(buffer_id);
    }

    /// バッファ一覧を表示（C-x C-b）
    pub fn showBufferList(self: *Editor) !void {
        // バッファ一覧のテキストを生成
        var list_text = std.ArrayList(u8){};
        defer list_text.deinit(self.allocator);

        const writer = list_text.writer(self.allocator);
        try writer.writeAll("  MR Buffer           Size  File\n");
        try writer.writeAll("  -- ------           ----  ----\n");

        for (self.buffer_manager.iterator()) |buf| {
            // 特殊バッファは除外
            if (buf.file.filename) |fname| {
                if (std.mem.eql(u8, fname, config.Messages.BUFFER_LIST)) continue;
                if (std.mem.eql(u8, fname, help.help_buffer_name)) continue;
            }

            // 変更フラグ
            const mod_char: u8 = if (buf.editing_ctx.modified) '*' else '.';
            // 読み取り専用フラグ
            const ro_char: u8 = if (buf.file.readonly) '%' else '.';

            // バッファ名
            const buf_name = buf.file.filename orelse config.Messages.BUFFER_SCRATCH;

            // サイズ
            const size = buf.editing_ctx.buffer.total_len;

            // フォーマットして追加（バッファ名は切り詰めない）
            try std.fmt.format(writer, "  {c}{c} {s} {d:>6}  {s}\n", .{
                mod_char,
                ro_char,
                buf_name,
                size,
                buf.file.filename orelse "",
            });
        }

        // "*Buffer List*"バッファを取得または作成
        const buf = try self.getOrCreateSpecialBuffer(config.Messages.BUFFER_LIST);

        // バッファの内容をクリアして新しい一覧を挿入
        if (buf.editing_ctx.buffer.total_len > 0) {
            try buf.editing_ctx.buffer.delete(0, buf.editing_ctx.buffer.total_len);
        }
        try buf.editing_ctx.buffer.insertSlice(0, list_text.items);
        buf.editing_ctx.modified = false; // バッファ一覧は変更扱いにしない

        // バッファ一覧に切り替え
        try self.switchToBuffer(buf.id);
    }

    /// ヘルプ画面を表示
    pub fn showHelp(self: *Editor) !void {
        // "*Help*"バッファを取得または作成
        const buf = try self.getOrCreateSpecialBuffer(help.help_buffer_name);

        // バッファの内容をクリアしてヘルプを挿入
        if (buf.editing_ctx.buffer.total_len > 0) {
            try buf.editing_ctx.buffer.delete(0, buf.editing_ctx.buffer.total_len);
        }
        try buf.editing_ctx.buffer.insertSlice(0, help.help_text);
        buf.editing_ctx.modified = false;

        // ヘルプバッファに切り替え
        try self.switchToBuffer(buf.id);

        // カーソルを先頭に
        const view = self.getCurrentView();
        view.top_line = 0;
        view.cursor_x = 0;
        view.cursor_y = 0;
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

        // 現在行の範囲を取得（getLineRangeはend=改行位置を返す）
        const line_range = buffer.getLineRange(cursor_line) orelse {
            self.getCurrentView().setError("Invalid line");
            return;
        };
        const line_start = line_range.start;

        // 行の長さを計算（getLineRangeのendは改行位置なので、そのまま使用）
        const line_len = if (line_range.end > line_start) line_range.end - line_start else 0;

        if (line_len == 0) {
            self.getCurrentView().setError("Empty line");
            return;
        }

        // 行のテキストを取得
        const line = try buffer.getRange(self.allocator, line_start, line_len);
        defer self.allocator.free(line);

        // バッファ名を抽出
        // フォーマット: "  {c}{c} {s} {d:>6}  {s}\n"
        // 最後の列がファイルパス（= バッファ名）なので、右から解析する
        if (line.len < 5) {
            self.getCurrentView().setError("Invalid line format");
            return;
        }

        // 右から "  " (2スペース) を探してパス列を特定
        // パス列の内容がバッファ名（ファイル名）
        var buf_name: []const u8 = "";

        // 末尾から2スペースを探す（サイズ列とパス列の区切り）
        var i: usize = line.len;
        while (i >= 2) {
            i -= 1;
            if (i >= 1 and line[i - 1] == ' ' and line[i] == ' ') {
                // "  " の後がパス列
                const path_start = i + 1;
                if (path_start < line.len) {
                    buf_name = line[path_start..];
                    // 末尾の改行を除去
                    while (buf_name.len > 0 and (buf_name[buf_name.len - 1] == '\n' or buf_name[buf_name.len - 1] == '\r')) {
                        buf_name = buf_name[0 .. buf_name.len - 1];
                    }
                }
                break;
            }
        }

        // パス列が空の場合は *scratch* バッファ
        if (buf_name.len == 0) {
            // 位置5からバッファ名を抽出（*scratch*など）
            const name_start: usize = 5;
            if (name_start >= line.len) {
                self.getCurrentView().setError("Invalid line format");
                return;
            }
            // サイズ列の前までを取得
            var name_end = name_start;
            while (name_end < line.len and !(line[name_end] == ' ' and name_end + 1 < line.len and line[name_end + 1] >= '0' and line[name_end + 1] <= '9')) {
                name_end += 1;
            }
            buf_name = line[name_start..name_end];
            // 末尾の空白を除去
            while (buf_name.len > 0 and buf_name[buf_name.len - 1] == ' ') {
                buf_name = buf_name[0 .. buf_name.len - 1];
            }
        }

        if (buf_name.len == 0) {
            self.getCurrentView().setError("No buffer name found");
            return;
        }

        // バッファを検索
        for (self.buffer_manager.iterator()) |buf| {
            const name = buf.file.filename orelse config.Messages.BUFFER_SCRATCH;
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

        // 新しいウィンドウにViewを設定し、言語検出とビューポートを設定
        result.new_window.view = new_view;
        setupWindowView(result.new_window, buffer_state);
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

        // Loading表示を省略（ほとんどのファイルは即座にロードされるため）
        // 大きなファイルでも最初のレンダリングで結果が見える

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

        // 古いファイル名を解放して新しいファイル名を設定（filename_normalizedもリセット）
        buffer_state.file.setFilenameOwned(new_filename);
        // 正規化パスは遅延初期化: findByFilename()で必要時に計算

        // Undo/Redoスタックをクリア
        buffer_state.editing_ctx.clearUndoHistory();
        buffer_state.editing_ctx.modified = false;

        // 言語検出（ファイル名とコンテンツ先頭から判定）
        var preview_buf: [512]u8 = undefined;
        const content_preview = buffer_state.editing_ctx.buffer.getContentPreview(&preview_buf);
        view.detectLanguage(path, content_preview);

        // ファイルの最終更新時刻を記録（Buffer.loadFromFileで既に取得済みなので再オープン不要）
        buffer_state.file.mtime = buffer_state.editing_ctx.buffer.loaded_mtime;

        // Loadingメッセージをクリア
        view.clearError();
    }

    pub fn saveFile(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        const view = self.getCurrentView();

        if (buffer_state.file.filename) |path| {
            // 外部変更チェック（新規ファイルの場合はスキップ）
            if (buffer_state.file.mtime) |original_mtime| {
                const maybe_file = std.fs.cwd().openFile(path, .{}) catch |err| blk: {
                    // ファイルが存在しない場合は外部で削除された
                    if (err == error.FileNotFound) {
                        view.setError(config.Messages.WARNING_FILE_DELETED);
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
                        view.setError(config.Messages.WARNING_FILE_MODIFIED);
                        // 続行して上書きする（ユーザーの編集を優先）
                    }
                }
            }

            const save_warning = try buffer_state.editing_ctx.buffer.saveToFile(path);
            // 保存時点を記録
            buffer_state.editing_ctx.modified = false;
            buffer_state.editing_ctx.savepoint = buffer_state.editing_ctx.undo_stack.items.len;

            // 保存後に新しい mtime を記録
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            const stat = try file.stat();
            buffer_state.file.mtime = stat.mtime;

            // 保存後にfilename_normalizedを更新（新規ファイル対応）
            if (buffer_state.file.filename_normalized == null) {
                buffer_state.file.filename_normalized = std.fs.cwd().realpathAlloc(self.allocator, path) catch null;
            }

            // 所有権変更警告がある場合は表示
            if (save_warning) |warning| {
                view.setError(warning);
            }
        }
    }

    /// ファイル名補完を実行
    /// 戻り値: 補完が行われた場合はtrue
    fn completeFilename(self: *Editor, prompt: []const u8) !bool {
        const current = self.minibuffer.getContent();
        if (current.len == 0) return false;

        // ディレクトリ部分とプレフィックス部分を分離
        var dir_path: []const u8 = undefined;
        var prefix: []const u8 = undefined;

        if (std.mem.lastIndexOfScalar(u8, current, '/')) |last_slash| {
            dir_path = if (last_slash == 0) "/" else current[0..last_slash];
            prefix = current[last_slash + 1 ..];
        } else {
            dir_path = ".";
            prefix = current;
        }

        // ディレクトリを開く
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return false;
        };
        defer dir.close();

        // マッチするエントリを収集
        var matches = try std.ArrayList([]const u8).initCapacity(self.allocator, 32);
        defer {
            for (matches.items) |item| {
                self.allocator.free(item);
            }
            matches.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (prefix.len == 0 or std.mem.startsWith(u8, entry.name, prefix)) {
                // ディレクトリなら末尾に/を追加
                const name = if (entry.kind == .directory)
                    try std.fmt.allocPrint(self.allocator, "{s}/", .{entry.name})
                else
                    try self.allocator.dupe(u8, entry.name);
                errdefer self.allocator.free(name); // append失敗時のリーク防止
                try matches.append(self.allocator, name);
            }
        }

        if (matches.items.len == 0) {
            self.getCurrentView().setError(config.Messages.NO_MATCH);
            self.completion_shown = true; // No matchもカーソル非表示
            return false;
        }

        // ソート（アルファベット順）
        std.mem.sort([]const u8, matches.items, {}, struct {
            fn cmp(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.cmp);

        if (matches.items.len == 1) {
            // 一意のマッチ: 完全補完
            const match = matches.items[0];
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const new_path = if (std.mem.eql(u8, dir_path, "."))
                match
            else if (std.mem.eql(u8, dir_path, "/"))
                try std.fmt.bufPrint(&path_buf, "/{s}", .{match})
            else
                try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, match });

            try self.minibuffer.setContent(new_path);
            // プロンプトを更新（clearError()ではなく）
            self.updateMinibufferPrompt(prompt);
            self.completion_shown = false;
        } else {
            // 複数マッチ: 共通プレフィックスを補完して候補を表示
            const common = unicode.findCommonPrefix(matches.items);

            if (common.len > prefix.len) {
                // 共通部分で補完
                var path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const new_path = if (std.mem.eql(u8, dir_path, "."))
                    common
                else if (std.mem.eql(u8, dir_path, "/"))
                    try std.fmt.bufPrint(&path_buf, "/{s}", .{common})
                else
                    try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, common });

                try self.minibuffer.setContent(new_path);
            }

            // 候補を表示（最大5件）
            var msg_buf: [256]u8 = undefined;
            var msg_len: usize = 0;
            const max_show: usize = 5;
            for (matches.items, 0..) |match, i| {
                if (i >= max_show) {
                    const more = std.fmt.bufPrint(msg_buf[msg_len..], " +{d} more", .{matches.items.len - max_show}) catch break;
                    msg_len += more.len;
                    break;
                }
                if (i > 0) {
                    if (msg_len < msg_buf.len) {
                        msg_buf[msg_len] = ' ';
                        msg_len += 1;
                    }
                }
                const written = std.fmt.bufPrint(msg_buf[msg_len..], "{s}", .{match}) catch break;
                msg_len += written.len;
            }
            self.getCurrentView().setError(msg_buf[0..msg_len]);
            // 候補表示中フラグを立てる（Enterを無効化）
            self.completion_shown = true;
        }

        // プロンプトを再描画
        self.minibuffer.setPrompt(prompt);
        return true;
    }

    /// 全ウィンドウをレンダリング
    fn renderAllWindows(self: *Editor) !void {
        // 選択範囲を先に更新（needsRedraw判定の前に必要）
        for (self.window_manager.iterator(), 0..) |*window, idx| {
            const is_active = (idx == self.window_manager.current_window_idx);
            if (is_active and window.mark_pos != null) {
                const cursor_pos = window.view.getCursorBufferPos();
                const mark = window.mark_pos.?;
                const sel_start = @min(mark, cursor_pos);
                const sel_end = @max(mark, cursor_pos);
                window.view.setSelection(sel_start, sel_end);
            } else {
                window.view.clearSelection();
            }
        }

        // 描画が必要かチェック（全ウィンドウがdirtyでないならスキップ）
        var needs_render = false;
        for (self.window_manager.iterator()) |*window| {
            if (window.view.needsRedraw()) {
                needs_render = true;
                break;
            }
        }

        // 描画が不要でもカーソル位置とステータスバーは更新する
        if (!needs_render) {
            const window = self.window_manager.getCurrentWindow();
            const buffer_state = self.findBufferById(window.buffer_id) orelse {
                const pos = window.view.getCursorScreenPosition(window.x, window.y, window.width);
                try self.terminal.moveCursor(pos.row, pos.col);
                try self.terminal.flush();
                return;
            };
            const buffer = buffer_state.editing_ctx.buffer;
            // ステータスバーのみ更新（カーソル位置を表示するため）
            try window.view.renderStatusBarAt(
                &self.terminal,
                window.x,
                window.y + window.height - 1,
                window.width,
                buffer_state.editing_ctx.modified,
                buffer_state.file.readonly,
                self.overwrite_mode,
                buffer.detected_line_ending,
                buffer.detected_encoding,
                buffer_state.file.filename,
            );
            // カーソル位置を更新
            const pos = window.view.getCursorScreenPosition(window.x, window.y, window.width);
            try self.terminal.moveCursor(pos.row, pos.col);
            try self.terminal.flush();
            return;
        }

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
                buffer_state.file.readonly,
                self.overwrite_mode,
                buffer.detected_line_ending,
                buffer.detected_encoding,
                buffer_state.file.filename,
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
        // ミニバッファモード中は別途カーソル位置を調整するのでここでは表示しない
        if (has_active and !self.isMinibufferMode()) {
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
        // 入力ソースを決定（tty_fileがあればそれを使用、なければstdin）
        const input_file = if (self.tty_file) |tty| tty else std.fs.File{ .handle = std.posix.STDIN_FILENO };
        // バッファ付き入力リーダー（ペースト時等の大量入力でシステムコールを削減）
        var input_reader = input.InputReader.init(input_file);

        // 効率的なI/O待機（epoll/kqueue）
        // ポーリングではなくイベント駆動で、入力待機中はCPUを消費しない
        var poll = poller.Poller.init(input_file.handle) catch {
            // Poller初期化失敗: 従来のVTIMEポーリングにフォールバック
            return self.mainLoop(&input_reader, null);
        };
        defer poll.deinit();

        try self.mainLoop(&input_reader, &poll);
    }

    /// メインループ（Pollerの有無で動作を切り替え）
    fn mainLoop(self: *Editor, input_reader: *input.InputReader, poll: ?*poller.Poller) !void {
        // Pollerが致命的エラー（EBADF等）を返した場合、VTIMEフォールバックに移行
        var poller_disabled = false;
        while (self.running) {
            // 終了シグナルチェック
            if (self.terminal.checkTerminate()) break;

            // リサイズチェック
            if (self.terminal.checkResize()) {
                try self.recalculateWindowSizes();
            }

            // シェルコマンド実行中はその出力をポーリング（描画前に処理）
            if (self.mode == .shell_running) {
                try self.pollShellCommand();
            }

            // カーソル位置補正と画面描画
            self.clampCursorPosition();
            try self.renderAllWindows();

            // ミニバッファ入力中はカーソル位置を調整
            // ただし補完候補表示中はカーソルを隠す
            if (self.isMinibufferMode() and !self.completion_shown) {
                const window = self.getCurrentWindow();
                // +1 はステータスバー描画時の先頭スペース分
                const cursor_col = 1 + self.prompt_prefix_len + self.getMinibufferCursorColumn();
                // 現在のウィンドウのステータスバー行（ウィンドウの最下行）
                const status_row = window.y + window.height - 1;
                try self.terminal.moveCursor(status_row, cursor_col);
                try self.terminal.showCursor();
                try self.terminal.flush();
            }

            // 入力を待機（Pollerがある場合はイベント駆動、なければVTIMEポーリング）
            if (poll) |p| {
                // Pollerが致命的エラーで無効化された場合はスキップ
                if (poller_disabled) {
                    // VTIMEフォールバック: 何もしない（VTIMEで入力を待つ）
                } else if (!input_reader.hasData()) {
                    // 重要: InputReaderのバッファにデータがあればkqueueをスキップ
                    // （バッファリングにより、カーネルバッファは空でもデータが残っている可能性がある）

                    // 動的タイムアウト: シェル実行中は短く（スピナー更新を速く）
                    const wait_timeout: u32 = if (self.mode == .shell_running)
                        25 // シェル実行中: 25ms（スピナー4fps）
                    else if (self.shell_service.isRunning())
                        50 // シェル準備中: 50ms
                    else
                        100; // 通常: 100ms
                    const poll_result = p.wait(wait_timeout);
                    if (poll_result == .signal) {
                        // SIGWINCH等のシグナル: ループ先頭に戻ってリサイズチェック
                        continue;
                    }
                    if (poll_result == .fatal_error) {
                        // 致命的エラー（EBADF/EINVAL等）: Pollerを無効化してVTIMEフォールバック
                        poller_disabled = true;
                        continue;
                    }
                    // タイムアウトでも入力チェックは行う（VTIMEモードで読み取り可能な場合がある）
                }
            }

            // キー入力を処理（バッチ処理で高速タイピング/ペースト対応）
            // バッファが空になるまで全キーを処理（制限なし）
            var keys_processed: usize = 0;
            while (true) {
                if (try input.readKeyFromReader(input_reader)) |key| {
                    keys_processed += 1;
                    // ミニバッファモード中はプロンプトを維持
                    if (!self.isMinibufferMode()) {
                        self.getCurrentView().clearError();
                    }
                    self.processKey(key) catch |err| {
                        const err_name = @errorName(err);
                        self.getCurrentView().setError(err_name);
                    };
                    // バッファにまだデータがあれば続行、なければ終了
                    if (!input_reader.hasData()) break;
                } else break;
            }

            // 【投機的即時レンダリング】キー処理後に変更があれば即座に再描画
            // 従来: render → wait → process → (次フレームで) render (16ms遅延)
            // 改善: render → wait → process → render (即座、0ms遅延)
            // 注意: running=falseの場合はスキップ（終了処理中に余計な描画をしない）
            if (self.running and keys_processed > 0 and self.anyWindowNeedsRedraw()) {
                self.clampCursorPosition();
                try self.renderAllWindows();
            }
        }
    }

    /// いずれかのウィンドウが再描画を必要としているかチェック
    fn anyWindowNeedsRedraw(self: *Editor) bool {
        for (self.window_manager.iterator()) |*window| {
            if (window.view.needsRedraw()) return true;
        }
        return false;
    }

    /// バッファから指定範囲のテキストを取得（削除前に使用）
    /// Buffer.extractTextに委譲（O(pieces + len)で効率的に取得）
    pub fn extractText(self: *Editor, pos: usize, len: usize) ![]u8 {
        const buffer = self.getCurrentBufferContent();
        return buffer.extractText(self.allocator, pos, len);
    }

    /// 再利用可能バッファを使ってテキストを抽出（正規表現検索用）
    /// ループ内での alloc/free を削減してパフォーマンス向上
    fn extractTextReusable(self: *Editor, pos: usize, len: usize) ![]const u8 {
        const buffer = self.getCurrentBufferContent();
        const buf_len = buffer.len();

        if (pos >= buf_len) {
            return &[_]u8{};
        }

        const actual_len = @min(len, buf_len - pos);
        if (actual_len == 0) {
            return &[_]u8{};
        }

        // 必要に応じてバッファを拡大（1MB + 余裕）
        if (self.search_chunk_capacity < actual_len) {
            const new_capacity = actual_len + (actual_len / 4) + 4096;
            // 先に新しいバッファを確保（失敗時に古いバッファを残す）
            const new_buf = try self.allocator.alloc(u8, new_capacity);
            if (self.search_chunk_buffer) |old| {
                self.allocator.free(old);
            }
            self.search_chunk_buffer = new_buf;
            self.search_chunk_capacity = new_capacity;
        }

        var iter = PieceIterator.init(buffer);
        iter.seek(pos);

        const result = self.search_chunk_buffer.?[0..actual_len];
        const copied = iter.copyBytes(result);
        if (copied != actual_len) {
            return error.BufferInconsistency;
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
        const max_screen_lines = view.viewport_height -| 1;

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

        // 前の状態を保存（スクロール検出用）
        const old_top_line = view.top_line;
        var needs_vertical_scroll = false;

        // 画面内の行位置を計算（ビューポート高さを使用）
        // 現在のtop_lineをなるべく維持し、カーソルが画面外に出た場合のみスクロール
        const max_screen_lines = view.viewport_height -| 1;
        if (max_screen_lines == 0) {
            view.top_line = 0;
            view.cursor_y = line;
        } else if (line < view.top_line) {
            // カーソルが画面より上 → スクロールして見えるようにする
            view.top_line = line;
            view.cursor_y = 0;
            needs_vertical_scroll = true;
        } else if (line >= view.top_line + max_screen_lines) {
            // カーソルが画面より下 → スクロールして見えるようにする
            view.top_line = line - max_screen_lines + 1;
            view.cursor_y = max_screen_lines - 1;
            needs_vertical_scroll = true;
        } else {
            // カーソルは画面内 → top_lineはそのまま
            view.cursor_y = line - view.top_line;
        }

        // カーソルX位置を計算（grapheme clusterの表示幅）
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        var display_col: usize = 0;
        while (iter.global_pos < clamped_pos) {
            const cluster = iter.nextGraphemeCluster() catch {
                // エラー時は1バイト進める、nullならイテレータ終了
                if (iter.next() == null) break;
                display_col += 1;
                continue;
            };
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                if (gc.base == '\t') {
                    // タブは次のタブストップまで進める
                    const tab_width = view.getTabWidth();
                    display_col = (display_col / tab_width + 1) * tab_width;
                } else {
                    display_col += gc.width; // 絵文字は2、通常文字は1
                }
            } else {
                break;
            }
        }

        view.cursor_x = display_col;

        // 水平スクロールを調整
        const line_num_width = view.getLineNumberWidth();
        const visible_width = if (view.viewport_width > line_num_width) view.viewport_width - line_num_width else 1;
        var needs_horizontal_scroll = false;
        if (view.cursor_x >= view.top_col + visible_width) {
            // カーソルが右端を超えている
            view.top_col = view.cursor_x - visible_width + 1;
            needs_horizontal_scroll = true;
        } else if (view.cursor_x < view.top_col) {
            // カーソルが左端より左
            view.top_col = view.cursor_x;
            needs_horizontal_scroll = true;
        }

        // カーソルバイト位置キャッシュを更新
        view.cursor_byte_pos_cache = clamped_pos;
        view.cursor_byte_pos_cache_x = view.cursor_x;
        view.cursor_byte_pos_cache_y = view.cursor_y;
        view.cursor_byte_pos_cache_top_line = view.top_line;

        // スクロールが発生した場合のみ再描画をマーク
        // カーソル移動だけなら再描画不要（カーソルはrenderAllWindowsで別途描画される）
        if (needs_vertical_scroll) {
            // オーバーフロー安全なスクロール量計算
            const scroll_amount: i32 = if (view.top_line >= old_top_line)
                @intCast(@min(view.top_line - old_top_line, std.math.maxInt(i32)))
            else
                -@as(i32, @intCast(@min(old_top_line - view.top_line, std.math.maxInt(i32))));
            view.markScroll(scroll_amount);
        } else if (needs_horizontal_scroll) {
            view.markHorizontalScroll();
        }
        // スクロールなしの場合は再描画不要（カーソル位置の更新のみ）
    }

    // エイリアス: restoreCursorPosはsetCursorToPosと同じ
    pub fn restoreCursorPos(self: *Editor, target_pos: usize) void {
        self.setCursorToPos(target_pos);
    }

    // ========================================
    // キー処理：モードハンドラー
    // ========================================

    /// ファイル入力モード共通処理（保存/開く）
    fn handleFileInputKey(self: *Editor, key: input.Key, comptime is_save: bool) !bool {
        const prompt = if (is_save) "Write file: " else "Find file: ";

        if (isCancelKey(key)) {
            self.completion_shown = false;
            if (is_save) {
                self.cancelSaveInput();
            } else {
                self.cancelInput();
            }
            return true;
        }

        if (key == .tab) {
            _ = try self.completeFilename(prompt);
            return true;
        }

        // 補完候補表示中は、Tab以外のキーで候補をクリア
        if (self.completion_shown) {
            self.completion_shown = false;
            self.updateMinibufferPrompt(prompt);
            // Enterは候補クリアのみで処理しない（誤操作防止）
            if (key == .enter) {
                return true;
            }
        }

        if (key == .enter) {
            if (self.minibuffer.hasContent()) {
                if (is_save) {
                    try self.handleSaveFileEnter();
                } else {
                    try self.handleFindFileEnter();
                }
            }
            return true;
        }

        try self.processMinibufferKeyWithPrompt(key, prompt);
        return true;
    }

    /// ファイル名入力モード（C-x C-s で新規ファイル保存時）
    fn handleFilenameInputKey(self: *Editor, key: input.Key) !bool {
        return self.handleFileInputKey(key, true);
    }

    /// ファイルを開くモード（C-x C-f）
    fn handleFindFileInputKey(self: *Editor, key: input.Key) !bool {
        return self.handleFileInputKey(key, false);
    }

    /// 保存時のEnter処理
    fn handleSaveFileEnter(self: *Editor) !void {
        const new_filename = self.minibuffer.getContent();
        const buffer_state = self.getCurrentBuffer();

        // 同じファイル名なら確認不要
        const is_same_file = if (buffer_state.file.filename) |old|
            std.mem.eql(u8, old, new_filename)
        else
            false;

        // ファイルが存在し、かつ別のファイルなら確認が必要
        const file_exists = blk: {
            std.fs.cwd().access(new_filename, .{}) catch |err| {
                // FileNotFound以外のエラーは「存在するかも」として確認を出す
                break :blk (err != error.FileNotFound);
            };
            break :blk true; // accessが成功 = ファイルが存在する
        };

        if (file_exists and !is_same_file) {
            // 確認待ちのファイル名を保存（buffer_state.file.filenameは確認後に設定）
            // 先にdupeしてからfreeする（dupe失敗時のダングリングポインタ防止）
            const new_pending = try self.allocator.dupe(u8, new_filename);
            if (self.pending_filename) |old| {
                self.allocator.free(old);
            }
            self.pending_filename = new_pending;
            self.clearInputBuffer();
            self.mode = .overwrite_confirm;
            self.getCurrentView().setError("File exists. Overwrite? (y)es (n)o");
        } else {
            // ファイルが存在しないか、同じファイルなら直接保存
            try buffer_state.file.setFilename(new_filename);
            self.clearInputBuffer();
            try self.saveFile();
            self.resetToNormal();
            if (self.quit_after_save) {
                self.quit_after_save = false;
                self.running = false;
            }
        }
    }

    /// ファイルを開く時のEnter処理
    fn handleFindFileEnter(self: *Editor) !void {
        const filename = self.minibuffer.getContent();
        const existing_buffer = self.findBufferByFilename(filename);
        if (existing_buffer) |buf| {
            try self.switchToBuffer(buf.id);
        } else {
            const new_buffer = try self.createNewBuffer();

            // filename_copyのdupe失敗時にnew_bufferをクリーンアップ
            const filename_copy = self.allocator.dupe(u8, filename) catch |err| {
                _ = self.closeBuffer(new_buffer.id) catch {};
                return err;
            };

            const loaded_buffer = Buffer.loadFromFile(self.allocator, filename_copy) catch |err| {
                self.allocator.free(filename_copy);
                if (err == error.FileNotFound) {
                    // ファイルが存在しない場合は新規ファイルとして扱う
                    new_buffer.file.setFilename(filename) catch |e| {
                        _ = self.closeBuffer(new_buffer.id) catch {};
                        return e;
                    };
                    try self.switchToBuffer(new_buffer.id);
                    self.cancelInput();
                    return;
                } else if (err == error.BinaryFile) {
                    // エラーパスではcatch {}を使用（tryだと失敗時にリーク）
                    _ = self.closeBuffer(new_buffer.id) catch {};
                    self.getCurrentView().setError("Cannot open binary file");
                    self.mode = .normal;
                    self.clearInputBuffer();
                    return;
                } else if (err == error.IsDir) {
                    _ = self.closeBuffer(new_buffer.id) catch {};
                    self.getCurrentView().setError("Cannot open directory");
                    self.mode = .normal;
                    self.clearInputBuffer();
                    return;
                } else {
                    _ = self.closeBuffer(new_buffer.id) catch {};
                    self.showError(err);
                    self.mode = .normal;
                    self.clearInputBuffer();
                    return;
                }
            };

            new_buffer.editing_ctx.buffer.deinit();
            new_buffer.editing_ctx.buffer.* = loaded_buffer;
            // ファイル名を設定（filename_normalizedは遅延初期化）
            new_buffer.file.setFilenameOwned(filename_copy);
            new_buffer.editing_ctx.modified = false;

            const file = std.fs.cwd().openFile(filename_copy, .{}) catch null;
            if (file) |f| {
                defer f.close();
                const stat = f.stat() catch null;
                if (stat) |s| {
                    new_buffer.file.mtime = s.mtime;
                }
            }
            try self.switchToBuffer(new_buffer.id);
        }
        self.cancelInput();
    }

    /// バッファ切り替えモード（C-x b）
    fn handleBufferSwitchInputKey(self: *Editor, key: input.Key) !bool {
        if (isCancelKey(key)) {
            self.cancelInput();
            return true;
        }
        if (key == .enter) {
            if (self.minibuffer.hasContent()) {
                const buffer_name = self.minibuffer.getContent();
                // まず完全パスで検索
                var found_buffer = self.findBufferByFilename(buffer_name);
                // 見つからなければベース名で検索
                if (found_buffer == null) {
                    found_buffer = self.findBufferByBasename(buffer_name);
                }
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
                        if (self.minibuffer.hasContent()) {
                            self.getCurrentView().setSearchHighlightEx(self.minibuffer.getContent(), self.is_regex_search);
                            try self.performSearch(true, true);
                        }
                    },
                    'r' => {
                        if (self.minibuffer.hasContent()) {
                            self.getCurrentView().setSearchHighlightEx(self.minibuffer.getContent(), self.is_regex_search);
                            try self.performSearch(false, true);
                        }
                    },
                    'p' => try self.navigateSearchHistory(true, is_forward),
                    'n' => try self.navigateSearchHistory(false, is_forward),
                    'x' => {
                        // C-x: 検索を終了してC-xプレフィックスモードに入る
                        if (self.minibuffer.hasContent()) {
                            try self.search_service.history.add(self.minibuffer.getContent());
                            self.updateLastSearch(self.minibuffer.getContent());
                        }
                        self.endSearch();
                        self.mode = .prefix_x;
                        self.getCurrentView().setError(config.Messages.KEY_PREFIX_CX);
                    },
                    else => {
                        // C-f/C-b/C-a/C-e/C-d/C-k/C-y等はミニバッファ共通処理へ
                        if (try self.handleMinibufferKey(key)) {
                            self.updateIsearchPrompt(is_forward);
                            self.updateIsearchHighlight();
                        }
                    },
                }
            },
            .alt => |c| {
                switch (c) {
                    'r' => {
                        // M-r: 正規表現/リテラルモードをトグル
                        self.is_regex_search = !self.is_regex_search;
                        self.updateIsearchPrompt(is_forward);
                        self.updateIsearchHighlight();
                    },
                    else => {
                        // その他のAltキーはミニバッファ共通処理へ（M-d/M-delete等の削除含む）
                        if (try self.handleMinibufferKey(key)) {
                            self.updateIsearchPrompt(is_forward);
                            self.updateIsearchHighlight();
                        }
                    },
                }
            },
            .ctrl_alt => |c| {
                switch (c) {
                    's' => {
                        // C-M-s: 次のマッチへ（C-sと同じ動作）
                        if (self.minibuffer.hasContent()) {
                            self.getCurrentView().setSearchHighlightEx(self.minibuffer.getContent(), self.is_regex_search);
                            try self.performSearch(true, true);
                        }
                    },
                    'r' => {
                        // C-M-r: 前のマッチへ（C-rと同じ動作）
                        if (self.minibuffer.hasContent()) {
                            self.getCurrentView().setSearchHighlightEx(self.minibuffer.getContent(), self.is_regex_search);
                            try self.performSearch(false, true);
                        }
                    },
                    else => {},
                }
            },
            .arrow_up => try self.navigateSearchHistory(true, is_forward),
            .arrow_down => try self.navigateSearchHistory(false, is_forward),
            .backspace => {
                if (self.minibuffer.hasContent()) {
                    self.minibuffer.moveToEnd();
                    self.minibuffer.backspace();
                    self.updateIsearchPrompt(is_forward);
                    self.updateIsearchHighlight();
                    if (self.search_start_pos) |start_pos| {
                        self.setCursorToPos(start_pos);
                    }
                    if (self.minibuffer.hasContent()) {
                        try self.performSearch(is_forward, false);
                    }
                }
            },
            .enter => {
                if (self.minibuffer.hasContent()) {
                    try self.search_service.history.add(self.minibuffer.getContent());
                    self.updateLastSearch(self.minibuffer.getContent());
                }
                self.endSearch();
            },
            else => {
                // その他のキーはミニバッファ共通処理にフォールバック
                // (C-f/C-b/C-a/C-e/M-f/M-b/左右矢印、C-d/delete削除など)
                if (try self.handleMinibufferKey(key)) {
                    self.updateIsearchPrompt(is_forward);
                    self.updateIsearchHighlight();
                }
            },
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
                        const prompt = "Find file: ";
                        self.prompt_prefix_len = stringDisplayWidth(prompt);
                        self.getCurrentView().setError(prompt);
                    },
                    's' => {
                        const buffer_state = self.getCurrentBuffer();
                        // ファイル名がない、または[stdin]の場合はファイル名入力を促す
                        const needs_filename = buffer_state.file.filename == null or
                            (buffer_state.file.filename != null and
                            std.mem.eql(u8, buffer_state.file.filename.?, "[stdin]"));
                        if (needs_filename) {
                            self.mode = .filename_input;
                            self.quit_after_save = false;
                            self.minibuffer.clear();
                            self.minibuffer.cursor = 0;
                            const prompt = "Write file: ";
                            self.prompt_prefix_len = stringDisplayWidth(prompt);
                            self.getCurrentView().setError(prompt);
                        } else {
                            try self.saveFile();
                        }
                    },
                    'w' => {
                        self.mode = .filename_input;
                        self.quit_after_save = false;
                        self.clearInputBuffer();
                        const prompt = "Write file: ";
                        self.prompt_prefix_len = stringDisplayWidth(prompt);
                        self.getCurrentView().setError(prompt);
                    },
                    'n' => {
                        // 新規バッファを作成
                        const new_buffer = try self.createNewBuffer();
                        try self.switchToBuffer(new_buffer.id);
                        self.getCurrentView().setError("New buffer");
                    },
                    'c' => {
                        var modified_count: usize = 0;
                        var first_modified_name: ?[]const u8 = null;
                        for (self.buffer_manager.iterator()) |buf| {
                            if (buf.editing_ctx.modified) {
                                modified_count += 1;
                                if (first_modified_name == null) {
                                    first_modified_name = buf.file.filename;
                                }
                            }
                        }
                        if (modified_count > 0) {
                            if (modified_count == 1) {
                                const name = first_modified_name orelse config.Messages.BUFFER_SCRATCH;
                                self.setPrompt("Save changes to {s}? (y/n/c): ", .{name});
                            } else {
                                self.setPrompt("{d} buffers modified; exit anyway? (y/n): ", .{modified_count});
                            }
                            self.mode = .quit_confirm;
                        } else {
                            self.running = false;
                        }
                    },
                    else => self.getCurrentView().setError(config.Messages.UNKNOWN_COMMAND),
                }
            },
            .char => |c| {
                switch (c) {
                    'h' => edit.selectAll(self) catch |err| self.showError(err),
                    'r' => {
                        self.mode = .prefix_r;
                        return true;
                    },
                    'b' => {
                        self.mode = .buffer_switch_input;
                        self.clearInputBuffer();
                        const prompt = "Switch to buffer: ";
                        self.prompt_prefix_len = stringDisplayWidth(prompt);
                        self.getCurrentView().setError(prompt);
                    },
                    'k' => {
                        const buffer_state = self.getCurrentBuffer();
                        if (buffer_state.editing_ctx.modified) {
                            const name = buffer_state.file.filename orelse config.Messages.BUFFER_SCRATCH;
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
                        // アクティブウィンドウが変わったので全ウィンドウを再描画
                        for (self.window_manager.windows.items) |*win| {
                            win.view.markFullRedraw();
                        }
                    },
                    '0' => self.closeCurrentWindow() catch |err| self.showError(err),
                    '1' => self.deleteOtherWindows() catch |err| self.showError(err),
                    '(' => self.startMacroRecording(),
                    ')' => self.stopMacroRecording(),
                    'e' => self.executeMacro() catch |err| self.showError(err),
                    else => self.getCurrentView().setError(config.Messages.UNKNOWN_COMMAND),
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
                    'w' => rectangle.copyRectangle(self) catch |err| {
                        self.getCurrentView().setError(@errorName(err));
                    },
                    'y' => rectangle.yankRectangle(self) catch |err| {
                        self.getCurrentView().setError(@errorName(err));
                    },
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
            self.getCurrentView().setSearchHighlight(null);
            return true;
        }
        if (key == .enter) {
            const content = self.minibuffer.getContent();
            // 空欄でEnter → 前回の検索文字を使用
            if (content.len == 0 and self.replace_search != null) {
                self.clearInputBuffer();
                self.mode = .query_replace_input_replacement;
                self.enterReplacementMode();
                return true;
            }
            if (content.len > 0) {
                // dupe成功後にfree（dupe失敗時は古い値を保持）
                const new_search = try self.allocator.dupe(u8, content);
                if (self.replace_search) |old| {
                    self.allocator.free(old);
                }
                self.replace_search = new_search;
                self.clearInputBuffer();
                self.mode = .query_replace_input_replacement;
                self.enterReplacementMode();
            }
            return true;
        }
        // M-r: 正規表現/リテラルモードをトグル
        if (key == .alt and key.alt == 'r') {
            self.is_regex_replace = !self.is_regex_replace;
            const prompt = config.QueryReplace.getPrompt(self.is_regex_replace);
            self.prompt_prefix_len = stringDisplayWidth(prompt);
            self.setPrompt("{s}{s}", .{ prompt, self.minibuffer.getContent() });
            // ハイライトを更新
            const content = self.minibuffer.getContent();
            if (content.len > 0) {
                self.getCurrentView().setSearchHighlightEx(content, self.is_regex_replace);
            }
            return true;
        }
        const prompt = config.QueryReplace.getPrompt(self.is_regex_replace);
        self.prompt_prefix_len = stringDisplayWidth(prompt);
        try self.processMinibufferKeyWithPrompt(key, prompt);
        // インクリメンタルハイライト
        const content = self.minibuffer.getContent();
        if (content.len > 0) {
            self.getCurrentView().setSearchHighlightEx(content, self.is_regex_replace);
        } else {
            self.getCurrentView().setSearchHighlight(null);
        }
        return true;
    }

    /// Query Replace: 置換文字列入力モード
    fn handleQueryReplaceInputReplacementKey(self: *Editor, key: input.Key) !bool {
        if (isCancelKey(key)) {
            self.cancelQueryReplaceInput();
            self.getCurrentView().setSearchHighlight(null);
            return true;
        }
        if (key == .enter) {
            const content = self.minibuffer.getContent();
            // 空欄でEnter → 前回の置換文字を使用（なければ空文字=削除）
            if (content.len == 0 and self.replace_replacement != null) {
                // 前回の値を再利用（何もしない）
            } else {
                // dupe成功後にfree（dupe失敗時は古い値を保持）
                const new_replacement = try self.allocator.dupe(u8, content);
                if (self.replace_replacement) |old| {
                    self.allocator.free(old);
                }
                self.replace_replacement = new_replacement;
            }
            self.minibuffer.clear();

            if (self.replace_search) |search| {
                const found = try self.findNextMatch(search, self.getCurrentView().getCursorBufferPos());
                if (found) {
                    self.mode = .query_replace_confirm;
                    self.setPrompt("Replace? (y)es (n)ext (!)all (q)uit", .{});
                } else {
                    self.mode = .normal;
                    self.getCurrentView().setSearchHighlight(null);
                    self.getCurrentView().setError("No match found");
                }
            } else {
                self.mode = .normal;
                self.getCurrentView().setSearchHighlight(null);
                self.getCurrentView().setError("No search string");
            }
            return true;
        }
        // M-r: 正規表現/リテラルモードをトグル
        if (key == .alt and key.alt == 'r') {
            self.is_regex_replace = !self.is_regex_replace;
            if (self.replace_search) |search| {
                const prefix = config.QueryReplace.getPrefix(self.is_regex_replace);
                self.prompt_prefix_len = self.calculateReplacementPromptWidth();
                self.setPrompt("{s}{s} with: {s}", .{ prefix, search, self.minibuffer.getContent() });
                // ハイライトを更新
                self.getCurrentView().setSearchHighlightEx(search, self.is_regex_replace);
            }
            return true;
        }
        _ = try self.handleMinibufferKey(key);
        const prefix = config.QueryReplace.getPrefix(self.is_regex_replace);
        self.prompt_prefix_len = self.calculateReplacementPromptWidth();
        if (self.replace_search) |search| {
            self.setPrompt("{s}{s} with: {s}", .{ prefix, search, self.minibuffer.getContent() });
        } else {
            self.setPrompt("{s}with: {s}", .{ prefix, self.minibuffer.getContent() });
        }
        return true;
    }

    /// Query Replace: 確認モード
    fn handleQueryReplaceConfirmKey(self: *Editor, key: input.Key) !bool {
        switch (key) {
            .char => |c| try self.handleReplaceConfirmChar(c),
            // 他の確認モード（quit_confirm, kill_buffer_confirm等）と統一
            // normalizeFullwidthは使用しない（toAsciiCharで十分）
            .codepoint => |cp| try self.handleReplaceConfirmChar(cp),
            .ctrl => |c| {
                if (c == 'g') {
                    self.finishReplace(); // 統一的にfinishReplaceを使用
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
                        self.shell_service.history.resetNavigation();
                        self.completion_shown = false;
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
            .tab => {
                try self.handleShellCompletion();
                return true;
            },
            .escape => {
                self.mode = .normal;
                self.clearInputBuffer();
                self.shell_service.history.resetNavigation();
                self.completion_shown = false;
                self.getCurrentView().clearError();
                return true;
            },
            .enter => {
                // 補完候補表示中はEnterで候補をクリアするのみ
                if (self.completion_shown) {
                    self.completion_shown = false;
                    self.updateMinibufferPrompt("| ");
                    return true;
                }
                if (self.minibuffer.hasContent()) {
                    try self.shell_service.history.add(self.minibuffer.getContent());
                    self.shell_service.history.resetNavigation();
                    try self.startShellCommand();
                }
                if (self.mode != .shell_running) {
                    self.mode = .normal;
                    self.clearInputBuffer();
                    self.getCurrentView().clearError();
                }
                return true;
            },
            else => {},
        }
        // 補完候補表示中は、Tab以外のキーで候補をクリア
        if (self.completion_shown) {
            self.completion_shown = false;
            self.updateMinibufferPrompt("| ");
        }
        _ = try self.handleMinibufferKey(key);
        self.updateMinibufferPrompt("| ");
        return true;
    }

    /// シェルコマンドのTab補完
    fn handleShellCompletion(self: *Editor) !void {
        const current = self.minibuffer.getContent();
        if (current.len == 0) return;

        var result = try self.shell_service.getCompletions(current) orelse {
            self.getCurrentView().setError("No completions");
            self.completion_shown = true;
            return;
        };
        defer result.deinit();

        if (result.matches.len == 1) {
            // ユニーク一致: 完全補完
            // 元の入力から補完対象トークンを置き換え
            const token = getLastToken(current);
            const prefix_len = current.len - token.len;
            var buf: [1024]u8 = undefined;
            if (prefix_len + result.matches[0].len < buf.len) {
                @memcpy(buf[0..prefix_len], current[0..prefix_len]);
                @memcpy(buf[prefix_len .. prefix_len + result.matches[0].len], result.matches[0]);
                // ディレクトリなら/を追加、それ以外はスペース
                const completed_len = prefix_len + result.matches[0].len;
                const completed = buf[0..completed_len];
                try self.minibuffer.setContent(completed);
            }
            self.completion_shown = false;
        } else {
            // 複数一致: 共通プレフィックス補完 + 候補表示
            const token = getLastToken(current);
            const prefix_len = current.len - token.len;

            // 共通プレフィックスで補完
            if (result.common_prefix.len > token.len) {
                var buf: [1024]u8 = undefined;
                if (prefix_len + result.common_prefix.len < buf.len) {
                    @memcpy(buf[0..prefix_len], current[0..prefix_len]);
                    @memcpy(buf[prefix_len .. prefix_len + result.common_prefix.len], result.common_prefix);
                    const completed = buf[0 .. prefix_len + result.common_prefix.len];
                    try self.minibuffer.setContent(completed);
                }
            }

            // 候補を表示（最大10個）
            var display_buf: [256]u8 = undefined;
            var len: usize = 0;
            const max_show = @min(result.matches.len, 10);
            for (result.matches[0..max_show]) |m| {
                // ファイル名部分のみ表示
                const basename = std.fs.path.basename(m);
                if (len + basename.len + 1 < display_buf.len) {
                    if (len > 0) {
                        display_buf[len] = ' ';
                        len += 1;
                    }
                    @memcpy(display_buf[len .. len + basename.len], basename);
                    len += basename.len;
                }
            }
            if (result.matches.len > max_show) {
                const suffix = " ...";
                if (len + suffix.len < display_buf.len) {
                    @memcpy(display_buf[len .. len + suffix.len], suffix);
                    len += suffix.len;
                }
            }
            self.getCurrentView().setError(display_buf[0..len]);
            self.completion_shown = true;
        }
    }

    /// 入力から最後のトークン（補完対象）を取得
    fn getLastToken(s: []const u8) []const u8 {
        var i = s.len;
        while (i > 0) {
            i -= 1;
            if (s[i] == ' ' or s[i] == '\t' or s[i] == '|' or s[i] == ';') {
                return s[i + 1 ..];
            }
        }
        return s;
    }

    /// M-xコマンド入力モード
    fn handleMxCommandKey(self: *Editor, key: input.Key) !bool {
        // キャンセル
        if (isCancelKey(key)) {
            self.completion_shown = false;
            self.cancelInput();
            return true;
        }
        // Tab: コマンド名補完
        if (key == .tab) {
            const current = self.minibuffer.getContent();
            // スペースがあれば補完しない（引数部分）
            if (std.mem.indexOfScalar(u8, current, ' ') != null) {
                return true;
            }
            const result = mx.completeCommand(current);
            if (result.matches.len == 0) {
                self.getCurrentView().setError(config.Messages.NO_MATCH);
                self.completion_shown = true; // No matchもカーソル非表示
            } else if (result.matches.len == 1) {
                // ユニーク一致: 完全補完 + スペース
                var buf: [64]u8 = undefined;
                const completed = std.fmt.bufPrint(&buf, "{s} ", .{result.matches[0]}) catch result.matches[0];
                try self.minibuffer.setContent(completed);
                self.updateMinibufferPrompt(": ");
                self.completion_shown = false;
            } else {
                // 複数一致: 共通プレフィックス補完 + 候補表示
                try self.minibuffer.setContent(result.common_prefix);
                var display_buf: [256]u8 = undefined;
                var len: usize = 0;
                for (result.matches) |m| {
                    if (len + m.len + 1 < display_buf.len) {
                        if (len > 0) {
                            display_buf[len] = ' ';
                            len += 1;
                        }
                        @memcpy(display_buf[len .. len + m.len], m);
                        len += m.len;
                    }
                }
                self.getCurrentView().setError(display_buf[0..len]);
                self.completion_shown = true;
            }
            return true;
        }
        // 補完候補表示中は、Tab以外のキーで候補をクリア
        if (self.completion_shown) {
            self.completion_shown = false;
            self.updateMinibufferPrompt(": ");
            // Enterは候補クリアのみで処理しない（誤操作防止）
            if (key == .enter) {
                return true;
            }
        }
        // Enter: コマンド実行
        if (key == .enter) {
            try mx.execute(self);
            return true;
        }
        _ = try self.handleMinibufferKey(key);
        self.updateMinibufferPrompt(": ");
        return true;
    }

    /// 通常モードのキー処理
    ///
    /// 【処理の優先順位】
    /// 1. Keymap検索: Ctrl/Alt/特殊キーはKeymapからハンドラを検索
    /// 2. 特殊処理: C-x(プレフィックス), C-s(検索), M-%(置換)等
    /// 3. 文字入力: .char/.codepointはinsertCodepoint()でバッファに挿入
    ///
    /// 【Keymapの利点】
    /// ハードコードされたswitch文ではなく、Keymapテーブルを使うことで:
    /// - O(1)ルックアップ（配列インデックス）
    /// - 将来的にランタイムで再バインド可能
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
                        self.getCurrentView().setError(config.Messages.KEY_PREFIX_CX);
                    },
                    's' => try self.startIsearch(true),
                    'r' => try self.startIsearch(false),
                    else => {},
                }
            },
            .alt => |c| {
                // 小文字のM-f, M-b, M-vは選択解除（大文字のM-F, M-B, M-Vは選択維持）
                if (c == 'f' or c == 'b' or c == 'v') {
                    self.getCurrentWindow().mark_pos = null;
                }
                // keymapから検索
                if (self.keymap.findAlt(c)) |handler| {
                    try handler(self);
                    return;
                }
                // keymapにない特殊処理
                switch (c) {
                    '%' => self.startQueryReplace(), // M-%: リテラル置換
                    '|' => {
                        self.mode = .shell_command;
                        self.clearInputBuffer();
                        const prompt = "| ";
                        self.prompt_prefix_len = stringDisplayWidth(prompt);
                        self.getCurrentView().setError(prompt);
                    },
                    'x' => {
                        self.mode = .mx_command;
                        self.clearInputBuffer();
                        const prompt = ": ";
                        self.prompt_prefix_len = stringDisplayWidth(prompt);
                        self.getCurrentView().setError(prompt);
                    },
                    '?' => try self.showHelp(),
                    else => {},
                }
            },
            .ctrl_alt => |c| {
                switch (c) {
                    's' => try self.startRegexIsearch(true), // C-M-s: 正規表現前方検索
                    'r' => try self.startRegexIsearch(false), // C-M-r: 正規表現後方検索
                    '%' => try self.startRegexQueryReplace(), // C-M-%: 正規表現置換
                    else => {},
                }
            },
            .enter => {
                const buffer_state = self.getCurrentBuffer();
                if (buffer_state.file.filename) |fname| {
                    if (std.mem.eql(u8, fname, config.Messages.BUFFER_LIST)) {
                        try self.selectBufferFromList();
                        return;
                    }
                }
                var indent_buf: [config.Editor.MAX_INDENT_LENGTH]u8 = undefined;
                const indent = edit.getCurrentLineIndent(self, &indent_buf);
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
            .insert => {
                self.overwrite_mode = !self.overwrite_mode;
                if (self.overwrite_mode) {
                    self.getCurrentView().setError("Overwrite mode enabled");
                } else {
                    self.getCurrentView().setError("Insert mode enabled");
                }
            },
            .char => |c| if (c >= 32 and c < 127) try self.insertCodepoint(c),
            .codepoint => |cp| try self.insertCodepoint(cp),
            else => {
                // 特殊キーをkeymapで検索
                if (Keymap.toSpecialKey(key)) |special_key| {
                    // Shift+矢印で選択した場合のみ、通常矢印キーで選択解除
                    // C-Spaceで設定したマークは維持する
                    const window = self.getCurrentWindow();
                    switch (special_key) {
                        .arrow_up, .arrow_down, .arrow_left, .arrow_right, .page_up, .page_down, .home, .end_key, .alt_arrow_left, .alt_arrow_right => {
                            if (window.shift_select) {
                                window.mark_pos = null;
                                window.shift_select = false;
                            }
                        },
                        else => {},
                    }
                    if (self.keymap.findSpecial(special_key)) |handler| {
                        try handler(self);
                    }
                }
            },
        }
    }

    /// キー入力を処理するメインディスパッチャ
    ///
    /// 【モード別分岐】
    /// EditorModeに応じて適切なハンドラに振り分ける:
    /// - normal: handleNormalKey() → 通常編集・Keymapコマンド実行
    /// - isearch_*: handleIsearchKey() → インクリメンタルサーチ
    /// - query_replace_*: handleQueryReplaceKey() → 対話的置換
    /// - shell_*: handleShellKey() → シェルコマンド入力/実行
    /// - prefix_x: handlePrefixXKey() → C-xプレフィックスコマンド
    /// - *_input: handleXxxInputKey() → ミニバッファ入力
    ///
    /// 【キャンセル】
    /// 多くのモードで C-g または Escape でキャンセルし、normalモードに戻る。
    fn processKey(self: *Editor, key: input.Key) !void {
        // ブラケットペーストモードの処理
        // ペースト開始: ESC[200~ → paste_mode = true
        // ペースト終了: ESC[201~ → 蓄積した内容を一括挿入
        switch (key) {
            .paste_start => {
                self.paste_mode = true;
                self.paste_buffer.clearRetainingCapacity();
                return;
            },
            .paste_end => {
                if (self.paste_mode) {
                    self.paste_mode = false;
                    // 蓄積したペースト内容を一括挿入（オートインデントなし）
                    if (self.paste_buffer.items.len > 0) {
                        try self.insertPasteContent(self.paste_buffer.items);
                    }
                }
                return;
            },
            else => {},
        }

        // ペーストモード中は文字をバッファに蓄積
        if (self.paste_mode) {
            switch (key) {
                .char => |c| try self.paste_buffer.append(self.allocator, c),
                .codepoint => |cp| {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch return;
                    try self.paste_buffer.appendSlice(self.allocator, buf[0..len]);
                },
                .enter => try self.paste_buffer.append(self.allocator, '\n'),
                .tab => try self.paste_buffer.append(self.allocator, '\t'),
                else => {}, // その他のキーは無視
            }
            return;
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
                self.dispatchConfirmKey(key, handleQuitConfirmChar);
                return;
            },
            .kill_buffer_confirm => {
                self.dispatchConfirmKey(key, handleKillBufferConfirmChar);
                return;
            },
            .exit_confirm => {
                self.dispatchConfirmKey(key, handleExitConfirmChar);
                return;
            },
            .overwrite_confirm => {
                self.dispatchConfirmKey(key, handleOverwriteConfirmChar);
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
                        } else {
                            self.getCurrentView().setError(config.Messages.SHELL_RUNNING);
                        }
                    },
                    else => {
                        self.getCurrentView().setError(config.Messages.SHELL_RUNNING);
                    },
                }
                return;
            },
            .mx_command => {
                _ = try self.handleMxCommandKey(key);
                return;
            },
            .mx_key_describe => {
                const key_desc = help.describeKey(key);
                self.getCurrentView().setError(key_desc);
                self.mode = .normal;
                return;
            },
            .macro_repeat => {
                self.handleMacroRepeatKey(key) catch |err| self.showError(err);
                return;
            },
            .normal => {},
        }

        // マクロ記録中ならキーを記録（マクロ制御キーは除外）
        if (self.macro_service.isRecording() and !self.macro_service.isPlaying()) {
            if (!self.isMacroControlKey(key)) {
                self.macro_service.recordKey(key) catch |err| {
                    self.showError(err);
                    self.macro_service.stopRecording(); // 記録を中断
                };
            }
        }

        // 通常モード
        try self.handleNormalKey(key);
    }

    fn insertChar(self: *Editor, ch: u8) !void {
        return self.insertCodepoint(ch); // u8→u21 自動昇格
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

        // 上書きモード：行末・改行以外では現在位置の文字を削除
        if (self.overwrite_mode and codepoint != '\n') {
            // 現在位置の文字を確認（改行でなければ削除）
            const current_byte = buffer.getByteAt(pos);
            if (current_byte != null and current_byte.? != '\n') {
                // 現在位置のUTF-8文字の長さを取得して削除
                const char_len = std.unicode.utf8ByteSequenceLength(current_byte.?) catch 1;
                // Undo用に削除される文字を記録
                const deleted_text = try buffer.getRange(self.allocator, pos, char_len);
                defer self.allocator.free(deleted_text);
                try self.recordDelete(pos, deleted_text, pos);
                try buffer.delete(pos, char_len);
            }
        }

        // バッファ変更を先に実行
        try buffer.insertSlice(pos, buf[0..len]);
        errdefer buffer.delete(pos, len) catch {};
        try self.recordInsert(pos, buf[0..len], pos); // 編集前のカーソル位置を記録
        buffer_state.editing_ctx.modified = true;

        if (codepoint == '\n') {
            // 改行処理
            const view = self.getCurrentView();
            const max_screen_line = view.viewport_height -| 2;
            if (view.cursor_y < max_screen_line) {
                view.cursor_y += 1;
            } else {
                // 画面の最下部の場合はスクロール
                view.top_line += 1;
            }
            // 改行は行シフトを起こすため、prev_screenキャッシュが無効になる
            // markDirtyでは差分描画が壊れるので全画面再描画が必要
            // 同一バッファを表示している全ウィンドウを更新
            self.markAllViewsFullRedrawForBuffer(buffer_state.id);
            view.cursor_x = 0;
            view.top_col = 0; // 水平スクロールもリセット
            // 改行後のカーソル位置キャッシュを更新
            view.updateCursorPosCacheAfterInsert(pos, len);
        } else {
            // 通常文字
            const view = self.getCurrentView();

            // カーソル移動（タブは特別扱い）
            const char_width: usize = if (codepoint == '\t') blk: {
                const tab_width = view.getTabWidth();
                const next_tab_stop = (view.cursor_x / tab_width + 1) * tab_width;
                const width = next_tab_stop - view.cursor_x;
                view.cursor_x = next_tab_stop;
                break :blk width;
            } else blk: {
                const width = unicode.displayWidth(codepoint);
                view.cursor_x += width;
                break :blk width;
            };

            // 行幅キャッシュを差分更新（markDirtyの前に呼び出してキャッシュが有効なうちに更新）
            view.updateLineWidthCacheAfterInsert(char_width);

            // 同一バッファを表示している全ウィンドウを更新
            // 注: 現在のviewのキャッシュは上で更新済みなので、他のviewの分だけ無効化される
            self.markAllViewsDirtyForBufferExceptCurrent(buffer_state.id, current_line, current_line);

            // 水平スクロール: カーソルが右端を超えた場合
            const line_num_width = view.getLineNumberWidth();
            const visible_width = if (view.viewport_width > line_num_width) view.viewport_width - line_num_width else 1;
            if (view.cursor_x >= view.top_col + visible_width) {
                view.top_col = view.cursor_x - visible_width + 1;
                view.markHorizontalScroll();
            }

            // カーソル位置キャッシュを更新（次回getCursorBufferPos()を高速化）
            view.updateCursorPosCacheAfterInsert(pos, len);
        }
    }

    /// ペースト内容を一括挿入（ブラケットペーストモード用）
    ///
    /// 通常の文字挿入と異なり、以下の特徴がある：
    /// - オートインデントなし（ペーストした内容をそのまま挿入）
    /// - 1回のUndo操作で全体を取り消し可能
    /// - 画面更新は1回のみ（パフォーマンス向上）
    fn insertPasteContent(self: *Editor, content: []const u8) !void {
        if (self.isReadOnly()) return;
        if (content.len == 0) return;

        const buffer_state = self.getCurrentBuffer();
        const buffer = self.getCurrentBufferContent();
        const pos = self.getCurrentView().getCursorBufferPos();

        // バッファに挿入
        try buffer.insertSlice(pos, content);
        errdefer buffer.delete(pos, content.len) catch {};

        // Undo用に記録（1回の操作として記録）
        try self.recordInsert(pos, content, pos);
        buffer_state.editing_ctx.modified = true;

        // カーソル位置を挿入後の位置に移動（setCursorToPosでキャッシュ再設定）
        self.setCursorToPos(pos + content.len);

        // 全画面再描画（複数行にわたる可能性があるため）
        self.markAllViewsFullRedrawForBuffer(buffer_state.id);
    }

    // マーク位置とカーソル位置から範囲を取得（開始位置と長さを返す）
    pub fn getRegion(self: *Editor) ?struct { start: usize, len: usize } {
        const window = self.getCurrentWindow();
        const raw_mark = window.mark_pos orelse return null;
        const buffer = self.getCurrentBufferContent();
        const raw_cursor = self.getCurrentView().getCursorBufferPos();

        // マーク位置・カーソル位置がバッファ範囲を超えている場合はクランプ（バッファ編集後の安全対策）
        const mark = @min(raw_mark, buffer.len());
        const cursor = @min(raw_cursor, buffer.len());

        if (mark < cursor) {
            return .{ .start = mark, .len = cursor - mark };
        } else if (cursor < mark) {
            return .{ .start = cursor, .len = mark - cursor };
        } else {
            return null; // 範囲が空
        }
    }

    /// チャンク化正規表現検索（共通ヘルパー）
    /// 大きなファイルを1MBチャンクで分割し、ラップアラウンド検索を行う
    /// 戻り値: マッチ位置と長さ（見つからなければnull）
    fn searchRegexChunked(
        self: *Editor,
        search_str: []const u8,
        start_pos: usize,
        forward: bool,
        skip_current: bool,
    ) !?struct { pos: usize, len: usize } {
        const buffer = self.getCurrentBufferContent();
        const buf_len = buffer.total_len;
        if (buf_len == 0 or search_str.len == 0) return null;

        const max_chunk_size: usize = 1024 * 1024; // 1MB
        const overlap: usize = 64 * 1024; // 64KB - チャンク境界マッチ用

        var search_pos = start_pos;
        var wrapped = false;
        var first_chunk = true;

        while (true) {
            // チャンク範囲を計算
            const chunk_start: usize = if (forward)
                (if (first_chunk) search_pos else if (search_pos > overlap) search_pos - overlap else 0)
            else
                (if (search_pos > max_chunk_size) search_pos - max_chunk_size else 0);

            const chunk_end: usize = if (forward)
                @min(buf_len, chunk_start + max_chunk_size)
            else
                @min(buf_len, if (first_chunk) search_pos else search_pos + overlap);
            const chunk_len = chunk_end - chunk_start;

            // chunk_len == 0 の場合: バッファ境界にいるのでwrap-around処理へ
            if (chunk_len == 0) {
                if (wrapped) break; // 既にwrap済みなら終了
                wrapped = true;
                first_chunk = false;
                search_pos = if (forward) 0 else buf_len;
                continue;
            }

            // 再利用バッファで抽出
            const content = try self.extractTextReusable(chunk_start, chunk_len);

            // チャンク内での検索開始位置
            const adjusted_start: usize = if (first_chunk)
                (if (search_pos > chunk_start) search_pos - chunk_start else 0)
            else if (forward)
                (if (overlap < chunk_len) overlap else 0)
            else
                (if (chunk_len > overlap) chunk_len - overlap else chunk_len);

            if (self.search_service.searchRegex(content, search_str, adjusted_start, forward, first_chunk and skip_current)) |match| {
                return .{ .pos = match.start + chunk_start, .len = match.len };
            }

            first_chunk = false;

            // 次のチャンクへ移動
            if (forward) {
                if (chunk_end >= buf_len) {
                    if (wrapped) break;
                    wrapped = true;
                    search_pos = 0;
                } else {
                    search_pos = chunk_end;
                }
                if (wrapped and search_pos >= start_pos) break;
            } else {
                if (chunk_start == 0) {
                    if (wrapped) break;
                    wrapped = true;
                    search_pos = buf_len;
                } else {
                    search_pos = chunk_start;
                }
                if (wrapped and search_pos <= start_pos) break;
            }
        }

        return null;
    }

    // インクリメンタルサーチ実行
    // forward: true=前方検索、false=後方検索
    // skip_current: true=現在位置をスキップして次を検索、false=現在位置から検索
    fn performSearch(self: *Editor, forward: bool, skip_current: bool) !void {
        const buffer = self.getCurrentBufferContent();
        const search_str = self.minibuffer.getContent();
        if (search_str.len == 0) return;

        const start_pos = self.getCurrentView().getCursorBufferPos();

        if (self.is_regex_search) {
            // 正規表現検索（C-M-s / C-M-r）- 共通ヘルパーを使用
            if (try self.searchRegexChunked(search_str, start_pos, forward, skip_current)) |match| {
                // Emacs風: 前方検索はマッチ終端、後方検索はマッチ先頭にカーソル
                const cursor_pos = if (forward) match.pos + match.len else match.pos;
                self.setCursorToPos(cursor_pos);
            }
        } else {
            // リテラル検索（C-s / C-r）- コピーなしのBuffer直接検索
            if (self.search_service.searchBuffer(buffer, search_str, start_pos, forward, skip_current)) |match| {
                // Emacs風: 前方検索はマッチ終端、後方検索はマッチ先頭にカーソル
                const cursor_pos = if (forward) match.start + match.len else match.start;
                self.setCursorToPos(cursor_pos);
            }
        }
        // 見つからなかった場合：プロンプトはそのまま（カーソルが動かないだけ）
    }

    // 置換：次の一致を検索してカーソルを移動
    fn findNextMatch(self: *Editor, search: []const u8, start_pos: usize) !bool {
        if (search.len == 0) return false;

        const buffer = self.getCurrentBufferContent();
        const buf_len = buffer.len();
        if (buf_len == 0) return false;

        // カーソルが終端にある場合は先頭からラップアラウンド検索
        const actual_start = if (start_pos >= buf_len) 0 else start_pos;

        if (self.is_regex_replace) {
            // 正規表現置換（C-M-%）- 共通ヘルパーを使用
            if (try self.searchRegexChunked(search, actual_start, true, false)) |match| {
                self.setCursorToPos(match.pos);
                self.replace_current_pos = match.pos;
                self.replace_match_len = match.len;
                return true;
            }
        } else {
            // リテラル置換（M-%）- コピーなしのBuffer直接検索
            if (self.search_service.searchBuffer(buffer, search, actual_start, true, false)) |match| {
                self.setCursorToPos(match.start);
                self.replace_current_pos = match.start;
                self.replace_match_len = match.len;
                return true;
            }
        }

        return false;
    }

    // 置換：現在の一致を置換
    fn replaceCurrentMatch(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const buffer_state = self.getCurrentBuffer();
        _ = self.replace_search orelse return error.NoSearchString;
        const replacement = self.replace_replacement orelse return error.NoReplacementString;
        const match_pos = self.replace_current_pos orelse return error.NoMatchPosition;
        const match_len = self.replace_match_len orelse return error.NoMatchLength;

        // Undo記録のために現在のカーソル位置を保存
        const cursor_pos_before = match_pos;

        // 一致部分のテキストを保存（Undo用）- 実際のマッチ長を使用
        const old_text = try self.extractText(match_pos, match_len);
        defer self.allocator.free(old_text);

        // 置換を実行（削除してから挿入）- 実際のマッチ長を使用
        try buffer.delete(match_pos, match_len);
        if (replacement.len > 0) {
            try buffer.insertSlice(match_pos, replacement);
        }

        // 原子的な置換操作として記録（1回のundoで元に戻る）
        try self.recordReplace(match_pos, old_text, replacement, cursor_pos_before);

        buffer_state.editing_ctx.modified = true;
        self.replace_match_count += 1;

        // カーソルを置換後の位置に移動
        // 空マッチの場合は無限ループを防ぐため少なくとも1文字進める
        // UTF-8文字の途中で分断しないようUTF-8シーケンス長を考慮
        var new_pos = match_pos + replacement.len;
        if (match_len == 0 and new_pos < buffer.total_len) {
            // 現在位置のバイトを読み取ってUTF-8シーケンス長を取得
            var iter = buffer_mod.PieceIterator.init(buffer);
            iter.seek(new_pos);
            if (iter.next()) |lead_byte| {
                // UTF-8リードバイトからシーケンス長を計算
                const byte_len = std.unicode.utf8ByteSequenceLength(lead_byte) catch 1;
                new_pos = @min(new_pos + byte_len, buffer.total_len);
            } else {
                // イテレータが終端に達している場合でも最低1バイト進める（無限ループ防止）
                new_pos = @min(new_pos + 1, buffer.total_len);
            }
        }

        // キャッシュを無効化（バッファが変更されたため）
        self.getCurrentView().invalidateCursorPosCache();

        self.setCursorToPos(new_pos);

        // 置換した行から再描画
        // マッチテキスト・置換文字列に改行が含まれる場合は行数が変わるため全画面再描画
        // 同一バッファを表示している全ウィンドウを更新
        const has_newline = std.mem.indexOfScalar(u8, old_text, '\n') != null or
            std.mem.indexOfScalar(u8, replacement, '\n') != null;
        if (has_newline) {
            self.markAllViewsFullRedrawForBuffer(buffer_state.id);
        } else {
            const current_line = buffer.findLineByPos(match_pos);
            self.markAllViewsDirtyForBuffer(buffer_state.id, current_line, current_line);
        }
    }

    // ========================================
    // Shell Integration
    // ========================================

    /// シェルコマンド履歴をナビゲート
    fn navigateShellHistory(self: *Editor, prev: bool) !void {
        // 最初のナビゲーションなら現在の入力を保存
        if (!self.shell_service.history.isNavigating()) {
            try self.shell_service.history.startNavigation(self.minibuffer.getContent());
        }

        const entry = if (prev) self.shell_service.history.prev() else self.shell_service.history.next();
        if (entry) |text| {
            // ミニバッファを履歴エントリで置き換え
            try self.minibuffer.setContent(text);
            self.updateMinibufferPrompt("| ");
        }
    }

    /// 検索履歴をナビゲート
    fn navigateSearchHistory(self: *Editor, prev: bool, is_forward: bool) !void {
        // 最初のナビゲーションなら現在の入力を保存
        if (!self.search_service.history.isNavigating()) {
            try self.search_service.history.startNavigation(self.minibuffer.getContent());
        }

        const entry = if (prev) self.search_service.history.prev() else self.search_service.history.next();
        if (entry) |text| {
            // ミニバッファを履歴エントリで置き換え
            try self.minibuffer.setContent(text);

            // プロンプトとハイライトを更新
            self.updateIsearchPrompt(is_forward);
            self.updateIsearchHighlight();

            // 検索を実行
            if (text.len > 0) {
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
            self.getCurrentView().setError(config.Messages.NO_COMMAND_SPECIFIED);
            return;
        }

        // 入力データの範囲を計算
        const window = self.window_manager.getCurrentWindow();
        const range: ?struct { start: usize, end: usize } = switch (parsed.input_source) {
            .selection => blk: {
                // 選択範囲（マークがあれば）
                if (window.mark_pos) |mark| {
                    const cursor_pos = self.getCurrentView().getCursorBufferPos();
                    const sel_start = @min(mark, cursor_pos);
                    const sel_end = @max(mark, cursor_pos);
                    if (sel_end > sel_start) {
                        break :blk .{ .start = sel_start, .end = sel_end };
                    }
                }
                break :blk null;
            },
            .buffer_all => blk: {
                // バッファ全体
                const total_len = self.getCurrentBufferContent().total_len;
                if (total_len > 0) {
                    break :blk .{ .start = 0, .end = total_len };
                }
                break :blk null;
            },
            .current_line => blk: {
                // 現在行
                const line_num = self.getCurrentView().top_line + self.getCurrentView().cursor_y;
                const buffer = self.getCurrentBufferContent();
                if (buffer.getLineStart(line_num)) |line_start| {
                    const next_line_start = buffer.getLineStart(line_num + 1);
                    const line_end = if (next_line_start) |ns| ns else buffer.total_len;
                    if (line_end > line_start) {
                        break :blk .{ .start = line_start, .end = line_end };
                    }
                }
                break :blk null;
            },
        };

        // 入力データのサイズに応じてストリーミングモードか通常モードを選択
        // 64KB以上の場合はストリーミングモードでメモリ効率化
        const STREAMING_THRESHOLD: usize = 64 * 1024;
        const use_streaming = if (range) |r| (r.end - r.start) >= STREAMING_THRESHOLD else false;

        if (use_streaming) {
            // ストリーミングモード: Bufferから直接チャンクを読み取りながらパイプに書き込む
            self.shell_service.startStreaming(cmd_input) catch |err| {
                switch (err) {
                    error.EmptyCommand => self.getCurrentView().setError(config.Messages.NO_COMMAND_SPECIFIED),
                    error.NoCommand => self.getCurrentView().setError(config.Messages.NO_COMMAND_SPECIFIED),
                    else => self.getCurrentView().setError(config.Messages.COMMAND_START_FAILED),
                }
                return;
            };
            // ストリーミング範囲を設定（pollShellCommandで使用）
            self.streaming_range = .{
                .start = range.?.start,
                .end = range.?.end,
                .current_pos = range.?.start,
            };
        } else {
            // 通常モード: 小さなデータはgetRange()で複製
            var stdin_data: ?[]const u8 = null;
            var stdin_allocated = false;

            if (range) |r| {
                stdin_data = try self.getCurrentBufferContent().getRange(self.allocator, r.start, r.end - r.start);
                stdin_allocated = true;
            }

            self.shell_service.start(cmd_input, stdin_data, stdin_allocated) catch |err| {
                // エラー時は入力データを解放
                if (stdin_allocated) {
                    if (stdin_data) |data| {
                        self.allocator.free(data);
                    }
                }
                switch (err) {
                    error.EmptyCommand, error.NoCommand => {
                        self.getCurrentView().setError(config.Messages.NO_COMMAND_SPECIFIED);
                    },
                    else => {
                        self.getCurrentView().setError(config.Messages.COMMAND_START_FAILED);
                    },
                }
                return;
            };
        }

        self.mode = .shell_running;
        self.getCurrentView().setError(config.Messages.SHELL_RUNNING);
    }

    /// シェルコマンドの完了をポーリング
    fn pollShellCommand(self: *Editor) !void {
        // ストリーミングモード: Bufferから直接チャンクを読み取ってパイプに書き込む
        if (self.streaming_range) |*range| {
            const buffer = self.getCurrentBufferContent();
            const remaining = range.end - range.current_pos;
            if (remaining > 0) {
                // チャンクサイズ（16KB）で読み取り
                const chunk_size = @min(remaining, 16 * 1024);
                const chunk = buffer.getRange(self.allocator, range.current_pos, chunk_size) catch {
                    // メモリ不足時はストリーミングを中止
                    self.shell_service.closeStdin();
                    self.streaming_range = null;
                    return;
                };
                defer self.allocator.free(chunk);

                // パイプに書き込み
                const written = self.shell_service.writeStdinChunk(chunk) catch {
                    // パイプエラー時はストリーミングを中止
                    self.shell_service.closeStdin();
                    self.streaming_range = null;
                    return;
                };

                range.current_pos += written;

                // WouldBlock（written=0）でもループを抜けてUIを更新
            } else {
                // 全データを送信完了、stdinを閉じる
                self.shell_service.closeStdin();
                self.streaming_range = null;
            }
        }

        // ShellServiceにポーリングを委譲
        if (try self.shell_service.poll()) |result| {
            // コマンド完了 - 結果を処理
            defer self.shell_service.finish();
            defer self.mode = .normal; // エラー時も必ずモード復帰

            try self.processShellResult(result.stdout, result.stderr, result.exit_status, result.input_source, result.output_dest, result.truncated);

            // 完了後に再描画（processShellResultで設定したステータスメッセージを保持）
            self.getCurrentView().markFullRedraw();
        } else {
            // まだ実行中 - スピナーを更新
            const spinner_chars = [_]u8{ '|', '/', '-', '\\' };
            self.spinner_frame = @intCast((self.spinner_frame +% 1) % spinner_chars.len);
            var msg_buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Running {c} (C-g to cancel)", .{spinner_chars[self.spinner_frame]}) catch "Running...";
            self.getCurrentView().setError(msg);
        }
    }

    /// シェルコマンドをキャンセル
    fn cancelShellCommand(self: *Editor) void {
        self.shell_service.cancel();
        self.mode = .normal;
        self.getCurrentView().setError(config.Messages.CANCELLED);
    }

    /// シェルコマンドのエラーをチェックしてメッセージ表示
    /// exit_status が非0なら true を返す（呼び出し側は return すべき）
    fn checkShellError(self: *Editor, exit_status: ?u32, stderr: []const u8, extra_msg: []const u8, truncated_suffix: []const u8) bool {
        if (exit_status) |status| {
            if (status != 0) {
                // エラー時でもstderrがあればCommand bufferに保存（エラーメッセージを見られるように）
                if (stderr.len > 0) {
                    self.appendStderrToCommandBuffer(stderr) catch {};
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Command failed (exit {d}, C-x ` to view stderr){s}{s}", .{ status, extra_msg, truncated_suffix }) catch "Command failed";
                    self.getCurrentView().setError(msg);
                } else {
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Command failed (exit {d}){s}{s}", .{ status, extra_msg, truncated_suffix }) catch "Command failed";
                    self.getCurrentView().setError(msg);
                }
                return true;
            }
        }
        return false;
    }

    /// シェル出力で範囲を置換する共通処理
    /// start位置からlengthバイトを削除し、contentを挿入する
    fn replaceRangeWithShellOutput(self: *Editor, start: usize, length: usize, content: []const u8, cursor_after: ?usize, clear_mark: bool) !void {
        const buf = self.getCurrentBufferContent();
        const cursor_pos = self.getCurrentView().getCursorBufferPos();

        // 既存コンテンツを削除（undo記録付き）
        if (length > 0) {
            const old = try buf.getRange(self.allocator, start, length);
            defer self.allocator.free(old);
            try buf.delete(start, length);
            try self.recordDelete(start, old, cursor_pos);
        }

        // 新しいコンテンツを挿入（undo記録付き）
        if (content.len > 0) {
            try buf.insertSlice(start, content);
            try self.recordInsert(start, content, cursor_pos);
        }

        // 状態更新
        self.getCurrentBuffer().editing_ctx.modified = true;
        if (cursor_after) |pos| self.setCursorToPos(pos);
        if (clear_mark) self.window_manager.getCurrentWindow().mark_pos = null;
        self.markAllViewsFullRedrawForBuffer(self.getCurrentBuffer().id);
    }

    /// シェル実行結果を処理
    fn processShellResult(self: *Editor, stdout: []const u8, stderr: []const u8, exit_status: ?u32, input_source: ShellInputSource, output_dest: ShellOutputDest, truncated: bool) !void {
        const window = self.window_manager.getCurrentWindow();

        // truncated警告はステータスメッセージに含める（上書きされないように）
        const truncated_suffix: []const u8 = if (truncated) " [TRUNCATED]" else "";

        // 結果を処理
        switch (output_dest) {
            .command_buffer => {
                // *Command* バッファに出力を表示（直接挿入で連結コピーを回避）
                const total_output_len = stdout.len + stderr.len + @as(usize, if (stdout.len > 0 and stderr.len > 0 and stdout[stdout.len - 1] != '\n') 1 else 0);
                if (total_output_len == 0) {
                    if (exit_status) |status| {
                        if (status != 0) {
                            var msg_buf: [128]u8 = undefined;
                            const msg = std.fmt.bufPrint(&msg_buf, "Exit status: {d}{s}", .{ status, truncated_suffix }) catch "(exit error)";
                            self.getCurrentView().setError(msg);
                        } else {
                            var msg_buf: [64]u8 = undefined;
                            const msg = std.fmt.bufPrint(&msg_buf, "(no output){s}", .{truncated_suffix}) catch "(no output)";
                            self.getCurrentView().setError(msg);
                        }
                    } else {
                        var msg_buf: [64]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "(no output){s}", .{truncated_suffix}) catch "(no output)";
                        self.getCurrentView().setError(msg);
                    }
                    return;
                }

                // コマンドバッファを取得/作成
                const cmd_buffer = try self.getOrCreateCommandBuffer();

                // バッファをクリアして新しい内容を設定
                if (cmd_buffer.editing_ctx.buffer.total_len > 0) {
                    cmd_buffer.editing_ctx.buffer.delete(0, cmd_buffer.editing_ctx.buffer.total_len) catch {};
                }

                // 出力を直接挿入（連結コピーを回避）
                var insert_pos: usize = 0;
                if (stdout.len > 0) {
                    cmd_buffer.editing_ctx.buffer.insertSlice(0, stdout) catch {};
                    insert_pos = stdout.len;
                }
                if (stderr.len > 0) {
                    if (stdout.len > 0 and stdout[stdout.len - 1] != '\n') {
                        cmd_buffer.editing_ctx.buffer.insertSlice(insert_pos, "\n") catch {};
                        insert_pos += 1;
                    }
                    cmd_buffer.editing_ctx.buffer.insertSlice(insert_pos, stderr) catch {};
                }

                // コマンド出力は再生成可能なのでmodifiedをクリア
                cmd_buffer.editing_ctx.modified = false;

                // *Command* バッファを表示している全ウィンドウを更新
                const windows = self.window_manager.iterator();
                var found_cmd_window = false;
                for (windows) |*win| {
                    if (win.buffer_id == cmd_buffer.id) {
                        found_cmd_window = true;
                        win.view.markFullRedraw();
                        win.view.cursor_x = 0;
                        win.view.cursor_y = 0;
                        win.view.top_line = 0;
                        win.view.top_col = 0;
                    }
                }

                if (!found_cmd_window) {
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
                        var msg_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "Exit {d} (see below){s}", .{ status, truncated_suffix }) catch "Exit error";
                        self.getCurrentView().setError(msg);
                    } else if (stderr.len > 0) {
                        var msg_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "Done with warnings (see below){s}", .{truncated_suffix}) catch "Done with warnings";
                        self.getCurrentView().setError(msg);
                    } else {
                        var msg_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "Done (see below){s}", .{truncated_suffix}) catch "Done";
                        self.getCurrentView().setError(msg);
                    }
                } else if (stderr.len > 0) {
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Done with warnings (see below){s}", .{truncated_suffix}) catch "Done with warnings";
                    self.getCurrentView().setError(msg);
                } else {
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Done (see below){s}", .{truncated_suffix}) catch "Done";
                    self.getCurrentView().setError(msg);
                }
            },
            .replace, .insert => {
                // コマンドが失敗した場合は置換/挿入しない
                if (self.checkShellError(exit_status, stderr, ", buffer unchanged", truncated_suffix)) return;
                // 読み取り専用バッファでは置換/挿入を禁止
                if (self.isReadOnly()) {
                    self.getCurrentView().setError(config.Messages.BUFFER_READONLY);
                    return;
                }
                // 置換/挿入の開始位置と長さを計算
                const replace_info: struct { start: usize, length: usize, cursor_after: usize, clear_mark: bool } = switch (input_source) {
                    .selection => if (window.mark_pos) |mark| blk: {
                        const cursor_pos = self.getCurrentView().getCursorBufferPos();
                        const start = @min(mark, cursor_pos);
                        const end_pos = @max(mark, cursor_pos);
                        // .insertの場合、または選択範囲が空の場合は挿入のみ
                        const length = if (output_dest == .insert or end_pos <= start) 0 else end_pos - start;
                        break :blk .{ .start = start, .length = length, .cursor_after = start, .clear_mark = length > 0 };
                    } else blk: {
                        // 選択なしの場合はカーソル位置に挿入
                        const pos = self.getCurrentView().getCursorBufferPos();
                        break :blk .{ .start = pos, .length = 0, .cursor_after = pos, .clear_mark = false };
                    },
                    .buffer_all => .{
                        .start = 0,
                        .length = if (output_dest == .insert) 0 else self.getCurrentBufferContent().total_len,
                        .cursor_after = 0,
                        .clear_mark = false,
                    },
                    .current_line => blk: {
                        const line_num = self.getCurrentView().top_line + self.getCurrentView().cursor_y;
                        const buf = self.getCurrentBufferContent();
                        const line_start = buf.getLineStart(line_num) orelse 0;
                        const line_end = if (buf.getLineStart(line_num + 1)) |ns| ns else buf.total_len;
                        const length = if (output_dest == .insert) 0 else line_end - line_start;
                        break :blk .{ .start = line_start, .length = length, .cursor_after = line_start, .clear_mark = false };
                    },
                };
                // stdoutが空の場合でも削除は行う（置換対象を消す）
                if (stdout.len > 0 or replace_info.length > 0) {
                    try self.replaceRangeWithShellOutput(
                        replace_info.start,
                        replace_info.length,
                        stdout,
                        replace_info.cursor_after,
                        replace_info.clear_mark,
                    );
                }

                // stderrがある場合はCommand bufferに追記して警告表示
                if (stderr.len > 0) {
                    try self.appendStderrToCommandBuffer(stderr);
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Done with stderr (C-x ` to view){s}", .{truncated_suffix}) catch "Done with stderr";
                    self.getCurrentView().setError(msg);
                } else if (truncated) {
                    self.getCurrentView().setError("Warning: output truncated (10MB limit)");
                } else {
                    // 正常完了時もメッセージをクリア（Running...が残らないように）
                    self.getCurrentView().clearError();
                }
            },
            .new_buffer => {
                // コマンドが失敗した場合は新規バッファを作成しない
                if (self.checkShellError(exit_status, stderr, "", truncated_suffix)) return;
                // 新規バッファに出力
                if (stdout.len > 0) {
                    const new_buffer = try self.createNewBuffer();
                    try new_buffer.editing_ctx.buffer.insertSlice(0, stdout);
                    try self.switchToBuffer(new_buffer.id);

                    // stderrがある場合はCommand bufferに追記して警告表示
                    if (stderr.len > 0) {
                        try self.appendStderrToCommandBuffer(stderr);
                        var msg_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "Done with stderr (C-x ` to view){s}", .{truncated_suffix}) catch "Done with stderr";
                        self.getCurrentView().setError(msg);
                    } else if (truncated) {
                        self.getCurrentView().setError("Warning: output truncated (10MB limit)");
                    } else {
                        // 正常完了時もメッセージをクリア
                        self.getCurrentView().clearError();
                    }
                } else {
                    // stdoutが空でもstderrがあればCommand bufferに表示
                    if (stderr.len > 0) {
                        try self.appendStderrToCommandBuffer(stderr);
                        var msg_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "stderr only (C-x ` to view){s}", .{truncated_suffix}) catch "stderr only";
                        self.getCurrentView().setError(msg);
                    } else {
                        var msg_buf: [64]u8 = undefined;
                        const msg = std.fmt.bufPrint(&msg_buf, "(no output){s}", .{truncated_suffix}) catch "(no output)";
                        self.getCurrentView().setError(msg);
                    }
                }
            },
        }
    }

    /// stderrをCommand bufferに追記（replace/insert/new_buffer用）
    /// Command bufferのViewをdirtyにして再描画を保証する
    fn appendStderrToCommandBuffer(self: *Editor, stderr: []const u8) !void {
        const cmd_buffer = try self.getOrCreateCommandBuffer();

        // 既存内容の末尾にstderrを追記
        var insert_pos = cmd_buffer.editing_ctx.buffer.total_len;

        // セパレータを追加（既存内容がある場合）
        if (insert_pos > 0) {
            const separator = "\n--- stderr ---\n";
            cmd_buffer.editing_ctx.buffer.insertSlice(insert_pos, separator) catch {};
            insert_pos += separator.len;
        }

        // stderrを挿入
        cmd_buffer.editing_ctx.buffer.insertSlice(insert_pos, stderr) catch {};

        // modifiedフラグをクリア（コマンド出力は再生成可能）
        cmd_buffer.editing_ctx.modified = false;

        // Command bufferを表示しているViewをdirtyにして再描画を保証
        self.markAllViewsDirtyForBuffer(cmd_buffer.id, 0, null);

        // Command bufferウィンドウが開いていなければ開く（ユーザーがすぐ見られるように）
        _ = self.openCommandBufferWindow() catch {};
    }

    // ========================================
    // マクロ機能
    // ========================================

    /// マクロ制御キーかどうか判定（C-x (, C-x ), C-x e）
    fn isMacroControlKey(self: *Editor, key: input.Key) bool {
        // C-xキーはマクロに記録しない（プレフィックスとして処理される）
        switch (key) {
            .ctrl => |c| if (c == 'x') return true,
            .char => |ch| {
                // C-xプレフィックスモード中の (, ), e もマクロに記録しない
                if (self.mode == .prefix_x) {
                    if (ch == '(' or ch == ')' or ch == 'e') return true;
                }
            },
            else => {},
        }
        return false;
    }

    /// マクロ記録を開始
    fn startMacroRecording(self: *Editor) void {
        if (self.macro_service.isRecording()) {
            self.getCurrentView().setError(config.Messages.MACRO_ALREADY_RECORDING);
            return;
        }
        if (self.macro_service.isPlaying()) {
            self.getCurrentView().setError(config.Messages.MACRO_CANNOT_RECORD_WHILE_PLAYING);
            return;
        }
        self.macro_service.startRecording();
        self.getCurrentView().setError(config.Messages.MACRO_DEFINING);
    }

    /// マクロ記録を終了
    fn stopMacroRecording(self: *Editor) void {
        if (!self.macro_service.isRecording()) {
            self.getCurrentView().setError(config.Messages.MACRO_NOT_RECORDING);
            return;
        }
        self.macro_service.stopRecording();
        const count = self.macro_service.lastMacroKeyCount();
        if (count > 0) {
            self.setPrompt("Keyboard macro defined ({d} keys)", .{count});
        } else {
            self.getCurrentView().setError(config.Messages.MACRO_EMPTY);
        }
    }

    /// マクロを実行
    fn executeMacro(self: *Editor) anyerror!void {
        if (self.macro_service.isRecording()) {
            // 記録中にC-x eが押された場合、記録を終了してから実行
            self.macro_service.stopRecording();
        }

        try self.executeMacroInternal();

        // 連打モードに移行
        self.mode = .macro_repeat;
        self.getCurrentView().setError(config.Messages.MACRO_REPEAT_PROMPT);
    }

    /// マクロの内部実行（processKeyを使わない）
    fn executeMacroInternal(self: *Editor) anyerror!void {
        const macro = self.macro_service.getLastMacro() orelse {
            self.getCurrentView().setError(config.Messages.MACRO_NOT_DEFINED);
            return error.NoMacroDefined;
        };

        self.macro_service.beginPlayback();
        defer self.macro_service.endPlayback();

        for (macro) |key| {
            try self.handleNormalKey(key);
        }
    }

    /// マクロ連打モードのキー処理
    fn handleMacroRepeatKey(self: *Editor, key: input.Key) anyerror!void {
        switch (key) {
            .char => |c| {
                if (c == 'e') {
                    // マクロを再実行
                    try self.executeMacroInternal();
                    // モードはmacro_repeatのまま
                    self.getCurrentView().setError(config.Messages.MACRO_REPEAT_PROMPT);
                    return;
                }
            },
            .ctrl => |c| {
                if (c == 'g') {
                    // キャンセル
                    self.mode = .normal;
                    self.getCurrentView().clearError();
                    return;
                }
            },
            else => {},
        }

        // 他のキーは通常処理に戻す
        self.mode = .normal;
        self.getCurrentView().clearError();
        try self.handleNormalKey(key);
    }
};
