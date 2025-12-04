const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;

test "Enter key: Insert newline at beginning" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello";
    try buffer.insertSlice(0, initial);

    // 先頭に改行を挿入
    try buffer.insert(0, '\n');

    // バッファの内容を確認
    try testing.expectEqual(@as(usize, 6), buffer.len()); // "\nHello"
    try testing.expectEqual(@as(u8, '\n'), buffer.charAt(0).?);
    try testing.expectEqual(@as(u8, 'H'), buffer.charAt(1).?);
}

test "Enter key: Insert newline in middle" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello";
    try buffer.insertSlice(0, initial);

    // 途中に改行を挿入 (Hel|lo)
    try buffer.insert(3, '\n');

    try testing.expectEqual(@as(usize, 6), buffer.len());
    try testing.expectEqual(@as(u8, 'H'), buffer.charAt(0).?);
    try testing.expectEqual(@as(u8, 'e'), buffer.charAt(1).?);
    try testing.expectEqual(@as(u8, 'l'), buffer.charAt(2).?);
    try testing.expectEqual(@as(u8, '\n'), buffer.charAt(3).?);
    try testing.expectEqual(@as(u8, 'l'), buffer.charAt(4).?);
    try testing.expectEqual(@as(u8, 'o'), buffer.charAt(5).?);
}

test "Enter key: Insert newline at end" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello";
    try buffer.insertSlice(0, initial);

    // 末尾に改行を挿入
    try buffer.insert(5, '\n');

    try testing.expectEqual(@as(usize, 6), buffer.len());
    try testing.expectEqual(@as(u8, '\n'), buffer.charAt(5).?);
}

test "Enter key: Multiple newlines" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Line1";
    try buffer.insertSlice(0, initial);

    // 改行を3回挿入
    try buffer.insert(5, '\n');
    try buffer.insertSlice(6, "Line2");
    try buffer.insert(11, '\n');
    try buffer.insertSlice(12, "Line3");

    try testing.expectEqual(@as(usize, 17), buffer.len()); // "Line1\nLine2\nLine3"
    try testing.expectEqual(@as(usize, 3), buffer.lineCount());
}

test "Enter key: Empty buffer" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 空のバッファに改行を挿入
    try buffer.insert(0, '\n');

    try testing.expectEqual(@as(usize, 1), buffer.len());
    try testing.expectEqual(@as(u8, '\n'), buffer.charAt(0).?);
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());
}

test "Enter key: Line counting" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 初期状態: 1行
    try testing.expectEqual(@as(usize, 1), buffer.lineCount());

    // 改行を追加: 2行
    try buffer.insert(0, '\n');
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());

    // さらに改行を追加: 3行
    try buffer.insert(1, '\n');
    try testing.expectEqual(@as(usize, 3), buffer.lineCount());

    // テキストを追加しても行数は変わらない
    try buffer.insertSlice(2, "Hello");
    try testing.expectEqual(@as(usize, 3), buffer.lineCount());

    // 改行を追加: 4行
    try buffer.insert(7, '\n');
    try testing.expectEqual(@as(usize, 4), buffer.lineCount());
}

test "Backspace: Delete newline" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Line1\nLine2";
    try buffer.insertSlice(0, initial);

    try testing.expectEqual(@as(usize, 3), buffer.lineCount());

    // 改行を削除
    try buffer.delete(5, 1);

    try testing.expectEqual(@as(usize, 2), buffer.lineCount());
    try testing.expectEqual(@as(usize, 10), buffer.len()); // "Line1Line2"
}

test "Enter key with emoji" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello😀World";
    try buffer.insertSlice(0, initial);

    // 😀の後に改行を挿入 (byte position 9)
    try buffer.insert(9, '\n');

    // 2行になっているはず
    try testing.expectEqual(@as(usize, 3), buffer.lineCount());
}

test "Word deletion: Delete word at beginning" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello World Test";
    try buffer.insertSlice(0, initial);

    // "Hello " を削除 (0から6文字)
    try buffer.delete(0, 6);

    try testing.expectEqual(@as(usize, 10), buffer.len());
    try testing.expectEqual(@as(u8, 'W'), buffer.charAt(0).?);
}

test "Word deletion: Delete word in middle" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello World Test";
    try buffer.insertSlice(0, initial);

    // "World " を削除 (position 6から6文字)
    try buffer.delete(6, 6);

    try testing.expectEqual(@as(usize, 10), buffer.len());
    // "Hello Test"
    try testing.expectEqual(@as(u8, 'H'), buffer.charAt(0).?);
    try testing.expectEqual(@as(u8, 'T'), buffer.charAt(6).?);
}

test "Word deletion: Delete word at end" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello World";
    try buffer.insertSlice(0, initial);

    // "World" を削除 (position 6から5文字)
    try buffer.delete(6, 5);

    try testing.expectEqual(@as(usize, 6), buffer.len());
    // "Hello "
    try testing.expectEqual(@as(u8, 'o'), buffer.charAt(4).?);
    try testing.expectEqual(@as(u8, ' '), buffer.charAt(5).?);
}

test "Word deletion: Multiple spaces" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello   World";
    try buffer.insertSlice(0, initial);

    // "Hello   " を削除
    try buffer.delete(0, 8);

    try testing.expectEqual(@as(usize, 5), buffer.len());
    try testing.expectEqual(@as(u8, 'W'), buffer.charAt(0).?);
}

test "Word deletion: With punctuation" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello, World!";
    try buffer.insertSlice(0, initial);

    // "Hello," を削除 (記号は単語の一部として扱われる)
    try buffer.delete(0, 6);

    try testing.expectEqual(@as(usize, 7), buffer.len());
}

test "Word deletion: Empty buffer" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 空のバッファで削除しても何も起きない
    try buffer.delete(0, 1);
    try testing.expectEqual(@as(usize, 0), buffer.len());
}
