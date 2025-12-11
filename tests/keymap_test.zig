const std = @import("std");
const testing = std.testing;
const Keymap = @import("keymap").Keymap;

test "Keymap - ctrl lookup" {
    var keymap = try Keymap.init(testing.allocator);
    defer keymap.deinit();

    try keymap.loadDefaults();

    // C-f はcursorRight
    const handler = keymap.findCtrl('f');
    try testing.expect(handler != null);

    // 未登録キーはnull
    try testing.expect(keymap.findCtrl('z') == null);
}

test "Keymap - alt lookup" {
    var keymap = try Keymap.init(testing.allocator);
    defer keymap.deinit();

    try keymap.loadDefaults();

    // M-f はforwardWord
    const handler = keymap.findAlt('f');
    try testing.expect(handler != null);
}

test "Keymap - special lookup" {
    var keymap = try Keymap.init(testing.allocator);
    defer keymap.deinit();

    try keymap.loadDefaults();

    // 矢印キー
    const handler = keymap.findSpecial(.arrow_up);
    try testing.expect(handler != null);
}
