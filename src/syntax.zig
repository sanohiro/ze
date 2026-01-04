// zeエディタのシンタックス定義
// ファイル拡張子・シグネチャから言語を判別し、コメント検出を提供
//
// 方針: コメントだけ色付け（キーワード等のシンタックスハイライトはしない）

const std = @import("std");

// ============================================
// 言語定義構造体
// ============================================

/// シグネチャのマッチ方法
pub const MatchType = enum {
    starts_with, // 行頭一致
    contains, // 含む
};

/// ファイル先頭のシグネチャ (shebang, マジックコメント等)
pub const Signature = struct {
    pattern: []const u8,
    match_type: MatchType,
    line: u8, // 対象行 (0 = 1行目)
};

/// ブロックコメントの開始・終了ペア
pub const BlockComment = struct {
    start: []const u8, // 例: "/*"
    end: []const u8, // 例: "*/"
};

/// インデントスタイル
pub const IndentStyle = enum {
    tab,
    space,
};

/// 言語のシンタックス定義（コメント検出用に簡略化）
pub const LanguageDef = struct {
    /// 言語名 (表示用)
    name: []const u8,

    /// ファイル拡張子 (例: &.{ "py", "pyw" })
    extensions: []const []const u8,

    /// ファイル名パターン (例: &.{ "Makefile", "Dockerfile" })
    filenames: []const []const u8,

    /// ファイル先頭のシグネチャ
    signatures: []const Signature,

    /// 行コメント開始 (例: "//", "#")
    line_comment: ?[]const u8,

    /// ブロックコメント (例: /* */)
    block_comment: ?BlockComment,

    /// 文字列区切り文字 (例: "\"'" または "\"" または "")
    string_chars: []const u8,

    /// インデントスタイル（タブ or スペース）
    indent_style: IndentStyle,

    /// インデント幅（スペース数 or タブ表示幅）
    indent_width: u8,

    /// 行のコメント解析結果
    pub const CommentSpan = struct {
        start: usize, // コメント開始バイト位置
        end: ?usize, // コメント終了バイト位置（nullなら行末まで）
    };

    /// 行のコメント解析結果（複数のコメント範囲を返す）
    pub const LineAnalysis = struct {
        /// コメント範囲のリスト（最大4つまで）
        spans: [4]?CommentSpan,
        span_count: usize,
        /// 行末でブロックコメント内かどうか
        ends_in_block: bool,

        pub fn init() LineAnalysis {
            return .{
                .spans = .{ null, null, null, null },
                .span_count = 0,
                .ends_in_block = false,
            };
        }

        pub fn addSpan(self: *LineAnalysis, start: usize, end: ?usize) void {
            if (self.span_count < 4) {
                self.spans[self.span_count] = .{ .start = start, .end = end };
                self.span_count += 1;
            }
        }
    };

    /// コメント定義があるかどうか
    pub inline fn hasComments(self: *const LanguageDef) bool {
        return self.line_comment != null or self.block_comment != null;
    }

    /// 行を解析してコメント範囲を検出
    /// in_block: この行がブロックコメント内で始まるかどうか
    pub fn analyzeLine(self: *const LanguageDef, line: []const u8, in_block: bool) LineAnalysis {
        var result = LineAnalysis.init();

        // コメントがない言語なら即座に終了（最適化）
        if (!in_block and self.line_comment == null and self.block_comment == null) {
            return result;
        }

        var i: usize = 0;
        var currently_in_block = in_block;

        // ブロックコメント内で始まる場合
        if (currently_in_block) {
            if (self.block_comment) |bc| {
                // ブロックコメント終了を探す
                if (std.mem.indexOf(u8, line, bc.end)) |end_pos| {
                    result.addSpan(0, end_pos + bc.end.len);
                    i = end_pos + bc.end.len;
                    currently_in_block = false;
                } else {
                    // 行全体がブロックコメント内
                    result.addSpan(0, null);
                    result.ends_in_block = true;
                    return result;
                }
            } else {
                // ブロックコメント定義がないのにin_block=trueは矛盾状態
                // 安全のためリセット
                currently_in_block = false;
            }
        }

        while (i < line.len) {
            const ch = line[i];

            // 文字列リテラルをスキップ
            var matched_delim: ?u8 = null;
            for (self.string_chars) |delim| {
                if (ch == delim) {
                    matched_delim = delim;
                    break;
                }
            }

            if (matched_delim) |delim| {
                i += 1;
                // 文字列の終端を探す（エスケープ考慮）
                while (i < line.len) {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 2;
                    } else if (line[i] == delim) {
                        i += 1;
                        break;
                    } else {
                        i += 1;
                    }
                }
                continue;
            }

            // ブロックコメント開始をチェック
            if (self.block_comment) |bc| {
                if (i + bc.start.len <= line.len and std.mem.eql(u8, line[i..][0..bc.start.len], bc.start)) {
                    const block_start = i;
                    i += bc.start.len;
                    // ブロックコメント終了を探す
                    if (std.mem.indexOf(u8, line[i..], bc.end)) |rel_end| {
                        const end_pos = i + rel_end + bc.end.len;
                        result.addSpan(block_start, end_pos);
                        i = end_pos;
                    } else {
                        // 行末まで（次行に続く）
                        result.addSpan(block_start, null);
                        result.ends_in_block = true;
                        return result;
                    }
                    continue;
                }
            }

            // 行コメント開始をチェック
            if (self.line_comment) |lc| {
                if (i + lc.len <= line.len and std.mem.eql(u8, line[i..][0..lc.len], lc)) {
                    result.addSpan(i, null);
                    return result; // 行コメントは行末まで
                }
            }

            i += 1;
        }

        result.ends_in_block = currently_in_block;
        return result;
    }

    /// 指定された行が全体がコメント行かどうかを判定（行頭判定）
    pub fn isCommentLine(self: *const LanguageDef, line: []const u8) bool {
        // 行頭の空白をスキップ
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
            i += 1;
        }
        if (i >= line.len) return false;

        // 行コメントをチェック
        if (self.line_comment) |lc| {
            if (i + lc.len <= line.len and std.mem.startsWith(u8, line[i..], lc)) {
                return true;
            }
        }

        return false;
    }
};

// ============================================
// 言語定義データ
// ============================================

// --- # コメント系 (Shell, Python, Ruby, Perl, etc.) ---

pub const lang_shell = LanguageDef{
    .name = "Shell",
    .extensions = &.{ "sh", "bash", "zsh", "fish", "ksh" },
    .filenames = &.{ ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile" },
    .signatures = &.{
        .{ .pattern = "#!/bin/sh", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/bin/bash", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/env bash", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/env sh", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/bin/zsh", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/env zsh", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_python = LanguageDef{
    .name = "Python",
    .extensions = &.{ "py", "pyw", "pyi" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env python", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/python", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "# -*- coding:", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "# -*- coding:", .match_type = .starts_with, .line = 1 },
    },
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_ruby = LanguageDef{
    .name = "Ruby",
    .extensions = &.{ "rb", "rake", "gemspec", "ru" },
    .filenames = &.{ "Rakefile", "Gemfile", "Guardfile", "Capfile" },
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env ruby", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/ruby", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_perl = LanguageDef{
    .name = "Perl",
    .extensions = &.{ "pl", "pm", "t", "pod" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env perl", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/perl", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_r = LanguageDef{
    .name = "R",
    .extensions = &.{ "r", "R", "Rmd" },
    .filenames = &.{ ".Rprofile" },
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env Rscript", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_makefile = LanguageDef{
    .name = "Makefile",
    .extensions = &.{"mk"},
    .filenames = &.{ "Makefile", "makefile", "GNUmakefile" },
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .tab, // Makefile はタブ必須
    .indent_width = 8,
};

pub const lang_yaml = LanguageDef{
    .name = "YAML",
    .extensions = &.{ "yml", "yaml" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "%YAML", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_toml = LanguageDef{
    .name = "TOML",
    .extensions = &.{"toml"},
    .filenames = &.{ "Cargo.toml", "pyproject.toml" },
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_dockerfile = LanguageDef{
    .name = "Dockerfile",
    .extensions = &.{},
    .filenames = &.{ "Dockerfile", "dockerfile", "Containerfile" },
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_nginx = LanguageDef{
    .name = "Nginx",
    .extensions = &.{},
    .filenames = &.{ "nginx.conf", "mime.types" },
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_apache = LanguageDef{
    .name = "Apache",
    .extensions = &.{},
    .filenames = &.{ ".htaccess", "httpd.conf", "apache.conf", "apache2.conf" },
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_systemd = LanguageDef{
    .name = "Systemd",
    .extensions = &.{ "service", "socket", "timer", "path", "mount", "automount", "target", "slice", "scope" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_env = LanguageDef{
    .name = "Environment",
    .extensions = &.{"env"},
    .filenames = &.{ ".env", ".env.local", ".env.development", ".env.production", ".env.test", ".env.example" },
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 0, // インデントなし
};

pub const lang_awk = LanguageDef{
    .name = "AWK",
    .extensions = &.{"awk"},
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/awk", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/env awk", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/gawk", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/env gawk", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_elixir = LanguageDef{
    .name = "Elixir",
    .extensions = &.{ "ex", "exs" },
    .filenames = &.{ "mix.exs" },
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env elixir", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_terraform = LanguageDef{
    .name = "Terraform",
    .extensions = &.{ "tf", "tfvars" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_graphql = LanguageDef{
    .name = "GraphQL",
    .extensions = &.{ "graphql", "gql" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_gitignore = LanguageDef{
    .name = "Gitignore",
    .extensions = &.{"gitignore"},
    .filenames = &.{ ".gitignore", ".gitattributes", ".gitmodules", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore" },
    .signatures = &.{},
    .line_comment = "#",
    .block_comment = null,
    .string_chars = "",
    .indent_style = .space,
    .indent_width = 0, // インデントなし
};

// --- // コメント系 (C, C++, Java, JavaScript, etc.) ---

pub const lang_c = LanguageDef{
    .name = "C",
    .extensions = &.{ "c", "h" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_cpp = LanguageDef{
    .name = "C++",
    .extensions = &.{ "cpp", "cxx", "cc", "hpp", "hxx", "hh", "h++" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_zig = LanguageDef{
    .name = "Zig",
    .extensions = &.{"zig"},
    .filenames = &.{ "build.zig", "build.zig.zon" },
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = null, // Zigはブロックコメントなし
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_rust = LanguageDef{
    .name = "Rust",
    .extensions = &.{"rs"},
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_go = LanguageDef{
    .name = "Go",
    .extensions = &.{"go"},
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'`",
    .indent_style = .tab, // Go は gofmt でタブ推奨
    .indent_width = 4,
};

pub const lang_javascript = LanguageDef{
    .name = "JavaScript",
    .extensions = &.{ "js", "mjs", "cjs", "jsx" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env node", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'`",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_typescript = LanguageDef{
    .name = "TypeScript",
    .extensions = &.{ "ts", "tsx", "mts", "cts" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'`",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_java = LanguageDef{
    .name = "Java",
    .extensions = &.{"java"},
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_swift = LanguageDef{
    .name = "Swift",
    .extensions = &.{"swift"},
    .filenames = &.{ "Package.swift" },
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env swift", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_kotlin = LanguageDef{
    .name = "Kotlin",
    .extensions = &.{ "kt", "kts" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_scala = LanguageDef{
    .name = "Scala",
    .extensions = &.{ "scala", "sc" },
    .filenames = &.{ "build.sbt" },
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_csharp = LanguageDef{
    .name = "C#",
    .extensions = &.{"cs"},
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_fsharp = LanguageDef{
    .name = "F#",
    .extensions = &.{ "fs", "fsi", "fsx" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//",
    .block_comment = .{ .start = "(*", .end = "*)" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_php = LanguageDef{
    .name = "PHP",
    .extensions = &.{ "php", "phtml", "php3", "php4", "php5", "phps" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "<?php", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/env php", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "//",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 4,
};

pub const lang_protobuf = LanguageDef{
    .name = "Protocol Buffers",
    .extensions = &.{"proto"},
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "syntax = ", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "//",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_css = LanguageDef{
    .name = "CSS",
    .extensions = &.{ "css", "scss", "sass", "less" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "//", // SCSS/LESS用
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

// --- -- コメント系 (SQL, Lua, Haskell) ---

pub const lang_sql = LanguageDef{
    .name = "SQL",
    .extensions = &.{"sql"},
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "--",
    .block_comment = .{ .start = "/*", .end = "*/" },
    .string_chars = "'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_lua = LanguageDef{
    .name = "Lua",
    .extensions = &.{"lua"},
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env lua", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = "--",
    .block_comment = .{ .start = "--[[", .end = "]]" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_haskell = LanguageDef{
    .name = "Haskell",
    .extensions = &.{ "hs", "lhs" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = "--",
    .block_comment = .{ .start = "{-", .end = "-}" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

// --- ; コメント系 (Lisp, INI) ---

pub const lang_elisp = LanguageDef{
    .name = "Emacs Lisp",
    .extensions = &.{"el"},
    .filenames = &.{ ".emacs", "_emacs", ".gnus" },
    .signatures = &.{
        .{ .pattern = ";;; -*-", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = ";",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_commonlisp = LanguageDef{
    .name = "Common Lisp",
    .extensions = &.{ "lisp", "cl", "lsp", "asd", "asdf" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env sbcl", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/env clisp", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = ";",
    .block_comment = .{ .start = "#|", .end = "|#" },
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_scheme = LanguageDef{
    .name = "Scheme",
    .extensions = &.{ "scm", "ss", "sld", "sls", "sps" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env guile", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "#!/usr/bin/env racket", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = ";",
    .block_comment = .{ .start = "#|", .end = "|#" },
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_clojure = LanguageDef{
    .name = "Clojure",
    .extensions = &.{ "clj", "cljs", "cljc", "edn" },
    .filenames = &.{ "project.clj", "deps.edn" },
    .signatures = &.{},
    .line_comment = ";",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_ini = LanguageDef{
    .name = "INI",
    .extensions = &.{ "ini", "cfg", "conf" },
    .filenames = &.{ ".gitconfig", ".editorconfig" },
    .signatures = &.{},
    .line_comment = ";",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 0, // インデントなし
};

// --- % コメント系 (Erlang) ---

pub const lang_erlang = LanguageDef{
    .name = "Erlang",
    .extensions = &.{ "erl", "hrl" },
    .filenames = &.{ "rebar.config" },
    .signatures = &.{},
    .line_comment = "%",
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 4,
};

// --- " コメント系 (Vim) ---

pub const lang_vim = LanguageDef{
    .name = "Vim script",
    .extensions = &.{"vim"},
    .filenames = &.{ ".vimrc", ".gvimrc", "_vimrc", "_gvimrc" },
    .signatures = &.{},
    .line_comment = "\"",
    .block_comment = null,
    .string_chars = "'", // " がコメントなので ' のみ
    .indent_style = .space,
    .indent_width = 2,
};

// --- コメントなし or ブロックのみ ---

pub const lang_json = LanguageDef{
    .name = "JSON",
    .extensions = &.{ "json", "jsonc" },
    .filenames = &.{ "package.json", "tsconfig.json", "composer.json" },
    .signatures = &.{},
    .line_comment = null,
    .block_comment = null,
    .string_chars = "\"",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_html = LanguageDef{
    .name = "HTML",
    .extensions = &.{ "html", "htm", "xhtml" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "<!DOCTYPE html", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "<html", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = null,
    .block_comment = .{ .start = "<!--", .end = "-->" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_xml = LanguageDef{
    .name = "XML",
    .extensions = &.{ "xml", "xsl", "xslt", "svg", "xsd", "wsdl" },
    .filenames = &.{ "pom.xml" },
    .signatures = &.{
        .{ .pattern = "<?xml", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = null,
    .block_comment = .{ .start = "<!--", .end = "-->" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_markdown = LanguageDef{
    .name = "Markdown",
    .extensions = &.{ "md", "markdown", "mdown", "mkd" },
    .filenames = &.{ "README", "CHANGELOG", "LICENSE" },
    .signatures = &.{},
    .line_comment = null,
    .block_comment = null,
    .string_chars = "",
    .indent_style = .space,
    .indent_width = 2,
};

pub const lang_diff = LanguageDef{
    .name = "Diff",
    .extensions = &.{ "diff", "patch" },
    .filenames = &.{},
    .signatures = &.{
        .{ .pattern = "diff ", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "--- ", .match_type = .starts_with, .line = 0 },
        .{ .pattern = "Index: ", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = null,
    .block_comment = null,
    .string_chars = "",
    .indent_style = .space,
    .indent_width = 0, // インデントなし
};

pub const lang_ocaml = LanguageDef{
    .name = "OCaml",
    .extensions = &.{ "ml", "mli", "mll", "mly" },
    .filenames = &.{ "dune", "dune-project" },
    .signatures = &.{
        .{ .pattern = "#!/usr/bin/env ocaml", .match_type = .starts_with, .line = 0 },
    },
    .line_comment = null,
    .block_comment = .{ .start = "(*", .end = "*)" },
    .string_chars = "\"'",
    .indent_style = .space,
    .indent_width = 2,
};

// --- デフォルト ---

pub const lang_text = LanguageDef{
    .name = "Text",
    .extensions = &.{ "txt", "text", "log" },
    .filenames = &.{},
    .signatures = &.{},
    .line_comment = null,
    .block_comment = null,
    .string_chars = "",
    .indent_style = .space,
    .indent_width = 4, // テキストのデフォルト
};

// ============================================
// 全言語リスト
// ============================================

pub const all_languages = [_]*const LanguageDef{
    // # コメント系
    &lang_shell,
    &lang_python,
    &lang_ruby,
    &lang_perl,
    &lang_r,
    &lang_makefile,
    &lang_yaml,
    &lang_toml,
    &lang_dockerfile,
    &lang_nginx,
    &lang_apache,
    &lang_systemd,
    &lang_env,
    &lang_awk,
    &lang_elixir,
    &lang_terraform,
    &lang_graphql,
    &lang_gitignore,
    // // コメント系
    &lang_c,
    &lang_cpp,
    &lang_zig,
    &lang_rust,
    &lang_go,
    &lang_javascript,
    &lang_typescript,
    &lang_java,
    &lang_swift,
    &lang_kotlin,
    &lang_scala,
    &lang_csharp,
    &lang_fsharp,
    &lang_php,
    &lang_protobuf,
    &lang_css,
    // -- コメント系
    &lang_sql,
    &lang_lua,
    &lang_haskell,
    // ; コメント系
    &lang_elisp,
    &lang_commonlisp,
    &lang_scheme,
    &lang_clojure,
    &lang_ini,
    // % コメント系
    &lang_erlang,
    // " コメント系
    &lang_vim,
    // コメントなし
    &lang_json,
    &lang_html,
    &lang_xml,
    &lang_markdown,
    &lang_diff,
    &lang_ocaml,
    // Default
    &lang_text,
};

// ============================================
// 言語アクセスヘルパー
// ============================================

/// デフォルトのテキスト言語を取得（コメントなし）
/// 外部からlang_textを直接参照する代わりにこれを使用
pub inline fn getTextLanguage() *const LanguageDef {
    return all_languages[all_languages.len - 1];
}

/// 言語名で言語定義を検索（テスト用）
/// 見つからない場合はnullを返す
pub fn findLanguageByName(name: []const u8) ?*const LanguageDef {
    for (all_languages) |lang| {
        if (std.mem.eql(u8, lang.name, name)) {
            return lang;
        }
    }
    return null;
}

// ============================================
// 言語検出
// ============================================

/// ファイル名とコンテンツから言語を検出
/// 優先順位: シグネチャ > ファイル名 > 拡張子 > テキスト
pub fn detectLanguage(filename: ?[]const u8, content: ?[]const u8) *const LanguageDef {
    // 1. シグネチャでチェック（shebang等）
    if (content) |c| {
        if (detectBySignature(c)) |lang| {
            return lang;
        }
    }

    const fname = filename orelse return getTextLanguage();

    // 2. ファイル名でチェック
    if (detectByFilename(fname)) |lang| {
        return lang;
    }

    // 3. 拡張子でチェック
    if (detectByExtension(fname)) |lang| {
        return lang;
    }

    return getTextLanguage();
}

/// シグネチャから言語を検出
fn detectBySignature(content: []const u8) ?*const LanguageDef {
    // 早期終了: 空またはシグネチャを持ちそうにないファイルはスキップ
    // シグネチャの大半はshebang (#!) なので、先頭2バイトでチェック
    if (content.len < 2) return null;

    // 先頭256バイトのみをチェック対象にする（シグネチャは必ず先頭付近）
    const check_content = content[0..@min(content.len, 256)];

    // 最初の数行を取得
    var lines: [5][]const u8 = undefined;
    var line_count: usize = 0;
    var start: usize = 0;

    for (check_content, 0..) |c, i| {
        if (c == '\n' or i == check_content.len - 1) {
            const end = if (c == '\n') i else i + 1;
            if (line_count < 5) {
                lines[line_count] = check_content[start..end];
                line_count += 1;
            }
            start = i + 1;
            if (line_count >= 5) break;
        }
    }

    // 各言語のシグネチャをチェック
    for (all_languages) |lang| {
        for (lang.signatures) |sig| {
            if (sig.line < line_count) {
                const line = lines[sig.line];
                const matched = switch (sig.match_type) {
                    .starts_with => std.mem.startsWith(u8, line, sig.pattern),
                    .contains => std.mem.indexOf(u8, line, sig.pattern) != null,
                };
                if (matched) return lang;
            }
        }
    }

    return null;
}

/// ファイル名から言語を検出
fn detectByFilename(path: []const u8) ?*const LanguageDef {
    const basename = getBasename(path);

    for (all_languages) |lang| {
        for (lang.filenames) |fname| {
            if (std.mem.eql(u8, basename, fname)) {
                return lang;
            }
            // Dockerfile.xxx パターン対応
            if (std.mem.startsWith(u8, fname, "Dockerfile") and
                std.mem.startsWith(u8, basename, "Dockerfile"))
            {
                return lang;
            }
        }
    }

    return null;
}

/// 拡張子から言語を検出
fn detectByExtension(path: []const u8) ?*const LanguageDef {
    const ext = getExtension(path);
    if (ext.len == 0) return null;

    for (all_languages) |lang| {
        for (lang.extensions) |e| {
            if (std.mem.eql(u8, ext, e)) {
                return lang;
            }
        }
    }

    return null;
}

/// ファイルパスからベースネームを取得
fn getBasename(path: []const u8) []const u8 {
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            return path[i + 1 ..];
        }
    }
    return path;
}

/// ファイルパスから拡張子を取得（ドットなし）
fn getExtension(path: []const u8) []const u8 {
    const basename = getBasename(path);
    var i: usize = basename.len;
    while (i > 0) {
        i -= 1;
        if (basename[i] == '.') {
            if (i + 1 < basename.len) {
                return basename[i + 1 ..];
            }
            return "";
        }
    }
    return "";
}
