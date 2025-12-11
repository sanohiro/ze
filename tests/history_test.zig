const std = @import("std");
const testing = std.testing;
const History = @import("history").History;

test "history basic operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    // 追加
    try history.add("ls -la");
    try history.add("grep foo");
    try history.add("cat bar");

    try testing.expectEqual(@as(usize, 3), history.entries.items.len);

    // 連続重複は追加されない
    try history.add("cat bar");
    try testing.expectEqual(@as(usize, 3), history.entries.items.len);

    // ナビゲーション
    try history.startNavigation("current");

    // prev: 最新から順に
    const e1 = history.prev();
    try testing.expectEqualStrings("cat bar", e1.?);

    const e2 = history.prev();
    try testing.expectEqualStrings("grep foo", e2.?);

    const e3 = history.prev();
    try testing.expectEqualStrings("ls -la", e3.?);

    // 最古を超えても同じ
    const e4 = history.prev();
    try testing.expectEqualStrings("ls -la", e4.?);

    // next: 戻る
    const e5 = history.next();
    try testing.expectEqualStrings("grep foo", e5.?);

    const e6 = history.next();
    try testing.expectEqualStrings("cat bar", e6.?);

    // 最新を超えると元の入力
    const e7 = history.next();
    try testing.expectEqualStrings("current", e7.?);
}
