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

// ============================================================
// Clear and setContent tests
// ============================================================

test "Minibuffer - clear" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello world");
    try testing.expect(mb.getContent().len > 0);

    mb.clear();
    try testing.expectEqual(@as(usize, 0), mb.getContent().len);
    try testing.expectEqual(@as(usize, 0), mb.cursor);
}

test "Minibuffer - setContent" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.setContent("initial");
    try testing.expectEqualStrings("initial", mb.getContent());
    try testing.expectEqual(@as(usize, 7), mb.cursor);

    // 新しい内容で上書き
    try mb.setContent("new");
    try testing.expectEqualStrings("new", mb.getContent());
    try testing.expectEqual(@as(usize, 3), mb.cursor);
}

// ============================================================
// Japanese (UTF-8) tests
// ============================================================

test "Minibuffer - Japanese input" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("日本語");
    try testing.expectEqualStrings("日本語", mb.getContent());
    // 日本語3文字 = 9バイト
    try testing.expectEqual(@as(usize, 9), mb.cursor);
}

test "Minibuffer - Japanese backspace" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("テスト");
    mb.backspace();
    try testing.expectEqualStrings("テス", mb.getContent());
    // 2文字 = 6バイト
    try testing.expectEqual(@as(usize, 6), mb.cursor);
}

test "Minibuffer - Japanese cursor movement" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("あいう");

    mb.moveLeft();
    // カーソルは「う」の前 = 6バイト
    try testing.expectEqual(@as(usize, 6), mb.cursor);

    mb.moveLeft();
    // カーソルは「い」の前 = 3バイト
    try testing.expectEqual(@as(usize, 3), mb.cursor);

    mb.moveRight();
    // カーソルは「う」の前 = 6バイト
    try testing.expectEqual(@as(usize, 6), mb.cursor);
}

test "Minibuffer - mixed Japanese and ASCII" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello日本語world");
    try testing.expectEqualStrings("hello日本語world", mb.getContent());
    // hello(5) + 日本語(9) + world(5) = 19バイト
    try testing.expectEqual(@as(usize, 19), mb.cursor);
}

// ============================================================
// Codepoint insertion tests
// ============================================================

test "Minibuffer - insertCodepointAtCursor ASCII" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertCodepointAtCursor('a');
    try mb.insertCodepointAtCursor('b');
    try mb.insertCodepointAtCursor('c');
    try testing.expectEqualStrings("abc", mb.getContent());
}

test "Minibuffer - insertCodepointAtCursor Unicode" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertCodepointAtCursor(0x3042); // あ
    try mb.insertCodepointAtCursor(0x3044); // い
    try testing.expectEqualStrings("あい", mb.getContent());
}

// ============================================================
// Delete operations tests
// ============================================================

test "Minibuffer - delete at cursor" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello");
    mb.moveToStart();

    mb.delete();
    try testing.expectEqualStrings("ello", mb.getContent());

    mb.delete();
    try testing.expectEqualStrings("llo", mb.getContent());
}

test "Minibuffer - delete at end does nothing" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("test");
    // カーソルは末尾

    mb.delete();
    try testing.expectEqualStrings("test", mb.getContent());
}

test "Minibuffer - backspace at start does nothing" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("test");
    mb.moveToStart();

    mb.backspace();
    try testing.expectEqualStrings("test", mb.getContent());
    try testing.expectEqual(@as(usize, 0), mb.cursor);
}

// ============================================================
// Word deletion tests
// ============================================================

test "Minibuffer - deleteWordBackward" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello world test");
    // カーソルは末尾

    mb.deleteWordBackward();
    try testing.expectEqualStrings("hello world ", mb.getContent());

    mb.deleteWordBackward();
    try testing.expectEqualStrings("hello ", mb.getContent());
}

test "Minibuffer - deleteWordForward" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello world test");
    mb.moveToStart();

    mb.deleteWordForward();
    try testing.expectEqualStrings("world test", mb.getContent());

    mb.deleteWordForward();
    try testing.expectEqualStrings("test", mb.getContent());
}

test "Minibuffer - killLine" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello world");
    mb.moveToStart();
    mb.moveRight(); // 'e'の前

    mb.killLine();
    try testing.expectEqualStrings("h", mb.getContent());
}

// ============================================================
// Display cursor tests
// ============================================================

test "Minibuffer - getDisplayCursorColumn without prompt" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("abc");
    mb.moveToStart();

    // プロンプトなし、カーソル先頭
    try testing.expectEqual(@as(usize, 0), mb.getDisplayCursorColumn());

    mb.moveRight();
    try testing.expectEqual(@as(usize, 1), mb.getDisplayCursorColumn());
}

test "Minibuffer - getDisplayCursorColumn with prompt" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    mb.setPrompt(">> "); // 3文字
    try mb.insertAtCursor("abc");
    mb.moveToStart();

    // プロンプト3文字 + カーソル先頭
    try testing.expectEqual(@as(usize, 3), mb.getDisplayCursorColumn());

    mb.moveRight();
    try testing.expectEqual(@as(usize, 4), mb.getDisplayCursorColumn());
}

test "Minibuffer - getDisplayCursorColumn with Japanese" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("日本");
    mb.moveToStart();
    mb.moveRight(); // 「本」の前

    // 「日」は幅2
    try testing.expectEqual(@as(usize, 2), mb.getDisplayCursorColumn());
}

// ============================================================
// Edge cases
// ============================================================

test "Minibuffer - empty buffer operations" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    // 空バッファでの操作はクラッシュしない
    mb.backspace();
    mb.delete();
    mb.moveLeft();
    mb.moveRight();
    mb.moveWordBackward();
    mb.moveWordForward();
    mb.deleteWordBackward();
    mb.deleteWordForward();
    mb.killLine();

    try testing.expectEqual(@as(usize, 0), mb.cursor);
    try testing.expectEqual(@as(usize, 0), mb.getContent().len);
}

test "Minibuffer - cursor bounds at end" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("test");

    // 末尾から右に移動しても動かない
    mb.moveRight();
    mb.moveRight();
    try testing.expectEqual(@as(usize, 4), mb.cursor);
}

test "Minibuffer - prompt truncation" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    // 256文字以上のプロンプトは切り捨てられる
    var long_prompt: [300]u8 = undefined;
    @memset(&long_prompt, 'x');

    mb.setPrompt(&long_prompt);
    try testing.expectEqual(@as(usize, 256), mb.getPrompt().len);
}

test "Minibuffer - word movement with multiple spaces" {
    var mb = Minibuffer.init(testing.allocator);
    defer mb.deinit();

    try mb.insertAtCursor("hello    world");
    mb.moveToStart();

    mb.moveWordForward();
    // 「world」の先頭 = "hello    "の後
    try testing.expectEqual(@as(usize, 9), mb.cursor);
}
