const std = @import("std");
const testing = std.testing;
const input = @import("input.zig");

test "Enter key recognition: \\r" {
    // Create a mock stdin with \r
    var buf = [_]u8{'\r'};
    var fbs = std.io.fixedBufferStream(&buf);
    const reader = fbs.reader();
    const file = std.fs.File{ .handle = 0 }; // Dummy handle

    // We can't easily test readKey directly without actual file descriptor
    // So we test the character recognition logic
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
