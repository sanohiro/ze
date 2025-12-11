const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer.zig").Buffer;
const View = @import("view.zig").View;

/// テストコンテキスト構造体
/// 重要: ViewはBufferへのポインタを保持するため、
/// この構造体内でポインタの整合性を保つ必要がある
const TestContext = struct {
    allocator: std.mem.Allocator,
    buffer: Buffer,
    view: View,

    pub fn deinit(self: *TestContext) void {
        self.view.deinit(self.allocator);
        self.buffer.deinit();
    }
};

// ViewのテストヘルパーでTerminalのダミーを渡す
// 注意: 戻り値をローカル変数に格納した後、view.bufferポインタを更新する必要がある
fn createTestView(allocator: std.mem.Allocator, content: []const u8) !TestContext {
    var buffer = try Buffer.init(allocator);
    errdefer buffer.deinit();

    // contentを追加
    if (content.len > 0) {
        try buffer.insertSlice(0, content);
    }

    // 仮のポインタでViewを初期化（後で修正）
    var view = try View.init(allocator, &buffer);
    errdefer view.deinit(allocator);

    // 戻り値の構造体を作成
    // 注意: この時点ではview.bufferは無効なポインタを指している
    // 呼び出し側でfixBufferPointerを呼ぶ必要がある
    return TestContext{ .allocator = allocator, .buffer = buffer, .view = view };
}

/// テストコンテキストのbufferポインタを修正する
/// createTestViewの直後に呼び出す必要がある
fn fixBufferPointer(ctx: *TestContext) void {
    ctx.view.buffer = &ctx.buffer;
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
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 初期位置: (0, 0)
    try checkCursorPos(&ctx.view, 0, 0, 0);

    // 右に5回移動: "Hello" の末尾
    ctx.view.moveCursorRight();
    ctx.view.moveCursorRight();
    ctx.view.moveCursorRight();
    ctx.view.moveCursorRight();
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // もう一度右: 改行を超えて次の行の先頭
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 0, 1, 0);

    // 左に移動: 前の行の末尾に戻る
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 5, 0, 0);
}

test "Cursor movement - emoji positioning" {
    const allocator = testing.allocator;
    const content = "☹️😀👋🌍";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 初期位置
    try checkCursorPos(&ctx.view, 0, 0, 0);

    // 1つ目の絵文字 ☹️ (width 2)
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 2, 0, 0);

    // 2つ目の絵文字 😀 (width 2)
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 4, 0, 0);

    // 3つ目の絵文字 👋 (width 2)
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 6, 0, 0);

    // 4つ目の絵文字 🌍 (width 2)
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 8, 0, 0);

    // 行末なのでこれ以上右に行けない
    ctx.view.moveCursorRight();
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
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 各文字を1つずつ移動して確認
    // H
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 1, 0, 0);

    // e
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 2, 0, 0);

    // l
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 3, 0, 0);

    // l
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 4, 0, 0);

    // o
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // スペース
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 6, 0, 0);

    // ☹️ を通過 (width 2)
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 8, 0, 0);

    // スペース
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 9, 0, 0);

    // W
    ctx.view.moveCursorRight();
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
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 1行目の "Test " まで
    for (0..5) |_| {
        ctx.view.moveCursorRight();
    }
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // 👋 を通過
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 7, 0, 0);

    // 戻る
    ctx.view.moveCursorLeft();
    try checkCursorPos(&ctx.view, 5, 0, 0);

    // 行頭に戻る
    ctx.view.moveToLineStart();
    try checkCursorPos(&ctx.view, 0, 0, 0);

    // 下に移動
    ctx.view.moveCursorDown();
    try checkCursorPos(&ctx.view, 0, 1, 0);

    // 上に戻る
    ctx.view.moveCursorUp();
    try checkCursorPos(&ctx.view, 0, 0, 0);
}

test "Cursor movement - Japanese characters" {
    const allocator = testing.allocator;
    const content = "日本語テスト";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 初期位置
    try checkCursorPos(&ctx.view, 0, 0, 0);

    // 各全角文字は幅2
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 2, 0, 0);

    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 4, 0, 0);

    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 6, 0, 0);
}
