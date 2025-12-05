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
        .SHIFT_JIS => return error.UnsupportedEncoding, // TODO: 実装予定
        .EUC_JP => return error.UnsupportedEncoding, // TODO: 実装予定
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
