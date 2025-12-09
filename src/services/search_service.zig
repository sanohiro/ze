// ============================================================================
// SearchService - 検索・置換サービス
// ============================================================================
//
// 【責務】
// - インクリメンタルサーチ（I-search）
// - Query Replace（対話的置換）
// - 検索履歴の管理
// - 正規表現検索のサポート
//
// 【設計原則】
// - Bufferへの直接操作は行わない（結果を返すのみ）
// - Viewへの依存を最小化
// ============================================================================

const std = @import("std");
const regex = @import("../regex.zig");
const History = @import("../history.zig").History;
const HistoryType = @import("../history.zig").HistoryType;

/// 検索結果
pub const SearchMatch = struct {
    start: usize,
    len: usize,
};

/// 検索状態
pub const SearchState = struct {
    start_pos: ?usize, // 検索開始位置
    last_search: ?[]const u8, // 最後の検索パターン
    is_forward: bool, // 前方検索かどうか
};

/// 置換状態
pub const ReplaceState = struct {
    search: ?[]const u8, // 検索パターン
    replacement: ?[]const u8, // 置換文字列
    current_pos: ?usize, // 現在のマッチ位置
    match_count: usize, // 置換回数
};

/// 検索サービス
pub const SearchService = struct {
    allocator: std.mem.Allocator,
    history: History,
    compiled_regex: ?regex.Regex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        var history = History.init(allocator);
        history.load(.search) catch {};
        return .{
            .allocator = allocator,
            .history = history,
            .compiled_regex = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.history.save(.search) catch {};
        self.history.deinit();
        if (self.compiled_regex) |*r| {
            r.deinit();
        }
    }

    /// リテラル検索（前方）
    pub fn searchForward(self: *Self, content: []const u8, pattern: []const u8, start_pos: usize) ?SearchMatch {
        _ = self;
        if (pattern.len == 0 or start_pos >= content.len) return null;

        // まず start_pos から検索
        if (std.mem.indexOf(u8, content[start_pos..], pattern)) |offset| {
            return .{
                .start = start_pos + offset,
                .len = pattern.len,
            };
        }

        // ラップアラウンド（先頭から start_pos まで）
        if (start_pos > 0) {
            if (std.mem.indexOf(u8, content[0..start_pos], pattern)) |offset| {
                return .{
                    .start = offset,
                    .len = pattern.len,
                };
            }
        }

        return null;
    }

    /// リテラル検索（後方）
    pub fn searchBackward(self: *Self, content: []const u8, pattern: []const u8, start_pos: usize) ?SearchMatch {
        _ = self;
        if (pattern.len == 0) return null;

        // まず start_pos まで後方検索
        const search_end = @min(start_pos, content.len);
        if (search_end > 0) {
            if (std.mem.lastIndexOf(u8, content[0..search_end], pattern)) |offset| {
                return .{
                    .start = offset,
                    .len = pattern.len,
                };
            }
        }

        // ラップアラウンド（start_pos から末尾まで）
        if (start_pos < content.len) {
            if (std.mem.lastIndexOf(u8, content[start_pos..], pattern)) |offset| {
                return .{
                    .start = start_pos + offset,
                    .len = pattern.len,
                };
            }
        }

        return null;
    }

    /// 正規表現検索（前方）
    pub fn searchRegexForward(self: *Self, content: []const u8, pattern: []const u8, start_pos: usize) ?SearchMatch {
        // 正規表現をコンパイル
        if (self.compiled_regex) |*r| {
            r.deinit();
            self.compiled_regex = null;
        }

        self.compiled_regex = regex.Regex.compile(self.allocator, pattern) catch return null;
        const re = &self.compiled_regex.?;

        // 前方検索
        if (re.search(content, start_pos)) |match| {
            return .{
                .start = match.start,
                .len = match.end - match.start,
            };
        }

        // ラップアラウンド
        if (start_pos > 0) {
            if (re.search(content, 0)) |match| {
                if (match.start < start_pos) {
                    return .{
                        .start = match.start,
                        .len = match.end - match.start,
                    };
                }
            }
        }

        return null;
    }

    /// 正規表現検索（後方）
    pub fn searchRegexBackward(self: *Self, content: []const u8, pattern: []const u8, start_pos: usize) ?SearchMatch {
        // 正規表現をコンパイル
        if (self.compiled_regex) |*r| {
            r.deinit();
            self.compiled_regex = null;
        }

        self.compiled_regex = regex.Regex.compile(self.allocator, pattern) catch return null;
        const re = &self.compiled_regex.?;

        // 後方検索
        if (re.searchBackward(content, start_pos)) |match| {
            return .{
                .start = match.start,
                .len = match.end - match.start,
            };
        }

        // ラップアラウンド
        if (re.searchBackward(content, content.len)) |match| {
            if (match.start > start_pos) {
                return .{
                    .start = match.start,
                    .len = match.end - match.start,
                };
            }
        }

        return null;
    }

    /// パターンが正規表現かどうか判定
    pub fn isRegexPattern(pattern: []const u8) bool {
        return regex.isRegexPattern(pattern);
    }

    /// 統合検索（パターンに応じてリテラル/正規表現を選択）
    pub fn search(self: *Self, content: []const u8, pattern: []const u8, start_pos: usize, forward: bool, skip_current: bool) ?SearchMatch {
        const search_from = if (skip_current and start_pos < content.len) start_pos + 1 else start_pos;

        if (isRegexPattern(pattern)) {
            if (forward) {
                return self.searchRegexForward(content, pattern, search_from);
            } else {
                return self.searchRegexBackward(content, pattern, search_from);
            }
        } else {
            if (forward) {
                return self.searchForward(content, pattern, search_from);
            } else {
                return self.searchBackward(content, pattern, search_from);
            }
        }
    }

    // ========================================
    // 履歴管理
    // ========================================

    /// 履歴にパターンを追加
    pub fn addToHistory(self: *Self, pattern: []const u8) !void {
        try self.history.add(pattern);
    }

    /// 履歴ナビゲーション開始
    pub fn startHistoryNavigation(self: *Self, current_input: []const u8) !void {
        try self.history.startNavigation(current_input);
    }

    /// 履歴の前のエントリを取得
    pub fn historyPrev(self: *Self) ?[]const u8 {
        return self.history.prev();
    }

    /// 履歴の次のエントリを取得
    pub fn historyNext(self: *Self) ?[]const u8 {
        return self.history.next();
    }

    /// 履歴ナビゲーションをリセット
    pub fn resetHistoryNavigation(self: *Self) void {
        self.history.resetNavigation();
    }

    /// 履歴ナビゲーション中かどうか
    pub fn isNavigating(self: *Self) bool {
        return self.history.current_index != null;
    }
};

// ============================================================================
// テスト
// ============================================================================

test "SearchService - literal forward search" {
    const allocator = std.testing.allocator;
    var service = SearchService.init(allocator);
    defer service.deinit();

    const content = "hello world hello";
    const result = service.searchForward(content, "hello", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 5), result.?.len);

    // 2番目のマッチを検索
    const result2 = service.searchForward(content, "hello", 1);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 12), result2.?.start);
}

test "SearchService - literal backward search" {
    const allocator = std.testing.allocator;
    var service = SearchService.init(allocator);
    defer service.deinit();

    const content = "hello world hello";
    const result = service.searchBackward(content, "hello", content.len);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 12), result.?.start);
}

test "SearchService - wraparound search" {
    const allocator = std.testing.allocator;
    var service = SearchService.init(allocator);
    defer service.deinit();

    const content = "hello world";
    // 末尾から検索、先頭にラップアラウンド
    const result = service.searchForward(content, "hello", 10);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
}

test "SearchService - no match" {
    const allocator = std.testing.allocator;
    var service = SearchService.init(allocator);
    defer service.deinit();

    const content = "hello world";
    const result = service.searchForward(content, "xyz", 0);
    try std.testing.expect(result == null);
}

test "SearchService - isRegexPattern" {
    try std.testing.expect(SearchService.isRegexPattern("\\d+"));
    try std.testing.expect(SearchService.isRegexPattern("^hello"));
    try std.testing.expect(SearchService.isRegexPattern("world$"));
    try std.testing.expect(!SearchService.isRegexPattern("hello"));
    try std.testing.expect(!SearchService.isRegexPattern("world"));
}
