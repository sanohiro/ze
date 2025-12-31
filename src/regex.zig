// 簡易正規表現エンジン
// サポート: . * + ? [] [^] ^ $ \d \w \s \D \W \S \\
// 非サポート: キャプチャグループ、後方参照、先読み等の高度な機能

const std = @import("std");
const unicode = @import("unicode");
const config = @import("config");

/// 簡易正規表現エンジン
///
/// 【サポートする構文】
/// - `.` : 任意の1文字（改行以外）
/// - `*` : 0回以上の繰り返し
/// - `+` : 1回以上の繰り返し
/// - `?` : 0回または1回
/// - `[abc]` : 文字クラス
/// - `[^abc]` : 否定文字クラス
/// - `^` : 行頭アンカー
/// - `$` : 行末アンカー
/// - `\d`, `\w`, `\s` : 文字タイプ
/// - `\D`, `\W`, `\S` : 否定文字タイプ
///
/// 【実装】
/// コンパイル時にパターンをInstruction列に変換し、
/// 実行時はバックトラッキングでマッチを試みる。
/// 貪欲マッチ（最長一致）を採用。
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

    /// 文字クラス（256ビットマップで O(1) マッチング）
    pub const CharClass = struct {
        bitmap: [32]u8, // 256 bits
        negated: bool,

        /// ビットマップで文字をマッチ（O(1)）
        pub fn matches(self: CharClass, c: u8) bool {
            const byte_idx = c >> 3; // c / 8
            const bit_idx: u3 = @truncate(c); // c % 8
            const found = (self.bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
            return if (self.negated) !found else found;
        }

        /// 空のビットマップを作成
        pub fn init() CharClass {
            return .{ .bitmap = [_]u8{0} ** 32, .negated = false };
        }

        /// ビットを設定
        pub fn setBit(self: *CharClass, c: u8) void {
            const byte_idx = c >> 3;
            const bit_idx: u3 = @truncate(c);
            self.bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
        }

        /// 範囲のビットを設定（start > endの場合は何もしない）
        pub fn setRange(self: *CharClass, start: u8, end: u8) void {
            if (start > end) return; // 無効な範囲（[z-a]等）は無視
            var c = start;
            while (true) {
                self.setBit(c);
                if (c == end) break;
                c += 1;
            }
        }
    };

    pub const MatchResult = struct {
        start: usize,
        end: usize,
    };

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Regex {
        var instructions = try std.ArrayList(Instruction).initCapacity(allocator, pattern.len);
        errdefer {
            // CharClassはビットマップなのでアロケーション解放不要
            instructions.deinit(allocator);
        }

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

    /// 文字クラスをパース（ビットマップに直接構築、アロケーション不要）
    fn parseCharClass(_: std.mem.Allocator, pattern: []const u8) !CharClassResult {
        var cc = CharClass.init();

        var i: usize = 1; // skip '['

        if (i < pattern.len and pattern[i] == '^') {
            cc.negated = true;
            i += 1;
        }

        if (i < pattern.len and pattern[i] == ']') {
            cc.setBit(']');
            i += 1;
        }

        while (i < pattern.len and pattern[i] != ']') {
            var c = pattern[i];

            if (c == '\\' and i + 1 < pattern.len) {
                i += 1;
                c = switch (pattern[i]) {
                    'd' => {
                        cc.setRange('0', '9');
                        i += 1;
                        continue;
                    },
                    'w' => {
                        cc.setRange('a', 'z');
                        cc.setRange('A', 'Z');
                        cc.setRange('0', '9');
                        cc.setBit('_');
                        i += 1;
                        continue;
                    },
                    's' => {
                        cc.setBit(' ');
                        cc.setBit('\t');
                        cc.setBit('\n');
                        cc.setBit('\r');
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
                cc.setRange(c, end_c);
                i += 3;
            } else {
                cc.setBit(c);
                i += 1;
            }
        }

        if (i < pattern.len and pattern[i] == ']') {
            i += 1;
        }

        return CharClassResult{
            .class = cc,
            .consumed = i,
        };
    }

    pub fn deinit(self: *Regex) void {
        // CharClassはビットマップなのでアロケーション解放不要
        self.allocator.free(self.compiled);
    }

    pub fn search(self: *const Regex, text: []const u8, start_pos: usize) ?MatchResult {
        if (self.compiled.len == 0) return null;

        const has_start_anchor = self.compiled[0] == .anchor_start;

        var pos = start_pos;
        while (pos <= text.len) {
            if (has_start_anchor) {
                if (pos > 0 and text[pos - 1] != '\n') {
                    // std.mem.indexOfScalarでSIMD最適化された改行検索
                    if (std.mem.indexOfScalar(u8, text[pos..], '\n')) |nl_offset| {
                        pos = pos + nl_offset + 1;
                    } else {
                        break; // テキスト終端に達したので終了
                    }
                    continue;
                }
            }

            if (self.matchAt(text, pos)) |end| {
                return MatchResult{ .start = pos, .end = end };
            }

            if (has_start_anchor) {
                // std.mem.indexOfScalarでSIMD最適化された改行検索
                if (std.mem.indexOfScalar(u8, text[pos..], '\n')) |nl_offset| {
                    pos = pos + nl_offset + 1;
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
                    if (!unicode.isWordCharByte(text[pos])) return null;
                    pos += 1;
                },
                .not_word => {
                    if (pos >= text.len) return null;
                    if (unicode.isWordCharByte(text[pos])) return null;
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

    /// 繰り返しマッチのバックトラック処理（共通ロジック）
    /// positions配列を受け取り、貪欲マッチで最長から試行する
    fn tryBacktrack(
        self: *const Regex,
        text: []const u8,
        current_idx: usize,
        positions: []const usize,
        min_count: usize,
    ) ?usize {
        var i: usize = positions.len;
        while (i > 0) {
            i -= 1;
            if (i < min_count and min_count > 0) break;
            if (self.matchInstructions(text, positions[i], current_idx + 1)) |end| {
                return end;
            }
        }
        return null;
    }

    /// 繰り返しマッチのバッファ管理（スタック優先、必要時ヒープ移行）
    /// 病的パターン（.*.*.*等）での指数時間を防ぐため、最大位置数を制限
    const PositionCollector = struct {

        stack_buf: [256]usize,
        heap_buf: ?std.ArrayList(usize),
        positions: []usize,
        len: usize,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, start_pos: usize) PositionCollector {
            var self = PositionCollector{
                .stack_buf = undefined,
                .heap_buf = null,
                .positions = undefined,
                .len = 1,
                .allocator = allocator,
            };
            self.stack_buf[0] = start_pos;
            self.positions = self.stack_buf[0..1];
            return self;
        }

        fn deinit(self: *PositionCollector) void {
            if (self.heap_buf) |*h| h.deinit(self.allocator);
        }

        fn append(self: *PositionCollector, pos: usize) bool {
            // 最大位置数制限（病的パターンでの指数時間防止）
            if (self.len >= config.Regex.MAX_POSITIONS) return false;

            if (self.heap_buf) |*h| {
                h.append(self.allocator, pos) catch return false;
                self.positions = h.items;
                self.len = h.items.len;
            } else if (self.len < self.stack_buf.len) {
                self.stack_buf[self.len] = pos;
                self.len += 1;
                self.positions = self.stack_buf[0..self.len];
            } else {
                // スタックバッファが足りない場合、ヒープに移行
                self.heap_buf = std.ArrayList(usize).initCapacity(self.allocator, self.stack_buf.len * 2) catch return false;
                self.heap_buf.?.appendSlice(self.allocator, self.stack_buf[0..]) catch return false;
                self.heap_buf.?.append(self.allocator, pos) catch return false;
                self.positions = self.heap_buf.?.items;
                self.len = self.heap_buf.?.items.len;
            }
            return true;
        }

        fn getPositions(self: *const PositionCollector) []const usize {
            return self.positions[0..self.len];
        }
    };

    fn matchRepeatLiteral(
        self: *const Regex,
        text: []const u8,
        start_pos: usize,
        current_idx: usize,
        target: u8,
        min_count: usize,
        max_count: ?usize,
    ) ?usize {
        var collector = PositionCollector.init(self.allocator, start_pos);
        defer collector.deinit();

        var pos = start_pos;
        var count: usize = 0;

        while (max_count == null or count < max_count.?) {
            if (pos >= text.len or text[pos] != target) break;
            pos += 1;
            count += 1;
            if (!collector.append(pos)) return null;
        }

        if (count < min_count) return null;
        return self.tryBacktrack(text, current_idx, collector.getPositions(), min_count);
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
        return unicode.isWordCharByte(c);
    }

    fn matchNotWord(c: u8) bool {
        return !unicode.isWordCharByte(c);
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
        var collector = PositionCollector.init(self.allocator, start_pos);
        defer collector.deinit();

        var pos = start_pos;
        var count: usize = 0;

        while (max_count == null or count < max_count.?) {
            if (pos >= text.len or !matcher(text[pos])) break;
            pos += 1;
            count += 1;
            if (!collector.append(pos)) return null;
        }

        if (count < min_count) return null;
        return self.tryBacktrack(text, current_idx, collector.getPositions(), min_count);
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
        var collector = PositionCollector.init(self.allocator, start_pos);
        defer collector.deinit();

        var pos = start_pos;
        var count: usize = 0;

        while (max_count == null or count < max_count.?) {
            if (pos >= text.len or !cc.matches(text[pos])) break;
            pos += 1;
            count += 1;
            if (!collector.append(pos)) return null;
        }

        if (count < min_count) return null;
        return self.tryBacktrack(text, current_idx, collector.getPositions(), min_count);
    }

    inline fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    // isWordChar は unicode.isWordCharByte に共通化済み

    inline fn isSpaceChar(c: u8) bool {
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
