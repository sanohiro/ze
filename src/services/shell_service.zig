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
const History = @import("../history.zig").History;
const HistoryType = @import("../history.zig").HistoryType;

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

    /// 文字列の末尾が引用符の内部にあるかどうかをチェック
    /// シングルクォート、ダブルクォート、バックスラッシュエスケープを考慮
    fn isInsideQuotes(s: []const u8) bool {
        var in_single = false;
        var in_double = false;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '\\' and i + 1 < s.len) {
                // バックスラッシュエスケープ: 次の文字をスキップ
                i += 1;
                continue;
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
            // 引用符状態をチェック（偶数個の引用符があれば外にいる）
            if (cmd_end > cmd_start and !isInsideQuotes(cmd[cmd_start..cmd_end])) {
                if (cmd_end >= 2 and cmd[cmd_end - 2] == 'n' and cmd[cmd_end - 1] == '>') {
                    output_dest = .new_buffer;
                    cmd_end -= 2;
                } else if (cmd_end >= 2 and cmd[cmd_end - 2] == '+' and cmd[cmd_end - 1] == '>') {
                    output_dest = .insert;
                    cmd_end -= 2;
                } else if (cmd[cmd_end - 1] == '>') {
                    if (cmd_end >= 2 and cmd[cmd_end - 2] == ' ') {
                        output_dest = .replace;
                        cmd_end -= 1;
                    } else if (cmd_end == 1) {
                        output_dest = .replace;
                        cmd_end -= 1;
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

        // コマンドをヒープにコピー
        const command_copy = try self.allocator.dupe(u8, parsed.command);
        errdefer self.allocator.free(command_copy);

        // 状態を作成
        const state = try self.allocator.create(CommandState);
        errdefer {
            state.stdout_buffer.deinit(self.allocator);
            state.stderr_buffer.deinit(self.allocator);
            self.allocator.destroy(state);
        }

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

        // stdout から読み取り
        if (state.child.stdout) |stdout_file| {
            while (true) {
                const bytes_read = stdout_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => break,
                };
                if (bytes_read == 0) break;
                try state.stdout_buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);
            }
        }

        // stderr から読み取り
        if (state.child.stderr) |stderr_file| {
            while (true) {
                const bytes_read = stderr_file.read(&read_buf) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => break,
                };
                if (bytes_read == 0) break;
                try state.stderr_buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);
            }
        }

        // stdin へのストリーミング書き込み
        if (state.child.stdin) |stdin_file| {
            if (state.stdin_data) |data| {
                const remaining = data.len - state.stdin_write_pos;
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

        // waitpidでプロセス終了をチェック
        const result = std.posix.waitpid(state.child.id, std.c.W.NOHANG);

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

        // 残りのデータを読み取る
        if (state.child.stdout) |stdout_file| {
            while (true) {
                const bytes_read = stdout_file.read(&read_buf) catch break;
                if (bytes_read == 0) break;
                try state.stdout_buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);
            }
        }
        if (state.child.stderr) |stderr_file| {
            while (true) {
                const bytes_read = stderr_file.read(&read_buf) catch break;
                if (bytes_read == 0) break;
                try state.stderr_buffer.appendSlice(self.allocator, read_buf[0..bytes_read]);
            }
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
    pub fn cancel(self: *Self) void {
        if (self.state) |state| {
            if (!state.child_reaped) {
                _ = state.child.kill() catch {};
                _ = state.child.wait() catch {};
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
            _ = state.child.kill() catch {};
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

// ============================================================================
// テスト
// ============================================================================

test "parseCommand - basic" {
    const result = ShellService.parseCommand("echo hello");
    try std.testing.expectEqual(InputSource.selection, result.input_source);
    try std.testing.expectEqual(OutputDest.command_buffer, result.output_dest);
    try std.testing.expectEqualStrings("echo hello", result.command);
}

test "parseCommand - with pipe prefix" {
    const result = ShellService.parseCommand("| sort");
    try std.testing.expectEqual(InputSource.selection, result.input_source);
    try std.testing.expectEqual(OutputDest.command_buffer, result.output_dest);
    try std.testing.expectEqualStrings("sort", result.command);
}

test "parseCommand - buffer all" {
    const result = ShellService.parseCommand("% | sort >");
    try std.testing.expectEqual(InputSource.buffer_all, result.input_source);
    try std.testing.expectEqual(OutputDest.replace, result.output_dest);
    try std.testing.expectEqualStrings("sort", result.command);
}

test "parseCommand - current line" {
    const result = ShellService.parseCommand(". | sh >");
    try std.testing.expectEqual(InputSource.current_line, result.input_source);
    try std.testing.expectEqual(OutputDest.replace, result.output_dest);
    try std.testing.expectEqualStrings("sh", result.command);
}

test "parseCommand - new buffer" {
    const result = ShellService.parseCommand("| grep TODO n>");
    try std.testing.expectEqual(InputSource.selection, result.input_source);
    try std.testing.expectEqual(OutputDest.new_buffer, result.output_dest);
    try std.testing.expectEqualStrings("grep TODO", result.command);
}

test "parseCommand - insert" {
    const result = ShellService.parseCommand("| date +>");
    try std.testing.expectEqual(InputSource.selection, result.input_source);
    try std.testing.expectEqual(OutputDest.insert, result.output_dest);
    try std.testing.expectEqualStrings("date", result.command);
}
