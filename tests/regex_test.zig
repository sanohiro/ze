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

// ============================================================
// Question mark quantifier tests
// ============================================================

test "question mark quantifier - optional match" {
    var regex = try Regex.compile(testing.allocator, "colou?r");
    defer regex.deinit();

    // "color" にマッチ（uなし）
    const result1 = regex.search("American color", 0);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 9), result1.?.start);

    // "colour" にマッチ（uあり）
    const result2 = regex.search("British colour", 0);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 8), result2.?.start);
}

test "question mark with class" {
    var regex = try Regex.compile(testing.allocator, "[abc]?x");
    defer regex.deinit();

    // "ax" にマッチ
    const result1 = regex.search("ax", 0);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 0), result1.?.start);

    // "x" にマッチ（先頭が[abc]でなくてもOK）
    const result2 = regex.search("x", 0);
    try testing.expect(result2 != null);
}

// ============================================================
// Escape character tests
// ============================================================

test "escaped special characters" {
    var regex = try Regex.compile(testing.allocator, "\\.");
    defer regex.deinit();

    // リテラルのドットにマッチ
    const result = regex.search("test.txt", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 4), result.?.start);
    try testing.expectEqual(@as(usize, 5), result.?.end);
}

test "escaped backslash" {
    var regex = try Regex.compile(testing.allocator, "\\\\");
    defer regex.deinit();

    // バックスラッシュにマッチ
    const result = regex.search("path\\file", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 4), result.?.start);
}

test "escaped star and plus" {
    var regex1 = try Regex.compile(testing.allocator, "\\*");
    defer regex1.deinit();

    const result1 = regex1.search("a*b", 0);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 1), result1.?.start);

    var regex2 = try Regex.compile(testing.allocator, "\\+");
    defer regex2.deinit();

    const result2 = regex2.search("a+b", 0);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 1), result2.?.start);
}

test "newline and tab escape" {
    var regex1 = try Regex.compile(testing.allocator, "\\n");
    defer regex1.deinit();

    const result1 = regex1.search("line1\nline2", 0);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 5), result1.?.start);

    var regex2 = try Regex.compile(testing.allocator, "\\t");
    defer regex2.deinit();

    const result2 = regex2.search("col1\tcol2", 0);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 4), result2.?.start);
}

// ============================================================
// Additional shorthand tests
// ============================================================

test "word shorthand" {
    var regex = try Regex.compile(testing.allocator, "\\w+");
    defer regex.deinit();

    const result = regex.search("!@#abc123_xyz!@#", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 3), result.?.start);
    // abc123_xyz = 10文字、インデックス3から始まるので終了は13
    try testing.expectEqual(@as(usize, 13), result.?.end);
}

test "non-word shorthand" {
    var regex = try Regex.compile(testing.allocator, "\\W+");
    defer regex.deinit();

    const result = regex.search("abc!@#xyz", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 3), result.?.start);
    try testing.expectEqual(@as(usize, 6), result.?.end);
}

test "space shorthand" {
    var regex = try Regex.compile(testing.allocator, "\\s+");
    defer regex.deinit();

    const result = regex.search("word1  \t word2", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 5), result.?.start);
    try testing.expectEqual(@as(usize, 9), result.?.end);
}

test "non-space shorthand" {
    var regex = try Regex.compile(testing.allocator, "\\S+");
    defer regex.deinit();

    const result = regex.search("   word   ", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 3), result.?.start);
    try testing.expectEqual(@as(usize, 7), result.?.end);
}

test "non-digit shorthand" {
    var regex = try Regex.compile(testing.allocator, "\\D+");
    defer regex.deinit();

    const result = regex.search("123abc456", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 3), result.?.start);
    try testing.expectEqual(@as(usize, 6), result.?.end);
}

// ============================================================
// Backward search tests
// ============================================================

test "backward search basic" {
    var regex = try Regex.compile(testing.allocator, "hello");
    defer regex.deinit();

    // 後方から検索
    const result = regex.searchBackward("hello world hello", 17);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 12), result.?.start);
}

test "backward search multiple matches" {
    var regex = try Regex.compile(testing.allocator, "ab");
    defer regex.deinit();

    // 最後のマッチを見つける
    const result1 = regex.searchBackward("ab ab ab", 8);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 6), result1.?.start);

    // 途中から検索
    const result2 = regex.searchBackward("ab ab ab", 5);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 3), result2.?.start);
}

test "backward search with pattern" {
    var regex = try Regex.compile(testing.allocator, "\\d+");
    defer regex.deinit();

    // "abc123def456ghi" (位置: a=0, b=1, c=2, 1=3, 2=4, 3=5, d=6, e=7, f=8, 4=9, 5=10, 6=11, g=12, h=13, i=14)
    // 後方検索は開始位置から逆順に各位置でマッチを試みる
    // 位置11から開始して、11, 10, 9, ... と試す
    // 位置11で"6"にマッチ、位置10で"56"にマッチ、位置9で"456"にマッチ
    // 最初に見つかったマッチ（位置11）が返される
    const result = regex.searchBackward("abc123def456ghi", 15);
    try testing.expect(result != null);
    // 後方検索は位置14から開始して最初に見つかった数字列を返す
    // 位置11で6が見つかる
    try testing.expectEqual(@as(usize, 11), result.?.start);
}

// ============================================================
// Character class edge cases
// ============================================================

test "character class with hyphen" {
    var regex = try Regex.compile(testing.allocator, "[a-z]+");
    defer regex.deinit();

    const result = regex.search("ABC def GHI", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 4), result.?.start);
    try testing.expectEqual(@as(usize, 7), result.?.end);
}

test "character class with digits" {
    var regex = try Regex.compile(testing.allocator, "[0-9a-f]+");
    defer regex.deinit();

    // 16進数にマッチ
    const result = regex.search("value: 0x1a2b3c", 0);
    try testing.expect(result != null);
}

test "negated class with multiple ranges" {
    var regex = try Regex.compile(testing.allocator, "[^a-zA-Z]+");
    defer regex.deinit();

    const result = regex.search("hello123world", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 5), result.?.start);
    try testing.expectEqual(@as(usize, 8), result.?.end);
}

// ============================================================
// Edge cases
// ============================================================

test "empty pattern" {
    var regex = try Regex.compile(testing.allocator, "");
    defer regex.deinit();

    // 空パターンはマッチしない
    const result = regex.search("test", 0);
    try testing.expect(result == null);
}

test "no match" {
    var regex = try Regex.compile(testing.allocator, "xyz");
    defer regex.deinit();

    const result = regex.search("hello world", 0);
    try testing.expect(result == null);
}

test "match at end of string" {
    var regex = try Regex.compile(testing.allocator, "end");
    defer regex.deinit();

    const result = regex.search("the end", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 4), result.?.start);
    try testing.expectEqual(@as(usize, 7), result.?.end);
}

test "greedy matching" {
    var regex = try Regex.compile(testing.allocator, "a.*b");
    defer regex.deinit();

    // 貪欲マッチ: 最長マッチ
    const result = regex.search("axxbxxb", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?.start);
    try testing.expectEqual(@as(usize, 7), result.?.end); // 最長マッチ
}

test "consecutive quantifiers" {
    var regex = try Regex.compile(testing.allocator, "a+b+");
    defer regex.deinit();

    const result = regex.search("aaabbb", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?.start);
    try testing.expectEqual(@as(usize, 6), result.?.end);
}

test "search with offset" {
    var regex = try Regex.compile(testing.allocator, "test");
    defer regex.deinit();

    // 最初のマッチ
    const result1 = regex.search("test test test", 0);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 0), result1.?.start);

    // オフセット5から検索
    const result2 = regex.search("test test test", 5);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 5), result2.?.start);

    // オフセット10から検索
    const result3 = regex.search("test test test", 10);
    try testing.expect(result3 != null);
    try testing.expectEqual(@as(usize, 10), result3.?.start);
}

test "multiline anchor" {
    var regex = try Regex.compile(testing.allocator, "^line");
    defer regex.deinit();

    // 2行目の行頭にマッチ
    const result = regex.search("first\nline two", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 6), result.?.start);
}
