// ============================================================================
// zeエディタのエンコーディング・改行コード処理
// ============================================================================
//
// 【設計方針】
// - 内部形式は常にUTF-8 + LF（Unix標準）
// - ファイル読み込み時: 自動検出 → UTF-8に変換 → LFに正規化
// - ファイル保存時: 元のエンコーディング・改行コードに復元
//
// 【サポートするエンコーディング】
// - UTF-8 (BOM有無両対応)
// - UTF-16LE/BE (BOM必須、Windows/Javaでよく使用)
// - Shift_JIS (Windows日本語環境のレガシー)
// - EUC-JP (Unix日本語環境のレガシー)
//
// 【日本語エンコーディングの検出】
// BOMがない場合、バイトパターンのヒューリスティックで判定。
// Shift_JISとEUC-JPは重複する範囲があるため、スコアリングで判定。
// ============================================================================

const std = @import("std");
const config = @import("config");
const unicode = @import("unicode");
const jis_kanji_table = @import("jis_kanji_table");

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

/// バイナリファイル判定
/// NULLバイトだけでなく、制御文字の頻度も考慮
pub fn isBinaryContent(content: []const u8) bool {
    // 先頭8KBをチェック（全体をチェックすると大きいファイルで遅い）
    const check_size = @min(content.len, 8192);
    var control_count: usize = 0;

    for (content[0..check_size]) |byte| {
        // NULLバイトは即座にバイナリ判定
        if (byte == 0) return true;

        // 制御文字（タブ、改行、CRを除く）
        if (byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') {
            control_count += 1;
        }
        // DEL (0x7F)
        if (byte == 0x7F) {
            control_count += 1;
        }
    }

    // 制御文字が5%を超えたらバイナリ
    if (check_size > 0 and control_count * 20 > check_size) {
        return true;
    }

    return false;
}

/// エンコーディングと改行コードを自動検出
pub fn detectEncoding(content: []const u8) DetectionResult {
    // ステップ1: BOM検出（最優先、UTF-16はNULLバイトを含むのでBOM検出を先に）
    if (content.len >= config.BOM.UTF8.len and
        std.mem.startsWith(u8, content, &config.BOM.UTF8))
    {
        return .{
            .encoding = .UTF8_BOM,
            .line_ending = detectLineEnding(content[config.BOM.UTF8.len..]),
        };
    }
    if (content.len >= config.BOM.UTF16LE.len and
        std.mem.startsWith(u8, content, &config.BOM.UTF16LE))
    {
        return .{
            .encoding = .UTF16LE_BOM,
            .line_ending = .LF, // UTF-16は変換後に改行検出
        };
    }
    if (content.len >= config.BOM.UTF16BE.len and
        std.mem.startsWith(u8, content, &config.BOM.UTF16BE))
    {
        return .{
            .encoding = .UTF16BE_BOM,
            .line_ending = .LF,
        };
    }

    // ステップ2: バイナリ判定（BOM付きUTF-16を除外した後で判定）
    if (isBinaryContent(content)) {
        return .{ .encoding = .Unknown, .line_ending = .LF };
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
/// 最適化: 先頭8KBをサンプリング。改行が見つからない場合は最大64KBまで拡張
/// 64KBでも見つからない場合（minified JSONなど長大な1行）はファイル全体をスキャン
/// 混在改行コードがある場合は優先順位: CRLF > LF > CR で判定
pub fn detectLineEnding(content: []const u8) LineEnding {
    // 初期サンプリングサイズ: 8KB
    const initial_sample_size: usize = 8 * 1024;
    // 中間サンプリングサイズ: 64KB
    const mid_sample_size: usize = 64 * 1024;

    var has_crlf = false;
    var has_lf = false;
    var has_cr = false;
    var found_any_newline = false;

    // まず初期サンプルサイズで検索
    var sample_end: usize = @min(content.len, initial_sample_size);
    var i: usize = 0;

    while (i < sample_end) {
        if (content[i] == '\r') {
            found_any_newline = true;
            if (i + 1 < content.len and content[i + 1] == '\n') {
                has_crlf = true;
                i += 2;
                continue;
            } else {
                has_cr = true;
                i += 1;
                continue;
            }
        } else if (content[i] == '\n') {
            found_any_newline = true;
            has_lf = true;
        }
        i += 1;

        // 改行が見つからないまま現在の範囲を使い切った場合、範囲を拡張
        if (i >= sample_end and !found_any_newline and sample_end < content.len) {
            // 64KBまでは段階的に拡張、その後はファイル全体をスキャン
            if (sample_end < mid_sample_size) {
                sample_end = @min(content.len, mid_sample_size);
            } else {
                // 64KBでも見つからない場合はファイル全体をスキャン
                // （minified JSON等の長大な1行ファイル対応）
                sample_end = content.len;
            }
        }
    }

    // 優先順位: CRLF > LF > CR
    if (has_crlf) return .CRLF;
    if (has_lf) return .LF;
    if (has_cr) return .CR;
    return .LF; // デフォルト
}

/// Valid UTF-8判定
/// RFC 3629準拠: オーバーロングエンコーディング、サロゲート範囲、無効な範囲を拒否
fn isValidUtf8(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len) {
        const byte = content[i];

        // ASCII (0x00-0x7F)
        if (byte <= config.ASCII.MAX) {
            i += 1;
            continue;
        }

        // 0x80-0xBF: 継続バイトが先頭に来るのは不正
        // 0xC0-0xC1: オーバーロング（2バイトでASCII範囲を表現）
        if (byte <= 0xC1) {
            return false;
        }

        // 2バイト文字 (0xC2-0xDF)
        if (byte <= config.UTF8.BYTE2_MAX) {
            if (i + 1 >= content.len) return false;
            if (!unicode.isUtf8Continuation(content[i + 1])) return false;
            i += 2;
            continue;
        }

        // 3バイト文字 (0xE0-0xEF)
        if (byte <= config.UTF8.BYTE3_MAX) {
            if (i + 2 >= content.len) return false;
            const b1 = content[i + 1];
            const b2 = content[i + 2];
            if (!unicode.isUtf8Continuation(b1)) return false;
            if (!unicode.isUtf8Continuation(b2)) return false;

            // オーバーロング検出: 0xE0の後は0xA0-0xBFのみ有効
            if (byte == 0xE0 and b1 < 0xA0) return false;

            // サロゲート範囲（U+D800-U+DFFF）の拒否: 0xED 0xA0以上
            if (byte == 0xED and b1 >= 0xA0) return false;

            i += 3;
            continue;
        }

        // 4バイト文字 (0xF0-0xF4)
        // 0xF5以上は無効（U+10FFFFを超える）
        if (byte <= 0xF4) {
            if (i + 3 >= content.len) return false;
            const b1 = content[i + 1];
            const b2 = content[i + 2];
            const b3 = content[i + 3];
            if (!unicode.isUtf8Continuation(b1)) return false;
            if (!unicode.isUtf8Continuation(b2)) return false;
            if (!unicode.isUtf8Continuation(b3)) return false;

            // オーバーロング検出: 0xF0の後は0x90-0xBFのみ有効
            if (byte == 0xF0 and b1 < 0x90) return false;

            // 範囲制限: 0xF4の後は0x80-0x8Fのみ有効（U+10FFFF以下）
            if (byte == 0xF4 and b1 > 0x8F) return false;

            i += 4;
            continue;
        }

        // 0xF5-0xFF: 無効なバイト
        return false;
    }

    return true;
}

// UTF-8の継続バイト判定は unicode.isUtf8Continuation() を使用

/// 日本語エンコーディングを推測（Shift_JIS vs EUC-JP）
///
/// 【判定アルゴリズム】
/// Shift_JISとEUC-JPはバイト範囲が重複するため、確実な判定は不可能。
/// そこでスコアリング方式を採用：
///
/// - Shift_JIS特有パターン（0x81-0x9F で始まる2バイト文字）→ 強い証拠
/// - EUC-JP特有パターン（0x8E/0x8Fプレフィックス）→ 強い証拠
/// - 両方で有効なパターン → 弱い証拠
///
/// 最終的にスコアが高い方を採用。同点ならShift_JIS（Windowsユーザーが多いため）
fn guessJapaneseEncoding(content: []const u8) Encoding {
    var sjis_score: usize = 0;
    var eucjp_score: usize = 0;

    var i: usize = 0;
    while (i < content.len) {
        const byte = content[i];

        // ASCII範囲はスキップ（両エンコーディングで共通）
        if (byte < 0x80) {
            i += 1;
            continue;
        }

        // ----------------------------------------
        // Shift_JIS特有の範囲 (0x81-0x9F)
        // この範囲はEUC-JPでは使用されないため、強い証拠となる
        // ----------------------------------------
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

    // スコア比較で判定（同点時はShift_JIS、Windowsユーザーが多いため）
    return if (eucjp_score > sjis_score) .EUC_JP else .SHIFT_JIS;
}

/// 改行コードを正規化（LFに統一）
/// 混在したCRLF/CR/LFを全てLFに変換する
/// line_endingパラメータは保存時に元の形式に戻すために使用（正規化処理自体には影響しない）
pub fn normalizeLineEndings(allocator: std.mem.Allocator, content: []const u8, line_ending: LineEnding) ![]u8 {
    _ = line_ending; // 正規化処理では使用しない（保存時の参考情報として呼び出し元で保持）

    // CR/CRLFが含まれているかチェック（なければコピーだけで済む）
    const has_cr = std.mem.indexOfScalar(u8, content, '\r') != null;
    if (!has_cr) {
        return try allocator.dupe(u8, content);
    }

    // CR/CRLFを全てLFに変換
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        if (content[i] == '\r') {
            // CRLF → LF または CR → LF
            try result.append(allocator, '\n');
            if (i + 1 < content.len and content[i + 1] == '\n') {
                i += 2; // CRLFの場合は2バイトスキップ
            } else {
                i += 1; // CRのみの場合は1バイトスキップ
            }
        } else {
            try result.append(allocator, content[i]);
            i += 1;
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

    // CRLFの場合は最大2倍になる可能性があるが、通常は改行は少ないのでcontent.lenで十分
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len);
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
            var result = try std.ArrayList(u8).initCapacity(allocator, content.len + 3);
            errdefer result.deinit(allocator);
            try result.appendSlice(allocator, &config.BOM.UTF8);
            try result.appendSlice(allocator, content);
            break :blk try result.toOwnedSlice(allocator);
        },
        .UTF16LE_BOM => try convertUtf8ToUtf16le(allocator, content),
        .UTF16BE_BOM => try convertUtf8ToUtf16be(allocator, content),
        .SHIFT_JIS => try convertUtf8ToShiftJis(allocator, content),
        .EUC_JP => try convertUtf8ToEucJp(allocator, content),
        .Unknown => return error.UnsupportedEncoding,
    };
}

/// UTF-16配列からUTF-8に変換する共通処理
fn convertUtf16ArrayToUtf8(allocator: std.mem.Allocator, utf16_array: []const u16) ![]u8 {
    // UTF-16からUTF-8への変換では最大3倍程度になる（サロゲートペア考慮）
    var result = try std.ArrayList(u8).initCapacity(allocator, utf16_array.len * 3);
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

    return try convertUtf16ArrayToUtf8(allocator, utf16_array);
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

    return try convertUtf16ArrayToUtf8(allocator, utf16_array);
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
        // ku が 94 を超える場合は無効
        if (ku > 94) return null;
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

/// 漢字テーブル検索（JIS X 0208 完全テーブル使用）
fn lookupKanji(ku: u8, ten: u8) ?u21 {
    return jis_kanji_table.kanjiJisToUnicode(ku, ten);
}

// ============================================================================
// UTF-8 → 他エンコーディング変換（保存用）
// ============================================================================
//
// 【変換の流れ】
// 1. UTF-8をコードポイント単位でデコード
// 2. コードポイントをターゲットエンコーディングにエンコード
//
// 【UTF-16の注意点】
// - BMP (U+0000-U+FFFF): 1つの16ビット値
// - Supplementary (U+10000以上): サロゲートペア（2つの16ビット値）
//   - High Surrogate: 0xD800-0xDBFF
//   - Low Surrogate: 0xDC00-0xDFFF
//
// 【日本語エンコーディングの制限】
// 完全な変換テーブル（約6000文字）は巨大なため、主要な文字のみサポート。
// 変換できない文字は '?' に置換される。
// ============================================================================

/// UTF-8からコードポイントをデコード（共通ヘルパー）
/// 戻り値: コードポイントと消費バイト数
const DecodeResult = struct { codepoint: u21, bytes: usize };

fn decodeUtf8Codepoint(content: []const u8, pos: usize) !DecodeResult {
    if (pos >= content.len) return error.InvalidUtf8;
    const byte = content[pos];

    // ASCII
    if (byte < 0x80) {
        return .{ .codepoint = @as(u21, byte), .bytes = 1 };
    }

    // 2バイト
    if (byte >= 0xC0 and byte <= 0xDF) {
        if (pos + 1 >= content.len) return error.InvalidUtf8;
        const second = content[pos + 1];
        if (!unicode.isUtf8Continuation(second)) return error.InvalidUtf8;
        const cp = (@as(u21, byte & 0x1F) << 6) | @as(u21, second & 0x3F);
        return .{ .codepoint = cp, .bytes = 2 };
    }

    // 3バイト
    if (byte >= 0xE0 and byte <= 0xEF) {
        if (pos + 2 >= content.len) return error.InvalidUtf8;
        const second = content[pos + 1];
        const third = content[pos + 2];
        if (!unicode.isUtf8Continuation(second)) return error.InvalidUtf8;
        if (!unicode.isUtf8Continuation(third)) return error.InvalidUtf8;
        const cp = (@as(u21, byte & 0x0F) << 12) |
            (@as(u21, second & 0x3F) << 6) |
            @as(u21, third & 0x3F);
        return .{ .codepoint = cp, .bytes = 3 };
    }

    // 4バイト
    if (byte >= 0xF0 and byte <= 0xF7) {
        if (pos + 3 >= content.len) return error.InvalidUtf8;
        const second = content[pos + 1];
        const third = content[pos + 2];
        const fourth = content[pos + 3];
        if (!unicode.isUtf8Continuation(second)) return error.InvalidUtf8;
        if (!unicode.isUtf8Continuation(third)) return error.InvalidUtf8;
        if (!unicode.isUtf8Continuation(fourth)) return error.InvalidUtf8;
        const cp = (@as(u21, byte & 0x07) << 18) |
            (@as(u21, second & 0x3F) << 12) |
            (@as(u21, third & 0x3F) << 6) |
            @as(u21, fourth & 0x3F);
        return .{ .codepoint = cp, .bytes = 4 };
    }

    return error.InvalidUtf8;
}

/// u16をエンディアンに従ってバイト列に追加
fn appendU16(result: *std.ArrayList(u8), allocator: std.mem.Allocator, val: u16, comptime big_endian: bool) !void {
    if (big_endian) {
        try result.append(allocator, @intCast(val >> 8));
        try result.append(allocator, @intCast(val & 0xFF));
    } else {
        try result.append(allocator, @intCast(val & 0xFF));
        try result.append(allocator, @intCast(val >> 8));
    }
}

/// UTF-8 → UTF-16 変換（共通実装）
fn convertUtf8ToUtf16(allocator: std.mem.Allocator, content: []const u8, comptime big_endian: bool) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len * 2 + 2);
    errdefer result.deinit(allocator);

    // BOMを追加
    const bom = if (big_endian) config.BOM.UTF16BE else config.BOM.UTF16LE;
    try result.appendSlice(allocator, &bom);

    // UTF-8をデコードしてUTF-16にエンコード
    var i: usize = 0;
    while (i < content.len) {
        const decoded = try decodeUtf8Codepoint(content, i);
        const codepoint = decoded.codepoint;
        i += decoded.bytes;

        // サロゲート範囲のチェック（UTF-8では不正なコードポイント）
        if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return error.InvalidUtf8;

        // UTF-16にエンコード
        if (codepoint < 0x10000) {
            try appendU16(&result, allocator, @intCast(codepoint), big_endian);
        } else {
            // サロゲートペア（U+10000以上）
            const adjusted = codepoint - 0x10000;
            const high: u16 = @intCast(0xD800 + (adjusted >> 10));
            const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
            try appendU16(&result, allocator, high, big_endian);
            try appendU16(&result, allocator, low, big_endian);
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// UTF-8 → UTF-16LE (BOM付き) 変換
fn convertUtf8ToUtf16le(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return convertUtf8ToUtf16(allocator, content, false);
}

/// UTF-8 → UTF-16BE (BOM付き) 変換
fn convertUtf8ToUtf16be(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    return convertUtf8ToUtf16(allocator, content, true);
}

/// UTF-8 → Shift_JIS 変換
fn convertUtf8ToShiftJis(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        const decoded = try decodeUtf8Codepoint(content, i);
        const codepoint = decoded.codepoint;
        i += decoded.bytes;

        // ASCII
        if (codepoint < 0x80) {
            try result.append(allocator, @intCast(codepoint));
            continue;
        }

        // 半角カナ (U+FF61-U+FF9F) → 0xA1-0xDF
        if (codepoint >= 0xFF61 and codepoint <= 0xFF9F) {
            try result.append(allocator, @intCast(codepoint - 0xFF61 + 0xA1));
            continue;
        }

        // Unicode → Shift_JIS変換
        if (unicodeToShiftJis(codepoint)) |sjis| {
            try result.append(allocator, sjis.byte1);
            if (sjis.byte2) |b2| {
                try result.append(allocator, b2);
            }
        } else {
            // 変換できない文字は '?' に
            try result.append(allocator, '?');
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// UTF-8 → EUC-JP 変換
fn convertUtf8ToEucJp(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, content.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) {
        const decoded = try decodeUtf8Codepoint(content, i);
        const codepoint = decoded.codepoint;
        i += decoded.bytes;

        // ASCII
        if (codepoint < 0x80) {
            try result.append(allocator, @intCast(codepoint));
            continue;
        }

        // 半角カナ (U+FF61-U+FF9F) → 0x8E + 0xA1-0xDF
        if (codepoint >= 0xFF61 and codepoint <= 0xFF9F) {
            try result.append(allocator, 0x8E);
            try result.append(allocator, @intCast(codepoint - 0xFF61 + 0xA1));
            continue;
        }

        // Unicode → EUC-JP変換
        if (unicodeToEucJp(codepoint)) |eucjp| {
            try result.append(allocator, eucjp.byte1);
            if (eucjp.byte2) |b2| {
                try result.append(allocator, b2);
            }
        } else {
            // 変換できない文字は '?' に
            try result.append(allocator, '?');
        }
    }

    return try result.toOwnedSlice(allocator);
}

/// Shift_JISバイト列
const ShiftJisBytes = struct {
    byte1: u8,
    byte2: ?u8,
};

/// EUC-JPバイト列
const EucJpBytes = struct {
    byte1: u8,
    byte2: ?u8,
};

/// Unicode → Shift_JIS 変換（逆引きテーブル）
fn unicodeToShiftJis(codepoint: u21) ?ShiftJisBytes {
    // ひらがな (U+3041-U+3093) → 4区
    if (codepoint >= 0x3041 and codepoint <= 0x3093) {
        const ten: u8 = @intCast(codepoint - 0x3041 + 1);
        const sjis = jisToShiftJis(4, ten);
        return .{ .byte1 = sjis.byte1, .byte2 = sjis.byte2 };
    }

    // カタカナ (U+30A1-U+30F6) → 5区
    if (codepoint >= 0x30A1 and codepoint <= 0x30F6) {
        const ten: u8 = @intCast(codepoint - 0x30A1 + 1);
        const sjis = jisToShiftJis(5, ten);
        return .{ .byte1 = sjis.byte1, .byte2 = sjis.byte2 };
    }

    // 全角数字 (U+FF10-U+FF19) → 3区17-26
    if (codepoint >= 0xFF10 and codepoint <= 0xFF19) {
        const ten: u8 = @intCast(codepoint - 0xFF10 + 17);
        const sjis = jisToShiftJis(3, ten);
        return .{ .byte1 = sjis.byte1, .byte2 = sjis.byte2 };
    }

    // 全角大文字 (U+FF21-U+FF3A) → 3区33-58
    if (codepoint >= 0xFF21 and codepoint <= 0xFF3A) {
        const ten: u8 = @intCast(codepoint - 0xFF21 + 33);
        const sjis = jisToShiftJis(3, ten);
        return .{ .byte1 = sjis.byte1, .byte2 = sjis.byte2 };
    }

    // 全角小文字 (U+FF41-U+FF5A) → 3区65-90
    if (codepoint >= 0xFF41 and codepoint <= 0xFF5A) {
        const ten: u8 = @intCast(codepoint - 0xFF41 + 65);
        const sjis = jisToShiftJis(3, ten);
        return .{ .byte1 = sjis.byte1, .byte2 = sjis.byte2 };
    }

    // 1区の記号
    if (unicodeToKu1Ten(codepoint)) |ten| {
        const sjis = jisToShiftJis(1, ten);
        return .{ .byte1 = sjis.byte1, .byte2 = sjis.byte2 };
    }

    // 漢字の逆引き
    if (unicodeToKanjiKuTen(codepoint)) |ku_ten| {
        const sjis = jisToShiftJis(ku_ten.ku, ku_ten.ten);
        return .{ .byte1 = sjis.byte1, .byte2 = sjis.byte2 };
    }

    return null;
}

/// Unicode → EUC-JP 変換（逆引きテーブル）
fn unicodeToEucJp(codepoint: u21) ?EucJpBytes {
    // ひらがな (U+3041-U+3093) → 4区
    if (codepoint >= 0x3041 and codepoint <= 0x3093) {
        const ten: u8 = @intCast(codepoint - 0x3041 + 1);
        return .{ .byte1 = 4 + 0xA0, .byte2 = ten + 0xA0 };
    }

    // カタカナ (U+30A1-U+30F6) → 5区
    if (codepoint >= 0x30A1 and codepoint <= 0x30F6) {
        const ten: u8 = @intCast(codepoint - 0x30A1 + 1);
        return .{ .byte1 = 5 + 0xA0, .byte2 = ten + 0xA0 };
    }

    // 全角数字 (U+FF10-U+FF19) → 3区17-26
    if (codepoint >= 0xFF10 and codepoint <= 0xFF19) {
        const ten: u8 = @intCast(codepoint - 0xFF10 + 17);
        return .{ .byte1 = 3 + 0xA0, .byte2 = ten + 0xA0 };
    }

    // 全角大文字 (U+FF21-U+FF3A) → 3区33-58
    if (codepoint >= 0xFF21 and codepoint <= 0xFF3A) {
        const ten: u8 = @intCast(codepoint - 0xFF21 + 33);
        return .{ .byte1 = 3 + 0xA0, .byte2 = ten + 0xA0 };
    }

    // 全角小文字 (U+FF41-U+FF5A) → 3区65-90
    if (codepoint >= 0xFF41 and codepoint <= 0xFF5A) {
        const ten: u8 = @intCast(codepoint - 0xFF41 + 65);
        return .{ .byte1 = 3 + 0xA0, .byte2 = ten + 0xA0 };
    }

    // 1区の記号
    if (unicodeToKu1Ten(codepoint)) |ten| {
        return .{ .byte1 = 1 + 0xA0, .byte2 = ten + 0xA0 };
    }

    // 漢字の逆引き
    if (unicodeToKanjiKuTen(codepoint)) |ku_ten| {
        return .{ .byte1 = ku_ten.ku + 0xA0, .byte2 = ku_ten.ten + 0xA0 };
    }

    return null;
}

/// JIS区点番号 → Shift_JIS バイト列
fn jisToShiftJis(ku: u8, ten: u8) ShiftJisBytes {
    var byte1: u8 = undefined;
    var byte2: u8 = undefined;

    // 第1バイト計算
    if (ku <= 62) {
        byte1 = ((ku + 1) / 2) + 0x80;
        if (byte1 >= 0xA0) byte1 += 0x40;
    } else {
        byte1 = ((ku - 62 + 1) / 2) + 0xDF;
    }

    // 第2バイト計算
    if (ku % 2 == 1) {
        // 奇数区
        if (ten <= 63) {
            byte2 = ten + 0x3F;
        } else {
            byte2 = ten + 0x40;
        }
    } else {
        // 偶数区
        byte2 = ten + 0x9E;
    }

    return .{ .byte1 = byte1, .byte2 = byte2 };
}

/// Unicode → 1区の点番号（記号）
fn unicodeToKu1Ten(codepoint: u21) ?u8 {
    // 1区の記号テーブル（逆引き用）
    const table = [_]struct { unicode: u21, ten: u8 }{
        .{ .unicode = 0x3000, .ten = 1 }, //
        .{ .unicode = 0x3001, .ten = 2 }, // 、
        .{ .unicode = 0x3002, .ten = 3 }, // 。
        .{ .unicode = 0xFF0C, .ten = 4 }, // ，
        .{ .unicode = 0xFF0E, .ten = 5 }, // ．
        .{ .unicode = 0x30FB, .ten = 6 }, // ・
        .{ .unicode = 0xFF1A, .ten = 7 }, // ：
        .{ .unicode = 0xFF1B, .ten = 8 }, // ；
        .{ .unicode = 0xFF1F, .ten = 9 }, // ？
        .{ .unicode = 0xFF01, .ten = 10 }, // ！
        .{ .unicode = 0x309B, .ten = 11 }, // ゛
        .{ .unicode = 0x309C, .ten = 12 }, // ゜
        .{ .unicode = 0x30FC, .ten = 28 }, // ー
        .{ .unicode = 0x2015, .ten = 29 }, // ―
        .{ .unicode = 0x2010, .ten = 30 }, // ‐
        .{ .unicode = 0xFF0F, .ten = 31 }, // ／
        .{ .unicode = 0xFF5E, .ten = 33 }, // ～
        .{ .unicode = 0x2225, .ten = 34 }, // ‖
        .{ .unicode = 0xFF5C, .ten = 35 }, // ｜
        .{ .unicode = 0x2026, .ten = 36 }, // …
        .{ .unicode = 0xFF08, .ten = 42 }, // （
        .{ .unicode = 0xFF09, .ten = 43 }, // ）
        .{ .unicode = 0xFF3B, .ten = 46 }, // ［
        .{ .unicode = 0xFF3D, .ten = 47 }, // ］
        .{ .unicode = 0xFF5B, .ten = 48 }, // ｛
        .{ .unicode = 0xFF5D, .ten = 49 }, // ｝
        .{ .unicode = 0x300C, .ten = 54 }, // 「
        .{ .unicode = 0x300D, .ten = 55 }, // 」
        .{ .unicode = 0x300E, .ten = 56 }, // 『
        .{ .unicode = 0x300F, .ten = 57 }, // 』
        .{ .unicode = 0xFF0B, .ten = 60 }, // ＋
        .{ .unicode = 0xFF0D, .ten = 61 }, // －
        .{ .unicode = 0xFF1D, .ten = 65 }, // ＝
        .{ .unicode = 0xFF1C, .ten = 67 }, // ＜
        .{ .unicode = 0xFF1E, .ten = 68 }, // ＞
        .{ .unicode = 0xFFE5, .ten = 79 }, // ￥
        .{ .unicode = 0xFF04, .ten = 80 }, // ＄
        .{ .unicode = 0xFF05, .ten = 83 }, // ％
        .{ .unicode = 0xFF03, .ten = 84 }, // ＃
        .{ .unicode = 0xFF06, .ten = 85 }, // ＆
        .{ .unicode = 0xFF0A, .ten = 86 }, // ＊
        .{ .unicode = 0xFF20, .ten = 87 }, // ＠
    };

    for (table) |entry| {
        if (entry.unicode == codepoint) {
            return entry.ten;
        }
    }
    return null;
}

/// 区点番号
const KuTen = struct {
    ku: u8,
    ten: u8,
};

/// Unicode → 漢字の区点番号（逆引き、JIS X 0208 完全テーブル使用）
fn unicodeToKanjiKuTen(codepoint: u21) ?KuTen {
    if (jis_kanji_table.unicodeToKanjiKuTen(codepoint)) |result| {
        return .{ .ku = result.ku, .ten = result.ten };
    }
    return null;
}
