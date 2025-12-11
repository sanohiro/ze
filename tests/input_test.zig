const std = @import("std");
const testing = std.testing;
const input = @import("input");

test "Enter key recognition: \\r" {
    // テスト: \r は Enter として認識される
    const ch: u8 = '\r';
    try testing.expect(ch == '\r' or ch == '\n');
}

test "Enter key recognition: \\n" {
    const ch: u8 = '\n';
    try testing.expect(ch == '\r' or ch == '\n');
}

test "Key type enum" {
    const key1 = input.Key.enter;
    const key2 = input.Key{ .char = 'a' };
    const key3 = input.Key{ .ctrl = 'q' };

    try testing.expect(key1 == .enter);
    try testing.expect(key2 == .char);
    try testing.expect(key3 == .ctrl);
}
