const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;

// バッファから1文字取得するヘルパー関数
fn getChar(buffer: *const Buffer, allocator: std.mem.Allocator, pos: usize) !?u8 {
    if (pos >= buffer.len()) return null;
    const data = try buffer.getRange(allocator, pos, 1);
    defer allocator.free(data);
    if (data.len == 0) return null;
    return data[0];
}

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
    try testing.expectEqual(@as(u8, '\n'), (try getChar(&buffer, allocator, 0)).?);
    try testing.expectEqual(@as(u8, 'H'), (try getChar(&buffer, allocator, 1)).?);
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
    try testing.expectEqual(@as(u8, 'H'), (try getChar(&buffer, allocator, 0)).?);
    try testing.expectEqual(@as(u8, 'e'), (try getChar(&buffer, allocator, 1)).?);
    try testing.expectEqual(@as(u8, 'l'), (try getChar(&buffer, allocator, 2)).?);
    try testing.expectEqual(@as(u8, '\n'), (try getChar(&buffer, allocator, 3)).?);
    try testing.expectEqual(@as(u8, 'l'), (try getChar(&buffer, allocator, 4)).?);
    try testing.expectEqual(@as(u8, 'o'), (try getChar(&buffer, allocator, 5)).?);
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
    try testing.expectEqual(@as(u8, '\n'), (try getChar(&buffer, allocator, 5)).?);
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
    try testing.expectEqual(@as(u8, '\n'), (try getChar(&buffer, allocator, 0)).?);
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());
}

test "Enter key: Line counting" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 初期状態: 1行
    try testing.expectEqual(@as(usize, 1), buffer.lineCount());

    // 改行を挿入: 2行
    try buffer.insert(0, '\n');
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());

    // もう一つ改行: 3行
    try buffer.insert(1, '\n');
    try testing.expectEqual(@as(usize, 3), buffer.lineCount());
}
