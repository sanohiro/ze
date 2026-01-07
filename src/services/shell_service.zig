// ============================================================================
// ShellService - シェルコマンド実行サービス
// ============================================================================
//
// 【責務】
// - シェルコマンドの非同期実行
// - stdin/stdout/stderrの非ブロッキングI/O
// - コマンド履歴の管理
// - 結果の処理（置換、挿入、新規バッファ）
//
// 【設計原則】
// - Editorへの依存を最小化（コールバック経由で結果を返す）
// - 状態管理を独立させ、テスト可能に
// ============================================================================

const std = @import("std");
const history_mod = @import("history");
const LazyHistory = history_mod.LazyHistory;
const config = @import("config");
const unicode = @import("unicode");

/// シェル構文上の空白文字（スペースとタブ）を判定
inline fn isShellWhitespace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// NONBLOCKフラグ（複数箇所で使用）
const NONBLOCK_FLAG: usize = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));

/// ファイルハンドルをノンブロッキングモードに設定
fn setNonBlocking(file: std.fs.File) void {
    const flags = std.posix.fcntl(file.handle, std.posix.F.GETFL, 0) catch 0;
    _ = std.posix.fcntl(file.handle, std.posix.F.SETFL, flags | NONBLOCK_FLAG) catch {};
}

/// ファイルハンドルをブロッキングモードに設定
fn setBlocking(file: std.fs.File) void {
    const flags = std.posix.fcntl(file.handle, std.posix.F.GETFL, 0) catch 0;
    _ = std.posix.fcntl(file.handle, std.posix.F.SETFL, flags & ~NONBLOCK_FLAG) catch {};
}

/// シェルコマンド出力先
pub const OutputDest = enum {
    command_buffer, // Command Bufferに表示（デフォルト）
    replace, // 入力元を置換 (>)
    insert, // カーソル位置に挿入 (+>)
    new_buffer, // 新規バッファ (n>)
};

/// シェルコマンド入力元
pub const InputSource = enum {
    selection, // 選択範囲（なければ空）
    buffer_all, // バッファ全体 (%)
    current_line, // 現在行 (.)
};

/// パースされたコマンド
pub const ParsedCommand = struct {
    input_source: InputSource,
    output_dest: OutputDest,
    command: []const u8,
};

/// シェルコマンドの非同期実行状態
pub const CommandState = struct {
    child: std.process.Child,
    input_source: InputSource,
    output_dest: OutputDest,
    stdin_data: ?[]const u8,
    stdin_allocated: bool,
    stdin_write_pos: usize,
    command: []const u8, // ヒープに確保されたコマンド文字列
    stdout_buffer: std.ArrayListUnmanaged(u8),
    stderr_buffer: std.ArrayListUnmanaged(u8),
    child_reaped: bool,
    exit_status: ?u32,
    stdout_truncated: bool, // 出力が10MB制限で切り詰められた
    stderr_truncated: bool,
    nonblock_configured: bool, // NONBLOCKフラグ設定済み（遅延設定用）
    streaming_mode: bool, // ストリーミングモード（呼び出し側がstdinに書き込む）
    stdin_eof_sent: bool, // stdinのEOFが送信済み
};

/// シェルコマンド実行結果
pub const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_status: ?u32,
    input_source: InputSource,
    output_dest: OutputDest,
    truncated: bool, // 出力が10MB制限で切り詰められた
};

/// シェルコマンド実行サービス
pub const ShellService = struct {
    allocator: std.mem.Allocator,
    state: ?*CommandState,
    history: LazyHistory,
    bash_path: ?[]const u8, // bashのパス（見つかった場合、遅延初期化）
    sh_path: ?[]const u8, // shのパス（見つかった場合、遅延初期化）
    aliases_path: ?[]const u8, // ~/.ze/aliasesのパス（存在する場合、遅延初期化）
    paths_initialized: bool, // bash_path/aliases_pathが初期化済みか

    const Self = @This();

    /// バッファサイズ制限付きで読み取り
    /// 全てのエラー（WouldBlock含む）でループを終了
    /// 戻り値: trueなら制限に達して切り詰めた
    fn readWithLimit(
        allocator: std.mem.Allocator,
        file: std.fs.File,
        buffer: *std.ArrayListUnmanaged(u8),
        read_buf: []u8,
    ) !bool {
        var truncated = false;
        while (buffer.items.len < config.Shell.MAX_OUTPUT_SIZE) {
            const bytes_read = file.read(read_buf) catch break;
            if (bytes_read == 0) break;
            const available = config.Shell.MAX_OUTPUT_SIZE - buffer.items.len;
            const to_append = @min(bytes_read, available);
            if (to_append > 0) {
                try buffer.appendSlice(allocator, read_buf[0..to_append]);
            }
            if (to_append < bytes_read) {
                truncated = true;
                break;
            }
        }
        // 上限に達したかチェック
        if (buffer.items.len >= config.Shell.MAX_OUTPUT_SIZE) {
            truncated = true;
        }
        return truncated;
    }

    /// パイプから1チャンク読み取る共通処理
    /// 戻り値: データを読み取った場合はtrue
    fn readFromPipe(
        self: *Self,
        state: *CommandState,
        file_ptr: *?std.fs.File,
        buffer: *std.ArrayListUnmanaged(u8),
        truncated: *bool,
        read_buf: []u8,
    ) !bool {
        const file = file_ptr.* orelse return false;
        if (buffer.items.len >= config.Shell.MAX_OUTPUT_SIZE) {
            // 上限到達時はパイプを閉じる
            truncated.* = true;
            file.close();
            file_ptr.* = null;
            return false;
        }

        const bytes_read: usize = file.read(read_buf) catch |err| switch (err) {
            error.WouldBlock => return false, // ノンブロッキングで読めるデータがない
            else => {
                // 真のエラー（EIO、EBADFD等）: パイプを閉じて続行
                file.close();
                file_ptr.* = null;
                return false;
            },
        };

        if (bytes_read == 0) {
            // EOF: パイプを閉じて無駄なread()ループを防ぐ
            file.close();
            file_ptr.* = null;
            return false;
        }

        const available = config.Shell.MAX_OUTPUT_SIZE - buffer.items.len;
        const to_append = @min(bytes_read, available);
        if (to_append > 0) {
            try buffer.appendSlice(self.allocator, read_buf[0..to_append]);
        }
        if (to_append < bytes_read) {
            truncated.* = true;
        }

        // 上限に達したらパイプを閉じる
        if (buffer.items.len >= config.Shell.MAX_OUTPUT_SIZE) {
            truncated.* = true;
            file.close();
            file_ptr.* = null;
        }

        _ = state; // 将来的な拡張用
        return true;
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        // 履歴とパス検索は遅延初期化（起動高速化）
        return .{
            .allocator = allocator,
            .state = null,
            .history = LazyHistory.init(allocator, .shell),
            .bash_path = null,
            .sh_path = null,
            .aliases_path = null,
            .paths_initialized = false,
        };
    }

    /// パス検索の遅延初期化（初回コマンド実行時に呼ばれる）
    fn ensurePathsInitialized(self: *Self) void {
        if (!self.paths_initialized) {
            self.paths_initialized = true;

            // bashのパスを探す（$SHELL → 一般的なパス）
            self.bash_path = findBashPath(self.allocator);

            // shのパスを探す（POSIX準拠シェル用）
            self.sh_path = findShPath(self.allocator);
        }

        // ~/.ze/aliases のチェック（毎回存在確認してキャッシュ無効化対応）
        self.checkAliasesFile();
    }

    /// ~/.ze/aliases ファイルの存在チェック
    /// キャッシュ済みでも削除されていればnullに戻す
    fn checkAliasesFile(self: *Self) void {
        // 既にキャッシュ済みの場合、ファイルが存在するか確認
        if (self.aliases_path) |cached_path| {
            if (std.fs.accessAbsolute(cached_path, .{})) |_| {
                // ファイルは存在する、キャッシュ有効
                return;
            } else |_| {
                // ファイルが削除された、キャッシュ無効化
                self.allocator.free(cached_path);
                self.aliases_path = null;
            }
        }

        // 未検出の場合、新規検索
        if (std.posix.getenv("HOME")) |home| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/.ze/aliases", .{home}) catch null;
            if (path) |p| {
                if (std.fs.accessAbsolute(p, .{})) |_| {
                    self.aliases_path = p;
                } else |_| {
                    self.allocator.free(p);
                }
            }
        }
    }

    /// タイムアウト付きでコマンドを実行（UIフリーズ防止）
    /// timeout_ms: ミリ秒単位のタイムアウト
    const RunResult = struct {
        stdout: []u8,
        stderr: []u8,
    };

    fn runWithTimeout(self: *Self, argv: []const []const u8, timeout_ms: u32) !RunResult {
        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.stdin_behavior = .Close; // 補完コマンドはstdin不要、エディタと競合防止

        try child.spawn();

        // パイプをノンブロッキングに設定
        if (child.stdout) |stdout| setNonBlocking(stdout);
        if (child.stderr) |stderr| setNonBlocking(stderr);

        var stdout_list: std.ArrayListUnmanaged(u8) = .{};
        errdefer stdout_list.deinit(self.allocator);
        var stderr_list: std.ArrayListUnmanaged(u8) = .{};
        errdefer stderr_list.deinit(self.allocator);

        const start_time = std.time.milliTimestamp();
        var child_exited = false;

        while (!child_exited) {
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed >= timeout_ms) {
                // タイムアウト: パイプを閉じてから子プロセスをキル
                if (child.stdout) |stdout| stdout.close();
                child.stdout = null;
                if (child.stderr) |stderr| stderr.close();
                child.stderr = null;
                _ = child.kill() catch {};
                _ = child.wait() catch {};
                return error.Timeout;
            }

            // パイプからドレイン（デッドロック防止）
            try self.drainPipe(&child.stdout, &stdout_list, config.Shell.COMPLETION_MAX_OUTPUT);
            try self.drainPipe(&child.stderr, &stderr_list, 4096);

            // ノンブロッキング完了チェック（WNOHANG = 1）
            const WNOHANG: u32 = 1;
            const result = std.posix.waitpid(child.id, WNOHANG);
            if (result.pid != 0) {
                // 子プロセスが終了
                child_exited = true;
            } else {
                // まだ実行中、少し待つ
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        // 残りの出力を読み取り
        try self.drainPipeBlocking(&child.stdout, &stdout_list, config.Shell.COMPLETION_MAX_OUTPUT);
        try self.drainPipeBlocking(&child.stderr, &stderr_list, 4096);

        // パイプを閉じる（FDリーク防止）
        if (child.stdout) |stdout| stdout.close();
        child.stdout = null;
        if (child.stderr) |stderr| stderr.close();
        child.stderr = null;

        return .{
            .stdout = try stdout_list.toOwnedSlice(self.allocator),
            .stderr = try stderr_list.toOwnedSlice(self.allocator),
        };
    }

    /// パイプからノンブロッキングで読み取り
    fn drainPipe(self: *Self, pipe_ptr: *?std.fs.File, list: *std.ArrayListUnmanaged(u8), max_size: usize) !void {
        if (pipe_ptr.*) |pipe| {
            var buf: [4096]u8 = undefined;
            while (list.items.len < max_size) {
                const n = pipe.read(&buf) catch |err| {
                    if (err == error.WouldBlock) break;
                    break;
                };
                if (n == 0) break;
                try list.appendSlice(self.allocator, buf[0..n]);
            }
        }
    }

    /// パイプからブロッキングで全て読み取り（プロセス終了後用）
    fn drainPipeBlocking(self: *Self, pipe_ptr: *?std.fs.File, list: *std.ArrayListUnmanaged(u8), max_size: usize) !void {
        if (pipe_ptr.*) |pipe| {
            // ブロッキングモードに戻す
            setBlocking(pipe);

            var buf: [4096]u8 = undefined;
            while (list.items.len < max_size) {
                const n = pipe.read(&buf) catch break;
                if (n == 0) break;
                try list.appendSlice(self.allocator, buf[0..n]);
            }
        }
    }

    /// シェル用にパスをクォート（シングルクォート使用）
    fn shellQuote(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        // シングルクォートで囲む。内部の ' は '\'' に置換
        var size: usize = 2; // 開始と終了の '
        for (s) |c| {
            if (c == '\'') {
                size += 4; // '\''
            } else {
                size += 1;
            }
        }
        var result = try allocator.alloc(u8, size);
        var i: usize = 0;
        result[i] = '\'';
        i += 1;
        for (s) |c| {
            if (c == '\'') {
                result[i] = '\'';
                result[i + 1] = '\\';
                result[i + 2] = '\'';
                result[i + 3] = '\'';
                i += 4;
            } else {
                result[i] = c;
                i += 1;
            }
        }
        result[i] = '\'';
        return result;
    }

    /// 実行可能ファイルをPATHとフォールバックパスから検索する共通関数
    fn findExecutable(
        allocator: std.mem.Allocator,
        name: []const u8,
        shell_env_suffix: ?[]const u8,
        fallback_paths: []const []const u8,
    ) ?[]const u8 {
        // 1. $SHELL 環境変数をチェック（suffixが指定された場合のみ）
        if (shell_env_suffix) |suffix| {
            if (std.posix.getenv("SHELL")) |shell| {
                if (std.mem.endsWith(u8, shell, suffix)) {
                    if (std.fs.accessAbsolute(shell, .{})) |_| {
                        return allocator.dupe(u8, shell) catch null;
                    } else |_| {}
                }
            }
        }
        // 2. PATH環境変数から検索（スタックバッファ使用）
        // 長いNixストアパスなどに対応するため4096バイトを確保
        if (std.posix.getenv("PATH")) |path_env| {
            var path_buf: [4096]u8 = undefined;
            var it = std.mem.splitScalar(u8, path_env, ':');
            while (it.next()) |dir| {
                const exec_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
                if (std.fs.accessAbsolute(exec_path, .{})) |_| {
                    return allocator.dupe(u8, exec_path) catch null;
                } else |_| {}
            }
        }
        // 3. フォールバックパスを試す
        for (fallback_paths) |path| {
            if (std.fs.accessAbsolute(path, .{})) |_| {
                return allocator.dupe(u8, path) catch null;
            } else |_| {}
        }
        return null;
    }

    /// bashのパスを探す
    fn findBashPath(allocator: std.mem.Allocator) ?[]const u8 {
        const fallbacks = [_][]const u8{
            "/bin/bash",
            "/usr/bin/bash",
            "/usr/local/bin/bash",
            "/opt/homebrew/bin/bash",
            "/opt/local/bin/bash",
        };
        return findExecutable(allocator, "bash", "/bash", &fallbacks);
    }

    /// shのパスを探す
    fn findShPath(allocator: std.mem.Allocator) ?[]const u8 {
        const fallbacks = [_][]const u8{ "/bin/sh", "/usr/bin/sh", "/system/bin/sh" };
        return findExecutable(allocator, "sh", null, &fallbacks);
    }

    pub fn deinit(self: *Self) void {
        if (self.state) |state| {
            self.cleanupState(state);
        }
        self.history.deinit();
        if (self.bash_path) |p| {
            self.allocator.free(p);
        }
        if (self.sh_path) |p| {
            self.allocator.free(p);
        }
        if (self.aliases_path) |p| {
            self.allocator.free(p);
        }
    }

    /// 指定位置が引用符の内部にあるかどうかをチェック
    /// シングルクォート、ダブルクォート、バックスラッシュエスケープを考慮
    /// シェルの仕様に従い:
    /// - シングルクォート内: バックスラッシュはリテラル（エスケープしない）
    /// - ダブルクォート内: \" と \\ のみエスケープ
    /// - 引用符外: バックスラッシュは次の文字をエスケープ
    fn isPositionInsideQuotes(s: []const u8, pos: usize) bool {
        var in_single = false;
        var in_double = false;
        var i: usize = 0;
        while (i < pos and i < s.len) : (i += 1) {
            const c = s[i];
            // バックスラッシュエスケープ（シングルクォート内では無効）
            if (c == '\\' and i + 1 < s.len and !in_single) {
                const next_c = s[i + 1];
                // ダブルクォート内では \" と \\ のみエスケープ
                // 引用符外では全てエスケープ
                if (!in_double or next_c == '"' or next_c == '\\') {
                    i += 1;
                    continue;
                }
            }
            if (c == '\'' and !in_double) {
                in_single = !in_single;
            } else if (c == '"' and !in_single) {
                in_double = !in_double;
            }
        }
        return in_single or in_double;
    }

    /// コマンド文字列をパースしてプレフィックス/サフィックスを取り出す
    pub fn parseCommand(cmd: []const u8) ParsedCommand {
        var input_source: InputSource = .selection;
        var output_dest: OutputDest = .command_buffer;
        var cmd_start: usize = 0;
        var cmd_end: usize = cmd.len;

        // 先頭の空白をスキップ（スペースとタブ）
        while (cmd_start < cmd.len and isShellWhitespace(cmd[cmd_start])) : (cmd_start += 1) {}

        // プレフィックス解析（引用符内でない場合のみ）
        // 注意: 先頭位置なのでisPositionInsideQuotesは常にfalseだが、
        // '%foo'のような入力でも'%'が先頭にある場合を考慮
        if (cmd_start < cmd.len and !isPositionInsideQuotes(cmd, cmd_start)) {
            if (cmd[cmd_start] == '%') {
                // "% " または "%|" の場合のみバッファ全体プレフィックス
                // '%foo' のようにクォートされている場合は通常コマンド
                const next_idx = cmd_start + 1;
                if (next_idx >= cmd.len or isShellWhitespace(cmd[next_idx]) or cmd[next_idx] == '|') {
                    input_source = .buffer_all;
                    cmd_start += 1;
                    while (cmd_start < cmd.len and isShellWhitespace(cmd[cmd_start])) : (cmd_start += 1) {}
                }
            } else if (cmd[cmd_start] == '.') {
                // ". " または ".|" の場合のみ現在行プレフィックス（"./cmd" は通常コマンド）
                const next_idx = cmd_start + 1;
                if (next_idx >= cmd.len or isShellWhitespace(cmd[next_idx]) or cmd[next_idx] == '|') {
                    input_source = .current_line;
                    cmd_start += 1;
                    while (cmd_start < cmd.len and isShellWhitespace(cmd[cmd_start])) : (cmd_start += 1) {}
                }
            }
        }

        // パイプ記号 '|' をスキップ
        if (cmd_start < cmd.len and cmd[cmd_start] == '|') {
            cmd_start += 1;
            while (cmd_start < cmd.len and isShellWhitespace(cmd[cmd_start])) : (cmd_start += 1) {}
        }

        // サフィックス解析（末尾から、引用符を考慮）
        // 重要: サフィックスはコマンドとスペースで区切られている必要がある
        // 例: "sort >" は有効、"grep -n>out" は無効（シェルのリダイレクト構文）
        if (cmd_end > cmd_start) {
            while (cmd_end > cmd_start and isShellWhitespace(cmd[cmd_end - 1])) : (cmd_end -= 1) {}

            // 引用符の外にあるサフィックスのみ解釈
            // サフィックスの開始位置が引用符内かどうかをチェック
            if (cmd_end > cmd_start) {
                if (cmd_end >= 3 and cmd[cmd_end - 2] == 'n' and cmd[cmd_end - 1] == '>' and isShellWhitespace(cmd[cmd_end - 3])) {
                    // " n>" の場合のみ新規バッファとして解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 2)) {
                        output_dest = .new_buffer;
                        cmd_end -= 2;
                    }
                } else if (cmd_end >= 3 and cmd[cmd_end - 2] == '+' and cmd[cmd_end - 1] == '>' and isShellWhitespace(cmd[cmd_end - 3])) {
                    // " +>" の場合のみ挿入として解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 2)) {
                        output_dest = .insert;
                        cmd_end -= 2;
                    }
                } else if (cmd[cmd_end - 1] == '>') {
                    // " >" の場合のみ置換として解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 1)) {
                        if (cmd_end >= 2 and isShellWhitespace(cmd[cmd_end - 2])) {
                            output_dest = .replace;
                            cmd_end -= 1;
                        }
                    }
                }
            }

            while (cmd_end > cmd_start and isShellWhitespace(cmd[cmd_end - 1])) : (cmd_end -= 1) {}
        }

        return .{
            .input_source = input_source,
            .output_dest = output_dest,
            .command = if (cmd_end > cmd_start) cmd[cmd_start..cmd_end] else "",
        };
    }

    /// コマンド実行用の共通初期化（start/startStreaming共通）
    /// 戻り値: (CommandState, actual_command) - errdefer用にactual_commandも返す
    fn initCommandState(self: *Self, parsed: ParsedCommand) !struct { state: *CommandState, command: []const u8 } {
        // bash + alias を使うかどうか判定
        const use_bash_aliases = self.bash_path != null and self.aliases_path != null;

        // 状態を作成
        const state = try self.allocator.create(CommandState);
        errdefer self.allocator.destroy(state);

        // 子プロセスを起動
        const actual_command: []const u8 = if (use_bash_aliases) blk: {
            // bash -c 'shopt -s expand_aliases; . "path"; eval "command"'
            const quoted_path = try shellQuote(self.allocator, self.aliases_path.?);
            defer self.allocator.free(quoted_path);
            const quoted_cmd = try shellQuote(self.allocator, parsed.command);
            defer self.allocator.free(quoted_cmd);
            const wrapped = try std.fmt.allocPrint(self.allocator, "shopt -s expand_aliases; . {s}; eval {s}", .{ quoted_path, quoted_cmd });
            const argv = [_][]const u8{ self.bash_path.?, "-c", wrapped };
            state.child = std.process.Child.init(&argv, self.allocator);
            break :blk wrapped;
        } else blk: {
            // shを使用（POSIX準拠を保証）
            const command_copy = try self.allocator.dupe(u8, parsed.command);
            const sh_path = self.sh_path orelse "/bin/sh";
            const argv = [_][]const u8{ sh_path, "-c", command_copy };
            state.child = std.process.Child.init(&argv, self.allocator);
            break :blk command_copy;
        };
        errdefer self.allocator.free(actual_command);

        // 共通の初期化
        state.child.stdout_behavior = .Pipe;
        state.child.stderr_behavior = .Pipe;
        state.input_source = parsed.input_source;
        state.output_dest = parsed.output_dest;
        state.command = actual_command;
        state.stdout_buffer = .{};
        state.stderr_buffer = .{};
        state.child_reaped = false;
        state.exit_status = null;
        state.stdout_truncated = false;
        state.stderr_truncated = false;
        state.nonblock_configured = false;

        return .{ .state = state, .command = actual_command };
    }

    /// シェルコマンドを非同期で開始
    /// parsedは呼び出し元でparseCommand()した結果を渡す（二重パース防止）
    pub fn start(self: *Self, parsed: ParsedCommand, stdin_data: ?[]const u8, stdin_allocated: bool) !void {
        if (parsed.command.len == 0) return error.NoCommand;

        // 遅延初期化: bashパスとaliasesパスを検索（初回のみ）
        self.ensurePathsInitialized();

        // 既存の状態をクリア（リーク防止）
        if (self.state) |old_state| {
            self.cleanupState(old_state);
            self.state = null;
        }

        // 共通初期化
        const result = try self.initCommandState(parsed);
        const state = result.state;
        errdefer self.allocator.destroy(state);
        errdefer self.allocator.free(result.command);
        // stdin_dataの所有権を受け取る場合、spawn失敗時に解放
        errdefer if (stdin_allocated) {
            if (stdin_data) |data| self.allocator.free(data);
        };

        // start固有の設定
        state.child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
        state.stdin_data = stdin_data;
        state.stdin_allocated = stdin_allocated;
        state.stdin_write_pos = 0;
        state.streaming_mode = false;
        state.stdin_eof_sent = false;

        try state.child.spawn();

        // stdinデータがない場合のみここで閉じる
        if (stdin_data == null) {
            if (state.child.stdin) |stdin| {
                stdin.close();
                state.child.stdin = null;
            }
        }

        self.state = state;
    }

    /// ストリーミングモードでシェルコマンドを開始
    /// 呼び出し側がwriteStdinChunk()でstdinにデータを書き込み、closeStdin()で終了する
    /// parsedは呼び出し元でparseCommand()した結果を渡す（二重パース防止）
    pub fn startStreaming(self: *Self, parsed: ParsedCommand) !void {
        if (parsed.command.len == 0) return error.NoCommand;

        // 遅延初期化: bashパスとaliasesパスを検索（初回のみ）
        self.ensurePathsInitialized();

        // 既存の状態をクリア（リーク防止）
        if (self.state) |old_state| {
            self.cleanupState(old_state);
            self.state = null;
        }

        // 共通初期化
        const result = try self.initCommandState(parsed);
        const state = result.state;
        errdefer self.allocator.destroy(state);
        errdefer self.allocator.free(result.command);

        // startStreaming固有の設定
        state.child.stdin_behavior = .Pipe;
        state.stdin_data = null;
        state.stdin_allocated = false;
        state.stdin_write_pos = 0;
        state.streaming_mode = true;
        state.stdin_eof_sent = false;

        try state.child.spawn();

        self.state = state;
    }

    /// ストリーミングモード: stdinにチャンクを書き込む
    /// 戻り値: 書き込んだバイト数（WouldBlockの場合は0）
    pub fn writeStdinChunk(self: *Self, data: []const u8) !usize {
        const state = self.state orelse return error.NotRunning;
        if (!state.streaming_mode) return error.NotStreamingMode;
        if (state.stdin_eof_sent) return error.StdinClosed;

        const stdin_file = state.child.stdin orelse return error.StdinClosed;

        // NONBLOCKを設定（初回のみ）
        if (!state.nonblock_configured) {
            state.nonblock_configured = true;
            setNonBlocking(stdin_file);
            // stdout/stderrも同時にNONBLOCK設定
            if (state.child.stdout) |stdout_file| setNonBlocking(stdout_file);
            if (state.child.stderr) |stderr_file| setNonBlocking(stderr_file);
        }

        return stdin_file.write(data) catch |err| switch (err) {
            error.WouldBlock => 0,
            else => err,
        };
    }

    /// ストリーミングモード: stdinを閉じる（EOF送信）
    pub fn closeStdin(self: *Self) void {
        const state = self.state orelse return;
        if (state.stdin_eof_sent) return;

        state.stdin_eof_sent = true;
        if (state.child.stdin) |stdin| {
            stdin.close();
            state.child.stdin = null;
        }
    }

    /// シェルコマンドの完了をポーリング
    /// 戻り値: 完了した場合は結果、まだ実行中の場合はnull
    pub fn poll(self: *Self) !?CommandResult {
        var state = self.state orelse return null;

        // 初回のみNONBLOCKを設定（遅延初期化でspawn時のシステムコールを削減）
        if (!state.nonblock_configured) {
            state.nonblock_configured = true;
            if (state.child.stdout) |stdout_file| setNonBlocking(stdout_file);
            if (state.child.stderr) |stderr_file| setNonBlocking(stderr_file);
            if (state.child.stdin) |stdin_file| setNonBlocking(stdin_file);
        }

        var read_buf: [config.Shell.READ_BUFFER_SIZE]u8 = undefined;

        // stdout と stderr を交互に読取（デッドロック防止）
        // 一方のパイプが詰まってもう一方を先に処理する必要がある場合に対応
        // WouldBlockになるまで読み続ける（パイプが詰まって子プロセスがブロックするのを防ぐ）
        while (true) {
            var any_read = false;

            // stdout から1チャンク読み取り
            const stdout_result = try self.readFromPipe(state, &state.child.stdout, &state.stdout_buffer, &state.stdout_truncated, &read_buf);
            if (stdout_result) any_read = true;

            // stderr から1チャンク読み取り
            const stderr_result = try self.readFromPipe(state, &state.child.stderr, &state.stderr_buffer, &state.stderr_truncated, &read_buf);
            if (stderr_result) any_read = true;

            if (!any_read) break;
        }

        // stdin へのストリーミング書き込み
        if (state.child.stdin) |stdin_file| {
            if (state.stdin_data) |data| {
                // アンダーフロー防止: write_pos が data.len を超える場合は remaining = 0
                const remaining = if (state.stdin_write_pos < data.len)
                    data.len - state.stdin_write_pos
                else
                    0;
                if (remaining > 0) {
                    // 大きなデータでは64KBチャンク、通常は16KBチャンク（システムコール削減）
                    const chunk_size = if (data.len > 1024 * 1024)
                        @min(remaining, config.Shell.LARGE_CHUNK_SIZE)
                    else
                        @min(remaining, config.Shell.READ_BUFFER_SIZE);
                    const chunk = data[state.stdin_write_pos .. state.stdin_write_pos + chunk_size];
                    const bytes_written = stdin_file.write(chunk) catch |err| switch (err) {
                        error.WouldBlock => 0,
                        else => blk: {
                            stdin_file.close();
                            state.child.stdin = null;
                            break :blk 0;
                        },
                    };
                    state.stdin_write_pos += bytes_written;
                } else {
                    stdin_file.close();
                    state.child.stdin = null;
                }
            }
        }

        // 既に回収済みの場合は結果を返す（再呼び出し対応）
        if (state.child_reaped) {
            const cmd_result = CommandResult{
                .stdout = state.stdout_buffer.items,
                .stderr = state.stderr_buffer.items,
                .exit_status = state.exit_status,
                .input_source = state.input_source,
                .output_dest = state.output_dest,
                .truncated = state.stdout_truncated or state.stderr_truncated,
            };
            return cmd_result;
        }

        // waitpidでプロセス終了をチェック
        const result = std.posix.waitpid(state.child.id, std.posix.W.NOHANG);

        if (result.pid == 0) {
            return null; // まだ実行中
        }

        state.child_reaped = true;

        // 終了ステータスを記録
        if (std.c.W.IFEXITED(result.status)) {
            state.exit_status = std.c.W.EXITSTATUS(result.status);
        } else if (std.c.W.IFSIGNALED(result.status)) {
            state.exit_status = 128 + @as(u32, std.c.W.TERMSIG(result.status));
        } else {
            state.exit_status = null;
        }

        // 残りのデータを読み取る（上限チェック付き、ブロッキング）
        if (state.child.stdout) |stdout_file| {
            if (try readWithLimit(self.allocator, stdout_file, &state.stdout_buffer, &read_buf)) {
                state.stdout_truncated = true;
            }
        }
        if (state.child.stderr) |stderr_file| {
            if (try readWithLimit(self.allocator, stderr_file, &state.stderr_buffer, &read_buf)) {
                state.stderr_truncated = true;
            }
        }

        // 結果を返す
        const cmd_result = CommandResult{
            .stdout = state.stdout_buffer.items,
            .stderr = state.stderr_buffer.items,
            .exit_status = state.exit_status,
            .input_source = state.input_source,
            .output_dest = state.output_dest,
            .truncated = state.stdout_truncated or state.stderr_truncated,
        };

        return cmd_result;
    }

    /// 実行完了後のクリーンアップ
    pub fn finish(self: *Self) void {
        if (self.state) |state| {
            self.cleanupState(state);
        }
    }

    /// シェルコマンドをキャンセル
    /// UIをブロックしないようノンブロッキングでプロセスを終了
    pub fn cancel(self: *Self) void {
        if (self.state) |state| {
            if (!state.child_reaped) {
                // SIGKILLで強制終了（SIGTERMを無視するプロセス対策）
                _ = std.posix.kill(state.child.id, std.posix.SIG.KILL) catch {};
                // ノンブロッキングでwaitを試みる（ゾンビプロセス回収）
                // 回収できなくても次のpollで処理される
                const wait_result = std.posix.waitpid(state.child.id, std.posix.W.NOHANG);
                if (wait_result.pid != 0) {
                    state.child_reaped = true;
                }
            }
            self.cleanupState(state);
        }
    }

    /// 実行中かどうか
    pub fn isRunning(self: *Self) bool {
        return self.state != null;
    }

    fn cleanupState(self: *Self, state: *CommandState) void {
        // 子プロセスをkill（まだ回収されていない場合のみ）
        if (!state.child_reaped) {
            // SIGKILLで強制終了（SIGTERMはプロセスが無視する可能性がありブロックの原因）
            _ = std.posix.kill(state.child.id, std.posix.SIG.KILL) catch {};
            _ = state.child.wait() catch {};
        }

        // パイプを閉じる
        if (state.child.stdin) |stdin| stdin.close();
        if (state.child.stdout) |stdout| stdout.close();
        if (state.child.stderr) |stderr| stderr.close();

        // stdinデータを解放
        if (state.stdin_allocated) {
            if (state.stdin_data) |data| {
                self.allocator.free(data);
            }
        }

        // コマンド文字列を解放
        self.allocator.free(state.command);

        // バッファを解放
        state.stdout_buffer.deinit(self.allocator);
        state.stderr_buffer.deinit(self.allocator);

        // 状態を解放
        self.allocator.destroy(state);
        self.state = null;
    }

    /// 補完結果
    pub const CompletionResult = struct {
        matches: [][]const u8, // マッチした補完候補
        common_prefix: []const u8, // 共通プレフィックス
        allocator: std.mem.Allocator,

        pub fn deinit(self: *CompletionResult) void {
            for (self.matches) |m| {
                self.allocator.free(m);
            }
            self.allocator.free(self.matches);
            self.allocator.free(self.common_prefix);
        }
    };

    /// bashのcompgenを使って補完候補を取得
    /// input: シェルコマンド入力全体
    /// 戻り値: 補完結果（呼び出し側でdeinit()する必要あり）
    /// 注意: 500msタイムアウトでUIフリーズを防止
    pub fn getCompletions(self: *Self, input: []const u8) !?CompletionResult {
        // 入力から最後のトークンを取得
        const token = getLastToken(input);
        if (token.len == 0) return null;

        // パス文字を含むかでコマンド補完かファイル補完かを判断
        const is_path = std.mem.indexOfScalar(u8, token, '/') != null or
            std.mem.startsWith(u8, token, "~") or
            std.mem.startsWith(u8, token, ".");

        const flag = if (is_path) "-f" else "-c";

        // compgenコマンドを構築
        // シングルクォートをエスケープ
        var escaped_buf: [512]u8 = undefined;
        const escaped_token = escapeForShell(token, &escaped_buf) orelse return null;

        var cmd_buf: [1024]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "compgen {s} -- '{s}' 2>/dev/null", .{ flag, escaped_token }) catch return null;

        // キャッシュされたbashパスを使用（未初期化なら初期化）
        self.ensurePathsInitialized();
        const bash_path = self.bash_path orelse return null;

        // タイムアウト付きでcompgenを実行（UIフリーズ防止）
        const result = self.runWithTimeout(&.{ bash_path, "-c", cmd }, 500) catch return null;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.stdout.len == 0) return null;

        // 結果を行に分割
        var lines: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (lines.items) |line| self.allocator.free(line);
            lines.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, result.stdout, '\n');
        while (iter.next()) |line| {
            if (line.len > 0) {
                const duped = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(duped); // append失敗時のリーク防止
                try lines.append(self.allocator, duped);
            }
        }

        if (lines.items.len == 0) {
            lines.deinit(self.allocator);
            return null;
        }

        // 共通プレフィックスを計算
        const common = unicode.findCommonPrefix(lines.items);
        const common_prefix = try self.allocator.dupe(u8, common);
        errdefer self.allocator.free(common_prefix); // toOwnedSlice失敗時にfree

        return CompletionResult{
            .matches = try lines.toOwnedSlice(self.allocator),
            .common_prefix = common_prefix,
            .allocator = self.allocator,
        };
    }

    /// 入力から最後のトークン（補完対象）を取得
    /// クォートとバックスラッシュエスケープを考慮
    fn getLastToken(input: []const u8) []const u8 {
        var in_single = false;
        var in_double = false;
        var last_delim_end: usize = 0; // 最後の区切り文字の次の位置

        var i: usize = 0;
        while (i < input.len) {
            const c = input[i];

            // バックスラッシュエスケープ（シングルクォート内では無効）
            if (c == '\\' and i + 1 < input.len and !in_single) {
                const next_c = input[i + 1];
                // ダブルクォート内では \" と \\ のみエスケープ
                // 引用符外では全てエスケープ
                if (!in_double or next_c == '"' or next_c == '\\') {
                    i += 2; // エスケープシーケンスをスキップ
                    continue;
                }
            }

            // クォート状態の更新
            if (c == '\'' and !in_double) {
                in_single = !in_single;
            } else if (c == '"' and !in_single) {
                in_double = !in_double;
            } else if (!in_single and !in_double) {
                // 引用符外の区切り文字
                // 空白、パイプ、セミコロン、シェル演算子、リダイレクト記号を区切りとして扱う
                if (c == ' ' or c == '\t' or c == '|' or c == ';' or
                    c == '&' or c == '(' or c == ')' or c == '<' or c == '>')
                {
                    last_delim_end = i + 1;
                }
            }

            i += 1;
        }

        return input[last_delim_end..];
    }

    /// シェル用にエスケープ（シングルクォート内で使用）
    fn escapeForShell(s: []const u8, buf: []u8) ?[]const u8 {
        var pos: usize = 0;
        for (s) |c| {
            if (c == '\'') {
                // シングルクォートは '\'' に置換
                if (pos + 4 > buf.len) return null;
                buf[pos] = '\'';
                buf[pos + 1] = '\\';
                buf[pos + 2] = '\'';
                buf[pos + 3] = '\'';
                pos += 4;
            } else {
                if (pos >= buf.len) return null;
                buf[pos] = c;
                pos += 1;
            }
        }
        return buf[0..pos];
    }
};
