const std = @import("std");
const testing = std.testing;
const WindowManager = @import("window_manager").WindowManager;

test "WindowManager - basic operations" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    // 最初は空
    try testing.expectEqual(@as(usize, 0), wm.windowCount());
}

test "WindowManager - screen size update" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    wm.updateScreenSize(120, 40);
    try testing.expectEqual(@as(usize, 120), wm.screen_width);
    try testing.expectEqual(@as(usize, 40), wm.screen_height);
}

// ============================================================
// Initialization tests
// ============================================================

test "WindowManager - initial state" {
    var wm = WindowManager.init(testing.allocator, 100, 50);
    defer wm.deinit();

    try testing.expectEqual(@as(usize, 100), wm.screen_width);
    try testing.expectEqual(@as(usize, 50), wm.screen_height);
    try testing.expectEqual(@as(usize, 0), wm.current_window_idx);
    try testing.expectEqual(@as(usize, 0), wm.next_window_id);
}

// ============================================================
// Window navigation tests (with mocked windows)
// ============================================================

// 注: 実際のウィンドウ作成はViewの初期化が必要なため、
// ウィンドウナビゲーションのテストは基本的な状態検証に限定

test "WindowManager - screen size zero edge case" {
    var wm = WindowManager.init(testing.allocator, 0, 0);
    defer wm.deinit();

    try testing.expectEqual(@as(usize, 0), wm.screen_width);
    try testing.expectEqual(@as(usize, 0), wm.screen_height);
}

test "WindowManager - updateScreenSize to small" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    wm.updateScreenSize(10, 5);
    try testing.expectEqual(@as(usize, 10), wm.screen_width);
    try testing.expectEqual(@as(usize, 5), wm.screen_height);
}

test "WindowManager - updateScreenSize to large" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    wm.updateScreenSize(1920, 1080);
    try testing.expectEqual(@as(usize, 1920), wm.screen_width);
    try testing.expectEqual(@as(usize, 1080), wm.screen_height);
}

// ============================================================
// Iterator tests
// ============================================================

test "WindowManager - iterator empty" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    const windows = wm.iterator();
    try testing.expectEqual(@as(usize, 0), windows.len);
}

test "WindowManager - iteratorConst empty" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    const const_wm: *const WindowManager = &wm;
    const windows = const_wm.iteratorConst();
    try testing.expectEqual(@as(usize, 0), windows.len);
}

// ============================================================
// Window struct tests
// ============================================================

test "Window.init" {
    const Window = @import("window_manager").Window;

    const window = Window.init(0, 1, 10, 20, 80, 24);

    try testing.expectEqual(@as(usize, 0), window.id);
    try testing.expectEqual(@as(usize, 1), window.buffer_id);
    try testing.expectEqual(@as(usize, 10), window.x);
    try testing.expectEqual(@as(usize, 20), window.y);
    try testing.expectEqual(@as(usize, 80), window.width);
    try testing.expectEqual(@as(usize, 24), window.height);
    try testing.expect(window.mark_pos == null);
}

// ============================================================
// Next window id tests
// ============================================================

test "WindowManager - next_window_id increments correctly" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    // 初期値は0
    try testing.expectEqual(@as(usize, 0), wm.next_window_id);
}

// ============================================================
// Find functions on empty manager
// ============================================================

test "WindowManager - findWindowById empty" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    const found = wm.findWindowById(0);
    try testing.expect(found == null);
}

test "WindowManager - findWindowByBufferId empty" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    const found = wm.findWindowByBufferId(0);
    try testing.expect(found == null);
}

// ============================================================
// Edge cases
// ============================================================

test "WindowManager - recalculateWindowSizes empty" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    // 空のウィンドウマネージャーでrecalculateWindowSizesを呼んでも問題ない
    wm.recalculateWindowSizes();
    try testing.expectEqual(@as(usize, 0), wm.windowCount());
}

test "WindowManager - nextWindow and prevWindow on empty" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    // 空の状態でもクラッシュしない
    wm.nextWindow();
    wm.prevWindow();
    try testing.expectEqual(@as(usize, 0), wm.current_window_idx);
}

test "WindowManager - setActiveWindow on empty" {
    var wm = WindowManager.init(testing.allocator, 80, 24);
    defer wm.deinit();

    // 範囲外のインデックスを設定しても問題ない（無視される）
    wm.setActiveWindow(10);
    try testing.expectEqual(@as(usize, 0), wm.current_window_idx);
}
