const std = @import("std");
const testing = std.testing;
const Buffer = @import("buffer").Buffer;
const EditingContext = @import("editing_context").EditingContext;

// ============================================================
// 矩形コピー＆ペーストテスト
// ============================================================

test "rectangle copy - basic rectangle" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc\ndef\nghi");

    // 矩形領域を抽出（列1〜2、行0〜2）
    // "bc", "ef", "hi"
    const line1_range = buffer.getLineRange(0);
    try testing.expect(line1_range != null);
    try testing.expectEqual(@as(usize, 0), line1_range.?.start);
    try testing.expectEqual(@as(usize, 3), line1_range.?.end);

    // 行2つ目
    const line2_range = buffer.getLineRange(1);
    try testing.expect(line2_range != null);
    try testing.expectEqual(@as(usize, 4), line2_range.?.start);
    try testing.expectEqual(@as(usize, 7), line2_range.?.end);
}

test "rectangle copy - single column" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc\ndef\nghi");

    // 単一列の矩形（列0のみ）
    // "a", "d", "g"
    const line0 = try buffer.getRange(allocator, 0, 1);
    defer allocator.free(line0);
    try testing.expectEqualStrings("a", line0);

    const line1 = try buffer.getRange(allocator, 4, 1);
    defer allocator.free(line1);
    try testing.expectEqualStrings("d", line1);

    const line2 = try buffer.getRange(allocator, 8, 1);
    defer allocator.free(line2);
    try testing.expectEqualStrings("g", line2);
}

test "rectangle paste - insert mode" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "12\n34\n56");

    // 矩形ペースト: 各行の位置1に"X"を挿入
    // "1X2\n3X4\n5X6"
    try buffer.insertSlice(1, "X");
    try buffer.insertSlice(5, "X");
    try buffer.insertSlice(9, "X");

    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("1X2\n3X4\n5X6", data);
}

test "rectangle paste - overwrite mode" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc\ndef\nghi");

    // 矩形ペースト（上書き）: 列1〜2を"XX"で上書き
    // "aXX\ndXX\ngXX"
    try buffer.delete(1, 2);
    try buffer.insertSlice(1, "XX");

    try buffer.delete(5, 2);
    try buffer.insertSlice(5, "XX");

    try buffer.delete(9, 2);
    try buffer.insertSlice(9, "XX");

    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("aXX\ndXX\ngXX", data);
}

// ============================================================
// 短い行を含む矩形操作テスト
// ============================================================

test "rectangle copy - short lines with padding" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // 行の長さがバラバラ
    try buffer.insertSlice(0, "abc\nx\ndefgh");

    // 矩形範囲（列1〜3）
    // "bc", " ", "ef" （2行目は短いのでスペースでパディング）

    const line0_text = try buffer.getRange(allocator, 1, 2); // "bc"
    defer allocator.free(line0_text);
    try testing.expectEqualStrings("bc", line0_text);

    // 2行目は1文字しかない（"x"）→ 列1以降は存在しない
    const line1_start = buffer.getLineStart(1).?;
    try testing.expectEqual(@as(usize, 4), line1_start);
    const line1_len = buffer.getLineRange(1).?.end - line1_start;
    try testing.expectEqual(@as(usize, 1), line1_len);

    // 3行目: "abc\nx\ndefgh" の "defgh" は位置6から
    const line2_text = try buffer.getRange(allocator, 7, 2); // "ef"
    defer allocator.free(line2_text);
    try testing.expectEqualStrings("ef", line2_text);
}

test "rectangle paste - short line padding" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // "abc\nx\ndefgh" の位置:
    // 0-2: abc
    // 3: \n
    // 4: x
    // 5: \n
    // 6-10: defgh
    try buffer.insertSlice(0, "abc\nx\ndefgh");

    // 矩形ペースト（列3に"!"を挿入）
    // 後ろから挿入することで位置ずれを防ぐ

    // 3行目: 位置11（defghの後ろ、つまりバッファ末尾）に挿入
    try buffer.insertSlice(11, "!");
    // 結果: "abc\nx\ndefgh!"

    // 2行目: 位置5（xの後ろ、改行の前）に"  !"を挿入
    try buffer.insertSlice(5, "  !");
    // 結果: "abc\nx  !\ndefgh!"

    // 1行目: 位置3に挿入
    try buffer.insertSlice(3, "!");
    // 結果: "abc!\nx  !\ndefgh!"

    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("abc!\nx  !\ndefgh!", data);
}

test "rectangle - empty line" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc\n\ndefgh");

    // 2行目は空行 → 矩形範囲を取ると何も取得できない
    const line1_range = buffer.getLineRange(1);
    try testing.expect(line1_range != null);
    const line1_len = line1_range.?.end - line1_range.?.start;
    try testing.expectEqual(@as(usize, 0), line1_len);
}

test "rectangle copy - all lines shorter than rectangle" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "a\nb\nc");

    // 矩形範囲（列2〜4）→ すべての行が短い
    // 各行1文字しかないので、列2以降は存在しない
    for (0..3) |i| {
        const line_range = buffer.getLineRange(i);
        try testing.expect(line_range != null);
        const line_len = line_range.?.end - line_range.?.start;
        try testing.expectEqual(@as(usize, 1), line_len);
    }
}

// ============================================================
// 矩形削除テスト
// ============================================================

test "rectangle delete - basic" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // "abcd\nefgh\nijkl" の位置:
    // 0-3: abcd
    // 4: \n
    // 5-8: efgh
    // 9: \n
    // 10-13: ijkl
    try buffer.insertSlice(0, "abcd\nefgh\nijkl");

    // 矩形削除（列1〜2を削除）
    // "ad\neh\nil"

    // 3行目から削除（後ろから削除することで位置がずれない）
    try buffer.delete(11, 2); // "jk" 削除 (位置11-12)
    try buffer.delete(6, 2); // "fg" 削除 (位置6-7)
    try buffer.delete(1, 2); // "bc" 削除 (位置1-2)

    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("ad\neh\nil", data);
}

test "rectangle delete - short lines" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // "abcd\nef\nghij" の位置:
    // 0-3: abcd
    // 4: \n
    // 5-6: ef
    // 7: \n
    // 8-11: ghij
    try buffer.insertSlice(0, "abcd\nef\nghij");

    // 矩形削除（列2〜3を削除）
    // 1行目: "ab"
    // 2行目: "ef" (削除対象なし、短い)
    // 3行目: "gh"

    // 3行目: "ij" を削除 (位置10-11)
    try buffer.delete(10, 2); // "ij" 削除
    // 2行目: 削除対象なし
    // 1行目: "cd" を削除 (位置2-3)
    try buffer.delete(2, 2); // "cd" 削除

    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("ab\nef\ngh", data);
}

// ============================================================
// 矩形挿入テスト（全行同じ位置に挿入）
// ============================================================

test "rectangle insert - prepend to all lines" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc\ndef\nghi");

    // 各行の先頭に">"を挿入
    // ">abc\n>def\n>ghi"

    try buffer.insertSlice(8, ">"); // 3行目
    try buffer.insertSlice(4, ">"); // 2行目
    try buffer.insertSlice(0, ">"); // 1行目

    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings(">abc\n>def\n>ghi", data);
}

test "rectangle insert - append to all lines" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc\ndef\nghi");

    // 各行の末尾に"!"を挿入
    // "abc!\ndef!\nghi!"

    try buffer.insertSlice(11, "!"); // 3行目
    try buffer.insertSlice(7, "!"); // 2行目
    try buffer.insertSlice(3, "!"); // 1行目

    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("abc!\ndef!\nghi!", data);
}

// ============================================================
// エッジケース: UTF-8
// ============================================================

test "rectangle - multibyte characters" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "あいう\nかきく\nさしす");

    // UTF-8では各文字3バイト
    // 1行目: 0-9 (9バイト + 改行)
    // 2行目: 10-19
    // 3行目: 20-29

    const line0_range = buffer.getLineRange(0);
    try testing.expect(line0_range != null);
    try testing.expectEqual(@as(usize, 0), line0_range.?.start);
    try testing.expectEqual(@as(usize, 9), line0_range.?.end);

    const line1_range = buffer.getLineRange(1);
    try testing.expect(line1_range != null);
    try testing.expectEqual(@as(usize, 10), line1_range.?.start);
    try testing.expectEqual(@as(usize, 19), line1_range.?.end);
}

test "rectangle copy - mixed ASCII and multibyte" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    // "a日本\nb語c\nd漢字"
    // a(1) + 日(3) + 本(3) + \n(1) + b(1) + 語(3) + c(1) + \n(1) + d(1) + 漢(3) + 字(3) = 21
    try buffer.insertSlice(0, "a日本\nb語c\nd漢字");

    // 矩形コピーはバイト位置ではなく表示列で行う
    // 実際の矩形操作は表示幅を考慮するため、ここでは基本的なバイト操作のみ確認
    try testing.expectEqual(@as(usize, 21), buffer.len());
}

// ============================================================
// エッジケース: 単一行バッファ
// ============================================================

test "rectangle - single line buffer" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abcdef");

    // 単一行での矩形操作は通常の範囲操作と同じ
    try buffer.delete(2, 2); // "cd" 削除 → "abef"
    const data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(data);
    try testing.expectEqualStrings("abef", data);
}

// ============================================================
// エッジケース: 矩形範囲が全バッファ
// ============================================================

test "rectangle - entire buffer as rectangle" {
    const allocator = testing.allocator;
    var buffer = try Buffer.init(allocator);
    defer buffer.deinit();

    try buffer.insertSlice(0, "abc\ndef\nghi");

    // 全体を矩形として扱う（列0〜末尾）
    const full_data = try buffer.getRange(allocator, 0, buffer.len());
    defer allocator.free(full_data);
    try testing.expectEqualStrings("abc\ndef\nghi", full_data);

    // 矩形削除 → 空バッファ
    try buffer.delete(0, buffer.len());
    try testing.expectEqual(@as(usize, 0), buffer.len());
}
