// mx.zig のユニットテスト
// M-xコマンド補完機能のテスト

const std = @import("std");
const testing = std.testing;

// ========================================
// completeCommand 関数の再実装（テスト用）
// ========================================
// mx.zig の completeCommand は comptime inline for を使用しており、
// テスト環境では直接呼び出せないため、ロジックを再実装してテスト

const Command = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
};

const commands = [_]Command{
    .{ .name = "?", .alias = "help" },
    .{ .name = "line" },
    .{ .name = "ln" },
    .{ .name = "tab" },
    .{ .name = "indent" },
    .{ .name = "mode" },
    .{ .name = "revert" },
    .{ .name = "key" },
    .{ .name = "ro" },
    .{ .name = "exit", .alias = "quit" },
};

fn completeCommand(prefix: []const u8) struct {
    matches: []const []const u8,
    common_prefix: []const u8,
} {
    const max_matches = commands.len * 2;
    const S = struct {
        var match_buf: [max_matches][]const u8 = undefined;
    };

    var count: usize = 0;

    for (commands) |cmd| {
        if (std.mem.startsWith(u8, cmd.name, prefix)) {
            S.match_buf[count] = cmd.name;
            count += 1;
        }
        if (cmd.alias) |alias| {
            if (std.mem.startsWith(u8, alias, prefix)) {
                S.match_buf[count] = alias;
                count += 1;
            }
        }
    }

    if (count == 0) {
        return .{ .matches = &[_][]const u8{}, .common_prefix = prefix };
    }

    // 共通プレフィックスを計算
    var common_len = S.match_buf[0].len;
    for (S.match_buf[1..count]) |m| {
        var i: usize = 0;
        while (i < common_len and i < m.len and S.match_buf[0][i] == m[i]) : (i += 1) {}
        common_len = i;
    }

    return .{
        .matches = S.match_buf[0..count],
        .common_prefix = S.match_buf[0][0..common_len],
    };
}

// ========================================
// 補完テスト
// ========================================

test "completeCommand - 空プレフィックス" {
    const result = completeCommand("");

    // 全コマンド + エイリアスがマッチ
    try testing.expect(result.matches.len >= commands.len);
}

test "completeCommand - 完全一致" {
    const result = completeCommand("line");

    // 'line' にマッチ
    try testing.expectEqual(@as(usize, 1), result.matches.len);
    try testing.expectEqualStrings("line", result.matches[0]);
    try testing.expectEqualStrings("line", result.common_prefix);
}

test "completeCommand - プレフィックス一致" {
    const result = completeCommand("l");

    // 'line' と 'ln' がマッチ
    try testing.expectEqual(@as(usize, 2), result.matches.len);
    try testing.expectEqualStrings("l", result.common_prefix);
}

test "completeCommand - エイリアスマッチ" {
    const result = completeCommand("he");

    // 'help' (エイリアス) がマッチ
    try testing.expectEqual(@as(usize, 1), result.matches.len);
    try testing.expectEqualStrings("help", result.matches[0]);
}

test "completeCommand - 複数エイリアス" {
    const result = completeCommand("q");

    // 'quit' (exit のエイリアス) がマッチ
    try testing.expectEqual(@as(usize, 1), result.matches.len);
    try testing.expectEqualStrings("quit", result.matches[0]);
}

test "completeCommand - マッチなし" {
    const result = completeCommand("xyz");

    try testing.expectEqual(@as(usize, 0), result.matches.len);
    try testing.expectEqualStrings("xyz", result.common_prefix);
}

test "completeCommand - 共通プレフィックス計算" {
    const result = completeCommand("re");

    // 'revert' がマッチ
    try testing.expectEqual(@as(usize, 1), result.matches.len);
    try testing.expectEqualStrings("revert", result.common_prefix);
}

test "completeCommand - 'in'で始まるコマンド" {
    const result = completeCommand("in");

    // 'indent' がマッチ
    try testing.expectEqual(@as(usize, 1), result.matches.len);
    try testing.expectEqualStrings("indent", result.matches[0]);
}

test "completeCommand - 't'で始まるコマンド" {
    const result = completeCommand("t");

    // 'tab' がマッチ
    try testing.expectEqual(@as(usize, 1), result.matches.len);
    try testing.expectEqualStrings("tab", result.matches[0]);
}

test "completeCommand - 'r'で始まるコマンド" {
    const result = completeCommand("r");

    // 'revert' と 'ro' がマッチ
    try testing.expectEqual(@as(usize, 2), result.matches.len);
    try testing.expectEqualStrings("r", result.common_prefix);
}

test "completeCommand - 'e'で始まるコマンド" {
    const result = completeCommand("e");

    // 'exit' がマッチ
    try testing.expectEqual(@as(usize, 1), result.matches.len);
    try testing.expectEqualStrings("exit", result.matches[0]);
}

// ========================================
// コマンド解析のテスト
// ========================================

test "コマンド分割 - 引数なし" {
    const cmd_line = "line";
    var parts = std.mem.splitScalar(u8, cmd_line, ' ');
    const cmd = parts.next().?;
    const arg = parts.next();

    try testing.expectEqualStrings("line", cmd);
    try testing.expectEqual(@as(?[]const u8, null), arg);
}

test "コマンド分割 - 引数あり" {
    const cmd_line = "line 42";
    var parts = std.mem.splitScalar(u8, cmd_line, ' ');
    const cmd = parts.next().?;
    const arg = parts.next();

    try testing.expectEqualStrings("line", cmd);
    try testing.expectEqualStrings("42", arg.?);
}

test "コマンド分割 - 複数スペース" {
    const cmd_line = "tab  8";
    var parts = std.mem.splitScalar(u8, cmd_line, ' ');
    const cmd = parts.next().?;
    const arg = parts.next();

    try testing.expectEqualStrings("tab", cmd);
    // splitScalar は空文字列を返す
    try testing.expectEqualStrings("", arg.?);
}

// ========================================
// 引数解析のテスト
// ========================================

test "parseInt - 有効な行番号" {
    const line_str = "42";
    const line_num = std.fmt.parseInt(usize, line_str, 10) catch unreachable;
    try testing.expectEqual(@as(usize, 42), line_num);
}

test "parseInt - 無効な行番号" {
    const line_str = "abc";
    const result = std.fmt.parseInt(usize, line_str, 10);
    try testing.expectError(error.InvalidCharacter, result);
}

test "parseInt - 負の数" {
    const line_str = "-1";
    // usize にパースしようとすると Overflow（負の値は表現できない）
    const result = std.fmt.parseInt(usize, line_str, 10);
    try testing.expectError(error.Overflow, result);
}

test "parseInt - タブ幅" {
    const width_str = "8";
    const width = std.fmt.parseInt(u8, width_str, 10) catch unreachable;
    try testing.expectEqual(@as(u8, 8), width);
}

test "parseInt - タブ幅範囲外" {
    const width_str = "256";
    const result = std.fmt.parseInt(u8, width_str, 10);
    try testing.expectError(error.Overflow, result);
}
