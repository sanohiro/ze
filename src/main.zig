const std = @import("std");
const Editor = @import("editor.zig").Editor;
const View = @import("view.zig").View;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // コマンドライン引数を処理
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // プログラム名をスキップ

    // ファイル名がある場合は、Editor初期化前にバイナリチェック
    var checked_filename: ?[]const u8 = null;
    if (args.next()) |filename| {
        // ファイルが存在する場合のみバイナリチェック
        const maybe_file = std.fs.cwd().openFile(filename, .{}) catch |err| blk: {
            if (err == error.FileNotFound) {
                // 新規ファイルとして扱う
                checked_filename = filename;
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
                const msg = try std.fmt.bufPrint(&buf, "エラー: バイナリファイルは開けません: {s}\n", .{filename});
                _ = try stderr_file.write(msg);
                return;
            }

            checked_filename = filename;
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
