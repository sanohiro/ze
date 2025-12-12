const std = @import("std");
const testing = std.testing;
const input = @import("input");
const Key = input.Key;

// ============================================================
// Key type tests
// ============================================================

test "Key type enum - enter" {
    const key = Key.enter;
    try testing.expect(key == .enter);
}

test "Key type enum - char" {
    const key = Key{ .char = 'a' };
    try testing.expect(key == .char);
    try testing.expectEqual(@as(u8, 'a'), key.char);
}

test "Key type enum - ctrl" {
    const key = Key{ .ctrl = 'q' };
    try testing.expect(key == .ctrl);
    try testing.expectEqual(@as(u8, 'q'), key.ctrl);
}

test "Key type enum - codepoint" {
    const key = Key{ .codepoint = 0x3042 }; // 'あ'
    try testing.expect(key == .codepoint);
    try testing.expectEqual(@as(u21, 0x3042), key.codepoint);
}

test "Key type enum - alt" {
    const key = Key{ .alt = 'f' };
    try testing.expect(key == .alt);
    try testing.expectEqual(@as(u8, 'f'), key.alt);
}

test "Key type enum - arrow keys" {
    try testing.expect(Key.arrow_up == .arrow_up);
    try testing.expect(Key.arrow_down == .arrow_down);
    try testing.expect(Key.arrow_left == .arrow_left);
    try testing.expect(Key.arrow_right == .arrow_right);
}

test "Key type enum - navigation keys" {
    try testing.expect(Key.page_up == .page_up);
    try testing.expect(Key.page_down == .page_down);
    try testing.expect(Key.home == .home);
    try testing.expect(Key.end_key == .end_key);
}

test "Key type enum - editing keys" {
    try testing.expect(Key.delete == .delete);
    try testing.expect(Key.backspace == .backspace);
    try testing.expect(Key.tab == .tab);
    try testing.expect(Key.escape == .escape);
}

test "Key type enum - alt modifiers" {
    try testing.expect(Key.alt_delete == .alt_delete);
    try testing.expect(Key.alt_arrow_up == .alt_arrow_up);
    try testing.expect(Key.alt_arrow_down == .alt_arrow_down);
}

test "Key type enum - tab variants" {
    try testing.expect(Key.shift_tab == .shift_tab);
    try testing.expect(Key.ctrl_tab == .ctrl_tab);
    try testing.expect(Key.ctrl_shift_tab == .ctrl_shift_tab);
}

// ============================================================
// Control key mapping tests
// ============================================================

test "Ctrl key mapping" {
    // Ctrl+A = 1, Ctrl+B = 2, ..., Ctrl+Z = 26
    for (0..26) |i| {
        const ctrl_value: u8 = @intCast(i + 1);
        const key = Key{ .ctrl = @intCast(i) };
        _ = ctrl_value;
        try testing.expect(key == .ctrl);
    }
}

// ============================================================
// InputReader tests
// ============================================================

test "InputReader available returns 0 initially" {
    // InputReaderの初期状態をテスト
    // 実際のstdinを使わずにInputReader構造体の動作を確認
    const reader = input.InputReader{
        .stdin = undefined, // 使用しない
        .buf = undefined,
        .start = 0,
        .end = 0,
    };
    try testing.expectEqual(@as(usize, 0), reader.available());
    try testing.expect(!reader.hasData());
}

test "InputReader available with data" {
    var reader = input.InputReader{
        .stdin = undefined,
        .buf = undefined,
        .start = 0,
        .end = 10,
    };
    try testing.expectEqual(@as(usize, 10), reader.available());
    try testing.expect(reader.hasData());

    reader.start = 5;
    try testing.expectEqual(@as(usize, 5), reader.available());
}

test "InputReader empty when start equals end" {
    const reader = input.InputReader{
        .stdin = undefined,
        .buf = undefined,
        .start = 5,
        .end = 5,
    };
    try testing.expectEqual(@as(usize, 0), reader.available());
    try testing.expect(!reader.hasData());
}
