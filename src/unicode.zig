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
    // ASCII control characters
    if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F)) return true;

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
    if (isBreaker(cp1)) return true;

    // GB5: ÷ (Control | CR | LF) (break before controls)
    if (isBreaker(cp2)) return true;

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
            state.regional = false;
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
    return true;
}

/// Calculate display width of a codepoint (East Asian Width)
/// OPTIMIZE: ASCII fast path first, then ranges by frequency
pub fn displayWidth(cp: u21) usize {
    // Fast path: ASCII (most common)
    if (cp < 0x7F) {
        if (cp < 0x20 or cp == 0x7F) return 0; // Control chars
        return 1;
    }

    // Zero-width characters
    if (cp == 0x200D or // ZWJ
        (cp >= 0xFE00 and cp <= 0xFE0F) or // Variation Selectors
        (cp >= 0x0300 and cp <= 0x036F) or // Combining marks
        (cp >= 0x1F3FB and cp <= 0x1F3FF)) // Skin tone modifiers
    {
        return 0;
    }

    // Wide characters (East Asian Width = W or F)
    // Emoji and symbols (width 2)
    if (isExtendedPictographic(cp)) return 2;

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
