const std = @import("std");
const Buffer = @import("src/buffer.zig").Buffer;
const View = @import("src/view.zig").View;
const Terminal = @import("src/terminal.zig").Terminal;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // テストファイル作成
    const test_content =
        \\Line 1: The quick brown fox jumps over the lazy dog.
        \\Line 2: This is a performance test for cell-level differential rendering.
        \\Line 3: We want to measure how much terminal output we generate per frame.
        \\Line 4: Lorem ipsum dolor sit amet, consectetur adipiscing elit.
        \\Line 5: Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.
        \\Line 6: Ut enim ad minim veniam, quis nostrud exercitation ullamco.
        \\Line 7: Duis aute irure dolor in reprehenderit in voluptate velit.
        \\Line 8: Excepteur sint occaecat cupidatat non proident sunt in culpa.
        \\Line 9: 日本語テキスト：セルレベル差分描画のテスト
        \\Line 10: 絵文字テスト: 🚀 🎉 🔥 ⚡ 💯
    ;

    try std.fs.cwd().writeFile(.{ .sub_path = "/tmp/bench_test.txt", .data = test_content });

    var buffer = try Buffer.loadFromFile(allocator, "/tmp/bench_test.txt");
    defer buffer.deinit();

    var terminal = try Terminal.init(allocator);
    defer terminal.deinit();

    var view = View.init(allocator, &buffer);
    defer view.deinit(allocator);

    std.debug.print("=== セル単位差分描画ベンチマーク ===\n", .{});
    std.debug.print("ファイルサイズ: {} バイト\n", .{buffer.len()});
    std.debug.print("行数: {}\n", .{buffer.lineCount()});
    std.debug.print("ターミナルサイズ: {}x{}\n\n", .{ terminal.width, terminal.height });

    // 初回レンダリング（全画面描画）
    view.markFullRedraw();
    try view.render(&terminal);
    const initial_output = terminal.buf.items.len;
    terminal.buf.clearRetainingCapacity();

    std.debug.print("初回レンダリング出力: {} バイト\n", .{initial_output});

    // 2回目レンダリング（変更なし、差分描画）
    try view.render(&terminal);
    const second_output = terminal.buf.items.len;
    terminal.buf.clearRetainingCapacity();

    std.debug.print("2回目レンダリング出力（変更なし）: {} バイト\n", .{second_output});
    std.debug.print("削減率: {d:.1}%\n\n", .{(1.0 - @as(f64, @floatFromInt(second_output)) / @as(f64, @floatFromInt(initial_output))) * 100.0});

    // 小さな変更（1文字変更）をシミュレート
    view.markDirty(0, 0);
    try view.render(&terminal);
    const dirty_output = terminal.buf.items.len;
    terminal.buf.clearRetainingCapacity();

    std.debug.print("小さな変更後レンダリング出力: {} バイト\n", .{dirty_output});
    std.debug.print("初回比: {d:.1}%\n", .{@as(f64, @floatFromInt(dirty_output)) / @as(f64, @floatFromInt(initial_output)) * 100.0});

    // 複数回レンダリングの平均
    const iterations = 100;
    var total_output: usize = 0;

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        try view.render(&terminal);
        total_output += terminal.buf.items.len;
        terminal.buf.clearRetainingCapacity();
    }
    const elapsed = timer.read();

    const avg_output = total_output / iterations;
    const avg_time_us = elapsed / iterations / 1000;

    std.debug.print("\n{} 回レンダリング平均:\n", .{iterations});
    std.debug.print("  出力: {} バイト\n", .{avg_output});
    std.debug.print("  時間: {} μs\n", .{avg_time_us});
    std.debug.print("  スループット: {d:.1} MB/s\n", .{@as(f64, @floatFromInt(avg_output)) / @as(f64, @floatFromInt(avg_time_us))});
}
