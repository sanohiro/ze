// Unicode Grapheme Cluster support for ze editor
//
// Based on ziglyph (MIT License) by Jose Colon Rodriguez
// https://codeberg.org/dude_the_builder/ziglyph
//
// Implements Unicode Standard Annex #29 (Text Segmentation)
// https://www.unicode.org/reports/tr29/
//
// MAINTENANCE NOTE:
// This implementation is based on Unicode 15.0 (2022).
// When new emojis or grapheme cluster rules are added in future Unicode versions:
// 1. Check Unicode release notes: https://www.unicode.org/versions/latest/
// 2. Update emoji ranges in isExtendedPictographic()
// 3. Update combining character ranges in isExtend() if needed
// 4. Test with new emoji sequences
//
// Typical update frequency: Every 2-3 years, 10-20 lines of changes
// Last reviewed: 2024-12

const std = @import("std");
const config = @import("config");
const ASCII = config.ASCII;
const UTF8 = config.UTF8;

// Grapheme Break Property types
// These determine whether two codepoints should be kept together as a grapheme cluster

/// Check if codepoint is CR (Carriage Return)
inline fn isCr(cp: u21) bool {
    return cp == '\r';
}

/// Check if codepoint is LF (Line Feed)
inline fn isLf(cp: u21) bool {
    return cp == '\n';
}

/// Check if codepoint is a Control character
inline fn isControl(cp: u21) bool {
    // ASCII control characters (C0: 0x00-0x1F, DEL: 0x7F, C1: 0x80-0x9F)
    if (cp <= ASCII.CTRL_MAX or (cp >= ASCII.DEL and cp <= 0x9F)) return true;

    // Unicode control characters (subset for performance)
    return switch (cp) {
        0xAD => true,           // Soft hyphen
        0x200B => true,         // Zero width space
        0x200E...0x200F => true, // Left-to-right/Right-to-left mark
        0x2028 => true,         // Line separator
        0x2029 => true,         // Paragraph separator
        0x202A...0x202E => true, // Embedding/Override controls
        0x2060...0x2064 => true, // Word joiner, etc
        0xFEFF => true,         // Zero width no-break space
        else => false,
    };
}

/// Check if codepoint is an Extend character (combining marks, etc)
/// OPTIMIZE: Using ranges for fast branch prediction
inline fn isExtend(cp: u21) bool {
    // Early exit for ASCII (most common case)
    if (cp < 0x300) return false;

    return switch (cp) {
        // Combining Diacritical Marks (most common)
        0x0300...0x036F => true,

        // Variation Selectors (emoji modifiers)
        0xFE00...0xFE0F => true,

        // Common combining marks
        0x0483...0x0489 => true,  // Cyrillic
        0x0591...0x05BD => true,  // Hebrew
        0x0610...0x061A => true,  // Arabic
        0x064B...0x065F => true,  // Arabic
        0x0670 => true,           // Arabic
        0x06D6...0x06ED => true,  // Arabic

        // Devanagari and related scripts
        0x0901...0x0903 => true,
        0x093A...0x093C => true,
        0x093E...0x094F => true,
        0x0951...0x0957 => true,
        0x0962...0x0963 => true,

        // Other important combining marks (subset)
        0x1AB0...0x1ACE => true,  // Combining Diacritical Marks Extended
        0x1DC0...0x1DFF => true,  // Combining Diacritical Marks Supplement
        0x20D0...0x20FF => true,  // Combining Diacritical Marks for Symbols
        0xFE20...0xFE2F => true,  // Combining Half Marks

        // Emoji skin tone modifiers
        0x1F3FB...0x1F3FF => true,

        else => false,
    };
}

/// Check if codepoint is Zero Width Joiner (used in emoji sequences)
inline fn isZwj(cp: u21) bool {
    return cp == 0x200D;
}

/// Check if codepoint is a Spacing Mark
inline fn isSpacingMark(cp: u21) bool {
    // Subset of spacing marks for performance
    return switch (cp) {
        0x0903 => true,           // Devanagari
        0x093B => true,           // Devanagari
        0x093E...0x0940 => true,  // Devanagari
        0x0949...0x094C => true,  // Devanagari
        0x094E...0x094F => true,  // Devanagari
        0x0982...0x0983 => true,  // Bengali
        0x09BF...0x09C0 => true,  // Bengali
        0x09C7...0x09C8 => true,  // Bengali
        0x09CB...0x09CC => true,  // Bengali
        else => false,
    };
}

/// Check if codepoint is a Prepend character
inline fn isPrepend(cp: u21) bool {
    // Subset for performance (only common cases)
    return switch (cp) {
        0x0600...0x0605 => true,  // Arabic number signs
        0x06DD => true,           // Arabic end of ayah
        0x070F => true,           // Syriac abbreviation mark
        0x0890...0x0891 => true,  // Arabic pound/piastre sign
        0x08E2 => true,           // Arabic disputed end of ayah
        else => false,
    };
}

/// Check if codepoint is a Regional Indicator (for flag emojis)
inline fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// Check if codepoint is an Extended Pictographic (emoji)
/// OPTIMIZE: Grouped by frequency of use for better branch prediction
inline fn isExtendedPictographic(cp: u21) bool {
    // Most common emoji ranges first
    return switch (cp) {
        // Emoticons (most frequently used)
        0x1F600...0x1F64F => true,

        // Transport and Map symbols
        0x1F680...0x1F6FF => true,

        // Supplemental Symbols and Pictographs
        0x1F900...0x1F9FF => true,

        // Miscellaneous Symbols and Pictographs
        0x1F300...0x1F5FF => true,

        // Symbols and Pictographs Extended-A
        0x1FA70...0x1FAFF => true,

        // Miscellaneous Symbols and Dingbats (merged ranges)
        0x2600...0x27BF => true,

        // Playing cards, Mahjong tiles
        0x1F0A0...0x1F0FF => true,

        // Enclosed characters and Regional Indicators
        0x1F100...0x1F1FF => true,

        // Additional common symbols (not in main ranges)
        0x231A...0x231B => true,  // Watch, Hourglass
        0x2328 => true,           // Keyboard
        0x23CF => true,           // Eject symbol
        0x23E9...0x23F3 => true,  // Media symbols
        0x23F8...0x23FA => true,  // Media symbols
        0x24C2 => true,           // Circled Latin Capital Letter M
        0x2B1B...0x2B1C => true,  // Black/White Large Square
        0x2B50 => true,           // Star
        0x2B55 => true,           // Circle

        else => false,
    };
}

/// Hangul syllable support (Korean)
inline fn isHangulL(cp: u21) bool {
    return cp >= 0x1100 and cp <= 0x115F;
}

inline fn isHangulV(cp: u21) bool {
    return cp >= 0x1160 and cp <= 0x11A7;
}

inline fn isHangulT(cp: u21) bool {
    return cp >= 0x11A8 and cp <= 0x11FF;
}

inline fn isHangulLV(cp: u21) bool {
    // Precomposed LV syllables
    if (cp < 0xAC00 or cp > 0xD7A3) return false;
    return (cp - 0xAC00) % 28 == 0;
}

inline fn isHangulLVT(cp: u21) bool {
    // Precomposed LVT syllables
    if (cp < 0xAC00 or cp > 0xD7A3) return false;
    return (cp - 0xAC00) % 28 != 0;
}

/// Check if codepoint breaks grapheme cluster (GB4)
inline fn isBreaker(cp: u21) bool {
    return isCr(cp) or isLf(cp) or isControl(cp);
}

/// State flags for grapheme break algorithm
pub const State = packed struct {
    regional: bool = false,  // Tracking Regional Indicator pairs
    xpic: bool = false,      // Tracking Extended Pictographic for ZWJ sequences
    _unused: u6 = 0,
};

/// Determine if there should be a grapheme break between two codepoints
/// This is the core algorithm from UAX #29
/// OPTIMIZE: Rules ordered by frequency for better branch prediction
pub fn graphemeBreak(cp1: u21, cp2: u21, state: *State) bool {
    // GB11: Track Extended Pictographic for emoji ZWJ sequences
    if (!state.xpic and isExtendedPictographic(cp1)) {
        state.xpic = true;
    }

    // GB3: CR × LF (don't break CRLF)
    if (isCr(cp1) and isLf(cp2)) return false;

    // GB4: (Control | CR | LF) ÷ (break after controls)
    if (isBreaker(cp1)) {
        state.* = .{};  // Reset state - sequence broken
        return true;
    }

    // GB5: ÷ (Control | CR | LF) (break before controls)
    if (isBreaker(cp2)) {
        state.* = .{};  // Reset state - sequence broken
        return true;
    }

    // GB9: × (Extend | ZWJ) (don't break before extends/ZWJ)
    // This is the most common case for emoji with modifiers
    if (isExtend(cp2) or isZwj(cp2)) return false;

    // GB9a: × SpacingMark (don't break before spacing marks)
    if (isSpacingMark(cp2)) return false;

    // GB9b: Prepend × (don't break after prepend)
    if (isPrepend(cp1) and !isBreaker(cp2)) return false;

    // GB12, GB13: Regional Indicator × Regional Indicator
    // Flags are made of two Regional Indicator symbols
    if (isRegionalIndicator(cp1) and isRegionalIndicator(cp2)) {
        if (state.regional) {
            state.* = .{};  // Reset all state - pair complete
            return true;  // Break after pair
        } else {
            state.regional = true;
            return false; // Don't break, forming pair
        }
    }

    // GB11: \p{Extended_Pictographic} Extend* ZWJ × \p{Extended_Pictographic}
    // This handles complex emoji sequences like 👨‍👩‍👧‍👦
    if (state.xpic and isZwj(cp1) and isExtendedPictographic(cp2)) {
        state.xpic = false;
        return false;
    }

    // Hangul syllable rules (Korean)
    // GB6: Hangul L × (L | V | LV | LVT)
    if (isHangulL(cp1) and
        (isHangulL(cp2) or isHangulV(cp2) or isHangulLV(cp2) or isHangulLVT(cp2))) {
        return false;
    }

    // GB7: Hangul (LV | V) × (V | T)
    if ((isHangulLV(cp1) or isHangulV(cp1)) and
        (isHangulV(cp2) or isHangulT(cp2))) {
        return false;
    }

    // GB8: Hangul (LVT | T) × T
    if ((isHangulLVT(cp1) or isHangulT(cp1)) and isHangulT(cp2)) {
        return false;
    }

    // GB999: Any ÷ Any (default: break between everything else)
    state.* = .{};  // Reset state - sequence broken
    return true;
}

/// Calculate display width of a codepoint (East Asian Width)
/// OPTIMIZE: ASCII fast path first, then ranges by frequency
pub fn displayWidth(cp: u21) usize {
    // Fast path: ASCII (most common) + DEL
    if (cp <= ASCII.MAX) {
        if (cp < ASCII.PRINTABLE_MIN or cp == ASCII.DEL) return 0; // Control chars including DEL
        return 1;
    }

    // Wide characters (East Asian Width = W or F)
    // Emoji and symbols (width 2)
    // Note: Check Extended Pictographic BEFORE Extend, because skin tone modifiers
    // (0x1F3FB-0x1F3FF) are both Extend AND Extended Pictographic
    if (isExtendedPictographic(cp)) return 2;

    // Zero-width characters (結合文字は幅0)
    // ZWJおよびExtend文字（結合アクセント等）は幅0
    if (cp == 0x200D or isExtend(cp)) {
        return 0;
    }

    // CJK and other wide characters
    if ((cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x9FFF) or // CJK Ideographs
        (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE10 and cp <= 0xFE19) or // Vertical forms
        (cp >= 0xFE30 and cp <= 0xFE6F) or // CJK Compatibility Forms
        (cp >= 0xFF00 and cp <= 0xFF60) or // Fullwidth Forms
        (cp >= 0xFFE0 and cp <= 0xFFE6) or // Fullwidth Forms
        (cp >= 0x20000 and cp <= 0x2FFFD) or // CJK Extension B-E
        (cp >= 0x30000 and cp <= 0x3FFFD)) // CJK Extension F-G
    {
        return 2;
    }

    // Default: narrow (width 1)
    return 1;
}

/// 文字種（単語境界の検出用）
pub const CharType = enum {
    alnum, // 英数字・アンダースコア
    hiragana, // ひらがな
    katakana, // カタカナ
    kanji, // 漢字
    space, // 空白
    other, // その他（記号など）
};

/// 文字種を判定
pub fn getCharType(cp: u21) CharType {
    // 英数字とアンダースコア
    if ((cp >= 'a' and cp <= 'z') or
        (cp >= 'A' and cp <= 'Z') or
        (cp >= '0' and cp <= '9') or
        cp == '_')
    {
        return .alnum;
    }

    // 空白文字
    if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') {
        return .space;
    }

    // ひらがな（U+3040〜U+309F）
    if (cp >= 0x3040 and cp <= 0x309F) {
        return .hiragana;
    }

    // カタカナ（U+30A0〜U+30FF）
    if (cp >= 0x30A0 and cp <= 0x30FF) {
        return .katakana;
    }

    // 漢字（CJK統合漢字）
    // U+4E00〜U+9FFF: CJK Unified Ideographs
    // U+3400〜U+4DBF: CJK Unified Ideographs Extension A
    if ((cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0x3400 and cp <= 0x4DBF))
    {
        return .kanji;
    }

    // その他の記号
    return .other;
}

/// 単語文字判定（バイト用 - ASCII英数字とアンダースコア）
/// regex.zig と editing_context.zig で共通使用
pub inline fn isWordCharByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// スライスの指定位置からコードポイントをデコード
/// 戻り値: (コードポイント, バイト長) または null
pub fn decodeCodepointAt(data: []const u8, pos: usize) ?struct { cp: u21, len: usize } {
    if (pos >= data.len) return null;
    const first = data[pos];

    // ASCII高速パス
    if (first < 0x80) {
        return .{ .cp = first, .len = 1 };
    }

    // UTF-8バイト数を判定
    const len = std.unicode.utf8ByteSequenceLength(first) catch return null;
    if (pos + len > data.len) return null;

    const cp = std.unicode.utf8Decode(data[pos..][0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

/// スライスの指定位置の文字種を取得（日本語対応）
/// decodeCodepointAt + getCharType の共通パターン
pub fn getCharTypeAt(data: []const u8, pos: usize) CharType {
    if (decodeCodepointAt(data, pos)) |decoded| {
        return getCharType(decoded.cp);
    }
    return .other;
}

/// ASCII範囲判定（バイト用）
pub inline fn isAsciiByte(byte: u8) bool {
    return byte <= ASCII.MAX;
}

/// コードポイントをASCII文字に変換（ASCII外は0を返す）
pub inline fn toAsciiChar(cp: u21) u8 {
    return if (cp <= ASCII.MAX) @truncate(cp) else 0;
}

/// UTF-8シーケンス長を取得（先頭バイトから判定）
pub inline fn utf8SeqLen(first_byte: u8) usize {
    return if (first_byte <= ASCII.MAX) 1 else if (first_byte < UTF8.BYTE3_MIN) 2 else if (first_byte < UTF8.BYTE4_MIN) 3 else 4;
}

/// UTF-8の先頭バイトかどうか（継続バイトでない）
pub inline fn isUtf8Start(byte: u8) bool {
    return byte <= ASCII.MAX or (byte & UTF8.CONTINUATION_MASK) == UTF8.CONTINUATION_MASK;
}

/// UTF-8の継続バイトかどうか（10xxxxxx形式）
pub inline fn isUtf8Continuation(byte: u8) bool {
    return (byte & UTF8.CONTINUATION_MASK) == UTF8.CONTINUATION_PATTERN;
}

/// ANSIエスケープシーケンスの開始かどうか（ESC [）
pub inline fn isAnsiEscapeStart(c: u8, next: u8) bool {
    return c == ASCII.ESC and next == ASCII.CSI_BRACKET;
}

/// 全角英数記号（U+FF01〜U+FF5E）を半角（U+0021〜U+007E）に変換
pub inline fn normalizeFullwidth(cp: u21) u21 {
    if (cp >= 0xFF01 and cp <= 0xFF5E) {
        return cp - 0xFF00 + 0x20;
    }
    return cp;
}

/// 文字列配列の共通プレフィックスを見つける
/// 全要素を走査して最短の共通プレフィックスを計算
pub fn findCommonPrefix(strings: []const []const u8) []const u8 {
    if (strings.len == 0) return "";
    if (strings.len == 1) return strings[0];

    const first = strings[0];
    var common_len: usize = first.len;

    // 全要素と比較して共通プレフィックス長を縮める
    for (strings[1..]) |s| {
        const min_len = @min(common_len, s.len);
        var i: usize = 0;
        while (i < min_len and first[i] == s[i]) : (i += 1) {}
        common_len = i;
        if (common_len == 0) break; // もう共通部分がない
    }

    return first[0..common_len];
}

/// グラフェムクラスタの情報
pub const GraphemeCluster = struct {
    /// クラスタのバイト長
    byte_len: usize,
    /// クラスタの表示幅（カラム数）
    display_width: usize,
};

/// 次のグラフェムクラスタを取得する
/// 文字列の先頭から1つのグラフェムクラスタを読み取り、そのバイト長と表示幅を返す
/// ZWJシーケンス（家族絵文字など）や結合文字を正しく処理する
///
/// 【表示幅の計算ルール】
/// ターミナルはグラフェムクラスタ全体を1つのグリフとして描画する。
/// - 単一コードポイント: そのコードポイントのdisplayWidth
/// - ZWJシーケンス（👨‍👩‍👧‍👦等）: 最初のベース文字の幅（通常2）
/// - 結合文字付き文字: ベース文字の幅
/// - 国旗（🇯🇵等）: 2（2つのRegional Indicatorで1つのグリフ）
///
/// 最適化: ASCII高速パス（最も一般的なケースを高速処理）
pub fn nextGraphemeCluster(str: []const u8) ?GraphemeCluster {
    if (str.len == 0) return null;

    const first_byte = str[0];

    // ASCII高速パス: 0x00-0x7Fは単独でグラフェムクラスタを形成
    // ただし制御文字(0x00-0x1F, 0x7F)は幅0、印字可能文字は幅1
    if (first_byte <= ASCII.MAX) {
        const width: usize = if (first_byte < ASCII.PRINTABLE_MIN or first_byte == ASCII.DEL) 0 else 1;
        return GraphemeCluster{ .byte_len = 1, .display_width = width };
    }

    // マルチバイトUTF-8のフルパス
    var byte_pos: usize = 0;
    var base_width: usize = 0; // 最初のベース文字の幅
    var state = State{};
    var prev_cp: u21 = 0;
    var first_codepoint = true;

    while (byte_pos < str.len) {
        const c = str[byte_pos];

        // UTF-8シーケンス長計算（inline関数なので性能影響なし）
        const seq_len: usize = utf8SeqLen(c);

        // 不完全なUTF-8シーケンス: 残りバイトが足りない
        if (byte_pos + seq_len > str.len) {
            if (first_codepoint) {
                return GraphemeCluster{ .byte_len = 1, .display_width = 1 };
            }
            break;
        }

        // インラインUTF-8デコード（2-4バイトシーケンス用の高速パス）
        const cp: u21 = switch (seq_len) {
            1 => @as(u21, c),
            2 => blk: {
                const b1 = str[byte_pos + 1];
                if (!isUtf8Continuation(b1)) {
                    if (first_codepoint) return GraphemeCluster{ .byte_len = 1, .display_width = 1 };
                    break;
                }
                break :blk (@as(u21, c & 0x1F) << 6) | @as(u21, b1 & 0x3F);
            },
            3 => blk: {
                const b1 = str[byte_pos + 1];
                const b2 = str[byte_pos + 2];
                if (!isUtf8Continuation(b1) or !isUtf8Continuation(b2)) {
                    if (first_codepoint) return GraphemeCluster{ .byte_len = 1, .display_width = 1 };
                    break;
                }
                break :blk (@as(u21, c & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | @as(u21, b2 & 0x3F);
            },
            4 => blk: {
                const b1 = str[byte_pos + 1];
                const b2 = str[byte_pos + 2];
                const b3 = str[byte_pos + 3];
                if (!isUtf8Continuation(b1) or !isUtf8Continuation(b2) or !isUtf8Continuation(b3)) {
                    if (first_codepoint) return GraphemeCluster{ .byte_len = 1, .display_width = 1 };
                    break;
                }
                break :blk (@as(u21, c & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) | (@as(u21, b2 & 0x3F) << 6) | @as(u21, b3 & 0x3F);
            },
            else => unreachable,
        };

        if (first_codepoint) {
            base_width = displayWidth(cp);
            prev_cp = cp;
            byte_pos += seq_len;
            first_codepoint = false;
            continue;
        }

        // グラフェムブレイクをチェック
        if (graphemeBreak(prev_cp, cp, &state)) {
            break;
        }

        prev_cp = cp;
        byte_pos += seq_len;
    }

    if (byte_pos == 0) return null;

    return GraphemeCluster{
        .byte_len = byte_pos,
        .display_width = base_width,
    };
}

/// 文字列の表示幅（カラム数）を計算
/// グラフェムクラスタを使用してZWJ絵文字等も正しく処理
pub fn stringDisplayWidth(str: []const u8) usize {
    var width: usize = 0;
    var pos: usize = 0;
    while (pos < str.len) {
        const cluster = nextGraphemeCluster(str[pos..]) orelse break;
        width += cluster.display_width;
        pos += cluster.byte_len;
    }
    return width;
}

/// 前のグラフェムクラスタの開始位置を見つける
/// ZWJ絵文字やスキントーン修飾子を含む複合文字を正しく扱う
/// 用途: バックスペース、左カーソル移動
pub fn findPrevGraphemeStart(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    const target = @min(pos, text.len);

    // 先頭から順にグラフェムクラスタを列挙し、
    // target直前の境界を見つける
    var last_boundary: usize = 0;
    var current_pos: usize = 0;

    while (current_pos < target) {
        const cluster = nextGraphemeCluster(text[current_pos..]) orelse break;
        // 防御的チェック: byte_len == 0 の場合は無限ループを防ぐ
        if (cluster.byte_len == 0) break;
        const next_pos = current_pos + cluster.byte_len;

        if (next_pos >= target) {
            // このクラスタがtargetを含むか超える
            return current_pos;
        }

        last_boundary = next_pos;
        current_pos = next_pos;
    }

    return last_boundary;
}

/// 次のグラフェムクラスタの終端位置を見つける
/// 用途: デリート、右カーソル移動
pub fn findNextGraphemeEnd(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    const cluster = nextGraphemeCluster(text[pos..]) orelse return text.len;
    return @min(pos + cluster.byte_len, text.len);
}
