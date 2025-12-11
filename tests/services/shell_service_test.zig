const std = @import("std");
const testing = std.testing;
const ShellService = @import("shell_service").ShellService;
const InputSource = @import("shell_service").InputSource;
const OutputDest = @import("shell_service").OutputDest;

test "parseCommand - basic" {
    const result = ShellService.parseCommand("echo hello");
    try testing.expectEqual(InputSource.selection, result.input_source);
    try testing.expectEqual(OutputDest.command_buffer, result.output_dest);
    try testing.expectEqualStrings("echo hello", result.command);
}

test "parseCommand - with pipe prefix" {
    const result = ShellService.parseCommand("| sort");
    try testing.expectEqual(InputSource.selection, result.input_source);
    try testing.expectEqual(OutputDest.command_buffer, result.output_dest);
    try testing.expectEqualStrings("sort", result.command);
}

test "parseCommand - buffer all" {
    const result = ShellService.parseCommand("% | sort >");
    try testing.expectEqual(InputSource.buffer_all, result.input_source);
    try testing.expectEqual(OutputDest.replace, result.output_dest);
    try testing.expectEqualStrings("sort", result.command);
}

test "parseCommand - current line" {
    const result = ShellService.parseCommand(". | sh >");
    try testing.expectEqual(InputSource.current_line, result.input_source);
    try testing.expectEqual(OutputDest.replace, result.output_dest);
    try testing.expectEqualStrings("sh", result.command);
}

test "parseCommand - new buffer" {
    const result = ShellService.parseCommand("| grep TODO n>");
    try testing.expectEqual(InputSource.selection, result.input_source);
    try testing.expectEqual(OutputDest.new_buffer, result.output_dest);
    try testing.expectEqualStrings("grep TODO", result.command);
}

test "parseCommand - insert" {
    const result = ShellService.parseCommand("| date +>");
    try testing.expectEqual(InputSource.selection, result.input_source);
    try testing.expectEqual(OutputDest.insert, result.output_dest);
    try testing.expectEqualStrings("date", result.command);
}

test "parseCommand - suffix inside single quotes" {
    // 引用符内の n> はサフィックスとして認識しない
    const result = ShellService.parseCommand("printf 'n>'");
    try testing.expectEqual(InputSource.selection, result.input_source);
    try testing.expectEqual(OutputDest.command_buffer, result.output_dest);
    try testing.expectEqualStrings("printf 'n>'", result.command);
}

test "parseCommand - suffix inside double quotes" {
    // ダブルクォート内の +> もサフィックスとして認識しない
    const result = ShellService.parseCommand("echo \"+>\"");
    try testing.expectEqual(InputSource.selection, result.input_source);
    try testing.expectEqual(OutputDest.command_buffer, result.output_dest);
    try testing.expectEqualStrings("echo \"+>\"", result.command);
}

test "parseCommand - suffix outside quotes" {
    // 引用符の外にある n> はサフィックスとして認識
    const result = ShellService.parseCommand("echo 'hello' n>");
    try testing.expectEqual(InputSource.selection, result.input_source);
    try testing.expectEqual(OutputDest.new_buffer, result.output_dest);
    try testing.expectEqualStrings("echo 'hello'", result.command);
}
