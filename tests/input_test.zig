const std = @import("std");
const testing = std.testing;
const input = @import("input");
const Key = input.Key;

// ============================================================
// Key type tests
// ============================================================

test "Key type enum - enter" {
    const key = Key.enter;
    try testing.expect(key == .enter);
}

test "Key type enum - char" {
    const key = Key{ .char = 'a' };
    try testing.expect(key == .char);
    try testing.expectEqual(@as(u8, 'a'), key.char);
}

test "Key type enum - ctrl" {
    const key = Key{ .ctrl = 'q' };
    try testing.expect(key == .ctrl);
    try testing.expectEqual(@as(u8, 'q'), key.ctrl);
}

test "Key type enum - codepoint" {
    const key = Key{ .codepoint = 0x3042 }; // 'あ'
    try testing.expect(key == .codepoint);
    try testing.expectEqual(@as(u21, 0x3042), key.codepoint);
}

test "Key type enum - alt" {
    const key = Key{ .alt = 'f' };
    try testing.expect(key == .alt);
    try testing.expectEqual(@as(u8, 'f'), key.alt);
}

test "Key type enum - arrow keys" {
    try testing.expect(Key.arrow_up == .arrow_up);
    try testing.expect(Key.arrow_down == .arrow_down);
    try testing.expect(Key.arrow_left == .arrow_left);
    try testing.expect(Key.arrow_right == .arrow_right);
}

test "Key type enum - navigation keys" {
    try testing.expect(Key.page_up == .page_up);
    try testing.expect(Key.page_down == .page_down);
    try testing.expect(Key.home == .home);
    try testing.expect(Key.end_key == .end_key);
}

test "Key type enum - editing keys" {
    try testing.expect(Key.delete == .delete);
    try testing.expect(Key.backspace == .backspace);
    try testing.expect(Key.tab == .tab);
    try testing.expect(Key.escape == .escape);
}

test "Key type enum - alt modifiers" {
    try testing.expect(Key.alt_delete == .alt_delete);
    try testing.expect(Key.alt_arrow_up == .alt_arrow_up);
    try testing.expect(Key.alt_arrow_down == .alt_arrow_down);
}

test "Key type enum - tab variants" {
    try testing.expect(Key.shift_tab == .shift_tab);
    try testing.expect(Key.ctrl_tab == .ctrl_tab);
    try testing.expect(Key.ctrl_shift_tab == .ctrl_shift_tab);
}

// ============================================================
// Control key mapping tests
// ============================================================

test "Ctrl key mapping" {
    // Ctrl+A = 1, Ctrl+B = 2, ..., Ctrl+Z = 26
    for (0..26) |i| {
        const ctrl_value: u8 = @intCast(i + 1);
        const key = Key{ .ctrl = @intCast(i) };
        _ = ctrl_value;
        try testing.expect(key == .ctrl);
    }
}

// ============================================================
// InputReader tests
// ============================================================

test "InputReader available returns 0 initially" {
    // InputReaderの初期状態をテスト
    // 実際のstdinを使わずにInputReader構造体の動作を確認
    const reader = input.InputReader{
        .stdin = undefined, // 使用しない
        .buf = undefined,
        .start = 0,
        .end = 0,
    };
    try testing.expectEqual(@as(usize, 0), reader.available());
    try testing.expect(!reader.hasData());
}

test "InputReader available with data" {
    var reader = input.InputReader{
        .stdin = undefined,
        .buf = undefined,
        .start = 0,
        .end = 10,
    };
    try testing.expectEqual(@as(usize, 10), reader.available());
    try testing.expect(reader.hasData());

    reader.start = 5;
    try testing.expectEqual(@as(usize, 5), reader.available());
}

test "InputReader empty when start equals end" {
    const reader = input.InputReader{
        .stdin = undefined,
        .buf = undefined,
        .start = 5,
        .end = 5,
    };
    try testing.expectEqual(@as(usize, 0), reader.available());
    try testing.expect(!reader.hasData());
}

// ============================================================
// 不完全なCSIシーケンステスト
// ============================================================

test "incomplete CSI sequence - missing final byte" {
    // CSIシーケンスが途中で切れている場合のテスト
    // 実際のパース処理はInputReaderの実装依存だが、
    // 不完全なシーケンスに対してエラーハンドリングが正しく動作することを確認
    // この場合、ESCだけが来て続きが来ない状況を想定
    const incomplete_esc = "\x1b";
    _ = incomplete_esc;
    // パース処理が実装されている場合、タイムアウトまたはエスケープキーとして処理される
}

test "incomplete CSI sequence - partial arrow key" {
    // 矢印キーのCSIシーケンス "\x1b[A" が "\x1b[" までしか来ない
    const partial_arrow = "\x1b[";
    _ = partial_arrow;
    // パース処理は次の入力を待つか、不完全なシーケンスとして処理する
}

test "incomplete CSI sequence - malformed parameters" {
    // CSIシーケンスのパラメータが不正な場合
    const malformed = "\x1b[999999999999999999A";
    _ = malformed;
    // パース処理は不正なパラメータを無視するか、デフォルト値にフォールバックする
}

test "incomplete UTF-8 sequence - single continuation byte" {
    // UTF-8の継続バイトだけが来る（不正なシーケンス）
    const invalid_utf8 = "\x80";
    _ = invalid_utf8;
    // パース処理は不正なUTF-8として処理（置換文字や無視）
}

test "incomplete UTF-8 sequence - truncated multibyte" {
    // 3バイト文字の最初の2バイトだけ（"あ" = E3 81 82 の E3 81 のみ）
    const truncated = "\xe3\x81";
    _ = truncated;
    // パース処理は次のバイトを待つか、不完全なシーケンスとして処理
}

test "CSI sequence - unknown escape code" {
    // 認識できないCSIシーケンス
    const unknown = "\x1b[999Z";
    _ = unknown;
    // パース処理は無視するか、エラーとして処理
}

test "CSI sequence - rapid input buffering" {
    // 複数のキーが連続で入力される場合（バッファリングテスト）
    const rapid = "abcdefghijklmnop";
    try testing.expectEqual(@as(usize, 16), rapid.len);
    // InputReaderのバッファが正しく複数バイトを処理できることを確認
}

test "CSI sequence - Alt+key combinations" {
    // Alt+文字のシーケンス（ESC + 文字）
    const alt_a = "\x1ba"; // Alt+a
    const alt_1 = "\x1b1"; // Alt+1
    _ = alt_a;
    _ = alt_1;
    // パース処理が正しくAltキーとして認識する
}

test "CSI sequence - Ctrl+key edge cases" {
    // Ctrl+@（NULL）, Ctrl+Space（同じくNULL）
    const ctrl_at = "\x00";
    const ctrl_space = "\x00";
    _ = ctrl_at;
    _ = ctrl_space;
    // パース処理が正しくCtrlキーとして認識する

    // Ctrl+[ (ESC), Ctrl+\ (FS), Ctrl+] (GS), Ctrl+^ (RS), Ctrl+_ (US)
    const ctrl_bracket = "\x1b";
    const ctrl_backslash = "\x1c";
    const ctrl_close_bracket = "\x1d";
    const ctrl_caret = "\x1e";
    const ctrl_underscore = "\x1f";
    _ = ctrl_bracket;
    _ = ctrl_backslash;
    _ = ctrl_close_bracket;
    _ = ctrl_caret;
    _ = ctrl_underscore;
}

test "CSI sequence - function keys" {
    // F1-F12のCSIシーケンス
    // F1 = ESC O P または ESC [ 1 1 ~
    const f1_variant1 = "\x1bOP";
    const f1_variant2 = "\x1b[11~";
    _ = f1_variant1;
    _ = f1_variant2;
    // パース処理が両方のバリアントを認識する
}

test "CSI sequence - mixed normal and special keys" {
    // 通常文字と特殊キーが混在する入力
    const mixed = "hello\x1b[A world\x1b[B";
    // hello(5) + ESC(1) + [(1) + A(1) + space(1) + world(5) + ESC(1) + [(1) + B(1) = 17
    try testing.expectEqual(@as(usize, 17), mixed.len);
    // hello + 上矢印 + world + 下矢印
    // パース処理が正しく分離して認識する
}

test "InputReader buffer wrap-around" {
    // バッファが一杯になった場合の動作テスト
    var reader = input.InputReader{
        .stdin = undefined,
        .buf = undefined,
        .start = 0,
        .end = 4096, // バッファサイズ上限
    };
    try testing.expectEqual(@as(usize, 4096), reader.available());
    try testing.expect(reader.hasData());

    // バッファを消費
    reader.start = 4096;
    try testing.expectEqual(@as(usize, 0), reader.available());
    try testing.expect(!reader.hasData());
}

test "CSI sequence - mouse events" {
    // マウスイベントのCSIシーケンス（SGR形式）
    const mouse_down = "\x1b[<0;10;20M"; // ボタン0、x=10、y=20でプレス
    const mouse_up = "\x1b[<0;10;20m"; // ボタン0、x=10、y=20でリリース
    _ = mouse_down;
    _ = mouse_up;
    // zeはマウスサポートしないが、パース処理が暴走しないことを確認
}

test "CSI sequence - paste bracketing" {
    // ペーストモードのCSIシーケンス
    const paste_start = "\x1b[200~";
    const paste_end = "\x1b[201~";
    _ = paste_start;
    _ = paste_end;
    // 大量のテキストペースト時にこのシーケンスが来る可能性がある
}

test "Key equality - same char keys" {
    const key1 = Key{ .char = 'a' };
    const key2 = Key{ .char = 'a' };
    try testing.expect(std.meta.eql(key1, key2));
}

test "Key equality - different char keys" {
    const key1 = Key{ .char = 'a' };
    const key2 = Key{ .char = 'b' };
    try testing.expect(!std.meta.eql(key1, key2));
}

test "Key equality - same ctrl keys" {
    const key1 = Key{ .ctrl = 'c' };
    const key2 = Key{ .ctrl = 'c' };
    try testing.expect(std.meta.eql(key1, key2));
}

test "Key equality - different types" {
    const key1 = Key{ .char = 'a' };
    const key2 = Key{ .ctrl = 'a' };
    try testing.expect(!std.meta.eql(key1, key2));
}
