const std = @import("std");
const build_options = @import("build_options");
const Editor = @import("editor.zig").Editor;
const View = @import("view.zig").View;

const version = build_options.version;

fn printHelp() void {
    const stdout_file: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    stdout_file.writeAll(
        \\ze - Zig Editor / Zero-latency Editor
        \\
        \\Usage: ze [options] [file]
        \\
        \\Options:
        \\  --help     このヘルプを表示
        \\  --version  バージョンを表示
        \\
        \\Examples:
        \\  ze file.txt    ファイルを開く
        \\  ze             新規バッファで起動
        \\
    ) catch {};
}

fn printVersion() void {
    const stdout_file: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    var buf: [32]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "ze {s}\n", .{version}) catch return;
    stdout_file.writeAll(msg) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // コマンドライン引数を処理
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // プログラム名をスキップ

    // オプションとファイル名を処理
    var checked_filename: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            printVersion();
            return;
        } else if (arg.len > 0 and arg[0] == '-') {
            // 未知のオプション
            const stderr_file: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "不明なオプション: {s}\n", .{arg}) catch {
                printHelp();
                return;
            };
            stderr_file.writeAll(msg) catch {};
            printHelp();
            return;
        } else {
            // ファイル名として扱う
            // ファイルが存在する場合のみバイナリチェック
            const maybe_file = std.fs.cwd().openFile(arg, .{}) catch |err| blk: {
                if (err == error.FileNotFound) {
                    // 新規ファイルとして扱う
                    checked_filename = arg;
                    break :blk null;
                } else {
                    return err;
                }
            };

            if (maybe_file) |f| {
                defer f.close();

                const stat = try f.stat();
                const content = try f.readToEndAlloc(allocator, stat.size);
                defer allocator.free(content);

                // バイナリファイルチェック
                const check_size = @min(content.len, 8192);
                var is_binary = false;
                for (content[0..check_size]) |byte| {
                    if (byte == 0) {
                        is_binary = true;
                        break;
                    }
                }

                if (is_binary) {
                    const stderr_file: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };
                    var buf: [256]u8 = undefined;
                    const msg = try std.fmt.bufPrint(&buf, "エラー: バイナリファイルは開けません: {s}\n", .{arg});
                    _ = try stderr_file.write(msg);
                    return;
                }

                checked_filename = arg;
            }
            break; // 最初のファイル名のみ処理
        }
    }

    var editor = try Editor.init(allocator);
    defer editor.deinit();

    if (checked_filename) |filename| {
        // ファイルを開く（既にバイナリチェック済み）
        editor.loadFile(filename) catch |err| {
            // ファイルが存在しない場合は新規作成として扱う
            if (err != error.FileNotFound) {
                return err;
            }
            // 新規ファイルの場合、現在のバッファにファイル名を設定
            const buffer = editor.getCurrentBuffer();
            buffer.filename = try allocator.dupe(u8, filename);
            // 新規ファイルでも拡張子から言語検出
            const view = editor.getCurrentView();
            view.detectLanguage(filename, null);
        };
    }

    // エディタを実行
    try editor.run();

    // 終了時に改行を出力（ターミナルのプロンプト表示を整える）
    const stdout_file: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    _ = try stdout_file.write("\n");
}
