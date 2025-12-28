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
const History = history_mod.History;
const HistoryType = history_mod.HistoryType;

/// I/O読み取りバッファサイズ（16KB = システムコール削減）
const READ_BUFFER_SIZE: usize = 16 * 1024;

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
    history: History,
    bash_path: ?[]const u8, // bashのパス（見つかった場合、遅延初期化）
    sh_path: ?[]const u8, // shのパス（見つかった場合、遅延初期化）
    aliases_path: ?[]const u8, // ~/.ze/aliasesのパス（存在する場合、遅延初期化）
    paths_initialized: bool, // bash_path/aliases_pathが初期化済みか
    history_loaded: bool, // 履歴がロード済みか

    const Self = @This();

    /// 出力バッファの上限（OOM防止）
    const MAX_OUTPUT_SIZE: usize = 10 * 1024 * 1024; // 10MB

    /// バッファサイズ制限付きで読み取り（ノンブロッキング対応）
    /// handle_would_block: trueならWouldBlockを特別処理、falseなら全エラーでbreak
    /// 戻り値: trueなら制限に達して切り詰めた
    fn readWithLimit(
        allocator: std.mem.Allocator,
        file: std.fs.File,
        buffer: *std.ArrayListUnmanaged(u8),
        read_buf: []u8,
        handle_would_block: bool,
    ) !bool {
        var truncated = false;
        while (buffer.items.len < MAX_OUTPUT_SIZE) {
            const bytes_read = file.read(read_buf) catch |err| {
                if (handle_would_block and err == error.WouldBlock) break;
                break;
            };
            if (bytes_read == 0) break;
            const available = MAX_OUTPUT_SIZE - buffer.items.len;
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
        if (buffer.items.len >= MAX_OUTPUT_SIZE) {
            truncated = true;
        }
        return truncated;
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        // 履歴とパス検索は遅延初期化（起動高速化）
        return .{
            .allocator = allocator,
            .state = null,
            .history = History.init(allocator),
            .bash_path = null,
            .sh_path = null,
            .aliases_path = null,
            .paths_initialized = false,
            .history_loaded = false,
        };
    }

    /// パス検索の遅延初期化（初回コマンド実行時に呼ばれる）
    fn ensurePathsInitialized(self: *Self) void {
        if (self.paths_initialized) return;
        self.paths_initialized = true;

        // bashのパスを探す（$SHELL → 一般的なパス）
        self.bash_path = findBashPath(self.allocator);

        // shのパスを探す（POSIX準拠シェル用）
        self.sh_path = findShPath(self.allocator);

        // ~/.ze/aliases が存在するかチェック
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

    /// 履歴の遅延ロード（初回履歴アクセス時に呼ばれる）
    fn ensureHistoryLoaded(self: *Self) void {
        if (self.history_loaded) return;
        self.history_loaded = true;
        self.history.load(.shell) catch {};
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

    /// bashのパスを探す（スタックバッファ使用でアロケーション削減）
    fn findBashPath(allocator: std.mem.Allocator) ?[]const u8 {
        // 1. $SHELL がbashなら使用（絶対パスの場合）
        if (std.posix.getenv("SHELL")) |shell| {
            if (std.mem.endsWith(u8, shell, "/bash")) {
                if (std.fs.accessAbsolute(shell, .{})) |_| {
                    return allocator.dupe(u8, shell) catch null;
                } else |_| {}
            }
        }
        // 2. PATH環境変数から探す（スタックバッファ使用）
        if (std.posix.getenv("PATH")) |path_env| {
            var path_buf: [512]u8 = undefined;
            var it = std.mem.splitScalar(u8, path_env, ':');
            while (it.next()) |dir| {
                const bash_path = std.fmt.bufPrint(&path_buf, "{s}/bash", .{dir}) catch continue;
                if (std.fs.accessAbsolute(bash_path, .{})) |_| {
                    // 見つかった時だけアロケーション
                    return allocator.dupe(u8, bash_path) catch null;
                } else |_| {}
            }
        }
        // 3. 一般的なパスを試す（フォールバック）
        const paths = [_][]const u8{
            "/bin/bash",
            "/usr/bin/bash",
            "/usr/local/bin/bash",
            "/opt/homebrew/bin/bash",
            "/opt/local/bin/bash",
        };
        for (paths) |path| {
            if (std.fs.accessAbsolute(path, .{})) |_| {
                return allocator.dupe(u8, path) catch null;
            } else |_| {}
        }
        return null;
    }

    /// shのパスを探す（/bin/shが無い環境用）
    /// 戻り値: 見つかった場合はアロケートされたパス、見つからない場合はnull
    /// 呼び出し側は戻り値を解放する責任を持つ
    fn findShPath(allocator: std.mem.Allocator) ?[]const u8 {
        // 1. /bin/sh を試す（最も一般的）
        if (std.fs.accessAbsolute("/bin/sh", .{})) |_| {
            return allocator.dupe(u8, "/bin/sh") catch null;
        } else |_| {}
        // 2. PATH環境変数から探す（スタックバッファ使用）
        if (std.posix.getenv("PATH")) |path_env| {
            var path_buf: [512]u8 = undefined;
            var it = std.mem.splitScalar(u8, path_env, ':');
            while (it.next()) |dir| {
                const sh_path = std.fmt.bufPrint(&path_buf, "{s}/sh", .{dir}) catch continue;
                if (std.fs.accessAbsolute(sh_path, .{})) |_| {
                    return allocator.dupe(u8, sh_path) catch null;
                } else |_| {}
            }
        }
        // 3. フォールバック
        const paths = [_][]const u8{ "/usr/bin/sh", "/system/bin/sh" };
        for (paths) |path| {
            if (std.fs.accessAbsolute(path, .{})) |_| {
                return allocator.dupe(u8, path) catch null;
            } else |_| {}
        }
        // 見つからない場合はnull（呼び出し側でデフォルト値を使用）
        return null;
    }

    pub fn deinit(self: *Self) void {
        if (self.state) |state| {
            self.cleanupState(state);
        }
        self.history.save(.shell) catch {};
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

        // 先頭の空白をスキップ
        while (cmd_start < cmd.len and cmd[cmd_start] == ' ') : (cmd_start += 1) {}

        // プレフィックス解析
        if (cmd_start < cmd.len) {
            if (cmd[cmd_start] == '%') {
                // "% " または "%|" の場合のみバッファ全体プレフィックス
                const next_idx = cmd_start + 1;
                if (next_idx >= cmd.len or cmd[next_idx] == ' ' or cmd[next_idx] == '|') {
                    input_source = .buffer_all;
                    cmd_start += 1;
                    while (cmd_start < cmd.len and cmd[cmd_start] == ' ') : (cmd_start += 1) {}
                }
            } else if (cmd[cmd_start] == '.') {
                // ". " または ".|" の場合のみ現在行プレフィックス（"./cmd" は通常コマンド）
                const next_idx = cmd_start + 1;
                if (next_idx >= cmd.len or cmd[next_idx] == ' ' or cmd[next_idx] == '|') {
                    input_source = .current_line;
                    cmd_start += 1;
                    while (cmd_start < cmd.len and cmd[cmd_start] == ' ') : (cmd_start += 1) {}
                }
            }
        }

        // パイプ記号 '|' をスキップ
        if (cmd_start < cmd.len and cmd[cmd_start] == '|') {
            cmd_start += 1;
            while (cmd_start < cmd.len and cmd[cmd_start] == ' ') : (cmd_start += 1) {}
        }

        // サフィックス解析（末尾から、引用符を考慮）
        // 重要: サフィックスはコマンドとスペースで区切られている必要がある
        // 例: "sort >" は有効、"grep -n>out" は無効（シェルのリダイレクト構文）
        if (cmd_end > cmd_start) {
            while (cmd_end > cmd_start and cmd[cmd_end - 1] == ' ') : (cmd_end -= 1) {}

            // 引用符の外にあるサフィックスのみ解釈
            // サフィックスの開始位置が引用符内かどうかをチェック
            if (cmd_end > cmd_start) {
                if (cmd_end >= 3 and cmd[cmd_end - 2] == 'n' and cmd[cmd_end - 1] == '>' and cmd[cmd_end - 3] == ' ') {
                    // " n>" の場合のみ新規バッファとして解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 2)) {
                        output_dest = .new_buffer;
                        cmd_end -= 2;
                    }
                } else if (cmd_end >= 3 and cmd[cmd_end - 2] == '+' and cmd[cmd_end - 1] == '>' and cmd[cmd_end - 3] == ' ') {
                    // " +>" の場合のみ挿入として解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 2)) {
                        output_dest = .insert;
                        cmd_end -= 2;
                    }
                } else if (cmd[cmd_end - 1] == '>') {
                    // " >" の場合のみ置換として解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 1)) {
                        if (cmd_end >= 2 and cmd[cmd_end - 2] == ' ') {
                            output_dest = .replace;
                            cmd_end -= 1;
                        }
                    }
                }
            }

            while (cmd_end > cmd_start and cmd[cmd_end - 1] == ' ') : (cmd_end -= 1) {}
        }

        return .{
            .input_source = input_source,
            .output_dest = output_dest,
            .command = if (cmd_end > cmd_start) cmd[cmd_start..cmd_end] else "",
        };
    }

    /// シェルコマンドを非同期で開始
    pub fn start(self: *Self, cmd_input: []const u8, stdin_data: ?[]const u8, stdin_allocated: bool) !void {
        if (cmd_input.len == 0) return error.EmptyCommand;

        const parsed = parseCommand(cmd_input);
        if (parsed.command.len == 0) return error.NoCommand;

        // 遅延初期化: bashパスとaliasesパスを検索（初回のみ）
        self.ensurePathsInitialized();

        // 既存の状態をクリア（リーク防止）
        if (self.state) |old_state| {
            self.cleanupState(old_state);
            self.state = null;
        }

        // bash + alias を使うかどうか判定
        const use_bash_aliases = self.bash_path != null and self.aliases_path != null;

        // 状態を作成
        const state = try self.allocator.create(CommandState);
        errdefer self.allocator.destroy(state);

        // 子プロセスを起動
        const actual_command: []const u8 = if (use_bash_aliases) blk: {
            // bash -c 'shopt -s expand_aliases; . "path"; eval "command"'
            // 注: エイリアスは非対話モードでは展開されないため shopt + eval が必要
            // パスとコマンドの両方をクォート（injection防止）
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
            // 注: $SHELLはfish等の場合があり-cの挙動が異なる可能性がある
            const command_copy = try self.allocator.dupe(u8, parsed.command);
            // キャッシュされたsh_pathを使用（見つからない場合はデフォルト）
            const sh_path = self.sh_path orelse "/bin/sh";
            const argv = [_][]const u8{ sh_path, "-c", command_copy };
            state.child = std.process.Child.init(&argv, self.allocator);
            break :blk command_copy;
        };
        // spawn失敗時にactual_commandを解放（成功時はcleanupStateで解放）
        errdefer self.allocator.free(actual_command);

        // 入力ソースなしの場合は /dev/null に接続（.Close だと Bad file descriptor エラー）
        state.child.stdin_behavior = if (stdin_data != null) .Pipe else .Ignore;
        state.child.stdout_behavior = .Pipe;
        state.child.stderr_behavior = .Pipe;
        state.input_source = parsed.input_source;
        state.output_dest = parsed.output_dest;
        state.stdin_data = stdin_data;
        state.stdin_allocated = stdin_allocated;
        state.stdin_write_pos = 0;
        state.command = actual_command;
        state.stdout_buffer = .{};
        state.stderr_buffer = .{};
        state.child_reaped = false;
        state.exit_status = null;
        state.stdout_truncated = false;
        state.stderr_truncated = false;
        state.nonblock_configured = false; // NONBLOCKは初回poll()で遅延設定

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

    /// シェルコマンドの完了をポーリング
    /// 戻り値: 完了した場合は結果、まだ実行中の場合はnull
    pub fn poll(self: *Self) !?CommandResult {
        var state = self.state orelse return null;

        // 初回のみNONBLOCKを設定（遅延初期化でspawn時のシステムコールを削減）
        if (!state.nonblock_configured) {
            state.nonblock_configured = true;
            const nonblock_flag: usize = @as(u32, @bitCast(std.posix.O{ .NONBLOCK = true }));
            if (state.child.stdout) |stdout_file| {
                const flags = std.posix.fcntl(stdout_file.handle, std.posix.F.GETFL, 0) catch 0;
                _ = std.posix.fcntl(stdout_file.handle, std.posix.F.SETFL, flags | nonblock_flag) catch {};
            }
            if (state.child.stderr) |stderr_file| {
                const flags = std.posix.fcntl(stderr_file.handle, std.posix.F.GETFL, 0) catch 0;
                _ = std.posix.fcntl(stderr_file.handle, std.posix.F.SETFL, flags | nonblock_flag) catch {};
            }
            if (state.child.stdin) |stdin_file| {
                const flags = std.posix.fcntl(stdin_file.handle, std.posix.F.GETFL, 0) catch 0;
                _ = std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, flags | nonblock_flag) catch {};
            }
        }

        var read_buf: [READ_BUFFER_SIZE]u8 = undefined;

        // stdout と stderr を交互に読取（デッドロック防止）
        // 一方のパイプが詰まってもう一方を先に処理する必要がある場合に対応
        const max_iterations = 16; // 十分な回数を確保
        var iter_count: usize = 0;
        while (iter_count < max_iterations) : (iter_count += 1) {
            var any_read = false;

            // stdout から1チャンク読み取り
            if (state.child.stdout) |stdout_file| {
                if (state.stdout_buffer.items.len < MAX_OUTPUT_SIZE) {
                    const bytes_read: usize = stdout_file.read(&read_buf) catch 0;
                    if (bytes_read > 0) {
                        any_read = true;
                        const available = MAX_OUTPUT_SIZE - state.stdout_buffer.items.len;
                        const to_append = @min(bytes_read, available);
                        if (to_append > 0) {
                            try state.stdout_buffer.appendSlice(self.allocator, read_buf[0..to_append]);
                        }
                        if (to_append < bytes_read) {
                            state.stdout_truncated = true;
                        }
                    }
                }
                // 上限に達したらパイプを閉じる（子プロセスのブロックを防ぐ）
                if (state.stdout_buffer.items.len >= MAX_OUTPUT_SIZE) {
                    stdout_file.close();
                    state.child.stdout = null;
                }
            }

            // stderr から1チャンク読み取り
            if (state.child.stderr) |stderr_file| {
                if (state.stderr_buffer.items.len < MAX_OUTPUT_SIZE) {
                    const bytes_read: usize = stderr_file.read(&read_buf) catch 0;
                    if (bytes_read > 0) {
                        any_read = true;
                        const available = MAX_OUTPUT_SIZE - state.stderr_buffer.items.len;
                        const to_append = @min(bytes_read, available);
                        if (to_append > 0) {
                            try state.stderr_buffer.appendSlice(self.allocator, read_buf[0..to_append]);
                        }
                        if (to_append < bytes_read) {
                            state.stderr_truncated = true;
                        }
                    }
                }
                // 上限に達したらパイプを閉じる（子プロセスのブロックを防ぐ）
                if (state.stderr_buffer.items.len >= MAX_OUTPUT_SIZE) {
                    stderr_file.close();
                    state.child.stderr = null;
                }
            }

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
                    const large_chunk_size: usize = 64 * 1024;
                    const chunk_size = if (data.len > 1024 * 1024)
                        @min(remaining, large_chunk_size)
                    else
                        @min(remaining, READ_BUFFER_SIZE);
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
            if (try readWithLimit(self.allocator, stdout_file, &state.stdout_buffer, &read_buf, false)) {
                state.stdout_truncated = true;
            }
        }
        if (state.child.stderr) |stderr_file| {
            if (try readWithLimit(self.allocator, stderr_file, &state.stderr_buffer, &read_buf, false)) {
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

    /// 履歴にコマンドを追加
    pub fn addToHistory(self: *Self, cmd: []const u8) !void {
        self.ensureHistoryLoaded();
        try self.history.add(cmd);
    }

    /// 履歴ナビゲーション開始
    pub fn startHistoryNavigation(self: *Self, current_input: []const u8) !void {
        self.ensureHistoryLoaded();
        try self.history.startNavigation(current_input);
    }

    /// 履歴の前のエントリを取得
    pub fn historyPrev(self: *Self) ?[]const u8 {
        self.ensureHistoryLoaded();
        return self.history.prev();
    }

    /// 履歴の次のエントリを取得
    pub fn historyNext(self: *Self) ?[]const u8 {
        self.ensureHistoryLoaded();
        return self.history.next();
    }

    /// 履歴ナビゲーションをリセット
    pub fn resetHistoryNavigation(self: *Self) void {
        self.history.resetNavigation();
    }

    /// 履歴ナビゲーション中かどうか
    pub fn isNavigating(self: *Self) bool {
        return self.history.current_index != null;
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

        // compgenを実行
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ bash_path, "-c", cmd },
            .max_output_bytes = 64 * 1024, // 64KB上限
        }) catch return null;
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
                try lines.append(self.allocator, duped);
            }
        }

        if (lines.items.len == 0) {
            lines.deinit(self.allocator);
            return null;
        }

        // 共通プレフィックスを計算
        const common = findCommonPrefix(lines.items);
        const common_prefix = try self.allocator.dupe(u8, common);

        return CompletionResult{
            .matches = try lines.toOwnedSlice(self.allocator),
            .common_prefix = common_prefix,
            .allocator = self.allocator,
        };
    }

    /// 入力から最後のトークン（補完対象）を取得
    fn getLastToken(input: []const u8) []const u8 {
        // 後ろから空白を探す
        var i = input.len;
        while (i > 0) {
            i -= 1;
            if (input[i] == ' ' or input[i] == '\t' or input[i] == '|' or input[i] == ';') {
                return input[i + 1 ..];
            }
        }
        return input;
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

    /// 文字列配列の共通プレフィックスを見つける
    fn findCommonPrefix(strings: []const []const u8) []const u8 {
        if (strings.len == 0) return "";
        if (strings.len == 1) return strings[0];

        const first = strings[0];
        var prefix_len: usize = first.len;

        for (strings[1..]) |s| {
            var i: usize = 0;
            while (i < prefix_len and i < s.len and first[i] == s[i]) : (i += 1) {}
            prefix_len = i;
            if (prefix_len == 0) break;
        }

        return first[0..prefix_len];
    }
};
