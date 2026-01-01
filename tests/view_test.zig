const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer").Buffer;
const View = @import("view").View;

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

// ============================================================
// Buffer navigation tests
// ============================================================

test "moveToBufferStart and moveToBufferEnd" {
    const allocator = testing.allocator;
    const content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 最初に末尾へ移動
    ctx.view.moveToBufferEnd();
    try testing.expectEqual(@as(usize, 4), ctx.view.cursor_y);

    // 先頭へ移動
    ctx.view.moveToBufferStart();
    try checkCursorPos(&ctx.view, 0, 0, 0);
}

test "moveToLineStart and moveToLineEnd" {
    const allocator = testing.allocator;
    const content = "Hello World";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 途中に移動
    ctx.view.moveCursorRight();
    ctx.view.moveCursorRight();
    ctx.view.moveCursorRight();
    try checkCursorPos(&ctx.view, 3, 0, 0);

    // 行末へ
    ctx.view.moveToLineEnd();
    try checkCursorPos(&ctx.view, 11, 0, 0);

    // 行頭へ
    ctx.view.moveToLineStart();
    try checkCursorPos(&ctx.view, 0, 0, 0);
}

// ============================================================
// Viewport tests
// ============================================================

test "setViewport" {
    const allocator = testing.allocator;
    const content = "Test";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    ctx.view.setViewport(120, 40);
    try testing.expectEqual(@as(usize, 120), ctx.view.viewport_width);
    try testing.expectEqual(@as(usize, 40), ctx.view.viewport_height);
}

test "constrainCursor clamps cursor to viewport bounds" {
    const allocator = testing.allocator;
    const content = "Short";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // ビューポートを設定（40行）
    ctx.view.setViewport(80, 40);

    // カーソルをビューポート外に設定
    ctx.view.cursor_x = 100;
    ctx.view.cursor_y = 100;

    ctx.view.constrainCursor();

    // ビューポート内に制限される（40行 - 2 = 38が最大）
    // cursor_y = 100は38に制限され、残りはtop_lineに移動
    try testing.expectEqual(@as(usize, 38), ctx.view.cursor_y);
    try testing.expectEqual(@as(usize, 62), ctx.view.top_line); // 100 - 38 = 62
}

// ============================================================
// Tab width tests
// ============================================================

test "tab width get and set" {
    const allocator = testing.allocator;
    const content = "";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // デフォルト値を確認
    const default_width = ctx.view.getTabWidth();
    try testing.expect(default_width > 0);

    // 変更
    ctx.view.setTabWidth(8);
    try testing.expectEqual(@as(u8, 8), ctx.view.getTabWidth());

    ctx.view.setTabWidth(2);
    try testing.expectEqual(@as(u8, 2), ctx.view.getTabWidth());
}

// ============================================================
// Error message tests
// ============================================================

test "error message set and clear" {
    const allocator = testing.allocator;
    const content = "";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 初期状態はエラーなし
    try testing.expect(ctx.view.getError() == null);

    // エラーを設定
    ctx.view.setError("Test error message");
    const err = ctx.view.getError();
    try testing.expect(err != null);
    try testing.expectEqualStrings("Test error message", err.?);

    // エラーをクリア
    ctx.view.clearError();
    try testing.expect(ctx.view.getError() == null);
}

// ============================================================
// Search highlight tests
// ============================================================

test "search highlight set and get" {
    const allocator = testing.allocator;
    const content = "";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 初期状態はハイライトなし
    try testing.expect(ctx.view.getSearchHighlight() == null);

    // ハイライトを設定
    ctx.view.setSearchHighlight("search term");
    const highlight = ctx.view.getSearchHighlight();
    try testing.expect(highlight != null);
    try testing.expectEqualStrings("search term", highlight.?);

    // ハイライトをクリア
    ctx.view.setSearchHighlight(null);
    try testing.expect(ctx.view.getSearchHighlight() == null);
}

// ============================================================
// Dirty flag tests
// ============================================================

test "dirty flag management" {
    const allocator = testing.allocator;
    const content = "Test content";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 全体を再描画としてマーク
    ctx.view.markFullRedraw();
    try testing.expect(ctx.view.needsRedraw());

    // クリア（コンテンツ用）
    ctx.view.clearDirty();
    // status_bar_dirtyも個別にクリア（描画後に自動クリアされる想定）
    ctx.view.status_bar_dirty = false;
    try testing.expect(!ctx.view.needsRedraw());

    // 特定の行をダーティにマーク
    ctx.view.markDirty(0, 1);
    try testing.expect(ctx.view.needsRedraw());
}

// ============================================================
// Line number width tests
// ============================================================

test "line number width calculation" {
    const allocator = testing.allocator;
    // 100行以上のコンテンツを作成
    var content_buf: [1000]u8 = undefined;
    var pos: usize = 0;
    for (0..100) |i| {
        const written = std.fmt.bufPrint(content_buf[pos..], "Line {d}\n", .{i + 1}) catch break;
        pos += written.len;
    }
    const content = content_buf[0..pos];

    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 100行あるので、行番号幅は3桁以上
    const width = ctx.view.getLineNumberWidth();
    try testing.expect(width >= 3);
}

// ============================================================
// Cursor position tests
// ============================================================

test "getCursorBufferPos" {
    const allocator = testing.allocator;
    const content = "Hello\nWorld";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 初期位置（先頭）
    try testing.expectEqual(@as(usize, 0), ctx.view.getCursorBufferPos());

    // 右に3つ移動
    ctx.view.moveCursorRight();
    ctx.view.moveCursorRight();
    ctx.view.moveCursorRight();
    try testing.expectEqual(@as(usize, 3), ctx.view.getCursorBufferPos());

    // 次の行へ
    ctx.view.moveCursorDown();
    // 2行目の先頭 = "Hello\n" の後 = 6
    const pos = ctx.view.getCursorBufferPos();
    try testing.expect(pos >= 6);
}

// ============================================================
// Empty buffer tests
// ============================================================

test "empty buffer operations" {
    const allocator = testing.allocator;
    const content = "";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 空バッファでの移動はクラッシュしない
    ctx.view.moveCursorLeft();
    ctx.view.moveCursorRight();
    ctx.view.moveCursorUp();
    ctx.view.moveCursorDown();
    ctx.view.moveToLineStart();
    ctx.view.moveToLineEnd();
    ctx.view.moveToBufferStart();
    ctx.view.moveToBufferEnd();

    try checkCursorPos(&ctx.view, 0, 0, 0);
}

// ============================================================
// Empty line tests (lines containing only '\n')
// ============================================================

test "getCursorBufferPos on empty line" {
    const allocator = testing.allocator;
    // "line1\n" + "\n" (空行) + "line3\n"
    // 位置: 0-5="line1", 5='\n', 6='\n'(空行), 7-11="line3", 12='\n'
    const content = "line1\n\nline3\n";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 空行（2行目、インデックス1）に移動
    ctx.view.moveCursorDown();
    try checkCursorPos(&ctx.view, 0, 1, 0);

    // 空行のカーソル位置は6（空行の'\n'の位置）であるべき
    // 7（次の行の開始位置）ではない
    const pos = ctx.view.getCursorBufferPos();
    try testing.expectEqual(@as(usize, 6), pos);
}

test "getLineWidthWithBytePos on empty line" {
    const allocator = testing.allocator;
    const content = "line1\n\nline3\n";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 空行（インデックス1）の情報を取得
    const info = ctx.view.getLineWidthWithBytePos(1, 0);

    // 空行の幅は0
    try testing.expectEqual(@as(usize, 0), info.width);
    // バイト位置は6（'\n'の位置）
    try testing.expectEqual(@as(usize, 6), info.byte_pos);
    // clamped_xは0
    try testing.expectEqual(@as(usize, 0), info.clamped_x);
}

test "cursor movement across empty line" {
    const allocator = testing.allocator;
    const content = "line1\n\nline3\n";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 1行目から空行を経由して3行目へ移動
    ctx.view.moveCursorDown(); // 空行へ
    try testing.expectEqual(@as(usize, 6), ctx.view.getCursorBufferPos());

    ctx.view.moveCursorDown(); // 3行目へ
    try testing.expectEqual(@as(usize, 7), ctx.view.getCursorBufferPos());

    // 戻る
    ctx.view.moveCursorUp(); // 空行へ
    try testing.expectEqual(@as(usize, 6), ctx.view.getCursorBufferPos());
}

test "cursor right on empty line moves to next line" {
    const allocator = testing.allocator;
    const content = "line1\n\nline3\n";
    var ctx = try createTestView(allocator, content);
    fixBufferPointer(&ctx);
    defer ctx.deinit();

    // 空行に移動
    ctx.view.moveCursorDown();
    try testing.expectEqual(@as(usize, 6), ctx.view.getCursorBufferPos());

    // 空行で右に移動すると次の行に移動
    ctx.view.moveCursorRight();
    // cursor_yが2になる（3行目）
    try testing.expectEqual(@as(usize, 2), ctx.view.cursor_y);
}
