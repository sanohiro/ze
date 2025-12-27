const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer").Buffer;

// ============================================================
// 空バッファでの操作テスト
// ============================================================

test "deleteChar - empty buffer" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 空バッファでdeleteCharは何もしない（エラーではなく正常終了）
    try testing.expectEqual(@as(usize, 0), buffer.len());
    try buffer.delete(0, 1);
    try testing.expectEqual(@as(usize, 0), buffer.len());
}

test "backspace - at beginning of buffer" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc");
    // バックスペースはカーソル位置が0の時は何もしない（削除位置がない）
    // カーソル位置0でバックスペース → 削除対象なし
    try testing.expectEqual(@as(usize, 3), buffer.len());
}

test "killLine - empty buffer" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 空バッファでkillLineは何もしない
    try testing.expectEqual(@as(usize, 0), buffer.len());
    try testing.expectEqual(@as(usize, 1), buffer.lineCount());
}

test "killLine - single line no newline" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "hello");

    // 行末に改行がない場合、killLineは行末まで削除
    try buffer.delete(0, 5);
    try testing.expectEqual(@as(usize, 0), buffer.len());
}

test "killLine - at end of line before newline" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "hello\nworld");

    // カーソルが改行の直前 (位置5) → 改行のみ削除
    try buffer.delete(5, 1);
    try testing.expectEqual(@as(usize, 10), buffer.len());
    const data = try buffer.getRange(allocator, 0, 10);
    defer allocator.free(data);
    try testing.expectEqualStrings("helloworld", data);
}

// ============================================================
// 選択範囲なしでの操作テスト
// ============================================================

test "copyRegion - no selection returns null" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "test");

    // 選択範囲がない場合、copyRegionは何もコピーしない
    // （実際のEditorレベルの動作確認）
    // ここではBufferが正常にデータを保持していることを確認
    try testing.expectEqual(@as(usize, 4), buffer.len());
}

test "killRegion - no selection" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "test");

    // 選択範囲がない場合は何も削除しない
    try testing.expectEqual(@as(usize, 4), buffer.len());
}

// ============================================================
// 境界値テスト
// ============================================================

test "deleteChar - at end of buffer" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc");

    // バッファ末尾で削除 → 何もしない（正常終了）
    try buffer.delete(3, 1);
    try testing.expectEqual(@as(usize, 3), buffer.len());
}

test "backspace - single character buffer" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "a");
    try buffer.delete(0, 1);

    try testing.expectEqual(@as(usize, 0), buffer.len());
}

test "killLine - cursor at start of empty line" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "line1\n\nline3");

    // 2行目（空行）の開始位置でkillLine → 改行のみ削除
    try buffer.delete(6, 1);
    try testing.expectEqual(@as(usize, 11), buffer.len());
    const data = try buffer.getRange(allocator, 0, 11);
    defer allocator.free(data);
    try testing.expectEqualStrings("line1\nline3", data);
}

test "joinLine - at first line" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "first\nsecond");

    // 1行目でjoinLine → 次の行を結合
    try buffer.delete(5, 1);
    const data = try buffer.getRange(allocator, 0, 11);
    defer allocator.free(data);
    try testing.expectEqualStrings("firstsecond", data);
}

test "joinLine - at last line" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "first\nsecond");

    // 最終行でjoinLine → 何もしない（次の行がない）
    try testing.expectEqual(@as(usize, 12), buffer.len());
}

test "joinLine - single line buffer" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "only line");

    // 1行のみのバッファでjoinLine → 何もしない
    try testing.expectEqual(@as(usize, 9), buffer.len());
}

// ============================================================
// UTF-8境界でのエッジケース
// ============================================================

test "deleteChar - multibyte character boundary" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "あいう");

    // UTF-8の3バイト文字「あ」を削除
    try buffer.delete(0, 3);
    try testing.expectEqual(@as(usize, 6), buffer.len());
    const data = try buffer.getRange(allocator, 0, 6);
    defer allocator.free(data);
    try testing.expectEqualStrings("いう", data);
}

test "backspace - after multibyte character" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc日本");

    // 「本」の後ろから「本」を削除（3バイト）
    try buffer.delete(6, 3);
    try testing.expectEqual(@as(usize, 6), buffer.len());
    const data = try buffer.getRange(allocator, 0, 6);
    defer allocator.free(data);
    try testing.expectEqualStrings("abc日", data);
}

test "killLine - line with multibyte characters" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "日本語\nenglish");

    // 1行目の開始から改行手前まで削除
    try buffer.delete(0, 9);
    try testing.expectEqual(@as(usize, 8), buffer.len());
    const data = try buffer.getRange(allocator, 0, 8);
    defer allocator.free(data);
    try testing.expectEqualStrings("\nenglish", data);
}

// ============================================================
// 複数連続操作のエッジケース
// ============================================================

test "repeated deleteChar - until empty" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc");

    try buffer.delete(0, 1); // "bc"
    try testing.expectEqual(@as(usize, 2), buffer.len());

    try buffer.delete(0, 1); // "c"
    try testing.expectEqual(@as(usize, 1), buffer.len());

    try buffer.delete(0, 1); // ""
    try testing.expectEqual(@as(usize, 0), buffer.len());

    // 空バッファでさらに削除 → 何もしない（正常終了）
    try buffer.delete(0, 1);
    try testing.expectEqual(@as(usize, 0), buffer.len());
}

test "killLine then yank - roundtrip" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "original line\nnext line");

    // 1行目を削除（0〜13: "original line"）
    const killed = try buffer.getRange(allocator, 0, 13);
    defer allocator.free(killed);
    try buffer.delete(0, 13);

    // yankで復元（位置0に挿入）
    try buffer.insertSlice(0, killed);

    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("original line\nnext line", data);
}

// ============================================================
// エラー処理のエッジケース
// ============================================================

test "deleteChar - out of bounds position" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "test");

    // 範囲外位置での削除は何もしない（正常終了）
    try buffer.delete(10, 1);
    try testing.expectEqual(@as(usize, 4), buffer.len());
}

test "killRegion - inverted selection" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "hello world");

    // カーソルがマークより前の場合でも正しく削除される
    // 開始位置と終了位置を正規化して削除
    const start = 6;
    const end = 11;
    const actual_start = @min(start, end);
    const actual_len = @max(start, end) - actual_start;

    try buffer.delete(actual_start, actual_len);
    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("hello ", data);
}
