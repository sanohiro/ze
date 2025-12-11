const std = @import("std");
const testing = std.testing;
const Minibuffer = @import("minibuffer").Minibuffer;

test "Minibuffer - basic operations" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello");
    try testing.expectEqualStrings("hello", mb.getContent());
    try testing.expectEqual(@as(usize, 5), mb.cursor);

    mb.backspace();
    try testing.expectEqualStrings("hell", mb.getContent());

    mb.moveToStart();
    try testing.expectEqual(@as(usize, 0), mb.cursor);

    mb.delete();
    try testing.expectEqualStrings("ell", mb.getContent());
}

test "Minibuffer - cursor movement" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello world");

    mb.moveToStart();
    try testing.expectEqual(@as(usize, 0), mb.cursor);

    mb.moveRight();
    try testing.expectEqual(@as(usize, 1), mb.cursor);

    mb.moveToEnd();
    try testing.expectEqual(@as(usize, 11), mb.cursor);

    mb.moveLeft();
    try testing.expectEqual(@as(usize, 10), mb.cursor);
}

test "Minibuffer - word operations" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello world test");

    mb.moveWordBackward();
    try testing.expectEqual(@as(usize, 12), mb.cursor);

    mb.moveWordBackward();
    try testing.expectEqual(@as(usize, 6), mb.cursor);

    mb.moveWordForward();
    try testing.expectEqual(@as(usize, 12), mb.cursor);
}

test "Minibuffer - prompt" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    mb.setPrompt("Search: ");
    try testing.expectEqualStrings("Search: ", mb.getPrompt());
}
