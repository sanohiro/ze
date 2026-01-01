const std = @import("std");
const build_options = @import("build_options");
const Editor = @import("editor").Editor;
const encoding = @import("encoding");

const version = build_options.version;

/// 標準出力/エラー出力
const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

/// stdinがパイプかどうかを判定
fn isStdinPipe() bool {
    const stdin_handle = std.posix.STDIN_FILENO;
    const stat = std.posix.fstat(stdin_handle) catch return false;
    // S_IFIFO (named pipe) または S_IFREG (regular file) の場合はパイプとみなす
    const mode = stat.mode & std.posix.S.IFMT;
    return mode == std.posix.S.IFIFO or mode == std.posix.S.IFREG;
}

/// stderr にエラーメッセージを出力
fn writeError(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stderr.writeAll(msg) catch {};
}

fn printHelp() void {
    stdout.writeAll(
        \\ze - Zig Editor / Zero-latency Editor
        \\
        \\Usage: ze [options] [file]
        \\       command | ze
        \\
        \\Options:
        \\  -R         Read-only mode (view mode)
        \\  --help     Show this help message
        \\  --version  Show version
        \\
        \\Examples:
        \\  ze file.txt        Open a file
        \\  ze -R log.txt      View a file (read-only)
        \\  ze                 Start with empty buffer
        \\  cat file | ze      Edit piped content
        \\  git diff | ze      View diff in editor
        \\
    ) catch {};
}

fn printVersion() void {
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ze {s}\n", .{version}) catch return;
    stdout.writeAll(msg) catch {};
}

/// Exit codes (Unix convention)
const EXIT_SUCCESS: u8 = 0;
const EXIT_IO_ERROR: u8 = 1;
const EXIT_USAGE_ERROR: u8 = 2;

/// ファイルがバイナリかどうかを事前チェック（Editor.init前に呼び出し）
/// ターミナルを代替スクリーンに入れる前にエラーを表示するため
fn checkBinaryFile(path: []const u8) error{BinaryFile}!void {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        // ファイルが開けない場合は新規ファイルとして扱う（バイナリではない）
        return;
    };
    defer file.close();

    // 最初の8KBを読み取ってバイナリ判定
    var buf: [8192]u8 = undefined;
    const bytes_read = file.read(&buf) catch return;
    if (bytes_read == 0) return; // 空ファイル

    const content = buf[0..bytes_read];
    const result = encoding.detectEncoding(content);
    if (result.encoding == .Unknown) {
        return error.BinaryFile;
    }
}

pub fn main() u8 {
    return mainImpl() catch |err| {
        writeError("Error: {}\n", .{err});
        return EXIT_IO_ERROR;
    };
}

fn mainImpl() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // コマンドライン引数を処理
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // プログラム名をスキップ

    // オプションとファイル名を処理
    var checked_filename: ?[]const u8 = null;
    var read_only_mode = false;
    var options_ended = false; // "--"でオプション終了
    while (args.next()) |arg| {
        if (!options_ended and std.mem.eql(u8, arg, "--")) {
            // "--"以降は全てファイル名として扱う
            options_ended = true;
            continue;
        } else if (!options_ended and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
            printHelp();
            return EXIT_SUCCESS;
        } else if (!options_ended and (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))) {
            printVersion();
            return EXIT_SUCCESS;
        } else if (!options_ended and std.mem.eql(u8, arg, "-R")) {
            read_only_mode = true;
            continue;
        } else if (!options_ended and arg.len > 0 and arg[0] == '-') {
            // 未知のオプション
            writeError("Unknown option: {s}\n", .{arg});
            printHelp();
            return EXIT_USAGE_ERROR;
        } else {
            // ファイル名として扱う
            checked_filename = arg;
            break; // 最初のファイル名のみ処理
        }
    }

    // stdinがパイプの場合、内容を読み込む
    var stdin_content: ?[]u8 = null;
    var tty_file: ?std.fs.File = null;
    defer if (stdin_content) |content| allocator.free(content);
    defer if (tty_file) |f| f.close();

    if (isStdinPipe()) {
        // パイプからの入力を全て読み込む（最大64MB）
        const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };
        stdin_content = stdin.readToEndAlloc(allocator, 64 * 1024 * 1024) catch |err| {
            writeError("Error reading from stdin: {}\n", .{err});
            return EXIT_IO_ERROR;
        };

        // バイナリチェック
        if (stdin_content) |content| {
            if (content.len > 0) {
                const check_len = @min(content.len, 8192);
                const result = encoding.detectEncoding(content[0..check_len]);
                if (result.encoding == .Unknown) {
                    writeError("Error: stdin contains binary data\n", .{});
                    return EXIT_IO_ERROR;
                }
            }
        }

        // キーボード入力用に/dev/ttyを開く
        tty_file = std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_only }) catch {
            writeError("Error: cannot open /dev/tty for keyboard input\n", .{});
            return EXIT_IO_ERROR;
        };
    }

    // バイナリファイルチェック（Editor.init前に実行）
    // ターミナルを代替スクリーンに入れる前にエラーを表示するため
    if (checked_filename) |filename| {
        checkBinaryFile(filename) catch {
            writeError("Error: cannot open binary file: {s}\n", .{filename});
            return EXIT_IO_ERROR;
        };
    }

    var editor = try Editor.init(allocator, tty_file);
    defer editor.deinit();

    // stdinからの入力がある場合、バッファに読み込む
    if (stdin_content) |content| {
        if (content.len > 0) {
            try editor.loadFromMemory(content, "[stdin]");
        }
    } else if (checked_filename) |filename| {
        // ファイルを開く
        editor.loadFile(filename) catch |err| {
            if (err == error.BinaryFile) {
                // 事前チェックをすり抜けた場合（通常は起きない）
                writeError("Error: cannot open binary file: {s}\n", .{filename});
                return EXIT_IO_ERROR;
            } else if (err == error.FileNotFound) {
                // 新規ファイルの場合、現在のバッファにファイル名を設定
                const buffer_state = editor.getCurrentBuffer();
                buffer_state.file.filename = try allocator.dupe(u8, filename);
                // 新規ファイルでも拡張子から言語検出
                const view = editor.getCurrentView();
                view.detectLanguage(filename, null);
            } else {
                return err;
            }
        };

        // -R オプションで読み取り専用モードを設定
        if (read_only_mode) {
            editor.getCurrentBuffer().file.readonly = true;
        }
    }

    // エディタを実行
    try editor.run();
    // 改行はterminal.deinit()で出力される
    return EXIT_SUCCESS;
}
