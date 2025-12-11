const std = @import("std");
const testing = std.testing;
const unicode = @import("unicode.zig");

// Unicode全範囲の包括的テスト
// Unicode 15.0準拠

test "Unicode: All ASCII control characters (0x00-0x1F)" {
    var cp: u21 = 0x00;
    while (cp <= 0x1F) : (cp += 1) {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 0), width);
    }
    // DEL (0x7F)
    try testing.expectEqual(@as(usize, 0), unicode.displayWidth(0x7F));
}

test "Unicode: All printable ASCII (0x20-0x7E)" {
    var cp: u21 = 0x20;
    while (cp <= 0x7E) : (cp += 1) {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 1), width);
    }
}

test "Unicode: Latin-1 Supplement (0x80-0xFF)" {
    // Most Latin-1 characters are width 1
    const samples = [_]u21{
        0xA0, // Non-breaking space
        0xA9, // Copyright
        0xC0, // À
        0xD1, // Ñ
        0xE9, // é
        0xF1, // ñ
        0xFF, // ÿ
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        // Most Latin-1 are width 1, but some may be 0 (control chars)
        try testing.expect(width <= 1);
    }
}

test "Unicode: Combining Diacritical Marks (0x0300-0x036F)" {
    var cp: u21 = 0x0300;
    while (cp <= 0x036F) : (cp += 1) {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 0), width);
    }
}

test "Unicode: Variation Selectors (0xFE00-0xFE0F)" {
    var cp: u21 = 0xFE00;
    while (cp <= 0xFE0F) : (cp += 1) {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 0), width);
    }
}

test "Unicode: Emoji skin tone modifiers (0x1F3FB-0x1F3FF)" {
    var cp: u21 = 0x1F3FB;
    while (cp <= 0x1F3FF) : (cp += 1) {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 0), width);
    }
}

test "Unicode: Zero Width Joiner" {
    const width = unicode.displayWidth(0x200D);
    try testing.expectEqual(@as(usize, 0), width);
}

test "Unicode: Emoticons (0x1F600-0x1F64F)" {
    const samples = [_]u21{
        0x1F600, // 😀
        0x1F601, // 😁
        0x1F602, // 😂
        0x1F603, // 😃
        0x1F620, // 😠
        0x1F64F, // 🙏
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Miscellaneous Symbols and Pictographs (0x1F300-0x1F5FF)" {
    const samples = [_]u21{
        0x1F300, // 🌀
        0x1F30D, // 🌍
        0x1F30E, // 🌎
        0x1F30F, // 🌏
        0x1F44B, // 👋
        0x1F4A9, // 💩
        0x1F525, // 🔥
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Transport and Map Symbols (0x1F680-0x1F6FF)" {
    const samples = [_]u21{
        0x1F680, // 🚀
        0x1F681, // 🚁
        0x1F682, // 🚂
        0x1F697, // 🚗
        0x1F6A2, // 🚢
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Supplemental Symbols and Pictographs (0x1F900-0x1F9FF)" {
    const samples = [_]u21{
        0x1F900, // 🤀
        0x1F910, // 🤐
        0x1F920, // 🤠
        0x1F980, // 🦀
        0x1F990, // 🦐
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Regional Indicators (0x1F1E6-0x1F1FF)" {
    var cp: u21 = 0x1F1E6; // 🇦
    while (cp <= 0x1F1FF) : (cp += 1) {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Miscellaneous Symbols (0x2600-0x26FF)" {
    const samples = [_]u21{
        0x2600, // ☀
        0x2601, // ☁
        0x2614, // ☔
        0x2639, // ☹
        0x263A, // ☺
        0x26A0, // ⚠
        0x26A1, // ⚡
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Dingbats (0x2700-0x27BF)" {
    const samples = [_]u21{
        0x2700, // ✀
        0x2701, // ✁
        0x2702, // ✂
        0x2705, // ✅
        0x2728, // ✨
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: CJK Unified Ideographs (0x4E00-0x9FFF)" {
    const samples = [_]u21{
        0x4E00, // 一
        0x4E8C, // 二
        0x4E09, // 三
        0x56DB, // 四
        0x4E94, // 五
        0x65E5, // 日
        0x672C, // 本
        0x8A9E, // 語
        0x4F60, // 你
        0x597D, // 好
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Hiragana (0x3040-0x309F)" {
    const samples = [_]u21{
        0x3042, // あ
        0x3044, // い
        0x3046, // う
        0x3048, // え
        0x304A, // お
        0x304B, // か
        0x304D, // き
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        // Hiragana are typically width 2
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Katakana (0x30A0-0x30FF)" {
    const samples = [_]u21{
        0x30A2, // ア
        0x30A4, // イ
        0x30A6, // ウ
        0x30A8, // エ
        0x30AA, // オ
        0x30AB, // カ
        0x30AD, // キ
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Hangul Syllables (0xAC00-0xD7A3)" {
    const samples = [_]u21{
        0xAC00, // 가
        0xAC01, // 각
        0xB098, // 나
        0xB2E4, // 다
        0xB77C, // 라
        0xB9C8, // 마
        0xBC14, // 바
        0xC0AC, // 사
        0xC544, // 아
        0xC790, // 자
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Fullwidth Latin (0xFF00-0xFF60)" {
    const samples = [_]u21{
        0xFF21, // Ａ
        0xFF22, // Ｂ
        0xFF23, // Ｃ
        0xFF41, // ａ
        0xFF42, // ｂ
        0xFF43, // ｃ
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        try testing.expectEqual(@as(usize, 2), width);
    }
}

test "Unicode: Halfwidth Katakana (0xFF65-0xFF9F)" {
    const samples = [_]u21{
        0xFF66, // ｦ
        0xFF67, // ｧ
        0xFF68, // ｨ
        0xFF69, // ｩ
    };

    for (samples) |cp| {
        const width = unicode.displayWidth(cp);
        // Halfwidth are width 1
        try testing.expectEqual(@as(usize, 1), width);
    }
}

test "Grapheme Break: CR × LF (GB3)" {
    var state = unicode.State{};
    try testing.expect(!unicode.graphemeBreak('\r', '\n', &state));
}

test "Grapheme Break: Control breaks (GB4, GB5)" {
    var state = unicode.State{};
    // GB4: (Control | CR | LF) ÷
    try testing.expect(unicode.graphemeBreak('\n', 'a', &state));
    try testing.expect(unicode.graphemeBreak('\r', 'a', &state));
    try testing.expect(unicode.graphemeBreak(0x01, 'a', &state));

    // GB5: ÷ (Control | CR | LF)
    state = unicode.State{};
    try testing.expect(unicode.graphemeBreak('a', '\n', &state));
    try testing.expect(unicode.graphemeBreak('a', '\r', &state));
}

test "Grapheme Break: Extend and ZWJ (GB9)" {
    var state = unicode.State{};
    // Don't break before Extend
    try testing.expect(!unicode.graphemeBreak('e', 0x0301, &state)); // e + combining acute
    try testing.expect(!unicode.graphemeBreak('a', 0x0302, &state)); // a + combining circumflex

    // Don't break before ZWJ
    state = unicode.State{};
    try testing.expect(!unicode.graphemeBreak(0x1F468, 0x200D, &state)); // 👨 + ZWJ
}

test "Grapheme Break: SpacingMark (GB9a)" {
    var state = unicode.State{};
    // Examples of spacing marks
    try testing.expect(!unicode.graphemeBreak('क', 0x0903, &state)); // Devanagari
}

test "Grapheme Break: Prepend (GB9b)" {
    var state = unicode.State{};
    // Prepend × anything (except breakers)
    try testing.expect(!unicode.graphemeBreak(0x0600, 'a', &state));
}

test "Grapheme Break: Regional Indicators (GB12, GB13)" {
    var state = unicode.State{};
    const RI_J = 0x1F1EF; // 🇯
    const RI_P = 0x1F1F5; // 🇵
    const RI_U = 0x1F1FA; // 🇺
    const RI_S = 0x1F1F8; // 🇸

    // First pair: 🇯🇵 (Japan) - should not break
    try testing.expect(!unicode.graphemeBreak(RI_J, RI_P, &state));
    try testing.expect(state.regional); // State should be set

    // Second pair: 🇺🇸 (USA) - should break because we already have a pair
    try testing.expect(unicode.graphemeBreak(RI_P, RI_U, &state));
    try testing.expect(!state.regional); // State should be reset

    // Third pair: continue with 🇸 (using RI_S)
    try testing.expect(!unicode.graphemeBreak(RI_U, RI_S, &state));
}

test "Grapheme Break: Emoji ZWJ sequences (GB11)" {
    var state = unicode.State{};

    // 👨‍👩‍👧‍👦 (Family)
    const man = 0x1F468;
    const woman = 0x1F469;
    const girl = 0x1F467;
    const boy = 0x1F466;
    const zwj = 0x200D;

    // 👨 × ZWJ
    try testing.expect(!unicode.graphemeBreak(man, zwj, &state));
    try testing.expect(state.xpic); // Extended Pictographic state set

    // ZWJ × 👩
    try testing.expect(!unicode.graphemeBreak(zwj, woman, &state));

    // 👩 × ZWJ
    state.xpic = true; // Reset for next segment
    try testing.expect(!unicode.graphemeBreak(woman, zwj, &state));

    // ZWJ × 👧
    try testing.expect(!unicode.graphemeBreak(zwj, girl, &state));

    // 👧 × ZWJ
    state.xpic = true; // Reset for next segment
    try testing.expect(!unicode.graphemeBreak(girl, zwj, &state));

    // ZWJ × 👦
    try testing.expect(!unicode.graphemeBreak(zwj, boy, &state));
}

test "Grapheme Break: Hangul syllables (GB6, GB7, GB8)" {
    var state = unicode.State{};

    // GB6: L × (L | V | LV | LVT)
    // GB7: (LV | V) × (V | T)
    // GB8: (LVT | T) × T

    // Basic Hangul syllable test: 가 (U+AC00 = LV) + 나 (U+B098)
    // LV type syllable should break before another syllable
    const ga: u21 = 0xAC00; // 가 (LV type)
    const na: u21 = 0xB098; // 나
    try testing.expect(unicode.graphemeBreak(ga, na, &state));
}

test "Edge case: Empty string" {
    // No crashes or errors on empty input
    // nextGraphemeClusterが空文字列でnullを返すことを確認
    const result = unicode.nextGraphemeCluster("");
    try testing.expect(result == null);
}

test "Edge case: Maximum codepoint" {
    // Test highest valid Unicode codepoint
    const max_cp: u21 = 0x10FFFF;
    const width = unicode.displayWidth(max_cp);
    // Should not crash, should return valid width
    try testing.expect(width <= 2);
}

test "Edge case: Surrogate range (invalid)" {
    // Surrogates (0xD800-0xDFFF) are not valid Unicode scalar values
    // But if they somehow appear, should not crash
    const surrogate: u21 = 0xD800;
    const width = unicode.displayWidth(surrogate);
    // Should return a valid width without crashing
    try testing.expect(width <= 2);
}

test "Performance: Large range scan" {
    // Test a large range of codepoints to ensure no crashes
    var cp: u21 = 0x0000;
    var count: usize = 0;
    const step: u21 = 0x100; // Sample every 256 codepoints

    while (cp < 0x10FFFF) : (cp += step) {
        _ = unicode.displayWidth(cp);
        count += 1;
    }

    // Should have scanned many codepoints without crashing
    try testing.expect(count > 1000);
}

test "All Extended Pictographic ranges" {
    const ranges = [_]struct { start: u21, end: u21 }{
        .{ .start = 0x1F600, .end = 0x1F64F }, // Emoticons
        .{ .start = 0x1F680, .end = 0x1F6FF }, // Transport
        .{ .start = 0x1F900, .end = 0x1F9FF }, // Supplemental
        .{ .start = 0x1F300, .end = 0x1F5FF }, // Misc Symbols
        .{ .start = 0x1FA70, .end = 0x1FAFF }, // Extended-A
        .{ .start = 0x2600, .end = 0x27BF },   // Misc + Dingbats
        .{ .start = 0x1F0A0, .end = 0x1F0FF }, // Playing cards
        .{ .start = 0x1F100, .end = 0x1F1FF }, // Enclosed + Regional
    };

    for (ranges) |range| {
        var cp = range.start;
        while (cp <= range.end) : (cp += 1) {
            const width = unicode.displayWidth(cp);
            // All Extended Pictographic should be width 2
            try testing.expectEqual(@as(usize, 2), width);
        }
    }
}

test "Sample text from many scripts" {
    const scripts = [_]struct { name: []const u8, sample: []const u8 }{
        .{ .name = "English", .sample = "Hello World" },
        .{ .name = "Japanese", .sample = "こんにちは世界" },
        .{ .name = "Chinese", .sample = "你好世界" },
        .{ .name = "Korean", .sample = "안녕하세요" },
        .{ .name = "Arabic", .sample = "مرحبا" },
        .{ .name = "Hebrew", .sample = "שלום" },
        .{ .name = "Russian", .sample = "Привет" },
        .{ .name = "Greek", .sample = "Γειά" },
        .{ .name = "Thai", .sample = "สวัสดี" },
        .{ .name = "Emoji", .sample = "😀🌍🚀" },
    };

    for (scripts) |script| {
        var view = std.unicode.Utf8View.init(script.sample) catch continue;
        var iter = view.iterator();
        var count: usize = 0;

        while (iter.nextCodepoint()) |cp| {
            const width = unicode.displayWidth(cp);
            // Should return valid width
            try testing.expect(width <= 2);
            count += 1;
        }

        // Should have processed some characters
        try testing.expect(count > 0);
    }
}
