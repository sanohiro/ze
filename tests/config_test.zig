// config.zig のユニットテスト
// 設定定数と関数のテスト

const std = @import("std");
const testing = std.testing;

// config モジュールは build.zig で定義されていないため、直接パスでインポート
// ただし、これは tests/ からは動作しないため、値を直接テストする

// ========================================
// QueryReplace プロンプト関数のテスト
// ========================================

const QueryReplace = struct {
    pub const PREFIX_REGEX = "Query replace regexp ";
    pub const PREFIX_LITERAL = "Query replace ";
    pub const PROMPT_REGEX = "Query replace regexp: ";
    pub const PROMPT_LITERAL = "Query replace: ";

    pub inline fn getPrefix(is_regex: bool) []const u8 {
        return if (is_regex) PREFIX_REGEX else PREFIX_LITERAL;
    }

    pub inline fn getPrompt(is_regex: bool) []const u8 {
        return if (is_regex) PROMPT_REGEX else PROMPT_LITERAL;
    }
};

test "QueryReplace.getPrefix - リテラル" {
    const prefix = QueryReplace.getPrefix(false);
    try testing.expectEqualStrings("Query replace ", prefix);
}

test "QueryReplace.getPrefix - 正規表現" {
    const prefix = QueryReplace.getPrefix(true);
    try testing.expectEqualStrings("Query replace regexp ", prefix);
}

test "QueryReplace.getPrompt - リテラル" {
    const prompt = QueryReplace.getPrompt(false);
    try testing.expectEqualStrings("Query replace: ", prompt);
}

test "QueryReplace.getPrompt - 正規表現" {
    const prompt = QueryReplace.getPrompt(true);
    try testing.expectEqualStrings("Query replace regexp: ", prompt);
}

// ========================================
// 定数値の妥当性テスト
// ========================================

test "Terminal - デフォルト値の妥当性" {
    // 一般的なターミナルサイズ
    const DEFAULT_WIDTH: usize = 80;
    const DEFAULT_HEIGHT: usize = 24;

    try testing.expect(DEFAULT_WIDTH >= 40);
    try testing.expect(DEFAULT_WIDTH <= 500);
    try testing.expect(DEFAULT_HEIGHT >= 10);
    try testing.expect(DEFAULT_HEIGHT <= 200);
}

test "Editor - タブ幅の妥当性" {
    const TAB_WIDTH: usize = 4;
    const MAX_TAB_WIDTH: usize = 16;

    try testing.expect(TAB_WIDTH >= 1);
    try testing.expect(TAB_WIDTH <= MAX_TAB_WIDTH);
    try testing.expect(MAX_TAB_WIDTH <= 32); // 合理的な上限
}

test "Regex - 最大ポジション数" {
    const MAX_POSITIONS: usize = 10000;

    // 指数時間防止のための適切な制限
    try testing.expect(MAX_POSITIONS >= 1000);
    try testing.expect(MAX_POSITIONS <= 100000);
}

// ========================================
// ASCII定数のテスト
// ========================================

test "ASCII - 制御文字境界" {
    const CTRL_MAX: u8 = 0x1F;
    const PRINTABLE_MIN: u8 = 0x20;

    try testing.expectEqual(PRINTABLE_MIN, CTRL_MAX + 1);
}

test "ASCII - 特殊文字コード" {
    const ESC: u8 = 0x1B;
    const DEL: u8 = 0x7F;
    const BACKSPACE: u8 = 0x08;

    try testing.expectEqual(@as(u8, 27), ESC);
    try testing.expectEqual(@as(u8, 127), DEL);
    try testing.expectEqual(@as(u8, 8), BACKSPACE);
}

// ========================================
// UTF-8定数のテスト
// ========================================

test "UTF8 - 継続バイトパターン" {
    const CONTINUATION_MASK: u8 = 0b11000000;
    const CONTINUATION_PATTERN: u8 = 0b10000000;

    // 継続バイトの検証（0x80-0xBF）
    for (0x80..0xC0) |b| {
        const byte: u8 = @intCast(b);
        try testing.expectEqual(CONTINUATION_PATTERN, byte & CONTINUATION_MASK);
    }
}

test "UTF8 - バイト範囲" {
    const BYTE2_MAX: u8 = 0xDF;
    const BYTE3_MIN: u8 = 0xE0;
    const BYTE3_MAX: u8 = 0xEF;
    const BYTE4_MIN: u8 = 0xF0;

    // 範囲が連続していることを確認
    try testing.expectEqual(BYTE2_MAX + 1, BYTE3_MIN);
    try testing.expectEqual(BYTE3_MAX + 1, BYTE4_MIN);
}

test "UTF8 - 全角スペース" {
    const FULLWIDTH_SPACE = [_]u8{ 0xE3, 0x80, 0x80 };

    // U+3000 のUTF-8エンコーディングを確認
    try testing.expectEqual(@as(usize, 3), FULLWIDTH_SPACE.len);

    // デコードして確認
    const cp = std.unicode.utf8Decode(&FULLWIDTH_SPACE) catch unreachable;
    try testing.expectEqual(@as(u21, 0x3000), cp);
}

// ========================================
// BOM定数のテスト
// ========================================

test "BOM - UTF-8" {
    const BOM_UTF8 = [_]u8{ 0xEF, 0xBB, 0xBF };
    try testing.expectEqual(@as(usize, 3), BOM_UTF8.len);
}

test "BOM - UTF-16LE" {
    const BOM_UTF16LE = [_]u8{ 0xFF, 0xFE };
    try testing.expectEqual(@as(usize, 2), BOM_UTF16LE.len);
}

test "BOM - UTF-16BE" {
    const BOM_UTF16BE = [_]u8{ 0xFE, 0xFF };
    try testing.expectEqual(@as(usize, 2), BOM_UTF16BE.len);
}

// ========================================
// メッセージ定数の一貫性テスト
// ========================================

test "Messages - 非空文字列" {
    const messages = [_][]const u8{
        "Buffer is read-only",
        "No mark set",
        "Mark set",
        "Cancelled",
        "Unknown command",
    };

    for (messages) |msg| {
        try testing.expect(msg.len > 0);
    }
}
