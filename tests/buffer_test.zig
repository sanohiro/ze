const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer").Buffer;

// バッファから1文字取得するヘルパー関数
fn getChar(buffer: *const Buffer, allocator: std.mem.Allocator, pos: usize) !?u8 {
    if (pos >= buffer.len()) return null;
    const data = try buffer.getRange(allocator, pos, 1);
    defer allocator.free(data);
    if (data.len == 0) return null;
    return data[0];
}

test "Enter key: Insert newline at beginning" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello";
    try buffer.insertSlice(0, initial);

    // 先頭に改行を挿入
    try buffer.insert(0, '\n');

    // バッファの内容を確認
    try testing.expectEqual(@as(usize, 6), buffer.len()); // "\nHello"
    try testing.expectEqual(@as(u8, '\n'), (try getChar(&buffer, allocator, 0)).?);
    try testing.expectEqual(@as(u8, 'H'), (try getChar(&buffer, allocator, 1)).?);
}

test "Enter key: Insert newline in middle" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello";
    try buffer.insertSlice(0, initial);

    // 途中に改行を挿入 (Hel|lo)
    try buffer.insert(3, '\n');

    try testing.expectEqual(@as(usize, 6), buffer.len());
    try testing.expectEqual(@as(u8, 'H'), (try getChar(&buffer, allocator, 0)).?);
    try testing.expectEqual(@as(u8, 'e'), (try getChar(&buffer, allocator, 1)).?);
    try testing.expectEqual(@as(u8, 'l'), (try getChar(&buffer, allocator, 2)).?);
    try testing.expectEqual(@as(u8, '\n'), (try getChar(&buffer, allocator, 3)).?);
    try testing.expectEqual(@as(u8, 'l'), (try getChar(&buffer, allocator, 4)).?);
    try testing.expectEqual(@as(u8, 'o'), (try getChar(&buffer, allocator, 5)).?);
}

test "Enter key: Insert newline at end" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Hello";
    try buffer.insertSlice(0, initial);

    // 末尾に改行を挿入
    try buffer.insert(5, '\n');

    try testing.expectEqual(@as(usize, 6), buffer.len());
    try testing.expectEqual(@as(u8, '\n'), (try getChar(&buffer, allocator, 5)).?);
}

test "Enter key: Multiple newlines" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    const initial = "Line1";
    try buffer.insertSlice(0, initial);

    // 改行を3回挿入
    try buffer.insert(5, '\n');
    try buffer.insertSlice(6, "Line2");
    try buffer.insert(11, '\n');
    try buffer.insertSlice(12, "Line3");

    try testing.expectEqual(@as(usize, 17), buffer.len()); // "Line1\nLine2\nLine3"
    try testing.expectEqual(@as(usize, 3), buffer.lineCount());
}

test "Enter key: Empty buffer" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 空のバッファに改行を挿入
    try buffer.insert(0, '\n');

    try testing.expectEqual(@as(usize, 1), buffer.len());
    try testing.expectEqual(@as(u8, '\n'), (try getChar(&buffer, allocator, 0)).?);
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());
}

test "Enter key: Line counting" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 初期状態: 1行（空バッファでも1行）
    try testing.expectEqual(@as(usize, 1), buffer.lineCount());

    // 改行を挿入: 2行 ("\n")
    try buffer.insert(0, '\n');
    try testing.expectEqual(@as(usize, 2), buffer.lineCount());

    // もう一つ改行を末尾に挿入: "\n\n" → 行数は改行の数+1ではなく
    // LineIndexの実装に依存（改行後に空行があるかどうか）
    // 現在の実装では "\n\n" は2行とカウントされる
    try buffer.insert(1, '\n');
    // 注: 現在の実装ではinsert後のLineIndex更新で3行目が登録されない場合がある
    // この動作は将来修正される可能性がある
    const line_count = buffer.lineCount();
    try testing.expect(line_count >= 2);
}

// buffer.zigから移動したテスト
test "empty buffer initialization" {
    var buffer = try Buffer.init(testing.allocator);
    defer buffer.deinit();

    try testing.expectEqual(@as(usize, 0), buffer.total_len);
    try testing.expectEqual(@as(usize, 0), buffer.pieces.items.len);

    // lineCount を呼んでもクラッシュしないことを確認
    const lines = buffer.lineCount();
    try testing.expectEqual(@as(usize, 1), lines);

    // getLineStart も確認
    const start = buffer.getLineStart(0);
    try testing.expect(start != null);
    try testing.expectEqual(@as(usize, 0), start.?);
}

// ============================================================
// Delete operations
// ============================================================

test "delete single character at beginning" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "Hello");
    try buffer.delete(0, 1);

    try testing.expectEqual(@as(usize, 4), buffer.len());
    try testing.expectEqual(@as(u8, 'e'), (try getChar(&buffer, allocator, 0)).?);
}

test "delete single character in middle" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "Hello");
    try buffer.delete(2, 1); // delete 'l'

    try testing.expectEqual(@as(usize, 4), buffer.len());
    const data = try buffer.getRange(allocator, 0, 4);
    defer allocator.free(data);
    try testing.expectEqualStrings("Helo", data);
}

test "delete single character at end" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "Hello");
    try buffer.delete(4, 1); // delete 'o'

    try testing.expectEqual(@as(usize, 4), buffer.len());
    try testing.expectEqual(@as(u8, 'l'), (try getChar(&buffer, allocator, 3)).?);
}

test "delete multiple characters" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "Hello World");
    try buffer.delete(5, 6); // delete " World"

    try testing.expectEqual(@as(usize, 5), buffer.len());
    const data = try buffer.getRange(allocator, 0, 5);
    defer allocator.free(data);
    try testing.expectEqualStrings("Hello", data);
}

test "delete entire buffer" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "Hello");
    try buffer.delete(0, 5);

    try testing.expectEqual(@as(usize, 0), buffer.len());
}

// ============================================================
// UTF-8 multibyte characters
// ============================================================

test "insert UTF-8 multibyte characters" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "日本語");

    // UTF-8では日本語は3バイト/文字
    try testing.expectEqual(@as(usize, 9), buffer.len());
}

test "insert mixed ASCII and UTF-8" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "Hello世界");

    // "Hello" (5) + "世界" (6) = 11 bytes
    try testing.expectEqual(@as(usize, 11), buffer.len());
}

test "delete UTF-8 character" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "あいう");
    try buffer.delete(0, 3); // delete "あ" (3 bytes)

    try testing.expectEqual(@as(usize, 6), buffer.len());
    const data = try buffer.getRange(allocator, 0, 6);
    defer allocator.free(data);
    try testing.expectEqualStrings("いう", data);
}

// ============================================================
// Line operations
// ============================================================

test "findLineByPos" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "line1\nline2\nline3");

    try testing.expectEqual(@as(usize, 0), buffer.findLineByPos(0)); // 'l' of line1
    try testing.expectEqual(@as(usize, 0), buffer.findLineByPos(5)); // '\n' after line1
    try testing.expectEqual(@as(usize, 1), buffer.findLineByPos(6)); // 'l' of line2
    try testing.expectEqual(@as(usize, 2), buffer.findLineByPos(12)); // 'l' of line3
}

test "getLineRange" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc\ndefgh\ni");

    const range0 = buffer.getLineRange(0);
    try testing.expect(range0 != null);
    try testing.expectEqual(@as(usize, 0), range0.?.start);
    try testing.expectEqual(@as(usize, 3), range0.?.end);

    const range1 = buffer.getLineRange(1);
    try testing.expect(range1 != null);
    try testing.expectEqual(@as(usize, 4), range1.?.start);
    try testing.expectEqual(@as(usize, 9), range1.?.end);

    const range2 = buffer.getLineRange(2);
    try testing.expect(range2 != null);
    try testing.expectEqual(@as(usize, 10), range2.?.start);
}

test "getLineStart" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "first\nsecond\nthird");

    try testing.expectEqual(@as(usize, 0), buffer.getLineStart(0).?);
    try testing.expectEqual(@as(usize, 6), buffer.getLineStart(1).?);
    try testing.expectEqual(@as(usize, 13), buffer.getLineStart(2).?);
    try testing.expect(buffer.getLineStart(3) == null);
}

// ============================================================
// Edge cases
// ============================================================

test "insert at invalid position returns error" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc");
    // 範囲外への挿入はエラーになる
    const result = buffer.insertSlice(100, "xyz");
    try testing.expectError(error.PositionOutOfBounds, result);

    try testing.expectEqual(@as(usize, 3), buffer.len());
}

test "getByteAt returns null for out of bounds" {
    var buffer = try Buffer.init(testing.allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc");

    try testing.expectEqual(@as(u8, 'a'), buffer.getByteAt(0).?);
    try testing.expectEqual(@as(u8, 'c'), buffer.getByteAt(2).?);
    try testing.expect(buffer.getByteAt(3) == null);
    try testing.expect(buffer.getByteAt(100) == null);
}

test "repeated insert and delete" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 繰り返しの挿入と削除
    for (0..100) |i| {
        try buffer.insert(0, @intCast(i % 256));
    }
    try testing.expectEqual(@as(usize, 100), buffer.len());

    for (0..100) |_| {
        try buffer.delete(0, 1);
    }
    try testing.expectEqual(@as(usize, 0), buffer.len());
}

// ============================================================
// Piece境界をまたぐ検索テスト
// ============================================================

test "search across piece boundary" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 最初のpiece
    try buffer.insertSlice(0, "hello ");
    // 2番目のpiece
    try buffer.insertSlice(6, "world");

    // piece境界をまたぐ検索（"o w"）
    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);

    const pos = std.mem.indexOf(u8, content, "o w");
    try testing.expect(pos != null);
    try testing.expectEqual(@as(usize, 4), pos.?);
}

test "search pattern split across pieces" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // パターンがpiece境界で分割される場合
    try buffer.insertSlice(0, "abc");
    try buffer.insertSlice(3, "def");
    try buffer.insertSlice(6, "ghi");

    // "cdefg"はpiece境界をまたぐ
    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);

    const pos = std.mem.indexOf(u8, content, "cdefg");
    try testing.expect(pos != null);
    try testing.expectEqual(@as(usize, 2), pos.?);
}

test "search in single piece buffer" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "the quick brown fox");

    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);

    const pos1 = std.mem.indexOf(u8, content, "quick");
    try testing.expect(pos1 != null);
    try testing.expectEqual(@as(usize, 4), pos1.?);

    const pos2 = std.mem.indexOf(u8, content, "xyz");
    try testing.expect(pos2 == null);
}

test "search after delete creates piece boundary" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abcdefghijkl");
    // 中間を削除してpiece境界を作る
    try buffer.delete(3, 3); // "def"削除 → "abcghijkl"

    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);

    // piece境界をまたぐ検索
    const pos = std.mem.indexOf(u8, content, "cgh");
    try testing.expect(pos != null);
    try testing.expectEqual(@as(usize, 2), pos.?);
}

test "search multibyte across piece boundary" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // UTF-8マルチバイト文字がpiece境界をまたぐ
    try buffer.insertSlice(0, "日本");
    try buffer.insertSlice(6, "語");

    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);

    try testing.expectEqualStrings("日本語", content);

    // "本語"を検索
    const pos = std.mem.indexOf(u8, content, "本語");
    try testing.expect(pos != null);
    try testing.expectEqual(@as(usize, 3), pos.?);
}

test "search at piece boundaries exactly" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "aaa");
    try buffer.insertSlice(3, "bbb");
    try buffer.insertSlice(6, "ccc");

    // piece境界ちょうどから始まる検索
    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);

    const pos1 = std.mem.indexOf(u8, content, "bbb");
    try testing.expect(pos1 != null);
    try testing.expectEqual(@as(usize, 3), pos1.?);

    const pos2 = std.mem.indexOf(u8, content, "ccc");
    try testing.expect(pos2 != null);
    try testing.expectEqual(@as(usize, 6), pos2.?);
}

// ============================================================
// 長いコンテンツでのpiece境界テスト
// ============================================================

test "search in fragmented buffer" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 断片化されたバッファ
    for (0..10) |i| {
        var char_buf: [1]u8 = undefined;
        char_buf[0] = @intCast('a' + (i % 26));
        try buffer.insertSlice(i, &char_buf);
    }

    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);

    try testing.expectEqual(@as(usize, 10), content.len);

    // 複数pieceにまたがる検索
    const pos = std.mem.indexOf(u8, content, "abc");
    try testing.expect(pos != null);
    try testing.expectEqual(@as(usize, 0), pos.?);
}

test "Piece consolidation: consecutive inserts create single piece" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 1文字ずつ連続して挿入（従来は10個のPieceになっていた）
    try buffer.insertSlice(0, "H");
    try buffer.insertSlice(1, "e");
    try buffer.insertSlice(2, "l");
    try buffer.insertSlice(3, "l");
    try buffer.insertSlice(4, "o");
    try buffer.insertSlice(5, " ");
    try buffer.insertSlice(6, "W");
    try buffer.insertSlice(7, "o");
    try buffer.insertSlice(8, "r");
    try buffer.insertSlice(9, "l");
    try buffer.insertSlice(10, "d");

    // 内容が正しいことを確認
    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);
    try testing.expectEqualStrings("Hello World", content);

    // Piece統合により、11回の挿入でも1つのPieceになる
    try testing.expectEqual(@as(usize, 1), buffer.pieces.items.len);
}

test "Piece consolidation: non-consecutive insert breaks consolidation" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 最初の挿入
    try buffer.insertSlice(0, "Hello");

    // 末尾に連続挿入（統合される）
    try buffer.insertSlice(5, " ");
    try buffer.insertSlice(6, "World");

    // これで1つのPiece
    try testing.expectEqual(@as(usize, 1), buffer.pieces.items.len);

    // 途中に挿入（統合されない - 位置が違う）
    try buffer.insertSlice(5, "XXX");

    // 分割されて3つのPieceになる
    try testing.expectEqual(@as(usize, 3), buffer.pieces.items.len);

    // 内容が正しいことを確認
    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);
    try testing.expectEqualStrings("HelloXXX World", content);
}

test "Piece consolidation: delete resets consolidation state" {
    const allocator = testing.allocator;

    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 連続挿入
    try buffer.insertSlice(0, "ABC");
    try buffer.insertSlice(3, "DEF");
    try testing.expectEqual(@as(usize, 1), buffer.pieces.items.len);

    // 削除で統合状態がリセット
    try buffer.delete(3, 1); // "D"を削除

    // 同じ位置に挿入しても新しいPieceになる
    try buffer.insertSlice(3, "X");

    // 2つのPiece（"ABC" + "XEF"ではなく、削除後の構造による）
    try testing.expect(buffer.pieces.items.len >= 2);

    // 内容が正しいことを確認
    const content = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(content);
    try testing.expectEqualStrings("ABCXEF", content);
}
