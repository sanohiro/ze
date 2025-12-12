const std = @import("std");
const testing = std.testing;
const encoding = @import("encoding");
const Encoding = encoding.Encoding;
const LineEnding = encoding.LineEnding;

// ============================================================
// BOM detection tests
// ============================================================

test "detect UTF-8 BOM" {
    const content = "\xEF\xBB\xBFHello";
    const result = encoding.detectEncoding(content);
    try testing.expectEqual(Encoding.UTF8_BOM, result.encoding);
}

test "detect UTF-16LE BOM" {
    const content = "\xFF\xFEH\x00e\x00l\x00l\x00o\x00";
    const result = encoding.detectEncoding(content);
    try testing.expectEqual(Encoding.UTF16LE_BOM, result.encoding);
}

test "detect UTF-16BE BOM" {
    const content = "\xFE\xFF\x00H\x00e\x00l\x00l\x00o";
    const result = encoding.detectEncoding(content);
    try testing.expectEqual(Encoding.UTF16BE_BOM, result.encoding);
}

test "detect plain UTF-8" {
    const content = "Hello, World!";
    const result = encoding.detectEncoding(content);
    try testing.expectEqual(Encoding.UTF8, result.encoding);
}

test "detect UTF-8 with Japanese" {
    const content = "こんにちは";
    const result = encoding.detectEncoding(content);
    try testing.expectEqual(Encoding.UTF8, result.encoding);
}

// ============================================================
// Line ending detection tests
// ============================================================

test "detect LF line ending" {
    const content = "line1\nline2\nline3";
    const result = encoding.detectLineEnding(content);
    try testing.expectEqual(LineEnding.LF, result);
}

test "detect CRLF line ending" {
    const content = "line1\r\nline2\r\nline3";
    const result = encoding.detectLineEnding(content);
    try testing.expectEqual(LineEnding.CRLF, result);
}

test "detect CR line ending" {
    const content = "line1\rline2\rline3";
    const result = encoding.detectLineEnding(content);
    try testing.expectEqual(LineEnding.CR, result);
}

test "default to LF for no line endings" {
    const content = "single line";
    const result = encoding.detectLineEnding(content);
    try testing.expectEqual(LineEnding.LF, result);
}

// ============================================================
// Binary detection tests
// ============================================================

test "detect binary content with NULL byte" {
    const content = "Hello\x00World";
    try testing.expect(encoding.isBinaryContent(content));
}

test "text content is not binary" {
    const content = "Hello World";
    try testing.expect(!encoding.isBinaryContent(content));
}

test "binary detection returns Unknown encoding" {
    const content = "Hello\x00World";
    const result = encoding.detectEncoding(content);
    try testing.expectEqual(Encoding.Unknown, result.encoding);
}

// ============================================================
// Line ending normalization tests
// ============================================================

test "normalize CRLF to LF" {
    const content = "line1\r\nline2\r\n";
    const result = try encoding.normalizeLineEndings(testing.allocator, content, .CRLF);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("line1\nline2\n", result);
}

test "normalize CR to LF" {
    const content = "line1\rline2\r";
    const result = try encoding.normalizeLineEndings(testing.allocator, content, .CR);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("line1\nline2\n", result);
}

test "LF stays unchanged" {
    const content = "line1\nline2\n";
    const result = try encoding.normalizeLineEndings(testing.allocator, content, .LF);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("line1\nline2\n", result);
}

// ============================================================
// Line ending conversion tests
// ============================================================

test "convert LF to CRLF" {
    const content = "line1\nline2\n";
    const result = try encoding.convertLineEndings(testing.allocator, content, .CRLF);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("line1\r\nline2\r\n", result);
}

test "convert LF to CR" {
    const content = "line1\nline2\n";
    const result = try encoding.convertLineEndings(testing.allocator, content, .CR);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("line1\rline2\r", result);
}

// ============================================================
// UTF-8 BOM conversion tests
// ============================================================

test "convert UTF-8 BOM to UTF-8 removes BOM" {
    const content = "\xEF\xBB\xBFHello";
    const result = try encoding.convertToUtf8(testing.allocator, content, .UTF8_BOM);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("Hello", result);
}

test "convert from UTF-8 to UTF-8 BOM adds BOM" {
    const content = "Hello";
    const result = try encoding.convertFromUtf8(testing.allocator, content, .UTF8_BOM);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 8), result.len); // 3 (BOM) + 5 (Hello)
    try testing.expectEqual(@as(u8, 0xEF), result[0]);
    try testing.expectEqual(@as(u8, 0xBB), result[1]);
    try testing.expectEqual(@as(u8, 0xBF), result[2]);
    try testing.expectEqualStrings("Hello", result[3..]);
}

// ============================================================
// UTF-16 conversion tests
// ============================================================

test "convert UTF-16LE to UTF-8" {
    // "AB" in UTF-16LE with BOM
    const content = "\xFF\xFEA\x00B\x00";
    const result = try encoding.convertToUtf8(testing.allocator, content, .UTF16LE_BOM);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("AB", result);
}

test "convert UTF-16BE to UTF-8" {
    // "AB" in UTF-16BE with BOM
    const content = "\xFE\xFF\x00A\x00B";
    const result = try encoding.convertToUtf8(testing.allocator, content, .UTF16BE_BOM);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("AB", result);
}

test "convert UTF-8 to UTF-16LE" {
    const content = "AB";
    const result = try encoding.convertFromUtf8(testing.allocator, content, .UTF16LE_BOM);
    defer testing.allocator.free(result);
    // BOM (2) + "A" (2) + "B" (2) = 6 bytes
    try testing.expectEqual(@as(usize, 6), result.len);
    try testing.expectEqual(@as(u8, 0xFF), result[0]); // BOM LE
    try testing.expectEqual(@as(u8, 0xFE), result[1]);
    try testing.expectEqual(@as(u8, 'A'), result[2]);
    try testing.expectEqual(@as(u8, 0x00), result[3]);
}

test "convert UTF-8 to UTF-16BE" {
    const content = "AB";
    const result = try encoding.convertFromUtf8(testing.allocator, content, .UTF16BE_BOM);
    defer testing.allocator.free(result);
    // BOM (2) + "A" (2) + "B" (2) = 6 bytes
    try testing.expectEqual(@as(usize, 6), result.len);
    try testing.expectEqual(@as(u8, 0xFE), result[0]); // BOM BE
    try testing.expectEqual(@as(u8, 0xFF), result[1]);
    try testing.expectEqual(@as(u8, 0x00), result[2]);
    try testing.expectEqual(@as(u8, 'A'), result[3]);
}

// ============================================================
// Encoding toString tests
// ============================================================

test "Encoding toString" {
    try testing.expectEqualStrings("UTF-8", Encoding.UTF8.toString());
    try testing.expectEqualStrings("UTF-8-BOM", Encoding.UTF8_BOM.toString());
    try testing.expectEqualStrings("UTF-16LE", Encoding.UTF16LE_BOM.toString());
    try testing.expectEqualStrings("UTF-16BE", Encoding.UTF16BE_BOM.toString());
    try testing.expectEqualStrings("Shift_JIS", Encoding.SHIFT_JIS.toString());
    try testing.expectEqualStrings("EUC-JP", Encoding.EUC_JP.toString());
    try testing.expectEqualStrings("Unknown", Encoding.Unknown.toString());
}

test "LineEnding toString" {
    try testing.expectEqualStrings("LF", LineEnding.LF.toString());
    try testing.expectEqualStrings("CRLF", LineEnding.CRLF.toString());
    try testing.expectEqualStrings("CR", LineEnding.CR.toString());
}

test "LineEnding toBytes" {
    try testing.expectEqualStrings("\n", LineEnding.LF.toBytes());
    try testing.expectEqualStrings("\r\n", LineEnding.CRLF.toBytes());
    try testing.expectEqualStrings("\r", LineEnding.CR.toBytes());
}

// ============================================================
// Edge cases
// ============================================================

test "empty content detection" {
    const content = "";
    const result = encoding.detectEncoding(content);
    try testing.expectEqual(Encoding.UTF8, result.encoding);
    try testing.expectEqual(LineEnding.LF, result.line_ending);
}

test "single byte content" {
    const content = "a";
    const result = encoding.detectEncoding(content);
    try testing.expectEqual(Encoding.UTF8, result.encoding);
}

test "convert Unknown encoding returns error" {
    const content = "test";
    const result = encoding.convertToUtf8(testing.allocator, content, .Unknown);
    try testing.expectError(error.UnsupportedEncoding, result);
}
