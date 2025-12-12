const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // バージョンはbuild.zig.zonから取得（単一ソースオブトルース）
    const version = @import("build.zig.zon").version;

    // リリースビルド時はデバッグ情報を削除
    const strip = b.option(bool, "strip", "Strip debug info") orelse (optimize != .Debug);

    // バージョンをビルドオプションとして渡す
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // === モジュール定義（依存関係順） ===

    // 依存なしのモジュール
    const unicode_mod = b.addModule("unicode", .{
        .root_source_file = b.path("src/unicode.zig"),
        .target = target,
        .optimize = optimize,
    });

    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    const history_mod = b.addModule("history", .{
        .root_source_file = b.path("src/history.zig"),
        .target = target,
        .optimize = optimize,
    });

    const regex_mod = b.addModule("regex", .{
        .root_source_file = b.path("src/regex.zig"),
        .target = target,
        .optimize = optimize,
    });

    const syntax_mod = b.addModule("syntax", .{
        .root_source_file = b.path("src/syntax.zig"),
        .target = target,
        .optimize = optimize,
    });

    const poller_mod = b.addModule("poller", .{
        .root_source_file = b.path("src/poller.zig"),
        .target = target,
        .optimize = optimize,
    });

    // encoding <- config
    const encoding_mod = b.addModule("encoding", .{
        .root_source_file = b.path("src/encoding.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    // terminal <- config
    const terminal_mod = b.addModule("terminal", .{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });

    // input <- config, unicode
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "unicode", .module = unicode_mod },
        },
    });

    // buffer <- unicode, config, encoding
    const buffer_mod = b.addModule("buffer", .{
        .root_source_file = b.path("src/buffer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unicode", .module = unicode_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "encoding", .module = encoding_mod },
        },
    });

    // view <- buffer, terminal, config, syntax, encoding, unicode
    const view_mod = b.addModule("view", .{
        .root_source_file = b.path("src/view.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "terminal", .module = terminal_mod },
            .{ .name = "config", .module = config_mod },
            .{ .name = "syntax", .module = syntax_mod },
            .{ .name = "encoding", .module = encoding_mod },
            .{ .name = "unicode", .module = unicode_mod },
        },
    });

    // editing_context <- buffer, unicode
    const editing_context_mod = b.addModule("editing_context", .{
        .root_source_file = b.path("src/editing_context.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "unicode", .module = unicode_mod },
        },
    });

    // services/minibuffer <- unicode, input
    const minibuffer_mod = b.addModule("minibuffer", .{
        .root_source_file = b.path("src/services/minibuffer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "unicode", .module = unicode_mod },
            .{ .name = "input", .module = input_mod },
        },
    });

    // services/search_service <- regex, history, buffer
    const search_service_mod = b.addModule("search_service", .{
        .root_source_file = b.path("src/services/search_service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "regex", .module = regex_mod },
            .{ .name = "history", .module = history_mod },
            .{ .name = "buffer", .module = buffer_mod },
        },
    });

    // services/shell_service <- history
    const shell_service_mod = b.addModule("shell_service", .{
        .root_source_file = b.path("src/services/shell_service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "history", .module = history_mod },
        },
    });

    // services/buffer_manager <- buffer, editing_context
    const buffer_manager_mod = b.addModule("buffer_manager", .{
        .root_source_file = b.path("src/services/buffer_manager.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "editing_context", .module = editing_context_mod },
        },
    });

    // services/window_manager <- view
    const window_manager_mod = b.addModule("window_manager", .{
        .root_source_file = b.path("src/services/window_manager.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "view", .module = view_mod },
        },
    });

    // services/macro_service <- input
    const macro_service_mod = b.addModule("macro_service", .{
        .root_source_file = b.path("src/services/macro_service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "input", .module = input_mod },
        },
    });

    // editor用の全依存関係リスト
    const editor_imports = &[_]std.Build.Module.Import{
        .{ .name = "buffer", .module = buffer_mod },
        .{ .name = "view", .module = view_mod },
        .{ .name = "terminal", .module = terminal_mod },
        .{ .name = "input", .module = input_mod },
        .{ .name = "config", .module = config_mod },
        .{ .name = "regex", .module = regex_mod },
        .{ .name = "history", .module = history_mod },
        .{ .name = "unicode", .module = unicode_mod },
        .{ .name = "poller", .module = poller_mod },
        .{ .name = "minibuffer", .module = minibuffer_mod },
        .{ .name = "search_service", .module = search_service_mod },
        .{ .name = "shell_service", .module = shell_service_mod },
        .{ .name = "buffer_manager", .module = buffer_manager_mod },
        .{ .name = "window_manager", .module = window_manager_mod },
        .{ .name = "editing_context", .module = editing_context_mod },
        .{ .name = "syntax", .module = syntax_mod },
        .{ .name = "macro_service", .module = macro_service_mod },
    };

    // commands/edit <- buffer, unicode (editorは循環参照になるので後で追加)
    const edit_cmd_mod = b.addModule("commands_edit", .{
        .root_source_file = b.path("src/commands/edit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "unicode", .module = unicode_mod },
        },
    });

    // commands/movement <- buffer, unicode
    const movement_cmd_mod = b.addModule("commands_movement", .{
        .root_source_file = b.path("src/commands/movement.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "unicode", .module = unicode_mod },
        },
    });

    // commands/rectangle <- buffer, editing_context
    const rectangle_cmd_mod = b.addModule("commands_rectangle", .{
        .root_source_file = b.path("src/commands/rectangle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "editing_context", .module = editing_context_mod },
        },
    });

    // commands/mx <- buffer, syntax
    const mx_cmd_mod = b.addModule("commands_mx", .{
        .root_source_file = b.path("src/commands/mx.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "syntax", .module = syntax_mod },
        },
    });

    // editor <- 全モジュール + commands
    const editor_mod = b.addModule("editor", .{
        .root_source_file = b.path("src/editor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = editor_imports,
    });
    editor_mod.addImport("commands_edit", edit_cmd_mod);
    editor_mod.addImport("commands_movement", movement_cmd_mod);
    editor_mod.addImport("commands_rectangle", rectangle_cmd_mod);
    editor_mod.addImport("commands_mx", mx_cmd_mod);

    // commandsモジュールにeditorを追加（循環参照解決）
    edit_cmd_mod.addImport("editor", editor_mod);
    movement_cmd_mod.addImport("editor", editor_mod);
    rectangle_cmd_mod.addImport("editor", editor_mod);
    mx_cmd_mod.addImport("editor", editor_mod);

    // keymap <- editor, input, commands
    const keymap_mod = b.addModule("keymap", .{
        .root_source_file = b.path("src/keymap.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "editor", .module = editor_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "commands_edit", .module = edit_cmd_mod },
            .{ .name = "commands_movement", .module = movement_cmd_mod },
        },
    });
    editor_mod.addImport("keymap", keymap_mod);

    // main <- editor, view
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "editor", .module = editor_mod },
            .{ .name = "view", .module = view_mod },
            .{ .name = "buffer", .module = buffer_mod },
            .{ .name = "unicode", .module = unicode_mod },
            .{ .name = "input", .module = input_mod },
        },
    });
    exe_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "ze",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the editor");
    run_step.dependOn(&run_cmd.step);

    // ユニットテスト
    const src_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_src_tests = b.addRunArtifact(src_tests);

    // 追加テスト: tests/ ディレクトリの専用テストファイル
    const test_files = [_][]const u8{
        "tests/buffer_test.zig",
        "tests/input_test.zig",
        "tests/view_test.zig",
        "tests/unicode_test.zig",
        "tests/comprehensive_test.zig",
        "tests/editing_context_test.zig",
        "tests/history_test.zig",
        "tests/keymap_test.zig",
        "tests/regex_test.zig",
        "tests/syntax_test.zig",
        "tests/encoding_test.zig",
        // services/
        "tests/services/buffer_manager_test.zig",
        "tests/services/minibuffer_test.zig",
        "tests/services/search_service_test.zig",
        "tests/services/shell_service_test.zig",
        "tests/services/window_manager_test.zig",
        "tests/services/macro_service_test.zig",
    };

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_src_tests.step);

    for (test_files) |test_file| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "buffer", .module = buffer_mod },
                .{ .name = "unicode", .module = unicode_mod },
                .{ .name = "view", .module = view_mod },
                .{ .name = "input", .module = input_mod },
                .{ .name = "editing_context", .module = editing_context_mod },
                .{ .name = "history", .module = history_mod },
                .{ .name = "keymap", .module = keymap_mod },
                .{ .name = "regex", .module = regex_mod },
                .{ .name = "syntax", .module = syntax_mod },
                .{ .name = "encoding", .module = encoding_mod },
                // services
                .{ .name = "buffer_manager", .module = buffer_manager_mod },
                .{ .name = "minibuffer", .module = minibuffer_mod },
                .{ .name = "search_service", .module = search_service_mod },
                .{ .name = "shell_service", .module = shell_service_mod },
                .{ .name = "window_manager", .module = window_manager_mod },
                .{ .name = "macro_service", .module = macro_service_mod },
            },
        });
        const unit_tests = b.addTest(.{
            .root_module = test_mod,
        });
        const run_test = b.addRunArtifact(unit_tests);
        run_test.step.dependOn(&run_src_tests.step);
        test_step.dependOn(&run_test.step);
    }
}
