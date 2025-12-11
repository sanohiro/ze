const std = @import("std");
const testing = std.testing;
const MacroService = @import("macro_service").MacroService;
const input = @import("input");

test "init and deinit" {
    var service = MacroService.init(testing.allocator);
    defer service.deinit();

    try testing.expect(!service.isRecording());
    try testing.expect(!service.isPlaying());
    try testing.expectEqual(@as(?[]const input.Key, null), service.getLastMacro());
}

test "start and stop recording" {
    var service = MacroService.init(testing.allocator);
    defer service.deinit();

    // 記録開始
    service.startRecording();
    try testing.expect(service.isRecording());

    // キーを記録
    try service.recordKey(.{ .char = 'a' });
    try service.recordKey(.{ .char = 'b' });
    try service.recordKey(.{ .char = 'c' });

    try testing.expectEqual(@as(usize, 3), service.recordedKeyCount());

    // 記録終了
    service.stopRecording();
    try testing.expect(!service.isRecording());

    // マクロが保存されていることを確認
    const macro = service.getLastMacro();
    try testing.expect(macro != null);
    try testing.expectEqual(@as(usize, 3), macro.?.len);
    try testing.expectEqual(input.Key{ .char = 'a' }, macro.?[0]);
    try testing.expectEqual(input.Key{ .char = 'b' }, macro.?[1]);
    try testing.expectEqual(input.Key{ .char = 'c' }, macro.?[2]);
}

test "empty recording preserves previous macro" {
    var service = MacroService.init(testing.allocator);
    defer service.deinit();

    // 最初のマクロを記録
    service.startRecording();
    try service.recordKey(.{ .char = 'x' });
    service.stopRecording();

    const first_macro = service.getLastMacro();
    try testing.expect(first_macro != null);
    try testing.expectEqual(@as(usize, 1), first_macro.?.len);

    // 空のマクロを記録（前のマクロが保持される）
    service.startRecording();
    service.stopRecording();

    const second_macro = service.getLastMacro();
    try testing.expect(second_macro != null);
    try testing.expectEqual(@as(usize, 1), second_macro.?.len);
    try testing.expectEqual(input.Key{ .char = 'x' }, second_macro.?[0]);
}

test "cancel recording" {
    var service = MacroService.init(testing.allocator);
    defer service.deinit();

    // 最初のマクロを記録
    service.startRecording();
    try service.recordKey(.{ .char = 'a' });
    service.stopRecording();

    // 新しい記録を開始してキャンセル
    service.startRecording();
    try service.recordKey(.{ .char = 'b' });
    try service.recordKey(.{ .char = 'c' });
    service.cancelRecording();

    try testing.expect(!service.isRecording());

    // 前のマクロが保持されていることを確認
    const macro = service.getLastMacro();
    try testing.expect(macro != null);
    try testing.expectEqual(@as(usize, 1), macro.?.len);
    try testing.expectEqual(input.Key{ .char = 'a' }, macro.?[0]);
}

test "recording not started when playing" {
    var service = MacroService.init(testing.allocator);
    defer service.deinit();

    // 再生中フラグをセット
    service.beginPlayback();
    try testing.expect(service.isPlaying());

    // 再生中に記録を開始しようとしても無視される
    service.startRecording();
    try testing.expect(!service.isRecording());

    service.endPlayback();
    try testing.expect(!service.isPlaying());
}

test "recording keys only when recording" {
    var service = MacroService.init(testing.allocator);
    defer service.deinit();

    // 記録開始前にキーを送っても記録されない
    try service.recordKey(.{ .char = 'x' });
    try testing.expectEqual(@as(usize, 0), service.recordedKeyCount());

    // 記録開始
    service.startRecording();
    try service.recordKey(.{ .char = 'a' });
    try testing.expectEqual(@as(usize, 1), service.recordedKeyCount());

    service.stopRecording();
}

test "macro with various key types" {
    var service = MacroService.init(testing.allocator);
    defer service.deinit();

    service.startRecording();
    try service.recordKey(.{ .char = 'h' });
    try service.recordKey(.{ .char = 'e' });
    try service.recordKey(.{ .char = 'l' });
    try service.recordKey(.{ .char = 'l' });
    try service.recordKey(.{ .char = 'o' });
    try service.recordKey(.{ .ctrl = 'a' }); // C-a
    try service.recordKey(.{ .ctrl = 'e' }); // C-e
    service.stopRecording();

    const macro = service.getLastMacro();
    try testing.expect(macro != null);
    try testing.expectEqual(@as(usize, 7), macro.?.len);
    try testing.expectEqual(input.Key{ .ctrl = 'a' }, macro.?[5]);
    try testing.expectEqual(input.Key{ .ctrl = 'e' }, macro.?[6]);
}

test "lastMacroKeyCount" {
    var service = MacroService.init(testing.allocator);
    defer service.deinit();

    // マクロがない場合は0
    try testing.expectEqual(@as(usize, 0), service.lastMacroKeyCount());

    // マクロを記録
    service.startRecording();
    try service.recordKey(.{ .char = 'a' });
    try service.recordKey(.{ .char = 'b' });
    service.stopRecording();

    try testing.expectEqual(@as(usize, 2), service.lastMacroKeyCount());
}
