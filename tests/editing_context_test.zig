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

// ============================================================
// Modified flag tests
// ============================================================

test "modified flag on insert" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try testing.expect(!ctx.modified);

    try ctx.insert("a");
    try testing.expect(ctx.modified);
}

test "modified flag reset after undo all changes" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try testing.expect(!ctx.modified);

    try ctx.insert("abc");
    try testing.expect(ctx.modified);

    _ = try ctx.undo();
    try testing.expect(!ctx.modified);
}

test "modified flag stays true after partial undo" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    // 2つの独立した操作（異なる操作タイプでグループ化されない）
    try ctx.insert("abc");
    // 削除操作を挟むことでグループ化を防ぐ
    try ctx.backspace(); // 'c'を削除
    try ctx.insert("xyz");

    try testing.expect(ctx.modified);

    // 1回目のundo（xyzを削除）
    _ = try ctx.undo();
    try testing.expect(ctx.modified); // まだ変更あり

    // 2回目のundo（backspaceを戻す）
    _ = try ctx.undo();
    try testing.expect(ctx.modified); // まだ変更あり

    // 3回目のundo（abcを削除）
    _ = try ctx.undo();
    try testing.expect(!ctx.modified); // 全て元に戻った
}

test "modified flag on delete" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello");
    ctx.modified = false; // リセット

    try ctx.backspace();
    try testing.expect(ctx.modified);
}

test "redo sets modified flag" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("abc");
    _ = try ctx.undo();
    try testing.expect(!ctx.modified);

    _ = try ctx.redo();
    try testing.expect(ctx.modified);
}

// ============================================================
// Kill ring and yank tests
// ============================================================

test "kill region" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello world");
    ctx.mark = 0;
    ctx.cursor = 5;

    try ctx.killRegion();
    try testing.expectEqual(@as(usize, 6), ctx.len()); // " world" remains
    try testing.expectEqualStrings("hello", ctx.kill_ring.?);
}

test "yank after kill" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello world");
    ctx.mark = 0;
    ctx.cursor = 5;

    try ctx.killRegion(); // kill "hello"
    try testing.expectEqual(@as(usize, 6), ctx.len());

    ctx.cursor = ctx.len(); // 末尾に移動
    try ctx.yank();

    // yank後の長さを確認（" world" + "hello" = 11文字）
    try testing.expectEqual(@as(usize, 11), ctx.len());
    // kill_ringが保持されていることを確認
    try testing.expectEqualStrings("hello", ctx.kill_ring.?);
}

// ============================================================
// Line operations tests
// ============================================================

test "line count" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("a\nb\nc");
    try testing.expectEqual(@as(usize, 3), ctx.lineCount());

    try ctx.insert("\n");
    try testing.expectEqual(@as(usize, 4), ctx.lineCount());
}

test "get cursor line and column" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("line1\nline2\nline3");
    ctx.cursor = 8; // "line2"の'n'

    try testing.expectEqual(@as(usize, 1), ctx.getCursorLine());
    try testing.expectEqual(@as(usize, 2), ctx.getCursorColumn()); // "li"の後
}

// ============================================================
// Word operations tests
// ============================================================

test "move forward word" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello world test");
    ctx.cursor = 0;

    ctx.moveForwardWord();
    try testing.expectEqual(@as(usize, 6), ctx.cursor); // "world"の先頭

    ctx.moveForwardWord();
    try testing.expectEqual(@as(usize, 12), ctx.cursor); // "test"の先頭
}

test "move backward word" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello world test");
    ctx.cursor = 16; // 末尾

    ctx.moveBackwardWord();
    try testing.expectEqual(@as(usize, 12), ctx.cursor); // "test"の先頭

    ctx.moveBackwardWord();
    try testing.expectEqual(@as(usize, 6), ctx.cursor); // "world"の先頭
}

// ============================================================
// Edge cases
// ============================================================

test "empty buffer operations" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try testing.expectEqual(@as(usize, 0), ctx.len());
    try testing.expectEqual(@as(usize, 0), ctx.cursor);

    // 空バッファでの移動
    ctx.moveForward();
    try testing.expectEqual(@as(usize, 0), ctx.cursor);

    ctx.moveBackward();
    try testing.expectEqual(@as(usize, 0), ctx.cursor);

    // 空バッファでのundo
    const undone = try ctx.undo();
    try testing.expect(!undone);
}

test "delete at beginning" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("hello");
    ctx.cursor = 0;

    // 先頭でbackspace（何も起きない）
    try ctx.backspace();
    try testing.expectEqual(@as(usize, 5), ctx.len());
}

test "cursor bounds" {
    var ctx = try EditingContext.init(testing.allocator);
    defer ctx.deinit();

    try ctx.insert("abc");

    // 末尾を超えて移動しようとしても末尾で止まる
    ctx.cursor = ctx.len();
    ctx.moveForward();
    try testing.expectEqual(ctx.len(), ctx.cursor);

    // 先頭を超えて移動しようとしても先頭で止まる
    ctx.cursor = 0;
    ctx.moveBackward();
    try testing.expectEqual(@as(usize, 0), ctx.cursor);
}
