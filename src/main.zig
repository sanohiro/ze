const std = @import("std");
const Editor = @import("editor.zig").Editor;
const View = @import("view.zig").View;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var editor = try Editor.init(allocator);
    defer editor.deinit();

    // Editorが値返しされた後、viewのbufferポインタを再設定
    editor.view = View.init(allocator, &editor.buffer);

    // コマンドライン引数を処理
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // プログラム名をスキップ

    if (args.next()) |filename| {
        // ファイルを開く
        editor.loadFile(filename) catch |err| {
            // ファイルが存在しない場合は新規作成として扱う
            if (err != error.FileNotFound) {
                return err;
            }
            editor.filename = try allocator.dupe(u8, filename);
        };
    }

    // エディタを実行
    try editor.run();

    // 終了時に改行を出力（ターミナルのプロンプト表示を整える）
    const stdout_file: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    _ = try stdout_file.write("\n");
}
