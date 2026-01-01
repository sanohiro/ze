// movement.zig のユニットテスト
// 純粋関数のテスト（Editorに依存しないもの）

const std = @import("std");
const testing = std.testing;
const buffer_mod = @import("buffer");
const Buffer = buffer_mod.Buffer;
const unicode = @import("unicode");

// ========================================
// decodeUtf8FromChunk のテスト
// ========================================

fn decodeUtf8FromChunk(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    return std.unicode.utf8Decode(bytes) catch null;
}

test "decodeUtf8FromChunk - ASCII" {
    const result = decodeUtf8FromChunk("A");
    try testing.expectEqual(@as(?u21, 'A'), result);
}

test "decodeUtf8FromChunk - 2バイトUTF-8（ラテン拡張）" {
    // é = U+00E9 = 0xC3 0xA9
    const result = decodeUtf8FromChunk(&[_]u8{ 0xC3, 0xA9 });
    try testing.expectEqual(@as(?u21, 0x00E9), result);
}

test "decodeUtf8FromChunk - 3バイトUTF-8（日本語）" {
    // あ = U+3042 = 0xE3 0x81 0x82
    const result = decodeUtf8FromChunk(&[_]u8{ 0xE3, 0x81, 0x82 });
    try testing.expectEqual(@as(?u21, 0x3042), result);
}

test "decodeUtf8FromChunk - 4バイトUTF-8（絵文字）" {
    // 😀 = U+1F600 = 0xF0 0x9F 0x98 0x80
    const result = decodeUtf8FromChunk(&[_]u8{ 0xF0, 0x9F, 0x98, 0x80 });
    try testing.expectEqual(@as(?u21, 0x1F600), result);
}

test "decodeUtf8FromChunk - 空配列" {
    const result = decodeUtf8FromChunk("");
    try testing.expectEqual(@as(?u21, null), result);
}

// ========================================
// findLineStart のテスト（Buffer.getLineStart経由）
// ========================================

test "findLineStart - バッファ先頭" {
    const allocator = testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.insertSlice(0, "hello\nworld");

    // 位置0の行開始は0
    const line_num = buf.findLineByPos(0);
    const start = buf.getLineStart(line_num);
    try testing.expectEqual(@as(?usize, 0), start);
}

test "findLineStart - 2行目" {
    const allocator = testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.insertSlice(0, "hello\nworld");

    // 位置7('o')の行開始は6
    const line_num = buf.findLineByPos(7);
    const start = buf.getLineStart(line_num);
    try testing.expectEqual(@as(?usize, 6), start);
}

test "findLineStart - 複数行" {
    const allocator = testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.insertSlice(0, "line1\nline2\nline3");

    // 3行目（位置12）
    const line_num = buf.findLineByPos(12);
    const start = buf.getLineStart(line_num);
    try testing.expectEqual(@as(?usize, 12), start);
}

test "findLineStart - 改行直後" {
    const allocator = testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.insertSlice(0, "abc\ndef");

    // 位置4（改行直後）
    const line_num = buf.findLineByPos(4);
    const start = buf.getLineStart(line_num);
    try testing.expectEqual(@as(?usize, 4), start);
}

test "findLineStart - 空行を含むバッファ" {
    const allocator = testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();
    try buf.insertSlice(0, "a\n\nb");

    // 空行（位置2）
    const line_num2 = buf.findLineByPos(2);
    const start2 = buf.getLineStart(line_num2);
    try testing.expectEqual(@as(?usize, 2), start2);

    // 最後の行（位置3）
    const line_num3 = buf.findLineByPos(3);
    const start3 = buf.getLineStart(line_num3);
    try testing.expectEqual(@as(?usize, 3), start3);
}

// ========================================
// unicode.CharType のテスト（単語移動で使用）
// ========================================

test "CharType - ASCII文字種別" {
    // アルファベット
    try testing.expectEqual(unicode.CharType.alnum, unicode.getCharType('a'));
    try testing.expectEqual(unicode.CharType.alnum, unicode.getCharType('Z'));

    // 数字
    try testing.expectEqual(unicode.CharType.alnum, unicode.getCharType('0'));
    try testing.expectEqual(unicode.CharType.alnum, unicode.getCharType('9'));

    // スペース
    try testing.expectEqual(unicode.CharType.space, unicode.getCharType(' '));
    try testing.expectEqual(unicode.CharType.space, unicode.getCharType('\t'));
    try testing.expectEqual(unicode.CharType.space, unicode.getCharType('\n'));

    // 記号
    try testing.expectEqual(unicode.CharType.other, unicode.getCharType('.'));
    try testing.expectEqual(unicode.CharType.other, unicode.getCharType('!'));
    try testing.expectEqual(unicode.CharType.other, unicode.getCharType('@'));
}

test "CharType - 日本語文字種別" {
    // ひらがな
    try testing.expectEqual(unicode.CharType.hiragana, unicode.getCharType(0x3042)); // あ

    // カタカナ
    try testing.expectEqual(unicode.CharType.katakana, unicode.getCharType(0x30A2)); // ア

    // 漢字
    try testing.expectEqual(unicode.CharType.kanji, unicode.getCharType(0x4E00)); // 一
}

test "CharType - 絵文字" {
    // 絵文字はotherカテゴリ
    try testing.expectEqual(unicode.CharType.other, unicode.getCharType(0x1F600)); // 😀
}

// ========================================
// isAsciiByte / isUtf8Continuation のテスト
// ========================================

test "isAsciiByte - ASCII範囲" {
    try testing.expect(unicode.isAsciiByte(0x00));
    try testing.expect(unicode.isAsciiByte(0x7F));
    try testing.expect(unicode.isAsciiByte('A'));
    try testing.expect(unicode.isAsciiByte(' '));
}

test "isAsciiByte - 非ASCII" {
    try testing.expect(!unicode.isAsciiByte(0x80));
    try testing.expect(!unicode.isAsciiByte(0xC0));
    try testing.expect(!unicode.isAsciiByte(0xFF));
}

test "isUtf8Continuation - 継続バイト" {
    // 10xxxxxx パターン (0x80-0xBF)
    try testing.expect(unicode.isUtf8Continuation(0x80));
    try testing.expect(unicode.isUtf8Continuation(0xBF));
    try testing.expect(unicode.isUtf8Continuation(0xA0));
}

test "isUtf8Continuation - 非継続バイト" {
    // ASCII
    try testing.expect(!unicode.isUtf8Continuation(0x00));
    try testing.expect(!unicode.isUtf8Continuation(0x7F));

    // 先頭バイト
    try testing.expect(!unicode.isUtf8Continuation(0xC0));
    try testing.expect(!unicode.isUtf8Continuation(0xE0));
    try testing.expect(!unicode.isUtf8Continuation(0xF0));
}
