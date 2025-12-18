const std = @import("std");
const build_options = @import("build_options");
const Editor = @import("editor").Editor;
const View = @import("view").View;

const version = build_options.version;

fn printHelp() void {
    const stdout_file: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    stdout_file.writeAll(
        \\ze - Zig Editor / Zero-latency Editor
        \\
        \\Usage: ze [options] [file]
        \\
        \\Options:
        \\  -R         Read-only mode (view mode)
        \\  --help     Show this help message
        \\  --version  Show version
        \\
        \\Examples:
        \\  ze file.txt    Open a file
        \\  ze -R log.txt  View a file (read-only)
        \\  ze             Start with empty buffer
        \\
    ) catch {};
}

fn printVersion() void {
    const stdout_file: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ze {s}\n", .{version}) catch return;
    stdout_file.writeAll(msg) catch {};
}

/// Exit codes (Unix convention)
const EXIT_SUCCESS: u8 = 0;
const EXIT_IO_ERROR: u8 = 1;
const EXIT_USAGE_ERROR: u8 = 2;

pub fn main() u8 {
    return mainImpl() catch |err| {
        const stderr_file: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error: {}\n", .{err}) catch return EXIT_IO_ERROR;
        stderr_file.writeAll(msg) catch {};
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
            const stderr_file: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Unknown option: {s}\n", .{arg}) catch {
                printHelp();
                return EXIT_USAGE_ERROR;
            };
            stderr_file.writeAll(msg) catch {};
            printHelp();
            return EXIT_USAGE_ERROR;
        } else {
            // ファイル名として扱う（バイナリチェックはloadFile内で行う）
            checked_filename = arg;
            break; // 最初のファイル名のみ処理
        }
    }

    var editor = try Editor.init(allocator);
    defer editor.deinit();

    if (checked_filename) |filename| {
        // ファイルを開く（バイナリチェックはloadFile内で行う）
        editor.loadFile(filename) catch |err| {
            if (err == error.BinaryFile) {
                // バイナリファイルはエラー終了
                const stderr_file: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Error: cannot open binary file: {s}\n", .{filename}) catch return EXIT_IO_ERROR;
                stderr_file.writeAll(msg) catch {};
                return EXIT_IO_ERROR;
            } else if (err == error.FileNotFound) {
                // 新規ファイルの場合、現在のバッファにファイル名を設定
                const buffer_state = editor.getCurrentBuffer();
                buffer_state.filename = try allocator.dupe(u8, filename);
                // 新規ファイルでも拡張子から言語検出
                const view = editor.getCurrentView();
                view.detectLanguage(filename, null);
            } else {
                return err;
            }
        };

        // -R オプションで読み取り専用モードを設定
        if (read_only_mode) {
            editor.getCurrentBuffer().readonly = true;
        }
    }

    // エディタを実行
    try editor.run();
    // 改行はterminal.deinit()で出力される
    return EXIT_SUCCESS;
}
