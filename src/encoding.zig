// zeエディタのエンコーディング・改行コード処理
// 検出、変換、保存時の復元を担当

const std = @import("std");
const config = @import("config.zig");

/// サポートするエンコーディング
pub const Encoding = enum {
    UTF8,           // UTF-8（デフォルト）
    UTF8_BOM,       // UTF-8 with BOM
    UTF16LE_BOM,    // UTF-16LE with BOM
    UTF16BE_BOM,    // UTF-16BE with BOM
    SHIFT_JIS,      // Shift_JIS/CP932
    EUC_JP,         // EUC-JP
    Unknown,        // 検出失敗（バイナリ扱い）

    pub fn toString(self: Encoding) []const u8 {
        return switch (self) {
            .UTF8 => "UTF-8",
            .UTF8_BOM => "UTF-8-BOM",
            .UTF16LE_BOM => "UTF-16LE",
            .UTF16BE_BOM => "UTF-16BE",
            .SHIFT_JIS => "Shift_JIS",
            .EUC_JP => "EUC-JP",
            .Unknown => "Unknown",
        };
    }
};

/// 改行コード
pub const LineEnding = enum {
    LF,     // Unix/Linux/macOS (\n)
    CRLF,   // Windows (\r\n)
    CR,     // Classic Mac OS (\r)

    pub fn toString(self: LineEnding) []const u8 {
        return switch (self) {
            .LF => "LF",
            .CRLF => "CRLF",
            .CR => "CR",
        };
    }

    pub fn toBytes(self: LineEnding) []const u8 {
        return switch (self) {
            .LF => "\n",
            .CRLF => "\r\n",
            .CR => "\r",
        };
    }
};

/// 検出結果
pub const DetectionResult = struct {
    encoding: Encoding,
    line_ending: LineEnding,
};

/// バイナリファイル判定（NULLバイトの有無）
pub fn isBinaryContent(content: []const u8) bool {
    // 先頭8KBをチェック（全体をチェックすると大きいファイルで遅い）
    const check_size = @min(content.len, 8192);
    for (content[0..check_size]) |byte| {
        if (byte == 0) return true;
    }
    return false;
}

/// エンコーディングと改行コードを自動検出
pub fn detectEncoding(content: []const u8) DetectionResult {
    // ステップ1: バイナリ判定（NULLバイトがあればUnknown）
    if (isBinaryContent(content)) {
        return .{ .encoding = .Unknown, .line_ending = .LF };
    }

    // ステップ2: BOM検出（確実な証拠）
    if (content.len >= 3 and
        content[0] == 0xEF and content[1] == 0xBB and content[2] == 0xBF)
    {
        return .{
            .encoding = .UTF8_BOM,
            .line_ending = detectLineEnding(content[3..]),
        };
    }
    if (content.len >= 2 and content[0] == 0xFF and content[1] == 0xFE) {
        return .{
            .encoding = .UTF16LE_BOM,
            .line_ending = .LF, // UTF-16は変換後に改行検出
        };
    }
    if (content.len >= 2 and content[0] == 0xFE and content[1] == 0xFF) {
        return .{
            .encoding = .UTF16BE_BOM,
            .line_ending = .LF,
        };
    }

    // ステップ3: Valid UTF-8判定（現代の標準）
    if (isValidUtf8(content)) {
        return .{
            .encoding = .UTF8,
            .line_ending = detectLineEnding(content),
        };
    }

    // ステップ4: 日本語レガシーエンコーディング（ヒューリスティック）
    const jp_encoding = guessJapaneseEncoding(content);
    return .{
        .encoding = jp_encoding,
        .line_ending = detectLineEnding(content),
    };
}

/// 改行コードを検出（LF/CRLF/CR）
pub fn detectLineEnding(content: []const u8) LineEnding {
    var has_crlf = false;
    var has_lf = false;
    var has_cr = false;

    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\r') {
            if (i + 1 < content.len and content[i + 1] == '\n') {
                has_crlf = true;
                i += 1; // \nをスキップ
            } else {
                has_cr = true;
            }
        } else if (content[i] == '\n') {
            has_lf = true;
        }
    }

    // 優先順位: CRLF > LF > CR
    if (has_crlf) return .CRLF;
    if (has_lf) return .LF;
    if (has_cr) return .CR;
    return .LF; // デフォルト
}

/// Valid UTF-8判定
fn isValidUtf8(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) {
        const byte = content[i];

        // ASCII (0x00-0x7F)
        if (byte < 0x80) {
            i += 1;
            continue;
        }

        // 2バイト文字 (0xC0-0xDF)
        if (byte >= 0xC0 and byte <= 0xDF) {
            if (i + 1 >= content.len) return false;
            if (!isContinuationByte(content[i + 1])) return false;
            i += 2;
            continue;
        }

        // 3バイト文字 (0xE0-0xEF)
        if (byte >= 0xE0 and byte <= 0xEF) {
            if (i + 2 >= content.len) return false;
            if (!isContinuationByte(content[i + 1])) return false;
            if (!isContinuationByte(content[i + 2])) return false;
            i += 3;
            continue;
        }

        // 4バイト文字 (0xF0-0xF7)
        if (byte >= 0xF0 and byte <= 0xF7) {
            if (i + 3 >= content.len) return false;
            if (!isContinuationByte(content[i + 1])) return false;
            if (!isContinuationByte(content[i + 2])) return false;
            if (!isContinuationByte(content[i + 3])) return false;
            i += 4;
            continue;
        }

        // 不正なバイト
        return false;
    }

    return true;
}

/// UTF-8の継続バイト判定 (0x80-0xBF)
fn isContinuationByte(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xBF;
}

/// 日本語エンコーディングを推測（Shift_JIS vs EUC-JP）
fn guessJapaneseEncoding(content: []const u8) Encoding {
    var sjis_score: usize = 0;
    var eucjp_score: usize = 0;

    var i: usize = 0;
    while (i < content.len) {
        const byte = content[i];

        // ASCII範囲はスキップ
        if (byte < 0x80) {
            i += 1;
            continue;
        }

        // Shift_JIS特有の範囲 (0x81-0x9F)
        if (byte >= 0x81 and byte <= 0x9F) {
            if (i + 1 < content.len) {
                const next = content[i + 1];
                if ((next >= 0x40 and next <= 0x7E) or
                    (next >= 0x80 and next <= 0xFC))
                {
                    sjis_score += 2; // 強い証拠
                    i += 2;
                    continue;
                }
            }
        }

        // Shift_JIS後半範囲 (0xE0-0xFC)
        if (byte >= 0xE0 and byte <= 0xFC) {
            if (i + 1 < content.len) {
                const next = content[i + 1];
                if ((next >= 0x40 and next <= 0x7E) or
                    (next >= 0x80 and next <= 0xFC))
                {
                    sjis_score += 1;
                    i += 2;
                    continue;
                }
            }
        }

        // 半角カナ (Shift_JISでは1バイト: 0xA1-0xDF)
        if (byte >= 0xA1 and byte <= 0xDF) {
            if (i + 1 < content.len) {
                const next = content[i + 1];
                if (next < 0x80) {
                    // 次がASCII → Shift_JISの半角カナの可能性高い
                    sjis_score += 1;
                    i += 1;
                    continue;
                } else if (next >= 0xA1 and next <= 0xFE) {
                    // 次も0xA1以上 → EUC-JPの2バイト文字
                    eucjp_score += 2;
                    i += 2;
                    continue;
                }
            }
            i += 1;
            continue;
        }

        // EUC-JP範囲 (0xA1-0xFE)
        if (byte >= 0xA1 and byte <= 0xFE) {
            if (i + 1 < content.len) {
                const next = content[i + 1];
                if (next >= 0xA1 and next <= 0xFE) {
                    eucjp_score += 2;
                    i += 2;
                    continue;
                }
            }
        }

        // EUC-JP半角カナ (0x8E 0xA1-0xDF)
        if (byte == 0x8E) {
            if (i + 1 < content.len) {
                const next = content[i + 1];
                if (next >= 0xA1 and next <= 0xDF) {
                    eucjp_score += 2;
                    i += 2;
                    continue;
                }
            }
        }

        // EUC-JP補助漢字 (0x8F ...)
        if (byte == 0x8F) {
            if (i + 2 < content.len) {
                const next1 = content[i + 1];
                const next2 = content[i + 2];
                if (next1 >= 0xA1 and next1 <= 0xFE and
                    next2 >= 0xA1 and next2 <= 0xFE)
                {
                    eucjp_score += 3; // 強い証拠
                    i += 3;
                    continue;
                }
            }
        }

        i += 1;
    }

    // スコア比較で判定
    if (sjis_score > eucjp_score) {
        return .SHIFT_JIS;
    } else if (eucjp_score > sjis_score) {
        return .EUC_JP;
    } else {
        // スコアが同じ、またはどちらも0
        // デフォルトでShift_JIS（Windowsユーザーが多いため）
        return .SHIFT_JIS;
    }
}

/// 改行コードを正規化（LFに統一）
pub fn normalizeLineEndings(allocator: std.mem.Allocator, content: []const u8, line_ending: LineEnding) ![]u8 {
    // LFならそのまま
    if (line_ending == .LF) {
        return try allocator.dupe(u8, content);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (line_ending == .CRLF) {
            // CRLF → LF
            if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') {
                try result.append(allocator, '\n');
                i += 2;
            } else {
                try result.append(allocator, content[i]);
                i += 1;
            }
        } else if (line_ending == .CR) {
            // CR → LF
            if (content[i] == '\r') {
                try result.append(allocator, '\n');
                i += 1;
            } else {
                try result.append(allocator, content[i]);
                i += 1;
            }
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// LFから指定の改行コードへ変換
pub fn convertLineEndings(allocator: std.mem.Allocator, content: []const u8, target: LineEnding) ![]u8 {
    // LFならそのまま
    if (target == .LF) {
        return try allocator.dupe(u8, content);
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer result.deinit(allocator);

    for (content) |byte| {
        if (byte == '\n') {
            // LF → target
            const ending = target.toBytes();
            try result.appendSlice(allocator, ending);
        } else {
            try result.append(allocator, byte);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// エンコーディングをUTF-8に変換
/// 戻り値: UTF-8に変換されたコンテンツ（呼び出し側がfreeする責任を持つ）
pub fn convertToUtf8(allocator: std.mem.Allocator, content: []const u8, encoding: Encoding) ![]u8 {
    return switch (encoding) {
        .UTF8 => try allocator.dupe(u8, content),
        .UTF8_BOM => blk: {
            // BOMを削除
            if (content.len >= 3) {
                break :blk try allocator.dupe(u8, content[3..]);
            } else {
                break :blk try allocator.dupe(u8, content);
            }
        },
        .UTF16LE_BOM => try convertUtf16leToUtf8(allocator, content),
        .UTF16BE_BOM => try convertUtf16beToUtf8(allocator, content),
        .SHIFT_JIS => try convertShiftJisToUtf8(allocator, content),
        .EUC_JP => try convertEucJpToUtf8(allocator, content),
        .Unknown => return error.UnsupportedEncoding,
    };
}

/// UTF-8からエンコーディングへ変換（保存時用）
/// 戻り値: 指定エンコーディングに変換されたコンテンツ（呼び出し側がfreeする責任を持つ）
pub fn convertFromUtf8(allocator: std.mem.Allocator, content: []const u8, encoding: Encoding) ![]u8 {
    return switch (encoding) {
        .UTF8 => try allocator.dupe(u8, content),
        .UTF8_BOM => blk: {
            // BOMを追加
            var result = try std.ArrayList(u8).initCapacity(allocator, 1024);
            errdefer result.deinit(allocator);
            try result.appendSlice(allocator, &[_]u8{ 0xEF, 0xBB, 0xBF });
            try result.appendSlice(allocator, content);
            break :blk try result.toOwnedSlice(allocator);
        },
        .UTF16LE_BOM => return error.UnsupportedEncoding, // TODO: 実装予定
        .UTF16BE_BOM => return error.UnsupportedEncoding, // TODO: 実装予定
        .SHIFT_JIS => return error.UnsupportedEncoding, // TODO: 実装予定
        .EUC_JP => return error.UnsupportedEncoding, // TODO: 実装予定
        .Unknown => return error.UnsupportedEncoding,
    };
}

/// UTF-16LE (BOM付き) → UTF-8 変換
fn convertUtf16leToUtf8(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    // BOMをスキップ（先頭2バイト: 0xFF 0xFE）
    const utf16_bytes = if (content.len >= 2) content[2..] else content;

    // バイト数が奇数なら不正
    if (utf16_bytes.len % 2 != 0) {
        return error.InvalidUtf16;
    }

    // UTF-16のu16配列を作成（LE → ホストエンディアン）
    const u16_count = utf16_bytes.len / 2;
    const utf16_array = try allocator.alloc(u16, u16_count);
    defer allocator.free(utf16_array);

    for (0..u16_count) |i| {
        const byte_idx = i * 2;
        // Little Endian: 下位バイトが先
        utf16_array[i] = @as(u16, utf16_bytes[byte_idx]) |
                        (@as(u16, utf16_bytes[byte_idx + 1]) << 8);
    }

    // UTF-16 → UTF-8 変換（最大バイト数は元の3倍）
    var result = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < utf16_array.len) {
        const codepoint = blk: {
            const first = utf16_array[i];

            // サロゲートペア判定（U+D800-U+DBFF）
            if (first >= 0xD800 and first <= 0xDBFF) {
                if (i + 1 >= utf16_array.len) {
                    return error.InvalidUtf16; // 後続がない
                }
                const second = utf16_array[i + 1];
                if (second < 0xDC00 or second > 0xDFFF) {
                    return error.InvalidUtf16; // 不正なサロゲートペア
                }

                // サロゲートペアをデコード
                const high = @as(u32, first - 0xD800);
                const low = @as(u32, second - 0xDC00);
                const cp = 0x10000 + (high << 10) + low;
                i += 2;
                break :blk @as(u21, @intCast(cp));
            } else if (first >= 0xDC00 and first <= 0xDFFF) {
                return error.InvalidUtf16; // 単独の下位サロゲート
            } else {
                i += 1;
                break :blk @as(u21, @intCast(first));
            }
        };

        // codepointをUTF-8にエンコード
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = try std.unicode.utf8Encode(codepoint, &utf8_buf);
        try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
    }

    return try result.toOwnedSlice(allocator);
}

/// UTF-16BE (BOM付き) → UTF-8 変換
fn convertUtf16beToUtf8(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    // BOMをスキップ（先頭2バイト: 0xFE 0xFF）
    const utf16_bytes = if (content.len >= 2) content[2..] else content;

    // バイト数が奇数なら不正
    if (utf16_bytes.len % 2 != 0) {
        return error.InvalidUtf16;
    }

    // UTF-16のu16配列を作成（BE → ホストエンディアン）
    const u16_count = utf16_bytes.len / 2;
    const utf16_array = try allocator.alloc(u16, u16_count);
    defer allocator.free(utf16_array);

    for (0..u16_count) |i| {
        const byte_idx = i * 2;
        // Big Endian: 上位バイトが先
        utf16_array[i] = (@as(u16, utf16_bytes[byte_idx]) << 8) |
                        @as(u16, utf16_bytes[byte_idx + 1]);
    }

    // UTF-16 → UTF-8 変換（最大バイト数は元の3倍）
    var result = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < utf16_array.len) {
        const codepoint = blk: {
            const first = utf16_array[i];

            // サロゲートペア判定（U+D800-U+DBFF）
            if (first >= 0xD800 and first <= 0xDBFF) {
                if (i + 1 >= utf16_array.len) {
                    return error.InvalidUtf16; // 後続がない
                }
                const second = utf16_array[i + 1];
                if (second < 0xDC00 or second > 0xDFFF) {
                    return error.InvalidUtf16; // 不正なサロゲートペア
                }

                // サロゲートペアをデコード
                const high = @as(u32, first - 0xD800);
                const low = @as(u32, second - 0xDC00);
                const cp = 0x10000 + (high << 10) + low;
                i += 2;
                break :blk @as(u21, @intCast(cp));
            } else if (first >= 0xDC00 and first <= 0xDFFF) {
                return error.InvalidUtf16; // 単独の下位サロゲート
            } else {
                i += 1;
                break :blk @as(u21, @intCast(first));
            }
        };

        // codepointをUTF-8にエンコード
        var utf8_buf: [4]u8 = undefined;
        const utf8_len = try std.unicode.utf8Encode(codepoint, &utf8_buf);
        try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
    }

    return try result.toOwnedSlice(allocator);
}

/// Shift_JIS → UTF-8 変換
fn convertShiftJisToUtf8(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len * 3);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        const byte = content[i];

        // ASCII (0x00-0x7F) と 制御文字
        if (byte < 0x80) {
            try result.append(allocator, byte);
            i += 1;
            continue;
        }

        // 半角カナ (0xA1-0xDF) → U+FF61-U+FF9F
        if (byte >= 0xA1 and byte <= 0xDF) {
            const codepoint: u21 = 0xFF61 + @as(u21, byte - 0xA1);
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                try result.append(allocator, '?');
                i += 1;
                continue;
            };
            try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
            i += 1;
            continue;
        }

        // 2バイト文字
        if ((byte >= 0x81 and byte <= 0x9F) or (byte >= 0xE0 and byte <= 0xFC)) {
            if (i + 1 >= content.len) {
                try result.append(allocator, '?');
                i += 1;
                continue;
            }

            const byte2 = content[i + 1];
            if (!((byte2 >= 0x40 and byte2 <= 0x7E) or (byte2 >= 0x80 and byte2 <= 0xFC))) {
                try result.append(allocator, '?');
                i += 1;
                continue;
            }

            // Shift_JIS → JIS X 0208 区点番号 → Unicode
            if (sjisToUnicode(byte, byte2)) |codepoint| {
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                    try result.append(allocator, '?');
                    i += 2;
                    continue;
                };
                try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
            } else {
                try result.append(allocator, '?');
            }
            i += 2;
            continue;
        }

        // その他の不正なバイト
        try result.append(allocator, '?');
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// EUC-JP → UTF-8 変換
fn convertEucJpToUtf8(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len * 3);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        const byte = content[i];

        // ASCII (0x00-0x7F)
        if (byte < 0x80) {
            try result.append(allocator, byte);
            i += 1;
            continue;
        }

        // 半角カナ (0x8E + 0xA1-0xDF) → U+FF61-U+FF9F
        if (byte == 0x8E) {
            if (i + 1 >= content.len) {
                try result.append(allocator, '?');
                i += 1;
                continue;
            }
            const byte2 = content[i + 1];
            if (byte2 >= 0xA1 and byte2 <= 0xDF) {
                const codepoint: u21 = 0xFF61 + @as(u21, byte2 - 0xA1);
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                    try result.append(allocator, '?');
                    i += 2;
                    continue;
                };
                try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
                i += 2;
                continue;
            }
            try result.append(allocator, '?');
            i += 1;
            continue;
        }

        // 補助漢字 (0x8F + 2バイト) - 現在はスキップ
        if (byte == 0x8F) {
            if (i + 2 >= content.len) {
                try result.append(allocator, '?');
                i += 1;
                continue;
            }
            // 補助漢字は '?' に置換（完全なサポートは複雑）
            try result.append(allocator, '?');
            i += 3;
            continue;
        }

        // 2バイト文字 (0xA1-0xFE, 0xA1-0xFE)
        if (byte >= 0xA1 and byte <= 0xFE) {
            if (i + 1 >= content.len) {
                try result.append(allocator, '?');
                i += 1;
                continue;
            }
            const byte2 = content[i + 1];
            if (byte2 >= 0xA1 and byte2 <= 0xFE) {
                // EUC-JP → JIS X 0208 区点番号 → Unicode
                const ku = byte - 0xA0;
                const ten = byte2 - 0xA0;

                if (jisToUnicode(ku, ten)) |codepoint| {
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch {
                        try result.append(allocator, '?');
                        i += 2;
                        continue;
                    };
                    try result.appendSlice(allocator, utf8_buf[0..utf8_len]);
                } else {
                    try result.append(allocator, '?');
                }
                i += 2;
                continue;
            }
            try result.append(allocator, '?');
            i += 1;
            continue;
        }

        // その他の不正なバイト
        try result.append(allocator, '?');
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

/// Shift_JIS 2バイトコード → Unicode コードポイント
fn sjisToUnicode(byte1: u8, byte2: u8) ?u21 {
    // Shift_JIS → JIS X 0208 区点番号に変換
    var ku: u8 = undefined;
    var ten: u8 = undefined;

    // 第1バイトの変換
    if (byte1 >= 0x81 and byte1 <= 0x9F) {
        ku = (byte1 - 0x81) * 2 + 1;
    } else if (byte1 >= 0xE0 and byte1 <= 0xFC) {
        ku = (byte1 - 0xE0) * 2 + 63;
    } else {
        return null;
    }

    // 第2バイトの変換
    if (byte2 >= 0x40 and byte2 <= 0x7E) {
        ten = byte2 - 0x3F;
    } else if (byte2 >= 0x80 and byte2 <= 0x9E) {
        ten = byte2 - 0x40;
    } else if (byte2 >= 0x9F and byte2 <= 0xFC) {
        ten = byte2 - 0x9E;
        ku += 1;
    } else {
        return null;
    }

    return jisToUnicode(ku, ten);
}

/// JIS X 0208 区点番号 → Unicode コードポイント
fn jisToUnicode(ku: u8, ten: u8) ?u21 {
    // 区番号範囲チェック (1-94)
    if (ku < 1 or ku > 94 or ten < 1 or ten > 94) {
        return null;
    }

    // 1区: 記号（句読点など）
    if (ku == 1) {
        const table = [_]u21{
            0x3000, 0x3001, 0x3002, 0xFF0C, 0xFF0E, 0x30FB, 0xFF1A, 0xFF1B, // 　、。，．・：；
            0xFF1F, 0xFF01, 0x309B, 0x309C, 0x00B4, 0xFF40, 0x00A8, 0xFF3E, // ？！゛゜´｀¨＾
            0xFFE3, 0xFF3F, 0x30FD, 0x30FE, 0x309D, 0x309E, 0x3003, 0x4EDD, // ￣＿ヽヾゝゞ〃仝
            0x3005, 0x3006, 0x3007, 0x30FC, 0x2015, 0x2010, 0xFF0F, 0xFF3C, // 々〆〇ー―‐／＼
            0xFF5E, 0x2225, 0xFF5C, 0x2026, 0x2025, 0x2018, 0x2019, 0x201C, // ～‖｜…‥''""
            0x201D, 0xFF08, 0xFF09, 0x3014, 0x3015, 0xFF3B, 0xFF3D, 0xFF5B, // "（）〔〕［］｛
            0xFF5D, 0x3008, 0x3009, 0x300A, 0x300B, 0x300C, 0x300D, 0x300E, // ｝〈〉《》「」『
            0x300F, 0x3010, 0x3011, 0xFF0B, 0xFF0D, 0x00B1, 0x00D7, 0x00F7, // 』【】＋－±×÷
            0xFF1D, 0x2260, 0xFF1C, 0xFF1E, 0x2266, 0x2267, 0x221E, 0x2234, // ＝≠＜＞≦≧∞∴
            0x2642, 0x2640, 0x00B0, 0x2032, 0x2033, 0x2103, 0xFFE5, 0xFF04, // ♂♀°′″℃￥＄
            0xFFE0, 0xFFE1, 0xFF05, 0xFF03, 0xFF06, 0xFF0A, 0xFF20, 0x00A7, // ￠￡％＃＆＊＠§
            0x2606, 0x2605, 0x25CB, 0x25CF, 0x25CE, 0x25C7, // ☆★○●◎◇
        };
        if (ten <= table.len) {
            return table[ten - 1];
        }
        return null;
    }

    // 4区: ひらがな (U+3041-U+3093)
    if (ku == 4) {
        if (ten >= 1 and ten <= 83) {
            return 0x3041 + @as(u21, ten - 1);
        }
        return null;
    }

    // 5区: カタカナ (U+30A1-U+30F6)
    if (ku == 5) {
        if (ten >= 1 and ten <= 86) {
            return 0x30A1 + @as(u21, ten - 1);
        }
        return null;
    }

    // 3区: 全角数字・アルファベット
    if (ku == 3) {
        // 17-26: ０-９ (0xFF10-0xFF19)
        if (ten >= 17 and ten <= 26) {
            return 0xFF10 + @as(u21, ten - 17);
        }
        // 33-58: Ａ-Ｚ (0xFF21-0xFF3A)
        if (ten >= 33 and ten <= 58) {
            return 0xFF21 + @as(u21, ten - 33);
        }
        // 65-90: ａ-ｚ (0xFF41-0xFF5A)
        if (ten >= 65 and ten <= 90) {
            return 0xFF41 + @as(u21, ten - 65);
        }
        return null;
    }

    // 6区: ギリシャ文字
    if (ku == 6) {
        // 大文字 (1-24): Α-Ω
        if (ten >= 1 and ten <= 24) {
            const greek_upper = [_]u21{
                0x0391, 0x0392, 0x0393, 0x0394, 0x0395, 0x0396, 0x0397, 0x0398, // ΑΒΓΔΕΖΗΘ
                0x0399, 0x039A, 0x039B, 0x039C, 0x039D, 0x039E, 0x039F, 0x03A0, // ΙΚΛΜΝΞΟΠ
                0x03A1, 0x03A3, 0x03A4, 0x03A5, 0x03A6, 0x03A7, 0x03A8, 0x03A9, // ΡΣΤΥΦΧΨΩ
            };
            return greek_upper[ten - 1];
        }
        // 小文字 (33-56): α-ω
        if (ten >= 33 and ten <= 56) {
            const greek_lower = [_]u21{
                0x03B1, 0x03B2, 0x03B3, 0x03B4, 0x03B5, 0x03B6, 0x03B7, 0x03B8, // αβγδεζηθ
                0x03B9, 0x03BA, 0x03BB, 0x03BC, 0x03BD, 0x03BE, 0x03BF, 0x03C0, // ικλμνξοπ
                0x03C1, 0x03C3, 0x03C4, 0x03C5, 0x03C6, 0x03C7, 0x03C8, 0x03C9, // ρστυφχψω
            };
            return greek_lower[ten - 33];
        }
        return null;
    }

    // 7区: キリル文字
    if (ku == 7) {
        // 大文字 (1-33): А-Я
        if (ten >= 1 and ten <= 33) {
            const cyrillic_upper = [_]u21{
                0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0401, 0x0416, // АБВГДЕЁЖ
                0x0417, 0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, // ЗИЙКЛМНО
                0x041F, 0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, // ПРСТУФХЦ
                0x0427, 0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, // ЧШЩЪЫЬЭЮ
                0x042F, // Я
            };
            return cyrillic_upper[ten - 1];
        }
        // 小文字 (49-81): а-я
        if (ten >= 49 and ten <= 81) {
            const cyrillic_lower = [_]u21{
                0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0451, 0x0436, // абвгдеёж
                0x0437, 0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, // зийклмно
                0x043F, 0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, // прстуфхц
                0x0447, 0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, // чшщъыьэю
                0x044F, // я
            };
            return cyrillic_lower[ten - 49];
        }
        return null;
    }

    // 8区: 罫線素片
    if (ku == 8) {
        const box_drawing = [_]u21{
            0x2500, 0x2502, 0x250C, 0x2510, 0x2518, 0x2514, 0x251C, 0x252C, // ─│┌┐┘└├┬
            0x2524, 0x2534, 0x253C, 0x2501, 0x2503, 0x250F, 0x2513, 0x251B, // ┤┴┼━┃┏┓┛
            0x2517, 0x2523, 0x2533, 0x252B, 0x253B, 0x254B, 0x2520, 0x252F, // ┗┣┳┫┻╋┠┯
            0x2528, 0x2537, 0x253F, 0x251D, 0x2530, 0x2525, 0x2538, 0x2542, // ┨┷┿┝┰┥┸╂
        };
        if (ten <= box_drawing.len) {
            return box_drawing[ten - 1];
        }
        return null;
    }

    // 16-47区: 第一水準漢字、48-84区: 第二水準漢字
    // 漢字の完全なテーブルは巨大なので、外部ファイルまたは変換表を使うのが理想
    // ここでは主要な漢字のみサポート
    if (ku >= 16) {
        return lookupKanji(ku, ten);
    }

    return null;
}

/// 漢字テーブル検索（主要な漢字のみ）
fn lookupKanji(ku: u8, ten: u8) ?u21 {
    // 16区1点から順にインデックス計算
    const base_ku: usize = 16;
    if (ku < base_ku or ku > 84) return null;

    const idx = (@as(usize, ku - base_ku) * 94) + @as(usize, ten - 1);

    // 主要な漢字テーブル（よく使われる漢字を優先）
    // 完全なテーブルは約6000文字必要
    const kanji_table = [_]u21{
        // 16区: 亜唖娃阿哀愛挨姶逢葵茜穐悪握渥旭葦芦鯵梓圧斡扱宛姐虻飴絢綾鮎或粟袷安庵按暗案闇鞍杏...
        0x4E9C, 0x5516, 0x5A03, 0x963F, 0x54C0, 0x611B, 0x6328, 0x59F6, // 亜唖娃阿哀愛挨姶
        0x9022, 0x8475, 0x831C, 0x7A50, 0x60AA, 0x63E1, 0x6E25, 0x65ED, // 逢葵茜穐悪握渥旭
        0x8466, 0x82A6, 0x9BC9, 0x6893, 0x5727, 0x65A1, 0x6271, 0x5B9B, // 葦芦鯵梓圧斡扱宛
        0x59D0, 0x867B, 0x98F4, 0x7D62, 0x7DBE, 0x9B8E, 0x6216, 0x7C9F, // 姐虻飴絢綾鮎或粟
        0x88B7, 0x5B89, 0x5EB5, 0x6309, 0x6697, 0x6848, 0x95C7, 0x978D, // 袷安庵按暗案闇鞍
        0x674F, 0x4EE5, 0x4F0A, 0x4F4D, 0x4F9D, 0x5049, 0x56F2, 0x5937, // 杏以伊位依偉囲夷
        0x59D4, 0x5A01, 0x5C09, 0x60DF, 0x610F, 0x6170, 0x6613, 0x6905, // 委威尉惟意慰易椅
        0x70BA, 0x754F, 0x7570, 0x79FB, 0x7DAD, 0x7DEF, 0x80C3, 0x840E, // 為畏異移維緯胃萎
        0x8863, 0x8B02, 0x9055, 0x907A, 0x533B, 0x4E95, 0x4EA5, 0x57DF, // 衣謂違遺医井亥域
        0x80B2, 0x90C1, 0x78EF, 0x4E00, 0x58F1, 0x6EA2, 0x9038, 0x7A32, // 育郁磯一壱溢逸稲
        0x8328, 0x828B, 0x9C2F, 0x5141, 0x5370, 0x54BD, 0x54E1, 0x56E0, // 茨芋鰯允印咽員因
        0x59FB, 0x5F15, 0x98F2, 0x6DEB, 0x80E4, 0x852D, // 姻引飲淫胤蔭
    };

    if (idx < kanji_table.len) {
        return kanji_table[idx];
    }

    // テーブルにない漢字は null
    return null;
}
