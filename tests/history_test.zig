const std = @import("std");
const testing = std.testing;
const history_mod = @import("history");
const History = history_mod.History;
const MAX_HISTORY_SIZE = history_mod.MAX_HISTORY_SIZE;

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

test "empty history navigation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    // 空の履歴でナビゲーション
    try history.startNavigation("test");

    // prev/nextはnull
    try testing.expect(history.prev() == null);
    try testing.expect(history.next() == null);
}

test "empty entry not added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    // 空文字列は追加されない
    try history.add("");
    try testing.expectEqual(@as(usize, 0), history.entries.items.len);

    try history.add("valid");
    try history.add("");
    try testing.expectEqual(@as(usize, 1), history.entries.items.len);
}

test "max history size limit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    // MAX_HISTORY_SIZE + 10 個追加
    for (0..MAX_HISTORY_SIZE + 10) |i| {
        var buf: [32]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "entry{d}", .{i}) catch unreachable;
        try history.add(entry);
    }

    // 最大数を超えない
    try testing.expectEqual(MAX_HISTORY_SIZE, history.entries.items.len);

    // 最古のエントリは削除されている（entry0〜entry9は消えている）
    const oldest = history.entries.items[0];
    try testing.expect(!std.mem.startsWith(u8, oldest, "entry0"));
    try testing.expect(!std.mem.startsWith(u8, oldest, "entry9"));
}

test "reset navigation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    try history.add("cmd1");
    try history.add("cmd2");

    try history.startNavigation("current");
    _ = history.prev(); // cmd2
    _ = history.prev(); // cmd1

    // リセット
    history.resetNavigation();
    try testing.expect(history.current_index == null);
    try testing.expect(history.temp_input == null);

    // リセット後のナビゲーション
    try history.startNavigation("new");
    const e = history.prev();
    try testing.expectEqualStrings("cmd2", e.?);
}

test "navigation without startNavigation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    try history.add("cmd1");

    // startNavigationなしでprev
    const e = history.prev();
    try testing.expectEqualStrings("cmd1", e.?);

    // nextで戻ってもtemp_inputがないのでnull
    const n = history.next();
    try testing.expect(n == null);
}

test "consecutive duplicates not added" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    try history.add("cmd1");
    try history.add("cmd1"); // 重複
    try history.add("cmd1"); // 重複
    try testing.expectEqual(@as(usize, 1), history.entries.items.len);

    try history.add("cmd2");
    try history.add("cmd1"); // cmd2の後なので追加される
    try testing.expectEqual(@as(usize, 3), history.entries.items.len);
}

test "navigation preserves temp input on multiple calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    try history.add("old1");
    try history.add("old2");

    // startNavigationを複数回呼んでも問題ない
    try history.startNavigation("first");
    try history.startNavigation("second"); // 上書き

    _ = history.prev();
    _ = history.prev();
    const back = history.next();
    try testing.expectEqualStrings("old2", back.?);
    const back2 = history.next();
    try testing.expectEqualStrings("second", back2.?);
}
