const std = @import("std");
const testing = std.testing;
const regex_mod = @import("regex");
const Regex = regex_mod.Regex;
const isRegexPattern = regex_mod.isRegexPattern;

test "literal match" {
    var regex = try Regex.compile(testing.allocator, "hello");
    defer regex.deinit();

    const result = regex.search("say hello world", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 4), result.?.start);
    try testing.expectEqual(@as(usize, 9), result.?.end);
}

test "dot match" {
    var regex = try Regex.compile(testing.allocator, "h.llo");
    defer regex.deinit();

    const result = regex.search("hallo world", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?.start);
    try testing.expectEqual(@as(usize, 5), result.?.end);
}

test "star quantifier" {
    var regex = try Regex.compile(testing.allocator, "ho*");
    defer regex.deinit();

    // "h" にマッチ（0回）
    const result1 = regex.search("h", 0);
    try testing.expect(result1 != null);

    // "hooo" にマッチ（3回）
    const result2 = regex.search("hooo", 0);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 4), result2.?.end);
}

test "plus quantifier" {
    var regex = try Regex.compile(testing.allocator, "ho+");
    defer regex.deinit();

    // "h" にはマッチしない（最低1回必要）
    const result1 = regex.search("h ", 0);
    try testing.expect(result1 == null);

    // "ho" にマッチ
    const result2 = regex.search("ho", 0);
    try testing.expect(result2 != null);
}

test "character class" {
    var regex = try Regex.compile(testing.allocator, "[abc]+");
    defer regex.deinit();

    const result = regex.search("xxxabcxxx", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 3), result.?.start);
    try testing.expectEqual(@as(usize, 6), result.?.end);
}

test "negated character class" {
    var regex = try Regex.compile(testing.allocator, "[^0-9]+");
    defer regex.deinit();

    const result = regex.search("123abc456", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 3), result.?.start);
    try testing.expectEqual(@as(usize, 6), result.?.end);
}

test "digit shorthand" {
    var regex = try Regex.compile(testing.allocator, "\\d+");
    defer regex.deinit();

    const result = regex.search("abc123def", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 3), result.?.start);
    try testing.expectEqual(@as(usize, 6), result.?.end);
}

test "anchor start" {
    var regex = try Regex.compile(testing.allocator, "^hello");
    defer regex.deinit();

    // 行頭の "hello" にマッチ
    const result1 = regex.search("hello world", 0);
    try testing.expect(result1 != null);

    // 行頭でない "hello" にはマッチしない
    const result2 = regex.search("say hello", 0);
    try testing.expect(result2 == null);
}

test "anchor end" {
    var regex = try Regex.compile(testing.allocator, "world$");
    defer regex.deinit();

    // 行末の "world" にマッチ
    const result1 = regex.search("hello world", 0);
    try testing.expect(result1 != null);

    // 行末でない "world" にはマッチしない
    const result2 = regex.search("world hello", 0);
    try testing.expect(result2 == null);
}

test "complex pattern" {
    var regex = try Regex.compile(testing.allocator, "[a-z]+\\d*");
    defer regex.deinit();

    const result = regex.search("test123", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?.start);
    try testing.expectEqual(@as(usize, 7), result.?.end);
}

test "isRegexPattern" {
    try testing.expect(isRegexPattern("hello.*world"));
    try testing.expect(isRegexPattern("\\d+"));
    try testing.expect(isRegexPattern("[abc]"));
    try testing.expect(!isRegexPattern("hello"));
    try testing.expect(!isRegexPattern("test123"));
}
