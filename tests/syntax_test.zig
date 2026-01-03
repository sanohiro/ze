const std = @import("std");
const testing = std.testing;
const syntax = @import("syntax");
const detectLanguage = syntax.detectLanguage;
const LanguageDef = syntax.LanguageDef;

// 言語取得ヘルパー（findLanguageByName経由で個別変数への依存を削減）
fn getLang(name: []const u8) *const LanguageDef {
    return syntax.findLanguageByName(name) orelse unreachable;
}

// analyzeLineを使ってコメント開始位置を取得するヘルパー
fn findCommentStart(lang: *const LanguageDef, line: []const u8) ?usize {
    const analysis = lang.analyzeLine(line, false);
    if (analysis.span_count > 0) {
        if (analysis.spans[0]) |span| {
            return span.start;
        }
    }
    return null;
}

// ヘルパー: 言語名で比較（ポインタアドレスは別モジュール間で異なるため）
fn expectLanguage(expected_name: []const u8, actual: *const LanguageDef) !void {
    try testing.expectEqualStrings(expected_name, actual.name);
}

test "detectLanguage by extension" {
    try expectLanguage("Python", detectLanguage("test.py", null));
    try expectLanguage("Zig", detectLanguage("main.zig", null));
    try expectLanguage("Shell", detectLanguage("script.sh", null));
    try expectLanguage("C", detectLanguage("main.c", null));
    try expectLanguage("Rust", detectLanguage("lib.rs", null));
}

test "detectLanguage by filename" {
    try expectLanguage("Makefile", detectLanguage("Makefile", null));
    try expectLanguage("Dockerfile", detectLanguage("Dockerfile", null));
    try expectLanguage("Shell", detectLanguage(".bashrc", null));
}

test "detectLanguage by shebang" {
    try expectLanguage("Shell", detectLanguage("script", "#!/bin/bash\necho hello"));
    try expectLanguage("Python", detectLanguage("script", "#!/usr/bin/env python\nprint('hello')"));
    try expectLanguage("JavaScript", detectLanguage("script", "#!/usr/bin/env node\nconsole.log('hi')"));
}

test "isCommentLine" {
    const lang_python = getLang("Python");
    const lang_zig = getLang("Zig");
    const lang_sql = getLang("SQL");
    const lang_text = syntax.getTextLanguage();

    // Python
    try testing.expect(lang_python.isCommentLine("# comment"));
    try testing.expect(lang_python.isCommentLine("  # indented"));
    try testing.expect(!lang_python.isCommentLine("code # not line comment"));

    // Zig
    try testing.expect(lang_zig.isCommentLine("// comment"));
    try testing.expect(!lang_zig.isCommentLine("# not zig"));

    // SQL
    try testing.expect(lang_sql.isCommentLine("-- comment"));

    // Text (no comment)
    try testing.expect(!lang_text.isCommentLine("# anything"));
}

test "findCommentStart - basic" {
    const lang_cpp = getLang("C++");
    const lang_python = getLang("Python");

    // C++: 行末コメント
    // "int x = 0; // comment"
    //  0123456789AB  (Aは10、Bは11)
    // 位置11から "//" が始まる
    try testing.expectEqual(@as(?usize, 11), findCommentStart(lang_cpp, "int x = 0; // comment"));
    try testing.expectEqual(@as(?usize, 0), findCommentStart(lang_cpp, "// full line comment"));
    try testing.expectEqual(@as(?usize, null), findCommentStart(lang_cpp, "int x = 0;"));

    // Python
    // "x = 10  # comment"
    //  01234567 (位置8が#)
    try testing.expectEqual(@as(?usize, 8), findCommentStart(lang_python, "x = 10  # comment"));
    try testing.expectEqual(@as(?usize, 0), findCommentStart(lang_python, "# comment"));
}

test "findCommentStart - string skip" {
    const lang_cpp = getLang("C++");
    const lang_python = getLang("Python");

    // 文字列内の // はコメントじゃない
    // "char* s = \"// not comment\";"  (28文字、0-27)
    try testing.expectEqual(@as(?usize, null), findCommentStart(lang_cpp, "char* s = \"// not comment\";"));
    // "char* s = \"// not comment\"; // real"
    //  0         1         2         3
    //  0123456789012345678901234567890123456
    // 位置28から "//" が始まる
    try testing.expectEqual(@as(?usize, 28), findCommentStart(lang_cpp, "char* s = \"// not comment\"; // real"));

    // Python: 文字列内の # はコメントじゃない
    // "s = \"# not comment\""  (19文字、0-18)
    try testing.expectEqual(@as(?usize, null), findCommentStart(lang_python, "s = \"# not comment\""));
    // "s = \"# not comment\" # real"
    //  0         1         2
    //  01234567890123456789012345
    // 位置20から "#" が始まる
    try testing.expectEqual(@as(?usize, 20), findCommentStart(lang_python, "s = \"# not comment\" # real"));

    // エスケープされた引用符
    // "char* s = \"test\\\"\"; // comment"
    //  0         1         2
    //  01234567890123456789012345678901
    // 文字列は "test\"" で、位置20から "//" が始まる
    try testing.expectEqual(@as(?usize, 20), findCommentStart(lang_cpp, "char* s = \"test\\\"\"; // comment"));
}
