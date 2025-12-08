const std = @import("std");
const testing = std.testing;
const buffer_mod = @import("buffer.zig");
const Buffer = buffer_mod.Buffer;
const PieceIterator = buffer_mod.PieceIterator;
const View = @import("view.zig").View;
const unicode = @import("unicode.zig");

// 包括的なUnicodeテスト

test "Unicode: ASCII characters" {
    const allocator = testing.allocator;
    const tests = [_]struct { char: []const u8, width: usize }{
        .{ .char = "A", .width = 1 },
        .{ .char = "a", .width = 1 },
        .{ .char = "0", .width = 1 },
        .{ .char = " ", .width = 1 },
        .{ .char = "!", .width = 1 },
        .{ .char = "\n", .width = 0 }, // Control char
        .{ .char = "\t", .width = 0 }, // Control char
    };

    for (tests) |t| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, t.char);

        var iter = PieceIterator.init(&buffer);
        const cluster = try iter.nextGraphemeCluster();
        try testing.expect(cluster != null);
        try testing.expectEqual(t.width, cluster.?.width);
    }
}

test "Unicode: Basic emoji (single codepoint)" {
    const allocator = testing.allocator;
    const emojis = [_][]const u8{
        "😀", "😃", "😄", "😁", "😆",
        "🌍", "🌎", "🌏",
        "🔥", "💧", "⚡",
    };

    for (emojis) |emoji| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, emoji);

        var iter = PieceIterator.init(&buffer);
        const cluster = try iter.nextGraphemeCluster();
        try testing.expect(cluster != null);
        try testing.expectEqual(@as(usize, 2), cluster.?.width);
    }
}

test "Unicode: Emoji with variation selectors" {
    const allocator = testing.allocator;
    const tests = [_]struct { emoji: []const u8, expected_clusters: usize }{
        .{ .emoji = "☹️", .expected_clusters = 1 }, // ☹ + FE0F
        .{ .emoji = "☺️", .expected_clusters = 1 }, // ☺ + FE0F
        .{ .emoji = "✨", .expected_clusters = 1 }, // ✨ (may have FE0F)
        .{ .emoji = "⭐", .expected_clusters = 1 }, // ⭐ (may have FE0F)
    };

    for (tests) |t| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, t.emoji);

        var iter = PieceIterator.init(&buffer);
        var count: usize = 0;
        while (try iter.nextGraphemeCluster()) |cluster| {
            count += 1;
            try testing.expectEqual(@as(usize, 2), cluster.width);
        }
        try testing.expectEqual(t.expected_clusters, count);
    }
}

test "Unicode: Emoji with ZWJ sequences" {
    const allocator = testing.allocator;
    const sequences = [_][]const u8{
        "👨‍👩‍👧‍👦", // Family
        "👨‍💻", // Man technologist
        "👩‍🔬", // Woman scientist
    };

    for (sequences) |seq| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, seq);

        var iter = PieceIterator.init(&buffer);
        const cluster = try iter.nextGraphemeCluster();
        try testing.expect(cluster != null);
        // ZWJ sequences should be treated as one grapheme cluster
        try testing.expectEqual(@as(usize, 2), cluster.?.width);

        // Should not have more clusters
        const next = try iter.nextGraphemeCluster();
        try testing.expect(next == null);
    }
}

test "Unicode: Emoji with skin tone modifiers" {
    const allocator = testing.allocator;
    const emojis = [_][]const u8{
        "👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿",
    };

    for (emojis) |emoji| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, emoji);

        var iter = PieceIterator.init(&buffer);
        const cluster = try iter.nextGraphemeCluster();
        try testing.expect(cluster != null);
        try testing.expectEqual(@as(usize, 2), cluster.?.width);

        // Should be one cluster
        const next = try iter.nextGraphemeCluster();
        try testing.expect(next == null);
    }
}

test "Unicode: Regional Indicator pairs (flags)" {
    const allocator = testing.allocator;
    const flags = [_][]const u8{
        "🇯🇵", // Japan
        "🇺🇸", // USA
        "🇬🇧", // UK
        "🇫🇷", // France
    };

    for (flags) |flag| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, flag);

        var iter = PieceIterator.init(&buffer);
        const cluster = try iter.nextGraphemeCluster();
        try testing.expect(cluster != null);
        try testing.expectEqual(@as(usize, 2), cluster.?.width);

        // Should be one cluster
        const next = try iter.nextGraphemeCluster();
        try testing.expect(next == null);
    }
}

test "Unicode: CJK characters (width 2)" {
    const allocator = testing.allocator;
    const chars = [_][]const u8{
        "你", "好", "世", "界", // Chinese
        "こ", "ん", "に", "ち", "は", // Hiragana
        "日", "本", "語", // Kanji
        "안", "녕", // Korean
    };

    for (chars) |char| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, char);

        var iter = PieceIterator.init(&buffer);
        const cluster = try iter.nextGraphemeCluster();
        try testing.expect(cluster != null);
        try testing.expectEqual(@as(usize, 2), cluster.?.width);
    }
}

test "Unicode: Combining marks" {
    const allocator = testing.allocator;
    const tests = [_][]const u8{
        "é", // e + combining acute
        "ñ", // n + combining tilde
        "ã", // a + combining tilde
    };

    for (tests) |text| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, text);

        var iter = PieceIterator.init(&buffer);
        const cluster = try iter.nextGraphemeCluster();
        try testing.expect(cluster != null);
        // Base character should determine width
        try testing.expectEqual(@as(usize, 1), cluster.?.width);
    }
}

test "Unicode: Fullwidth forms" {
    const allocator = testing.allocator;
    const chars = [_][]const u8{
        "Ｈ", "ｅ", "ｌ", "ｌ", "ｏ",
    };

    for (chars) |char| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        try buffer.insertSlice(0, char);

        var iter = PieceIterator.init(&buffer);
        const cluster = try iter.nextGraphemeCluster();
        try testing.expect(cluster != null);
        try testing.expectEqual(@as(usize, 2), cluster.?.width);
    }
}

test "Cursor movement: Complex emoji sequences" {
    const allocator = testing.allocator;

    const DummyTerminal = struct {
        width: usize = 80,
        height: usize = 24,
    };

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 👨‍👩‍👧‍👦 (family, ZWJ sequence)
    const family = "👨‍👩‍👧‍👦";
    try buffer.insertSlice(0, family);

    var view = try View.init(allocator, &buffer);
    var dummy_term = DummyTerminal{};

    // Should move over entire family as one unit
    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 2), view.cursor_x);

    // Should not move further (at end)
    const pos_before = view.cursor_x;
    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(pos_before, view.cursor_x);
}

test "Cursor movement: Multiple flags in sequence" {
    const allocator = testing.allocator;

    const DummyTerminal = struct {
        width: usize = 80,
        height: usize = 24,
    };

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const flags = "🇯🇵🇺🇸🇬🇧";
    try buffer.insertSlice(0, flags);

    var view = try View.init(allocator, &buffer);
    var dummy_term = DummyTerminal{};

    // Move through each flag
    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 2), view.cursor_x); // 🇯🇵

    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 4), view.cursor_x); // 🇺🇸

    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 6), view.cursor_x); // 🇬🇧

    // Move back
    view.moveCursorLeft();
    try testing.expectEqual(@as(usize, 4), view.cursor_x);

    view.moveCursorLeft();
    try testing.expectEqual(@as(usize, 2), view.cursor_x);

    view.moveCursorLeft();
    try testing.expectEqual(@as(usize, 0), view.cursor_x);
}

test "Cursor movement: Mixed ASCII, CJK, and emoji" {
    const allocator = testing.allocator;

    const DummyTerminal = struct {
        width: usize = 80,
        height: usize = 24,
    };

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const mixed = "Hi日本🌍";
    try buffer.insertSlice(0, mixed);

    var view = try View.init(allocator, &buffer);
    var dummy_term = DummyTerminal{};

    // H (width 1)
    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 1), view.cursor_x);

    // i (width 1)
    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 2), view.cursor_x);

    // 日 (width 2)
    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 4), view.cursor_x);

    // 本 (width 2)
    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 6), view.cursor_x);

    // 🌍 (width 2)
    view.moveCursorRight(@ptrCast(&dummy_term));
    try testing.expectEqual(@as(usize, 8), view.cursor_x);
}

test "Grapheme break algorithm: All break rules" {
    // GB3: CR × LF
    var initial_state = unicode.State{};
    try testing.expect(!unicode.graphemeBreak('\r', '\n', &initial_state));

    // GB4: (Control | CR | LF) ÷
    var state = unicode.State{};
    try testing.expect(unicode.graphemeBreak('\r', 'a', &state));
    try testing.expect(unicode.graphemeBreak('\n', 'a', &state));

    // GB5: ÷ (Control | CR | LF)
    state = unicode.State{};
    try testing.expect(unicode.graphemeBreak('a', '\r', &state));
    try testing.expect(unicode.graphemeBreak('a', '\n', &state));

    // GB9: × (Extend | ZWJ)
    state = unicode.State{};
    try testing.expect(!unicode.graphemeBreak('e', 0x0301, &state)); // e + combining acute
    try testing.expect(!unicode.graphemeBreak('👨', 0x200D, &state)); // emoji + ZWJ
}

test "Display width calculation" {
    // ASCII
    try testing.expectEqual(@as(usize, 1), unicode.displayWidth('A'));
    try testing.expectEqual(@as(usize, 1), unicode.displayWidth('a'));
    try testing.expectEqual(@as(usize, 1), unicode.displayWidth(' '));

    // Control characters
    try testing.expectEqual(@as(usize, 0), unicode.displayWidth('\n'));
    try testing.expectEqual(@as(usize, 0), unicode.displayWidth('\r'));
    try testing.expectEqual(@as(usize, 0), unicode.displayWidth('\t'));

    // Zero-width
    try testing.expectEqual(@as(usize, 0), unicode.displayWidth(0x200D)); // ZWJ
    try testing.expectEqual(@as(usize, 0), unicode.displayWidth(0xFE0F)); // Variation Selector
    try testing.expectEqual(@as(usize, 0), unicode.displayWidth(0x0301)); // Combining acute

    // Emoji (width 2)
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth(0x1F600)); // 😀
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth(0x1F44B)); // 👋
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth(0x1F30D)); // 🌍

    // CJK (width 2)
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth('日'));
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth('本'));
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth('你'));
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth('好'));

    // Fullwidth (width 2)
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth('Ａ'));
    try testing.expectEqual(@as(usize, 2), unicode.displayWidth('Ｈ'));
}

test "Line counting with various line endings" {
    const allocator = testing.allocator;

    const tests = [_]struct { content: []const u8, expected_lines: usize }{
        .{ .content = "Line1\n", .expected_lines = 2 },
        .{ .content = "Line1\nLine2\n", .expected_lines = 3 },
        .{ .content = "Line1\nLine2\nLine3\n", .expected_lines = 4 },
        .{ .content = "No newline", .expected_lines = 1 },
        .{ .content = "", .expected_lines = 1 },
    };

    for (tests) |t| {
        var buffer = try Buffer.init(allocator);
        defer buffer.deinit();
        if (t.content.len > 0) {
            try buffer.insertSlice(0, t.content);
        }
        try testing.expectEqual(t.expected_lines, buffer.lineCount());
    }
}

test "Buffer operations with emoji" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // Insert emoji
    const emoji = "😀";
    try buffer.insertSlice(0, emoji);
    try testing.expectEqual(@as(usize, 4), buffer.len()); // 😀 is 4 bytes

    // Insert more emoji
    try buffer.insertSlice(4, "🌍");
    try testing.expectEqual(@as(usize, 8), buffer.len());

    // Delete emoji
    try buffer.delete(0, 4);
    try testing.expectEqual(@as(usize, 4), buffer.len());
}

test "Stress test: Long line with mixed content" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // Create a long line with various Unicode characters
    const line = "Hello世界😀Test日本語🌍ASCII文字🇯🇵Flag";
    try buffer.insertSlice(0, line);

    var view = try View.init(allocator, &buffer);
    const DummyTerminal = struct {
        width: usize = 80,
        height: usize = 24,
    };
    var dummy_term = DummyTerminal{};

    // Move to end
    var moves: usize = 0;
    const max_moves: usize = 100; // Safety limit
    while (moves < max_moves) : (moves += 1) {
        const old_x = view.cursor_x;
        view.moveCursorRight(@ptrCast(&dummy_term));
        if (view.cursor_x == old_x) break; // Reached end
    }

    // Move back to start
    var back_moves: usize = 0;
    while (back_moves < max_moves) : (back_moves += 1) {
        const old_x = view.cursor_x;
        view.moveCursorLeft();
        if (view.cursor_x == old_x) break; // Reached start
    }

    try testing.expectEqual(@as(usize, 0), view.cursor_x);
}
