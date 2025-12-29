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

// ============================================================
// Multiple buffer tests
// ============================================================

test "BufferManager - multiple buffers" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.createBuffer();
    _ = try bm.createBuffer();
    _ = try bm.createBuffer();

    try testing.expectEqual(@as(usize, 3), bm.bufferCount());
}

test "BufferManager - buffer IDs are unique" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buf1 = try bm.createBuffer();
    const buf2 = try bm.createBuffer();
    const buf3 = try bm.createBuffer();

    // IDはすべて異なる
    try testing.expect(buf1.id != buf2.id);
    try testing.expect(buf2.id != buf3.id);
    try testing.expect(buf1.id != buf3.id);
}

test "BufferManager - find by id returns null for non-existent" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.createBuffer();

    // 存在しないIDで検索
    const not_found = bm.findById(999);
    try testing.expect(not_found == null);
}

test "BufferManager - delete non-existent buffer" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.createBuffer();

    // 存在しないIDを削除しようとする
    const deleted = bm.deleteBuffer(999);
    try testing.expect(!deleted);
    try testing.expectEqual(@as(usize, 1), bm.bufferCount());
}

test "BufferManager - delete middle buffer" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buf1 = try bm.createBuffer();
    const buf2 = try bm.createBuffer();
    const buf3 = try bm.createBuffer();

    // 真ん中のバッファを削除
    const deleted = bm.deleteBuffer(buf2.id);
    try testing.expect(deleted);
    try testing.expectEqual(@as(usize, 2), bm.bufferCount());

    // buf1とbuf3はまだ存在する
    try testing.expect(bm.findById(buf1.id) != null);
    try testing.expect(bm.findById(buf3.id) != null);
    try testing.expect(bm.findById(buf2.id) == null);
}

// ============================================================
// Modified state tests
// ============================================================

test "BufferState - isModified initially false" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();
    try testing.expect(!buffer.isModified());
}

test "BufferState - markSaved clears modified" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();

    // バッファを変更
    try buffer.editing_ctx.insert("test");
    try testing.expect(buffer.isModified());

    // 保存済みとしてマーク
    buffer.markSaved();
    try testing.expect(!buffer.isModified());
}

test "BufferManager - hasUnsavedChanges" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.createBuffer();
    const buf2 = try bm.createBuffer();

    // 初期状態は未変更
    try testing.expect(!bm.hasUnsavedChanges());

    // buf2を変更
    try buf2.editing_ctx.insert("modified");
    try testing.expect(bm.hasUnsavedChanges());

    // 保存済みにする
    buf2.markSaved();
    try testing.expect(!bm.hasUnsavedChanges());
}

// ============================================================
// Buffer access tests
// ============================================================

test "BufferState - getBuffer returns editing context buffer" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buf_state = try bm.createBuffer();

    // getBuffer()とediting_ctx.bufferは同じ
    const buffer_via_getter = buf_state.getBuffer();
    const buffer_via_ctx = buf_state.editing_ctx.buffer;
    try testing.expect(buffer_via_getter == buffer_via_ctx);
}

test "BufferState - buffer() shorthand" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buf_state = try bm.createBuffer();

    // buffer()メソッドでもアクセスできる
    const buffer = buf_state.buffer();
    try testing.expect(buffer == buf_state.editing_ctx.buffer);
}

// ============================================================
// Iterator tests
// ============================================================

test "BufferManager - iterator" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.createBuffer();
    _ = try bm.createBuffer();
    _ = try bm.createBuffer();

    const buffers = bm.iterator();
    try testing.expectEqual(@as(usize, 3), buffers.len);
}

test "BufferManager - iteratorConst" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.createBuffer();
    _ = try bm.createBuffer();

    const const_bm: *const BufferManager = &bm;
    const buffers = const_bm.iteratorConst();
    try testing.expectEqual(@as(usize, 2), buffers.len);
}

test "BufferManager - getFirst" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    // 空の場合はnull
    try testing.expect(bm.getFirst() == null);

    const buf1 = try bm.createBuffer();
    _ = try bm.createBuffer();

    // 最初のバッファを取得
    const first = bm.getFirst();
    try testing.expect(first != null);
    try testing.expectEqual(buf1.id, first.?.id);
}

// ============================================================
// Buffer names tests
// ============================================================

test "BufferManager - getBufferNames" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.createBuffer();
    _ = try bm.createBuffer();

    const names = try bm.getBufferNames(testing.allocator);
    defer testing.allocator.free(names);

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("*scratch*", names[0]);
    try testing.expectEqualStrings("*scratch*", names[1]);
}

// ============================================================
// Path tests
// ============================================================

test "BufferState - getPath returns null for scratch buffer" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();
    try testing.expect(buffer.getPath() == null);
}

// ============================================================
// Edge cases
// ============================================================

test "BufferManager - empty after deleting all buffers" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buf1 = try bm.createBuffer();
    const buf2 = try bm.createBuffer();

    _ = bm.deleteBuffer(buf1.id);
    _ = bm.deleteBuffer(buf2.id);

    try testing.expectEqual(@as(usize, 0), bm.bufferCount());
    try testing.expect(bm.getFirst() == null);
}

test "BufferManager - buffer id continues after delete" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buf1 = try bm.createBuffer(); // id = 0
    _ = bm.deleteBuffer(buf1.id);

    const buf2 = try bm.createBuffer(); // id = 1（0ではない）
    try testing.expect(buf2.id > buf1.id);
}

test "BufferState - readonly flag" {
    var bm = BufferManager.init(testing.allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();

    // 初期状態は読み取り専用ではない
    try testing.expect(!buffer.file.readonly);

    // 読み取り専用に設定
    buffer.file.readonly = true;
    try testing.expect(buffer.file.readonly);
}
