const std = @import("std");
const testing = std.testing;
const BufferManager = @import("buffer_manager").BufferManager;

test "BufferManager - create buffer" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();
    try testing.expectEqual(@as(usize, 0), buffer.id);
    try testing.expectEqual(@as(usize, 1), bm.bufferCount());
}

test "BufferManager - find by id" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buffer1 = try bm.createBuffer();
    const buffer2 = try bm.createBuffer();

    const found = bm.findById(buffer1.id);
    try testing.expect(found != null);
    try testing.expectEqual(buffer1.id, found.?.id);

    const found2 = bm.findById(buffer2.id);
    try testing.expect(found2 != null);
    try testing.expectEqual(buffer2.id, found2.?.id);
}

test "BufferManager - delete buffer" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();
    try testing.expectEqual(@as(usize, 1), bm.bufferCount());

    const deleted = bm.deleteBuffer(buffer.id);
    try testing.expect(deleted);
    try testing.expectEqual(@as(usize, 0), bm.bufferCount());
}

test "BufferState - getName" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();
    try testing.expectEqualStrings("*scratch*", buffer.getName());
}
