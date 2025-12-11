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
