// 簡易正規表現エンジン
// サポート: . * + ? [] [^] ^ $ \d \w \s \D \W \S \\
// 非サポート: キャプチャグループ、後方参照、先読み等の高度な機能

const std = @import("std");

pub const Regex = struct {
    pattern: []const u8,
    compiled: []const Instruction,
    allocator: std.mem.Allocator,

    pub const Instruction = union(enum) {
        literal: u8, // 単一文字
        any: void, // . (改行以外の任意の1文字)
        char_class: CharClass, // [] 文字クラス
        anchor_start: void, // ^ (行頭)
        anchor_end: void, // $ (行末)
        digit: void, // \d
        word: void, // \w
        space: void, // \s
        not_digit: void, // \D
        not_word: void, // \W
        not_space: void, // \S
        // 量指定子付き命令
        star_literal: u8, // x*
        plus_literal: u8, // x+
        question_literal: u8, // x?
        star_any: void, // .*
        plus_any: void, // .+
        question_any: void, // .?
        star_digit: void, // \d*
        plus_digit: void, // \d+
        question_digit: void, // \d?
        star_word: void, // \w*
        plus_word: void, // \w+
        question_word: void, // \w?
        star_space: void, // \s*
        plus_space: void, // \s+
        question_space: void, // \s?
        star_not_digit: void, // \D*
        plus_not_digit: void, // \D+
        question_not_digit: void, // \D?
        star_not_word: void, // \W*
        plus_not_word: void, // \W+
        question_not_word: void, // \W?
        star_not_space: void, // \S*
        plus_not_space: void, // \S+
        question_not_space: void, // \S?
        star_class: CharClass, // []+
        plus_class: CharClass, // []+
        question_class: CharClass, // []?
    };

    pub const CharClass = struct {
        ranges: []const Range,
        negated: bool,

        pub const Range = struct {
            start: u8,
            end: u8,
        };

        pub fn matches(self: CharClass, c: u8) bool {
            var found = false;
            for (self.ranges) |range| {
                if (c >= range.start and c <= range.end) {
                    found = true;
                    break;
                }
            }
            return if (self.negated) !found else found;
        }
    };

    pub const MatchResult = struct {
        start: usize,
        end: usize,
    };

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        var instructions = try std.ArrayList(Instruction).initCapacity(allocator, pattern.len);
        errdefer instructions.deinit(allocator);

        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];

            // 次の文字が量指定子かチェック
            const next_is_quantifier = i + 1 < pattern.len and
                (pattern[i + 1] == '*' or pattern[i + 1] == '+' or pattern[i + 1] == '?');

            switch (c) {
                '.' => {
                    if (next_is_quantifier) {
                        i += 1;
                        switch (pattern[i]) {
                            '*' => try instructions.append(allocator, .star_any),
                            '+' => try instructions.append(allocator, .plus_any),
                            '?' => try instructions.append(allocator, .question_any),
                            else => unreachable,
                        }
                    } else {
                        try instructions.append(allocator, .any);
                    }
                },
                '^' => try instructions.append(allocator, .anchor_start),
                '$' => try instructions.append(allocator, .anchor_end),
                '[' => {
                    const class_result = try parseCharClass(allocator, pattern[i..]);
                    i += class_result.consumed - 1;

                    // 量指定子チェック
                    if (i + 1 < pattern.len and
                        (pattern[i + 1] == '*' or pattern[i + 1] == '+' or pattern[i + 1] == '?'))
                    {
                        i += 1;
                        switch (pattern[i]) {
                            '*' => try instructions.append(allocator, .{ .star_class = class_result.class }),
                            '+' => try instructions.append(allocator, .{ .plus_class = class_result.class }),
                            '?' => try instructions.append(allocator, .{ .question_class = class_result.class }),
                            else => unreachable,
                        }
                    } else {
                        try instructions.append(allocator, .{ .char_class = class_result.class });
                    }
                },
                '\\' => {
                    if (i + 1 >= pattern.len) {
                        try instructions.append(allocator, .{ .literal = '\\' });
                    } else {
                        i += 1;
                        const escaped = pattern[i];

                        // 量指定子チェック
                        const esc_next_is_quantifier = i + 1 < pattern.len and
                            (pattern[i + 1] == '*' or pattern[i + 1] == '+' or pattern[i + 1] == '?');

                        if (esc_next_is_quantifier) {
                            i += 1;
                            const q = pattern[i];
                            switch (escaped) {
                                'd' => switch (q) {
                                    '*' => try instructions.append(allocator, .star_digit),
                                    '+' => try instructions.append(allocator, .plus_digit),
                                    '?' => try instructions.append(allocator, .question_digit),
                                    else => unreachable,
                                },
                                'D' => switch (q) {
                                    '*' => try instructions.append(allocator, .star_not_digit),
                                    '+' => try instructions.append(allocator, .plus_not_digit),
                                    '?' => try instructions.append(allocator, .question_not_digit),
                                    else => unreachable,
                                },
                                'w' => switch (q) {
                                    '*' => try instructions.append(allocator, .star_word),
                                    '+' => try instructions.append(allocator, .plus_word),
                                    '?' => try instructions.append(allocator, .question_word),
                                    else => unreachable,
                                },
                                'W' => switch (q) {
                                    '*' => try instructions.append(allocator, .star_not_word),
                                    '+' => try instructions.append(allocator, .plus_not_word),
                                    '?' => try instructions.append(allocator, .question_not_word),
                                    else => unreachable,
                                },
                                's' => switch (q) {
                                    '*' => try instructions.append(allocator, .star_space),
                                    '+' => try instructions.append(allocator, .plus_space),
                                    '?' => try instructions.append(allocator, .question_space),
                                    else => unreachable,
                                },
                                'S' => switch (q) {
                                    '*' => try instructions.append(allocator, .star_not_space),
                                    '+' => try instructions.append(allocator, .plus_not_space),
                                    '?' => try instructions.append(allocator, .question_not_space),
                                    else => unreachable,
                                },
                                'n' => switch (q) {
                                    '*' => try instructions.append(allocator, .{ .star_literal = '\n' }),
                                    '+' => try instructions.append(allocator, .{ .plus_literal = '\n' }),
                                    '?' => try instructions.append(allocator, .{ .question_literal = '\n' }),
                                    else => unreachable,
                                },
                                'r' => switch (q) {
                                    '*' => try instructions.append(allocator, .{ .star_literal = '\r' }),
                                    '+' => try instructions.append(allocator, .{ .plus_literal = '\r' }),
                                    '?' => try instructions.append(allocator, .{ .question_literal = '\r' }),
                                    else => unreachable,
                                },
                                't' => switch (q) {
                                    '*' => try instructions.append(allocator, .{ .star_literal = '\t' }),
                                    '+' => try instructions.append(allocator, .{ .plus_literal = '\t' }),
                                    '?' => try instructions.append(allocator, .{ .question_literal = '\t' }),
                                    else => unreachable,
                                },
                                else => switch (q) {
                                    '*' => try instructions.append(allocator, .{ .star_literal = escaped }),
                                    '+' => try instructions.append(allocator, .{ .plus_literal = escaped }),
                                    '?' => try instructions.append(allocator, .{ .question_literal = escaped }),
                                    else => unreachable,
                                },
                            }
                        } else {
                            const instr: Instruction = switch (escaped) {
                                'd' => .digit,
                                'D' => .not_digit,
                                'w' => .word,
                                'W' => .not_word,
                                's' => .space,
                                'S' => .not_space,
                                'n' => .{ .literal = '\n' },
                                'r' => .{ .literal = '\r' },
                                't' => .{ .literal = '\t' },
                                else => .{ .literal = escaped },
                            };
                            try instructions.append(allocator, instr);
                        }
                    }
                },
                '*', '+', '?' => {
                    // 単独の量指定子はリテラルとして扱う
                    try instructions.append(allocator, .{ .literal = c });
                },
                else => {
                    if (next_is_quantifier) {
                        i += 1;
                        switch (pattern[i]) {
                            '*' => try instructions.append(allocator, .{ .star_literal = c }),
                            '+' => try instructions.append(allocator, .{ .plus_literal = c }),
                            '?' => try instructions.append(allocator, .{ .question_literal = c }),
                            else => unreachable,
                        }
                    } else {
                        try instructions.append(allocator, .{ .literal = c });
                    }
                },
            }
            i += 1;
        }

        return Regex{
            .pattern = pattern,
            .compiled = try instructions.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    const CharClassResult = struct {
        class: CharClass,
        consumed: usize,
    };

    fn parseCharClass(allocator: std.mem.Allocator, pattern: []const u8) !CharClassResult {
        var ranges = try std.ArrayList(CharClass.Range).initCapacity(allocator, 8);
        errdefer ranges.deinit(allocator);

        var i: usize = 1; // skip '['
        var negated = false;

        if (i < pattern.len and pattern[i] == '^') {
            negated = true;
            i += 1;
        }

        if (i < pattern.len and pattern[i] == ']') {
            try ranges.append(allocator, .{ .start = ']', .end = ']' });
            i += 1;
        }

        while (i < pattern.len and pattern[i] != ']') {
            var c = pattern[i];

            if (c == '\\' and i + 1 < pattern.len) {
                i += 1;
                c = switch (pattern[i]) {
                    'd' => {
                        try ranges.append(allocator, .{ .start = '0', .end = '9' });
                        i += 1;
                        continue;
                    },
                    'w' => {
                        try ranges.append(allocator, .{ .start = 'a', .end = 'z' });
                        try ranges.append(allocator, .{ .start = 'A', .end = 'Z' });
                        try ranges.append(allocator, .{ .start = '0', .end = '9' });
                        try ranges.append(allocator, .{ .start = '_', .end = '_' });
                        i += 1;
                        continue;
                    },
                    's' => {
                        try ranges.append(allocator, .{ .start = ' ', .end = ' ' });
                        try ranges.append(allocator, .{ .start = '\t', .end = '\t' });
                        try ranges.append(allocator, .{ .start = '\n', .end = '\n' });
                        try ranges.append(allocator, .{ .start = '\r', .end = '\r' });
                        i += 1;
                        continue;
                    },
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => pattern[i],
                };
            }

            if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                var end_c = pattern[i + 2];
                if (end_c == '\\' and i + 3 < pattern.len) {
                    end_c = switch (pattern[i + 3]) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => pattern[i + 3],
                    };
                    i += 1;
                }
                try ranges.append(allocator, .{ .start = c, .end = end_c });
                i += 3;
            } else {
                try ranges.append(allocator, .{ .start = c, .end = c });
                i += 1;
            }
        }

        if (i < pattern.len and pattern[i] == ']') {
            i += 1;
        }

        return CharClassResult{
            .class = CharClass{
                .ranges = try ranges.toOwnedSlice(allocator),
                .negated = negated,
            },
            .consumed = i,
        };
    }

    pub fn deinit(self: *Regex) void {
        for (self.compiled) |instr| {
            switch (instr) {
                .char_class, .star_class, .plus_class, .question_class => |cc| self.allocator.free(cc.ranges),
                else => {},
            }
        }
        self.allocator.free(self.compiled);
    }

    pub fn search(self: *const Regex, text: []const u8, start_pos: usize) ?MatchResult {
        if (self.compiled.len == 0) return null;

        const has_start_anchor = self.compiled.len > 0 and self.compiled[0] == .anchor_start;

        var pos = start_pos;
        while (pos <= text.len) {
            if (has_start_anchor) {
                if (pos > 0 and text[pos - 1] != '\n') {
                    while (pos < text.len and text[pos] != '\n') {
                        pos += 1;
                    }
                    if (pos < text.len) {
                        pos += 1;
                    }
                    continue;
                }
            }

            if (self.matchAt(text, pos)) |end| {
                return MatchResult{ .start = pos, .end = end };
            }

            if (has_start_anchor) {
                while (pos < text.len and text[pos] != '\n') {
                    pos += 1;
                }
                if (pos < text.len) {
                    pos += 1;
                } else {
                    break;
                }
            } else {
                pos += 1;
            }
        }

        return null;
    }

    pub fn searchBackward(self: *const Regex, text: []const u8, start_pos: usize) ?MatchResult {
        if (self.compiled.len == 0) return null;

        var pos: usize = @min(start_pos, text.len);
        while (pos > 0) {
            pos -= 1;
            if (self.matchAt(text, pos)) |end| {
                return MatchResult{ .start = pos, .end = end };
            }
        }

        if (self.matchAt(text, 0)) |end| {
            return MatchResult{ .start = 0, .end = end };
        }

        return null;
    }

    fn matchAt(self: *const Regex, text: []const u8, start: usize) ?usize {
        return self.matchInstructions(text, start, 0);
    }

    fn matchInstructions(self: *const Regex, text: []const u8, text_pos: usize, instr_idx: usize) ?usize {
        var pos = text_pos;
        var idx = instr_idx;

        while (idx < self.compiled.len) {
            const instr = self.compiled[idx];

            switch (instr) {
                .literal => |c| {
                    if (pos >= text.len or text[pos] != c) return null;
                    pos += 1;
                },
                .any => {
                    if (pos >= text.len or text[pos] == '\n') return null;
                    pos += 1;
                },
                .char_class => |cc| {
                    if (pos >= text.len) return null;
                    if (!cc.matches(text[pos])) return null;
                    pos += 1;
                },
                .anchor_start => {
                    if (pos != 0 and (pos > text.len or text[pos - 1] != '\n')) return null;
                },
                .anchor_end => {
                    if (pos < text.len and text[pos] != '\n') return null;
                },
                .digit => {
                    if (pos >= text.len) return null;
                    if (!isDigit(text[pos])) return null;
                    pos += 1;
                },
                .not_digit => {
                    if (pos >= text.len) return null;
                    if (isDigit(text[pos])) return null;
                    pos += 1;
                },
                .word => {
                    if (pos >= text.len) return null;
                    if (!isWordChar(text[pos])) return null;
                    pos += 1;
                },
                .not_word => {
                    if (pos >= text.len) return null;
                    if (isWordChar(text[pos])) return null;
                    pos += 1;
                },
                .space => {
                    if (pos >= text.len) return null;
                    if (!isSpaceChar(text[pos])) return null;
                    pos += 1;
                },
                .not_space => {
                    if (pos >= text.len) return null;
                    if (isSpaceChar(text[pos])) return null;
                    pos += 1;
                },
                // 量指定子付き命令
                .star_literal => |c| {
                    return self.matchRepeatLiteral(text, pos, idx, c, 0, null);
                },
                .plus_literal => |c| {
                    return self.matchRepeatLiteral(text, pos, idx, c, 1, null);
                },
                .question_literal => |c| {
                    return self.matchRepeatLiteral(text, pos, idx, c, 0, 1);
                },
                .star_any => {
                    return self.matchRepeat(text, pos, idx, matchAny, 0, null);
                },
                .plus_any => {
                    return self.matchRepeat(text, pos, idx, matchAny, 1, null);
                },
                .question_any => {
                    return self.matchRepeat(text, pos, idx, matchAny, 0, 1);
                },
                .star_digit => {
                    return self.matchRepeat(text, pos, idx, matchDigit, 0, null);
                },
                .plus_digit => {
                    return self.matchRepeat(text, pos, idx, matchDigit, 1, null);
                },
                .question_digit => {
                    return self.matchRepeat(text, pos, idx, matchDigit, 0, 1);
                },
                .star_not_digit => {
                    return self.matchRepeat(text, pos, idx, matchNotDigit, 0, null);
                },
                .plus_not_digit => {
                    return self.matchRepeat(text, pos, idx, matchNotDigit, 1, null);
                },
                .question_not_digit => {
                    return self.matchRepeat(text, pos, idx, matchNotDigit, 0, 1);
                },
                .star_word => {
                    return self.matchRepeat(text, pos, idx, matchWord, 0, null);
                },
                .plus_word => {
                    return self.matchRepeat(text, pos, idx, matchWord, 1, null);
                },
                .question_word => {
                    return self.matchRepeat(text, pos, idx, matchWord, 0, 1);
                },
                .star_not_word => {
                    return self.matchRepeat(text, pos, idx, matchNotWord, 0, null);
                },
                .plus_not_word => {
                    return self.matchRepeat(text, pos, idx, matchNotWord, 1, null);
                },
                .question_not_word => {
                    return self.matchRepeat(text, pos, idx, matchNotWord, 0, 1);
                },
                .star_space => {
                    return self.matchRepeat(text, pos, idx, matchSpace, 0, null);
                },
                .plus_space => {
                    return self.matchRepeat(text, pos, idx, matchSpace, 1, null);
                },
                .question_space => {
                    return self.matchRepeat(text, pos, idx, matchSpace, 0, 1);
                },
                .star_not_space => {
                    return self.matchRepeat(text, pos, idx, matchNotSpace, 0, null);
                },
                .plus_not_space => {
                    return self.matchRepeat(text, pos, idx, matchNotSpace, 1, null);
                },
                .question_not_space => {
                    return self.matchRepeat(text, pos, idx, matchNotSpace, 0, 1);
                },
                .star_class => |cc| {
                    return self.matchRepeatClass(text, pos, idx, cc, 0, null);
                },
                .plus_class => |cc| {
                    return self.matchRepeatClass(text, pos, idx, cc, 1, null);
                },
                .question_class => |cc| {
                    return self.matchRepeatClass(text, pos, idx, cc, 0, 1);
                },
            }
            idx += 1;
        }

        return pos;
    }

    fn matchRepeatLiteral(
        self: *const Regex,
        text: []const u8,
        start_pos: usize,
        current_idx: usize,
        target: u8,
        min_count: usize,
        max_count: ?usize,
    ) ?usize {
        var positions: [1024]usize = undefined;
        var positions_len: usize = 1;
        positions[0] = start_pos;

        var pos = start_pos;
        var count: usize = 0;

        while (max_count == null or count < max_count.?) {
            if (pos >= text.len) break;
            if (text[pos] != target) break;
            pos += 1;
            count += 1;
            if (positions_len < positions.len) {
                positions[positions_len] = pos;
                positions_len += 1;
            }
        }

        if (count < min_count) return null;

        var i: usize = positions_len;
        while (i > 0) {
            i -= 1;
            if (i < min_count and min_count > 0) break;
            const try_pos = positions[i];
            if (self.matchInstructions(text, try_pos, current_idx + 1)) |end| {
                return end;
            }
        }

        return null;
    }

    fn matchAny(c: u8) bool {
        return c != '\n';
    }

    fn matchDigit(c: u8) bool {
        return isDigit(c);
    }

    fn matchNotDigit(c: u8) bool {
        return !isDigit(c);
    }

    fn matchWord(c: u8) bool {
        return isWordChar(c);
    }

    fn matchNotWord(c: u8) bool {
        return !isWordChar(c);
    }

    fn matchSpace(c: u8) bool {
        return isSpaceChar(c);
    }

    fn matchNotSpace(c: u8) bool {
        return !isSpaceChar(c);
    }

    fn matchRepeat(
        self: *const Regex,
        text: []const u8,
        start_pos: usize,
        current_idx: usize,
        matcher: fn (u8) bool,
        min_count: usize,
        max_count: ?usize,
    ) ?usize {
        var positions: [1024]usize = undefined;
        var positions_len: usize = 1;
        positions[0] = start_pos;

        var pos = start_pos;
        var count: usize = 0;

        while (max_count == null or count < max_count.?) {
            if (pos >= text.len) break;
            if (!matcher(text[pos])) break;
            pos += 1;
            count += 1;
            if (positions_len < positions.len) {
                positions[positions_len] = pos;
                positions_len += 1;
            }
        }

        if (count < min_count) return null;

        // 貪欲マッチ: 最長から試す
        var i: usize = positions_len;
        while (i > 0) {
            i -= 1;
            if (i < min_count and min_count > 0) break;
            const try_pos = positions[i];
            if (self.matchInstructions(text, try_pos, current_idx + 1)) |end| {
                return end;
            }
        }

        return null;
    }

    fn matchRepeatClass(
        self: *const Regex,
        text: []const u8,
        start_pos: usize,
        current_idx: usize,
        cc: CharClass,
        min_count: usize,
        max_count: ?usize,
    ) ?usize {
        var positions: [1024]usize = undefined;
        var positions_len: usize = 1;
        positions[0] = start_pos;

        var pos = start_pos;
        var count: usize = 0;

        while (max_count == null or count < max_count.?) {
            if (pos >= text.len) break;
            if (!cc.matches(text[pos])) break;
            pos += 1;
            count += 1;
            if (positions_len < positions.len) {
                positions[positions_len] = pos;
                positions_len += 1;
            }
        }

        if (count < min_count) return null;

        var i: usize = positions_len;
        while (i > 0) {
            i -= 1;
            if (i < min_count and min_count > 0) break;
            const try_pos = positions[i];
            if (self.matchInstructions(text, try_pos, current_idx + 1)) |end| {
                return end;
            }
        }

        return null;
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    fn isSpaceChar(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c or c == 0x0b;
    }
};

/// パターンが正規表現かどうかを判定
pub fn isRegexPattern(pattern: []const u8) bool {
    for (pattern) |c| {
        switch (c) {
            '.', '*', '+', '?', '[', ']', '^', '$', '\\' => return true,
            else => {},
        }
    }
    return false;
}

// テスト
test "literal match" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "hello");
    defer regex.deinit();

    const result = regex.search("say hello world", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 4), result.?.start);
    try std.testing.expectEqual(@as(usize, 9), result.?.end);
}

test "dot match" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "h.llo");
    defer regex.deinit();

    const result = regex.search("hallo world", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 5), result.?.end);
}

test "star quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "ho*");
    defer regex.deinit();

    // "h" にマッチ（0回）
    const result1 = regex.search("h", 0);
    try std.testing.expect(result1 != null);

    // "hooo" にマッチ（3回）
    const result2 = regex.search("hooo", 0);
    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(@as(usize, 4), result2.?.end);
}

test "plus quantifier" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "ho+");
    defer regex.deinit();

    // "h" にはマッチしない（最低1回必要）
    const result1 = regex.search("h ", 0);
    try std.testing.expect(result1 == null);

    // "ho" にマッチ
    const result2 = regex.search("ho", 0);
    try std.testing.expect(result2 != null);
}

test "character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[abc]+");
    defer regex.deinit();

    const result = regex.search("xxxabcxxx", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.start);
    try std.testing.expectEqual(@as(usize, 6), result.?.end);
}

test "negated character class" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[^0-9]+");
    defer regex.deinit();

    const result = regex.search("123abc456", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.start);
    try std.testing.expectEqual(@as(usize, 6), result.?.end);
}

test "digit shorthand" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    const result = regex.search("abc123def", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.start);
    try std.testing.expectEqual(@as(usize, 6), result.?.end);
}

test "anchor start" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "^hello");
    defer regex.deinit();

    // 行頭の "hello" にマッチ
    const result1 = regex.search("hello world", 0);
    try std.testing.expect(result1 != null);

    // 行頭でない "hello" にはマッチしない
    const result2 = regex.search("say hello", 0);
    try std.testing.expect(result2 == null);
}

test "anchor end" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "world$");
    defer regex.deinit();

    // 行末の "world" にマッチ
    const result1 = regex.search("hello world", 0);
    try std.testing.expect(result1 != null);

    // 行末でない "world" にはマッチしない
    const result2 = regex.search("world hello", 0);
    try std.testing.expect(result2 == null);
}

test "complex pattern" {
    const allocator = std.testing.allocator;
    var regex = try Regex.compile(allocator, "[a-z]+\\d*");
    defer regex.deinit();

    const result = regex.search("test123", 0);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.start);
    try std.testing.expectEqual(@as(usize, 7), result.?.end);
}

test "isRegexPattern" {
    try std.testing.expect(isRegexPattern("hello.*world"));
    try std.testing.expect(isRegexPattern("\\d+"));
    try std.testing.expect(isRegexPattern("[abc]"));
    try std.testing.expect(!isRegexPattern("hello"));
    try std.testing.expect(!isRegexPattern("test123"));
}
