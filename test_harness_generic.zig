const std = @import("std");
const posix = std.posix;

/// 汎用PTYテストハーネス
/// コマンドライン引数からキーシーケンスを受け取り、zeに送信してテストする
///
/// 使用例:
///   zig run test_harness_generic.zig -lc -- "hello" "C-x" "C-s" "/tmp/test.txt" "Enter" "C-x" "C-c"
///   zig run test_harness_generic.zig -lc -- --file=/tmp/existing.txt "C-e" " world" "C-x" "C-s" "C-x" "C-c"
///
/// 特殊キー:
///   C-<char>    : Ctrl+文字 (例: C-x, C-s, C-g)
///   M-<char>    : Alt+文字 (例: M-f, M-b)
///   Enter       : Enter/Return
///   Backspace   : Backspace
///   Tab         : Tab
///   Escape      : Escape
///   Up/Down/Left/Right : 矢印キー
///
/// オプション:
///   --file=<path>  : 指定ファイルを開く
///   --wait=<ms>    : キー送信前の待機時間（デフォルト: 500ms）
///   --delay=<ms>   : キー間の遅延（デフォルト: 100ms）
///   --show-output  : zeの出力を表示
///   --ze=<path>    : zeバイナリのパス（デフォルト: ./zig-out/bin/ze）
///
/// 環境変数:
///   ZE_BIN         : zeバイナリのパス（--zeオプションより優先度低）
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const base_allocator = gpa.allocator();

    // ArenaAllocatorを使用してメモリ管理を簡素化
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // プログラム名をスキップ

    var filename: ?[]const u8 = null;
    var input_file: ?[]const u8 = null;
    var wait_ms: u64 = 500;
    var delay_ms: u64 = 100;
    var show_output = false;
    var ze_path: []const u8 = "./zig-out/bin/ze"; // デフォルトパス
    var key_sequences = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer key_sequences.deinit(allocator);

    // 環境変数 ZE_BIN をチェック
    if (getenv("ZE_BIN")) |env_path| {
        ze_path = std.mem.sliceTo(env_path, 0);
    }

    // 引数を解析
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--file=")) {
            filename = arg[7..];
        } else if (std.mem.startsWith(u8, arg, "--input-file=")) {
            input_file = arg[13..];
        } else if (std.mem.startsWith(u8, arg, "--wait=")) {
            wait_ms = try std.fmt.parseInt(u64, arg[7..], 10);
        } else if (std.mem.startsWith(u8, arg, "--delay=")) {
            delay_ms = try std.fmt.parseInt(u64, arg[8..], 10);
        } else if (std.mem.startsWith(u8, arg, "--ze=")) {
            ze_path = arg[5..]; // コマンドライン引数が最優先
        } else if (std.mem.eql(u8, arg, "--show-output")) {
            show_output = true;
        } else {
            try key_sequences.append(allocator, arg);
        }
    }

    // --input-file が指定された場合、ファイルからキーシーケンスを読み込む
    if (input_file) |file_path| {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 最大1MB
        defer allocator.free(content);

        // 改行で分割してキーシーケンスを作成
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (line.len > 0) { // 空行をスキップ
                const line_copy = try allocator.dupe(u8, line);
                try key_sequences.append(allocator, line_copy);
            }
        }
    }

    if (key_sequences.items.len == 0) {
        std.debug.print("Usage: test_harness_generic [options] <key1> <key2> ...\n\n", .{});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --file=<path>        Open specified file\n", .{});
        std.debug.print("  --input-file=<path>  Read key sequences from file (one per line)\n", .{});
        std.debug.print("  --wait=<ms>          Wait time before sending keys (default: 500ms)\n", .{});
        std.debug.print("  --delay=<ms>         Delay between keys (default: 100ms)\n", .{});
        std.debug.print("  --ze=<path>          Path to ze binary (default: ./zig-out/bin/ze)\n", .{});
        std.debug.print("  --show-output        Show ze output\n\n", .{});
        std.debug.print("Environment variables:\n", .{});
        std.debug.print("  ZE_BIN               Path to ze binary (lower priority than --ze)\n\n", .{});
        std.debug.print("Special keys:\n", .{});
        std.debug.print("  C-<char>        Ctrl+char (e.g., C-x, C-s)\n", .{});
        std.debug.print("  M-<char>        Alt+char (e.g., M-f)\n", .{});
        std.debug.print("  Enter, Backspace, Tab, Escape\n", .{});
        std.debug.print("  Up, Down, Left, Right\n\n", .{});
        std.debug.print("Examples:\n", .{});
        std.debug.print("  # Create new file\n", .{});
        std.debug.print("  test_harness_generic \"hello\" \"C-x\" \"C-s\" \"/tmp/test.txt\" \"Enter\" \"C-x\" \"C-c\"\n\n", .{});
        std.debug.print("  # Edit existing file\n", .{});
        std.debug.print("  test_harness_generic --file=/tmp/existing.txt \"C-e\" \" world\" \"C-x\" \"C-s\" \"C-x\" \"C-c\"\n\n", .{});
        return;
    }

    // ze_path をnull終端バッファにコピー（forkした子プロセスで使用）
    var ze_path_buf: [512]u8 = undefined;
    if (ze_path.len >= ze_path_buf.len) {
        std.debug.print("Error: ze path too long\n", .{});
        return error.PathTooLong;
    }
    @memcpy(ze_path_buf[0..ze_path.len], ze_path);
    ze_path_buf[ze_path.len] = 0;
    const ze_path_z: [*:0]const u8 = @ptrCast(ze_path_buf[0..ze_path.len :0]);

    std.debug.print("=== Generic PTY Test Harness ===\n", .{});
    std.debug.print("Using ze binary: {s}\n", .{ze_path});
    if (filename) |f| {
        std.debug.print("Opening file: {s}\n", .{f});
    } else {
        std.debug.print("Starting with new file\n", .{});
    }
    std.debug.print("Sending {} key sequence(s)\n\n", .{key_sequences.items.len});

    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;

    // ウィンドウサイズを設定（80x24）
    var winsize: winsize_t = undefined;
    winsize.ws_row = 24;
    winsize.ws_col = 80;
    winsize.ws_xpixel = 0;
    winsize.ws_ypixel = 0;

    const result = openpty(&master_fd, &slave_fd, null, null, &winsize);
    if (result != 0) {
        std.debug.print("Error: openpty failed\n", .{});
        return error.OpenPtyFailed;
    }
    defer {
        _ = posix.system.close(master_fd);
        _ = posix.system.close(slave_fd);
    }

    std.debug.print("PTY created: master_fd={}, slave_fd={}\n", .{ master_fd, slave_fd });

    // マスターFDをノンブロッキングモードに設定
    const flags = fcntl(master_fd, F_GETFL, 0);
    _ = fcntl(master_fd, F_SETFL, flags | O_NONBLOCK);

    const pid = try posix.fork();

    if (pid == 0) {
        // 子プロセス: zeを実行
        _ = posix.system.close(master_fd);
        _ = posix.system.dup2(slave_fd, posix.STDIN_FILENO);
        _ = posix.system.dup2(slave_fd, posix.STDOUT_FILENO);
        _ = posix.system.dup2(slave_fd, posix.STDERR_FILENO);

        if (slave_fd > 2) {
            _ = posix.system.close(slave_fd);
        }

        _ = setenv("TERM", "xterm-256color", 1);

        if (filename) |f| {
            // ファイル指定あり - filenameをnull終端にコピー
            var fname_buf: [512]u8 = undefined;
            if (f.len >= fname_buf.len) posix.exit(1);
            @memcpy(fname_buf[0..f.len], f);
            fname_buf[f.len] = 0;
            const fname_z: [*:0]const u8 = @ptrCast(fname_buf[0..f.len :0]);

            const argv = [_:null]?[*:0]const u8{ ze_path_z, fname_z, null };
            const envp = [_:null]?[*:0]const u8{null};
            const err = posix.execveZ(ze_path_z, &argv, &envp);
            std.debug.print("execve failed: {}\n", .{err});
        } else {
            // ファイル指定なし
            const argv = [_:null]?[*:0]const u8{ ze_path_z, null };
            const envp = [_:null]?[*:0]const u8{null};
            const err = posix.execveZ(ze_path_z, &argv, &envp);
            std.debug.print("execve failed: {}\n", .{err});
        }
        posix.exit(1);
    } else {
        // 親プロセス
        _ = posix.system.close(slave_fd);

        std.debug.print("Child process started: pid={}\n\n", .{pid});

        // 起動待ち
        std.Thread.sleep(wait_ms * std.time.ns_per_ms);

        const master_file = std.fs.File{ .handle = master_fd };

        var all_output = try std.ArrayList(u8).initCapacity(allocator, 8192);
        defer all_output.deinit(allocator);

        // 初期画面をキャプチャ（キー送信前）
        if (show_output) {
            std.debug.print("Capturing initial screen...\n", .{});
        }
        {
            var read_attempts: u32 = 0;
            while (read_attempts < 3) : (read_attempts += 1) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                var output_buffer: [4096]u8 = undefined;
                const bytes_read: usize = posix.read(master_fd, &output_buffer) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    if (show_output) std.debug.print("Read error: {}\n", .{err});
                    break :blk 0;
                };
                if (bytes_read > 0 and show_output) {
                    try all_output.appendSlice(allocator, output_buffer[0..bytes_read]);
                }
            }
        }

        // キーシーケンスを送信
        for (key_sequences.items, 0..) |seq, i| {
            std.debug.print("Sending key #{}: \"{s}\"\n", .{ i + 1, seq });

            const bytes = try parseKeySequence(allocator, seq);
            defer allocator.free(bytes);

            master_file.writeAll(bytes) catch |err| {
                std.debug.print("Warning: Failed to send key (process may have exited): {}\n", .{err});
                break; // プロセスが終了した場合はループを抜ける
            };
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);

            // 各キー送信後に出力をキャプチャ（常にバッファを空にする）
            {
                var read_attempts: u32 = 0;
                while (read_attempts < 2) : (read_attempts += 1) {
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                    var output_buffer: [4096]u8 = undefined;
                    const bytes_read: usize = posix.read(master_fd, &output_buffer) catch |err| blk: {
                        if (err == error.WouldBlock) break :blk 0;
                        break :blk 0;
                    };
                    if (bytes_read > 0 and show_output) {
                        try all_output.appendSlice(allocator, output_buffer[0..bytes_read]);
                    }
                }
            }
        }

        // 最終的な画面状態をキャプチャ
        if (show_output) {
            std.debug.print("Capturing final screen...\n", .{});
        }
        {
            var read_attempts: u32 = 0;
            while (read_attempts < 3) : (read_attempts += 1) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                var output_buffer: [4096]u8 = undefined;
                const bytes_read: usize = posix.read(master_fd, &output_buffer) catch |err| blk: {
                    if (err == error.WouldBlock) break :blk 0;
                    break :blk 0;
                };
                if (bytes_read > 0 and show_output) {
                    try all_output.appendSlice(allocator, output_buffer[0..bytes_read]);
                }
            }
        }

        if (show_output) {
            if (all_output.items.len > 0) {
                std.debug.print("\n=== Output ({} bytes) ===\n", .{all_output.items.len});
                std.debug.print("{s}\n", .{all_output.items});
                std.debug.print("\n=== Escaped view ===\n", .{});
                for (all_output.items) |byte| {
                    if (byte == '\x1b') {
                        std.debug.print("\\x1b", .{});
                    } else if (byte >= 32 and byte < 127) {
                        std.debug.print("{c}", .{byte});
                    } else if (byte == '\n') {
                        std.debug.print("\\n\n", .{});
                    } else if (byte == '\r') {
                        std.debug.print("\\r", .{});
                    } else {
                        std.debug.print("\\x{x:0>2}", .{byte});
                    }
                }
                std.debug.print("\n", .{});
            }
        }

        // 子プロセスの終了を待つ（タイムアウト付き）
        std.debug.print("\nWaiting for child process to exit (timeout: 3s)...\n", .{});

        var timeout_count: u32 = 0;
        const max_timeout = 30; // 30 * 100ms = 3秒
        while (timeout_count < max_timeout) : (timeout_count += 1) {
            const wait_result = posix.waitpid(pid, posix.W.NOHANG);
            if (wait_result.pid != 0) {
                std.debug.print("Child exited with status: {}\n", .{wait_result.status});
                std.debug.print("\n=== Test completed ===\n", .{});
                return;
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        // タイムアウト：子プロセスを強制終了
        std.debug.print("Timeout! Killing child process...\n", .{});
        posix.kill(pid, posix.SIG.TERM) catch |err| {
            std.debug.print("Failed to send SIGTERM: {}\n", .{err});
        };
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // それでも終了しない場合はKILL
        const wait_result = posix.waitpid(pid, posix.W.NOHANG);
        if (wait_result.pid == 0) {
            std.debug.print("Child still alive, sending SIGKILL...\n", .{});
            posix.kill(pid, posix.SIG.KILL) catch |err| {
                std.debug.print("Failed to send SIGKILL: {}\n", .{err});
            };
            _ = posix.waitpid(pid, 0);
        }

        std.debug.print("\n=== Test completed (with timeout) ===\n", .{});
    }
}

/// キーシーケンス文字列をバイト列に変換
fn parseKeySequence(allocator: std.mem.Allocator, seq: []const u8) ![]const u8 {
    // 特殊キーのマッピング
    if (std.mem.startsWith(u8, seq, "C-") and seq.len == 3) {
        // Ctrl+文字
        const char = seq[2];
        const ctrl_char: u8 = if (char >= 'a' and char <= 'z')
            char - 'a' + 1
        else if (char >= 'A' and char <= 'Z')
            char - 'A' + 1
        else if (char == '@')
            0
        else if (char == '/' or char == '_')
            31 // C-/ と C-_ は 0x1f (31)
        else
            return error.InvalidCtrlChar;

        const result = try allocator.alloc(u8, 1);
        result[0] = ctrl_char;
        return result;
    } else if (std.mem.startsWith(u8, seq, "M-") and seq.len == 3) {
        // Alt+文字 (ESC + 文字)
        const result = try allocator.alloc(u8, 2);
        result[0] = 0x1B; // ESC
        result[1] = seq[2];
        return result;
    } else if (std.mem.eql(u8, seq, "M-delete")) {
        // Alt+Delete (ESC [3;3~)
        const result = try allocator.alloc(u8, 6);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = '3';
        result[3] = ';';
        result[4] = '3';
        result[5] = '~';
        return result;
    } else if (std.mem.eql(u8, seq, "C-Space")) {
        // Ctrl+Space (C-@)
        const result = try allocator.alloc(u8, 1);
        result[0] = 0;
        return result;
    } else if (std.mem.eql(u8, seq, "Space")) {
        // Space キー
        const result = try allocator.alloc(u8, 1);
        result[0] = ' ';
        return result;
    } else if (std.mem.eql(u8, seq, "Enter")) {
        const result = try allocator.alloc(u8, 1);
        result[0] = '\r';
        return result;
    } else if (std.mem.eql(u8, seq, "Backspace")) {
        const result = try allocator.alloc(u8, 1);
        result[0] = 0x7F;
        return result;
    } else if (std.mem.eql(u8, seq, "Tab")) {
        const result = try allocator.alloc(u8, 1);
        result[0] = '\t';
        return result;
    } else if (std.mem.eql(u8, seq, "Escape")) {
        const result = try allocator.alloc(u8, 1);
        result[0] = 0x1B;
        return result;
    } else if (std.mem.eql(u8, seq, "Up")) {
        const result = try allocator.alloc(u8, 3);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = 'A';
        return result;
    } else if (std.mem.eql(u8, seq, "Down")) {
        const result = try allocator.alloc(u8, 3);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = 'B';
        return result;
    } else if (std.mem.eql(u8, seq, "Right")) {
        const result = try allocator.alloc(u8, 3);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = 'C';
        return result;
    } else if (std.mem.eql(u8, seq, "Left")) {
        const result = try allocator.alloc(u8, 3);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = 'D';
        return result;
    } else if (std.mem.eql(u8, seq, "PageDown")) {
        const result = try allocator.alloc(u8, 4);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = '6';
        result[3] = '~';
        return result;
    } else if (std.mem.eql(u8, seq, "PageUp")) {
        const result = try allocator.alloc(u8, 4);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = '5';
        result[3] = '~';
        return result;
    } else if (std.mem.eql(u8, seq, "Home")) {
        const result = try allocator.alloc(u8, 3);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = 'H';
        return result;
    } else if (std.mem.eql(u8, seq, "End")) {
        const result = try allocator.alloc(u8, 3);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = 'F';
        return result;
    } else if (std.mem.eql(u8, seq, "M-Up")) {
        // Alt+Up (ESC [1;3A)
        const result = try allocator.alloc(u8, 6);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = '1';
        result[3] = ';';
        result[4] = '3';
        result[5] = 'A';
        return result;
    } else if (std.mem.eql(u8, seq, "M-Down")) {
        // Alt+Down (ESC [1;3B)
        const result = try allocator.alloc(u8, 6);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = '1';
        result[3] = ';';
        result[4] = '3';
        result[5] = 'B';
        return result;
    } else if (std.mem.eql(u8, seq, "S-Tab")) {
        // Shift+Tab (ESC [Z)
        const result = try allocator.alloc(u8, 3);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = 'Z';
        return result;
    } else if (std.mem.eql(u8, seq, "C-Tab")) {
        // Ctrl+Tab (ESC [27;5;9~) - zeが期待する形式
        const result = try allocator.alloc(u8, 9);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = '2';
        result[3] = '7';
        result[4] = ';';
        result[5] = '5';
        result[6] = ';';
        result[7] = '9';
        result[8] = '~';
        return result;
    } else if (std.mem.eql(u8, seq, "C-S-Tab")) {
        // Ctrl+Shift+Tab (ESC [27;6;9~) - zeが期待する形式
        const result = try allocator.alloc(u8, 9);
        result[0] = 0x1B;
        result[1] = '[';
        result[2] = '2';
        result[3] = '7';
        result[4] = ';';
        result[5] = '6';
        result[6] = ';';
        result[7] = '9';
        result[8] = '~';
        return result;
    } else {
        // 通常の文字列
        return try allocator.dupe(u8, seq);
    }
}

extern "c" fn openpty(
    master_fd: *c_int,
    slave_fd: *c_int,
    name: ?[*:0]u8,
    termp: ?*const anyopaque,
    winp: ?*const anyopaque,
) c_int;

extern "c" fn setenv(
    name: [*:0]const u8,
    value: [*:0]const u8,
    overwrite: c_int,
) c_int;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;

const F_GETFL = 3;
const F_SETFL = 4;
const O_NONBLOCK = 0x0004;

const winsize_t = extern struct {
    ws_row: c_ushort,
    ws_col: c_ushort,
    ws_xpixel: c_ushort,
    ws_ypixel: c_ushort,
};
