const std = @import("std");
const testing = std.testing;
const EditingContext = @import("editing_context").EditingContext;

test "basic insert and delete" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello");
    try testing.expectEqual(@as(usize, 5), ctx.len());
    try testing.expectEqual(@as(usize, 5), ctx.cursor);

    try ctx.backspace();
    try testing.expectEqual(@as(usize, 4), ctx.len());
}

test "undo and redo" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("abc");
    try testing.expectEqual(@as(usize, 3), ctx.len());

    _ = try ctx.undo();
    try testing.expectEqual(@as(usize, 0), ctx.len());

    _ = try ctx.redo();
    try testing.expectEqual(@as(usize, 3), ctx.len());
}

test "undo grouping for consecutive inserts" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    // 連続した挿入はグループ化される
    try ctx.insertChar('h');
    try ctx.insertChar('e');
    try ctx.insertChar('l');
    try ctx.insertChar('l');
    try ctx.insertChar('o');
    try testing.expectEqual(@as(usize, 5), ctx.len());

    // 1回のUndoで全て取り消される
    _ = try ctx.undo();
    try testing.expectEqual(@as(usize, 0), ctx.len());
}

test "undo grouping for consecutive backspaces" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello");
    try testing.expectEqual(@as(usize, 5), ctx.len());

    // Undoスタックをクリアして削除操作のグループ化をテスト
    ctx.clearUndoHistory();

    // 連続したBackspace
    try ctx.backspace(); // o
    try ctx.backspace(); // l
    try ctx.backspace(); // l
    try testing.expectEqual(@as(usize, 2), ctx.len());

    // 1回のUndoで全て復元される
    _ = try ctx.undo();
    try testing.expectEqual(@as(usize, 5), ctx.len());
}

test "selection and copy" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello world");
    ctx.mark = 0;
    ctx.cursor = 5;

    try ctx.copyRegion();
    try testing.expect(ctx.kill_ring != null);
    try testing.expectEqualStrings("hello", ctx.kill_ring.?);
}

test "cursor movement" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello\nworld");
    try testing.expectEqual(@as(usize, 11), ctx.cursor);

    // 先頭に移動
    ctx.moveBeginningOfBuffer();
    try testing.expectEqual(@as(usize, 0), ctx.cursor);

    // 前進
    ctx.moveForward();
    try testing.expectEqual(@as(usize, 1), ctx.cursor);

    // 行末に移動
    ctx.moveEndOfLine();
    try testing.expectEqual(@as(usize, 5), ctx.cursor);

    // 次の行へ
    ctx.moveNextLine();
    try testing.expectEqual(@as(usize, 1), ctx.getCursorLine());

    // 行頭へ
    ctx.moveBeginningOfLine();
    try testing.expectEqual(@as(usize, 6), ctx.cursor);
}
