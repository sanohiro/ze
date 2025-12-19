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
};

/// シェルコマンド実行結果
pub const CommandResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_status: ?u32,
    input_source: InputSource,
    output_dest: OutputDest,
};

/// シェルコマンド実行サービス
pub const ShellService = struct {
    allocator: std.mem.Allocator,
    state: ?*CommandState,
    history: History,

    const Self = @This();

    /// 出力バッファの上限（OOM防止）
    const MAX_OUTPUT_SIZE: usize = 10 * 1024 * 1024; // 10MB

    /// バッファサイズ制限付きで読み取り（ノンブロッキング対応）
    /// handle_would_block: trueならWouldBlockを特別処理、falseなら全エラーでbreak
    fn readWithLimit(
        allocator: std.mem.Allocator,
        file: std.fs.File,
        buffer: *std.ArrayListUnmanaged(u8),
        read_buf: []u8,
        handle_would_block: bool,
    ) !void {
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
        }
    }

    pub fn init(allocator: std.mem.Allocator) Self {
        var history = History.init(allocator);
        history.load(.shell) catch {}; // エラーは無視
        return .{
            .allocator = allocator,
            .state = null,
            .history = history,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.state) |state| {
            self.cleanupState(state);
        }
        self.history.save(.shell) catch {};
        self.history.deinit();
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

        // プレフィックス解析
        if (cmd.len > 0) {
            if (cmd[0] == '%') {
                input_source = .buffer_all;
                cmd_start = 1;
                while (cmd_start < cmd.len and cmd[cmd_start] == ' ') : (cmd_start += 1) {}
            } else if (cmd[0] == '.') {
                input_source = .current_line;
                cmd_start = 1;
                while (cmd_start < cmd.len and cmd[cmd_start] == ' ') : (cmd_start += 1) {}
            }
        }

        // パイプ記号 '|' をスキップ
        if (cmd_start < cmd.len and cmd[cmd_start] == '|') {
            cmd_start += 1;
            while (cmd_start < cmd.len and cmd[cmd_start] == ' ') : (cmd_start += 1) {}
        }

        // サフィックス解析（末尾から、引用符を考慮）
        if (cmd_end > cmd_start) {
            while (cmd_end > cmd_start and cmd[cmd_end - 1] == ' ') : (cmd_end -= 1) {}

            // 引用符の外にあるサフィックスのみ解釈
            // サフィックスの開始位置が引用符内かどうかをチェック
            if (cmd_end > cmd_start) {
                if (cmd_end >= 2 and cmd[cmd_end - 2] == 'n' and cmd[cmd_end - 1] == '>') {
                    // n> の位置（cmd_end - 2）が引用符外ならサフィックスとして解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 2)) {
                        output_dest = .new_buffer;
                        cmd_end -= 2;
                    }
                } else if (cmd_end >= 2 and cmd[cmd_end - 2] == '+' and cmd[cmd_end - 1] == '>') {
                    // +> の位置が引用符外ならサフィックスとして解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 2)) {
                        output_dest = .insert;
                        cmd_end -= 2;
                    }
                } else if (cmd[cmd_end - 1] == '>') {
                    // > の位置が引用符外で、かつスペースの後ならサフィックスとして解釈
                    if (!isPositionInsideQuotes(cmd, cmd_end - 1)) {
                        if (cmd_end >= 2 and cmd[cmd_end - 2] == ' ') {
                            output_dest = .replace;
                            cmd_end -= 1;
                        } else if (cmd_end == 1) {
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

        // 既存の状態をクリア（リーク防止）
        if (self.state) |old_state| {
            self.cleanupState(old_state);
            self.state = null;
        }

        // コマンドをヒープにコピー
        const command_copy = try self.allocator.dupe(u8, parsed.command);
        errdefer self.allocator.free(command_copy);

        // 状態を作成
        const state = try self.allocator.create(CommandState);
        errdefer self.allocator.destroy(state);

        // 子プロセスを起動
        const argv = [_][]const u8{ "/bin/sh", "-c", command_copy };
        state.child = std.process.Child.init(&argv, self.allocator);
        state.child.stdin_behavior = if (stdin_data != null) .Pipe else .Close;
        state.child.stdout_behavior = .Pipe;
        state.child.stderr_behavior = .Pipe;
        state.input_source = parsed.input_source;
        state.output_dest = parsed.output_dest;
        state.stdin_data = stdin_data;
        state.stdin_allocated = stdin_allocated;
        state.stdin_write_pos = 0;
        state.command = command_copy;
        state.stdout_buffer = .{};
        state.stderr_buffer = .{};
        state.child_reaped = false;
        state.exit_status = null;

        try state.child.spawn();

        // ノンブロッキングに設定
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

        var read_buf: [8192]u8 = undefined;

        // stdout から読み取り（上限チェック付き、ノンブロッキング）
        if (state.child.stdout) |stdout_file| {
            try readWithLimit(self.allocator, stdout_file, &state.stdout_buffer, &read_buf, true);
            // 上限に達したらパイプを閉じる（子プロセスのブロックを防ぐ）
            if (state.stdout_buffer.items.len >= MAX_OUTPUT_SIZE) {
                stdout_file.close();
                state.child.stdout = null;
            }
        }

        // stderr から読み取り（上限チェック付き、ノンブロッキング）
        if (state.child.stderr) |stderr_file| {
            try readWithLimit(self.allocator, stderr_file, &state.stderr_buffer, &read_buf, true);
            // 上限に達したらパイプを閉じる（子プロセスのブロックを防ぐ）
            if (state.stderr_buffer.items.len >= MAX_OUTPUT_SIZE) {
                stderr_file.close();
                state.child.stderr = null;
            }
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
                    const chunk_size = @min(remaining, 8192);
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
            try readWithLimit(self.allocator, stdout_file, &state.stdout_buffer, &read_buf, false);
        }
        if (state.child.stderr) |stderr_file| {
            try readWithLimit(self.allocator, stderr_file, &state.stderr_buffer, &read_buf, false);
        }

        // 結果を返す
        const cmd_result = CommandResult{
            .stdout = state.stdout_buffer.items,
            .stderr = state.stderr_buffer.items,
            .exit_status = state.exit_status,
            .input_source = state.input_source,
            .output_dest = state.output_dest,
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
        try self.history.add(cmd);
    }

    /// 履歴ナビゲーション開始
    pub fn startHistoryNavigation(self: *Self, current_input: []const u8) !void {
        try self.history.startNavigation(current_input);
    }

    /// 履歴の前のエントリを取得
    pub fn historyPrev(self: *Self) ?[]const u8 {
        return self.history.prev();
    }

    /// 履歴の次のエントリを取得
    pub fn historyNext(self: *Self) ?[]const u8 {
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
};
