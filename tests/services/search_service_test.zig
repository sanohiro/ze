const std = @import("std");
const testing = std.testing;
const SearchService = @import("search_service").SearchService;

test "SearchService - literal forward search" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "hello world hello";
    const result = service.searchForward(content, "hello", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?.start);
    try testing.expectEqual(@as(usize, 5), result.?.len);

    // 2番目のマッチを検索
    const result2 = service.searchForward(content, "hello", 1);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 12), result2.?.start);
}

test "SearchService - literal backward search" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "hello world hello";
    const result = service.searchBackward(content, "hello", content.len);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 12), result.?.start);
}

test "SearchService - wraparound search" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "hello world";
    // 末尾から検索、先頭にラップアラウンド
    const result = service.searchForward(content, "hello", 10);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 0), result.?.start);
}

test "SearchService - no match" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "hello world";
    const result = service.searchForward(content, "xyz", 0);
    try testing.expect(result == null);
}

test "SearchService - isRegexPattern" {
    try testing.expect(SearchService.isRegexPattern("\\d+"));
    try testing.expect(SearchService.isRegexPattern("^hello"));
    try testing.expect(SearchService.isRegexPattern("world$"));
    try testing.expect(!SearchService.isRegexPattern("hello"));
    try testing.expect(!SearchService.isRegexPattern("world"));
}

test "SearchService - regex cache" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "test123 foo456 bar789";
    // positions: test=0-3, 123=4-6, space=7, foo=8-10, 456=11-13, space=14, bar=15-17, 789=18-20

    // 最初の検索でキャッシュ作成
    const result1 = service.searchRegexForward(content, "\\d+", 0);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 4), result1.?.start);
    try testing.expectEqual(@as(usize, 3), result1.?.len);

    // LRUキャッシュにエントリがあることを確認
    var cache_has_pattern1 = false;
    for (service.regex_cache) |entry_opt| {
        if (entry_opt) |entry| {
            if (std.mem.eql(u8, entry.pattern, "\\d+")) {
                cache_has_pattern1 = true;
                break;
            }
        }
    }
    try testing.expect(cache_has_pattern1);

    // 同じパターンで2番目のマッチを検索（キャッシュを使用）
    // 位置7（スペース）から検索 → 456は位置11から始まる
    const result2 = service.searchRegexForward(content, "\\d+", 7);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 11), result2.?.start);

    // パターンが変わるとキャッシュに新しいエントリが追加される
    const result3 = service.searchRegexForward(content, "[a-z]+", 0);
    try testing.expect(result3 != null);
    var cache_has_pattern2 = false;
    for (service.regex_cache) |entry_opt| {
        if (entry_opt) |entry| {
            if (std.mem.eql(u8, entry.pattern, "[a-z]+")) {
                cache_has_pattern2 = true;
                break;
            }
        }
    }
    try testing.expect(cache_has_pattern2);
}

test "SearchService - regex backward search" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    // content: "abc123def456"
    //           0  3  6  9
    // searchBackward finds the last character position that starts a match
    // For "\d+" at position 11 ('6'), it matches "6"
    // For "\d+" at position 5 ('3'), it matches "3"
    const content = "abc123def456";

    // 末尾から後方検索 → 位置11('6')でマッチ開始
    const result1 = service.searchRegexBackward(content, "\\d+", content.len);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 11), result1.?.start);
    try testing.expectEqual(@as(usize, 1), result1.?.len);

    // 位置9から後方検索 → 位置8('f')より前の数字、位置5('3')でマッチ
    const result2 = service.searchRegexBackward(content, "\\d+", 9);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 5), result2.?.start);
}

test "SearchService - regex backward wraparound" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    // content: "abc123def456"
    //           0  3  6  9
    // searchBackward wraparound: if nothing found before start_pos,
    // search from end and return match after start_pos
    const content = "abc123def456";

    // 位置3から後方検索 → 位置2,1,0には数字がない → ラップして末尾から検索
    // 末尾から検索すると位置11('6')でマッチ
    const result = service.searchRegexBackward(content, "\\d+", 3);
    try testing.expect(result != null);
    // ラップアラウンドで start_pos より後ろのマッチを返す（位置11）
    try testing.expectEqual(@as(usize, 11), result.?.start);
}

// ============================================================
// エッジケース
// ============================================================

test "SearchService - empty pattern" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "hello world";
    // 空パターンで検索 → nullを返す
    const result = service.searchForward(content, "", 0);
    try testing.expect(result == null);
}

test "SearchService - empty buffer" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "";
    // 空バッファで検索 → nullを返す
    const result = service.searchForward(content, "hello", 0);
    try testing.expect(result == null);
}

test "SearchService - empty pattern and empty buffer" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "";
    const result = service.searchForward(content, "", 0);
    try testing.expect(result == null);
}

test "SearchService - pattern longer than buffer" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "hi";
    const result = service.searchForward(content, "hello world", 0);
    try testing.expect(result == null);
}

test "SearchService - search at buffer boundary" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "hello";
    // バッファ末尾から検索
    const result = service.searchForward(content, "hello", 5);
    try testing.expect(result != null);
    // ラップアラウンドで先頭を見つける
    try testing.expectEqual(@as(usize, 0), result.?.start);
}

test "SearchService - regex empty pattern" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "test";
    // 正規表現で空パターン → nullを返す
    const result = service.searchRegexForward(content, "", 0);
    try testing.expect(result == null);
}

test "SearchService - regex invalid pattern" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "test";
    // 不正な正規表現パターン → コンパイルエラーでnullを返す
    const result = service.searchRegexForward(content, "[", 0);
    try testing.expect(result == null);
}

test "SearchService - single character buffer" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "a";
    const result1 = service.searchForward(content, "a", 0);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 0), result1.?.start);
    try testing.expectEqual(@as(usize, 1), result1.?.len);

    const result2 = service.searchForward(content, "b", 0);
    try testing.expect(result2 == null);
}

test "SearchService - backward search from start" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "hello world hello";
    // 先頭から後方検索 → ラップアラウンドで末尾のhelloを見つける
    const result = service.searchBackward(content, "hello", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 12), result.?.start);
}

test "SearchService - regex single character" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "abcabc";
    const result = service.searchRegexForward(content, "b", 0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.start);
    try testing.expectEqual(@as(usize, 1), result.?.len);
}

test "SearchService - case sensitive literal" {
    var service = SearchService.init(testing.allocator);
    defer service.deinit();

    const content = "Hello hello HELLO";
    const result1 = service.searchForward(content, "hello", 0);
    try testing.expect(result1 != null);
    try testing.expectEqual(@as(usize, 6), result1.?.start);

    const result2 = service.searchForward(content, "HELLO", 0);
    try testing.expect(result2 != null);
    try testing.expectEqual(@as(usize, 12), result2.?.start);
}
