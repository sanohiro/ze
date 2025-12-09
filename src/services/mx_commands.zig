// ============================================================================
// MxCommands - M-x コマンド実行サービス
// ============================================================================
//
// 【責務】
// - M-x コマンドの解析と実行
// - コマンド名と引数のパース
// - ヘルプ情報の提供
//
// 【対応コマンド】
// - line [n]: 行番号表示/移動
// - tab [n]: タブ幅表示/設定
// - indent [n]: インデント幅表示/設定
// - mode: モード表示
// - revert: ファイル再読み込み
// - ro: 読み取り専用トグル
// - key: 次のキー入力を説明
// - ?: ヘルプ
// ============================================================================

const std = @import("std");

/// M-x コマンドの種類
pub const Command = enum {
    help,
    line,
    tab,
    indent,
    mode,
    revert,
    readonly,
    key,
    unknown,
};

/// パースされたコマンド
pub const ParsedCommand = struct {
    cmd: Command,
    arg: ?[]const u8,
};

/// ヘルプテキスト
pub const HELP_TEXT = "Commands: line tab indent mode revert key ro ?";

/// コマンドをパース
pub fn parse(cmd_line: []const u8) ParsedCommand {
    if (cmd_line.len == 0) {
        return .{ .cmd = .unknown, .arg = null };
    }

    var parts = std.mem.splitScalar(u8, cmd_line, ' ');
    const cmd = parts.next() orelse "";
    const arg = parts.next();

    const command: Command = if (std.mem.eql(u8, cmd, "?") or std.mem.eql(u8, cmd, "help"))
        .help
    else if (std.mem.eql(u8, cmd, "line"))
        .line
    else if (std.mem.eql(u8, cmd, "tab"))
        .tab
    else if (std.mem.eql(u8, cmd, "indent"))
        .indent
    else if (std.mem.eql(u8, cmd, "mode"))
        .mode
    else if (std.mem.eql(u8, cmd, "revert"))
        .revert
    else if (std.mem.eql(u8, cmd, "ro") or std.mem.eql(u8, cmd, "readonly"))
        .readonly
    else if (std.mem.eql(u8, cmd, "key"))
        .key
    else
        .unknown;

    return .{ .cmd = command, .arg = arg };
}

/// 引数を数値としてパース
pub fn parseNumber(arg: ?[]const u8) ?usize {
    const a = arg orelse return null;
    return std.fmt.parseInt(usize, a, 10) catch null;
}

// ============================================================================
// テスト
// ============================================================================

test "parse - help command" {
    const result = parse("?");
    try std.testing.expectEqual(Command.help, result.cmd);
    try std.testing.expect(result.arg == null);
}

test "parse - line command with arg" {
    const result = parse("line 42");
    try std.testing.expectEqual(Command.line, result.cmd);
    try std.testing.expectEqualStrings("42", result.arg.?);
}

test "parse - tab command" {
    const result = parse("tab 4");
    try std.testing.expectEqual(Command.tab, result.cmd);
    try std.testing.expectEqualStrings("4", result.arg.?);
}

test "parse - unknown command" {
    const result = parse("foobar");
    try std.testing.expectEqual(Command.unknown, result.cmd);
}

test "parseNumber" {
    try std.testing.expectEqual(@as(?usize, 42), parseNumber("42"));
    try std.testing.expectEqual(@as(?usize, null), parseNumber("abc"));
    try std.testing.expectEqual(@as(?usize, null), parseNumber(null));
}
