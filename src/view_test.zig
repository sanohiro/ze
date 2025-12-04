const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;
const View = @import("view.zig").View;

// テスト用のダミーTerminal構造体
const DummyTerminal = struct {
    width: usize = 80,
    height: usize = 24,
};

// ViewのテストヘルパーでTerminalのダミーを渡す
fn createTestView(allocator: std.mem.Allocator, content: []const u8) !struct { buffer: Buffer, view: View } {
    var buffer = Buffer.init(allocator) catch unreachable;
    errdefer buffer.deinit();

    // contentを追加
    if (content.len > 0) {
        try buffer.insertSlice(0, content);
    }

    const view = View.init(&buffer);
    return .{ .buffer = buffer, .view = view };
}

// カーソル位置の内部状態をチェック
fn checkCursorPos(view: *const View, expected_x: usize, expected_y: usize, expected_top_line: usize) !void {
    try testing.expectEqual(expected_x, view.cursor_x);
    try testing.expectEqual(expected_y, view.cursor_y);
    try testing.expectEqual(expected_top_line, view.top_line);
}

test "Cursor movement - basic ASCII" {
    const allocator = testing.allocator;
    const content = "Hello\nWorld\n";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 初期位置: (0, 0)
    try checkCursorPos(&ctx.view, 0, 0, 0);

    // 右に5回移動: "Hello" の末尾
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // もう一度右: 改行を超えて次の行の先頭
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 0, 1, 0);

    // 左に移動: 前の行の末尾に戻る
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 5, 0, 0);
}

test "Cursor movement - emoji positioning" {
    const allocator = testing.allocator;
    const content = "☹️😀👋🌍";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 初期位置
    try checkCursorPos(&ctx.view, 0, 0, 0);

    // 1つ目の絵文字 ☹️ (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 2, 0, 0);

    // 2つ目の絵文字 😀 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 4, 0, 0);

    // 3つ目の絵文字 👋 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 6, 0, 0);

    // 4つ目の絵文字 🌍 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 8, 0, 0);

    // 行末なのでこれ以上右に行けない
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 8, 0, 0);

    // 戻る: 👋の後ろ
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 6, 0, 0);

    // 戻る: 😀の後ろ
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 4, 0, 0);

    // 戻る: ☹️の後ろ
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 2, 0, 0);

    // 戻る: 行頭
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 0, 0, 0);
}

test "Cursor movement - emoji in text" {
    const allocator = testing.allocator;
    const content = "Hello ☹️ World";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 各文字を1つずつ移動して確認
    // H
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 1, 0, 0);

    // e
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 2, 0, 0);

    // l
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 3, 0, 0);

    // l
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 4, 0, 0);

    // o
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // スペース
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 6, 0, 0);

    // ☹️ を通過 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 8, 0, 0);

    // スペース
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 9, 0, 0);

    // W
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 10, 0, 0);

    // 戻る - W
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 9, 0, 0);

    // 戻る - スペース
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 8, 0, 0);

    // 戻る - ☹️
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 6, 0, 0);
}

test "Cursor movement - multiline with emoji" {
    const allocator = testing.allocator;
    const content = "Test 👋 Test\nHello\n";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 1行目の "Test " まで
    for (0..5) |_| {
        ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    }
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // 👋 を通過
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 7, 0, 0);

    // 戻る
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // 行頭に戻る
    ctx.view.moveToLineStart();
    try checkCursorPos(&ctx.view, 0, 0, 0);

    // 下に移動
    ctx.view.moveCursorDown(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 0, 1, 0);

    // 上に戻る
    ctx.view.moveCursorUp();
    try checkCursorPos(&ctx.view, 0, 0, 0);
}

test "Cursor movement - line end boundary" {
    const allocator = testing.allocator;
    const content = "Short\nVery long line here\n";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 1行目の末尾に移動
    ctx.view.moveToLineEnd();
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // 下に移動: カーソルxは5のまま（2行目も5文字目に移動）
    ctx.view.moveCursorDown(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 5, 1, 0);

    // 行頭
    ctx.view.moveToLineStart();
    try checkCursorPos(&ctx.view, 0, 1, 0);

    // 行末
    ctx.view.moveToLineEnd();
    try checkCursorPos(&ctx.view, 19, 1, 0);

    // 上に移動: 1行目は5文字しかないので5に調整される
    ctx.view.moveCursorUp();
    try checkCursorPos(&ctx.view, 5, 0, 0);
}

test "Cursor movement - beginning of line with left arrow" {
    const allocator = testing.allocator;
    const content = "Line 1\nLine 2\nLine 3\n";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    // 2行目に移動
    var dummy_term = DummyTerminal{};
    ctx.view.moveCursorDown(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 0, 1, 0);

    // 行頭で左矢印: 前の行の末尾に移動
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 6, 0, 0);

    // もう一度行頭に行ってから左
    ctx.view.moveToLineStart();
    try checkCursorPos(&ctx.view, 0, 0, 0);

    // これ以上上がない場合は動かない
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 0, 0, 0);
}

test "Cursor movement - Japanese with emoji" {
    const allocator = testing.allocator;
    const content = "🇯🇵日本\n";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 🇯🇵 (Regional Indicator pair, width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 2, 0, 0);

    // 日 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 4, 0, 0);

    // 本 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 6, 0, 0);

    // 戻る
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 4, 0, 0);

    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 2, 0, 0);

    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 0, 0, 0);
}

test "Buffer position calculation" {
    const allocator = testing.allocator;
    const content = "Hello\nWorld\n";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 行頭
    try testing.expectEqual(@as(usize, 0), ctx.view.getCursorBufferPos());

    // 右に3文字
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 3), ctx.view.getCursorBufferPos());

    // 2行目の先頭 (改行の後なので6)
    ctx.view.moveToLineStart();
    ctx.view.moveCursorDown(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 6), ctx.view.getCursorBufferPos());
}

test "emoji_test.txt - Emoji with text line" {
    const allocator = testing.allocator;
    const content = "Emoji with text:\nHello ☹️ World";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 2行目に移動
    ctx.view.moveCursorDown(@ptrCast(&dummy_term));

    // Helloを1文字ずつ
    for (0..5) |i| {
        ctx.view.moveCursorRight(@ptrCast(&dummy_term));
        try checkCursorPos(&ctx.view, i + 1, 1, 0);
    }

    // スペース
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 6, 1, 0);

    // ☹️ (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 8, 1, 0);

    // スペース
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 9, 1, 0);

    // Worldを1文字ずつ
    for (0..5) |i| {
        ctx.view.moveCursorRight(@ptrCast(&dummy_term));
        try checkCursorPos(&ctx.view, 10 + i, 1, 0);
    }
}

test "emoji_test.txt - Test 👋 Test line" {
    const allocator = testing.allocator;
    const content = "Test 👋 Test";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // Test を1文字ずつ
    for (0..4) |i| {
        ctx.view.moveCursorRight(@ptrCast(&dummy_term));
        try checkCursorPos(&ctx.view, i + 1, 0, 0);
    }

    // スペース
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // 👋 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 7, 0, 0);

    // スペース
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 8, 0, 0);

    // Test を1文字ずつ
    for (0..4) |i| {
        ctx.view.moveCursorRight(@ptrCast(&dummy_term));
        try checkCursorPos(&ctx.view, 9 + i, 0, 0);
    }
}

test "emoji_test.txt - Multiple emojis line" {
    const allocator = testing.allocator;
    const content = "Multiple emojis:\n☹️😀👋🌍";
    var ctx = try createTestView(allocator, content);
    defer ctx.buffer.deinit();

    var dummy_term = DummyTerminal{};

    // 2行目に移動
    ctx.view.moveCursorDown(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 0, 1, 0);

    // ☹️ (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 2, 1, 0);

    // 😀 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 4, 1, 0);

    // 👋 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 6, 1, 0);

    // 🌍 (width 2)
    ctx.view.moveCursorRight(@ptrCast(&dummy_term));
    try checkCursorPos(&ctx.view, 8, 1, 0);

    // 戻る - 🌍
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 6, 1, 0);

    // 戻る - 👋
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 4, 1, 0);

    // 戻る - 😀
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 2, 1, 0);

    // 戻る - ☹️
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 0, 1, 0);
}
