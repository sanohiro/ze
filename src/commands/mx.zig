const std = @import("std");
const config = @import("config");
const Editor = @import("editor").Editor;
const Buffer = @import("buffer").Buffer;
const syntax = @import("syntax");

/// コマンドハンドラの型
const CommandHandler = union(enum) {
    with_arg: *const fn (*Editor, ?[]const u8) anyerror!void,
    no_arg: *const fn (*Editor) anyerror!void,
    special: *const fn (*Editor) void, // モード遷移など特殊処理
};

/// M-xコマンド定義
const Command = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    handler: CommandHandler,
};

/// コマンドテーブル（comptime生成）
const commands = [_]Command{
    .{ .name = "?", .alias = "help", .handler = .{ .special = cmdHelp } },
    .{ .name = "line", .handler = .{ .with_arg = cmdLine } },
    .{ .name = "ln", .handler = .{ .special = cmdLineNumbers } },
    .{ .name = "tab", .handler = .{ .with_arg = cmdTab } },
    .{ .name = "indent", .handler = .{ .with_arg = cmdIndent } },
    .{ .name = "mode", .handler = .{ .with_arg = cmdMode } },
    .{ .name = "revert", .handler = .{ .no_arg = cmdRevert } },
    .{ .name = "key", .handler = .{ .special = cmdKeyDescribe } },
    .{ .name = "ro", .handler = .{ .special = cmdReadonly } },
    .{ .name = "exit", .alias = "quit", .handler = .{ .special = cmdExit } },
};

/// M-xコマンドを実行
pub fn execute(e: *Editor) !void {
    const cmd_line = e.minibuffer.getContent();
    e.minibuffer.clear();
    e.mode = .normal;

    if (cmd_line.len == 0) {
        e.getCurrentView().clearError();
        return;
    }

    // コマンドと引数を分割
    var parts = std.mem.splitScalar(u8, cmd_line, ' ');
    const cmd = parts.next() orelse "";
    const arg = parts.next();

    // コマンドテーブルから検索
    inline for (commands) |command| {
        if (std.mem.eql(u8, cmd, command.name) or
            (command.alias != null and std.mem.eql(u8, cmd, command.alias.?)))
        {
            switch (command.handler) {
                .with_arg => |handler| try handler(e, arg),
                .no_arg => |handler| try handler(e),
                .special => |handler| handler(e),
            }
            return;
        }
    }

    // 未知のコマンド
    e.setPrompt("Unknown command: {s}", .{cmd});
}

/// help コマンド: コマンド一覧を表示
fn cmdHelp(e: *Editor) void {
    e.getCurrentView().setError(config.Messages.MX_COMMANDS_HELP);
}

/// ln コマンド: 行番号表示のトグル
fn cmdLineNumbers(e: *Editor) void {
    const view = e.getCurrentView();
    view.toggleLineNumbers();
    if (view.show_line_numbers) {
        view.setError(config.Messages.MX_LINE_NUMBERS_ON);
    } else {
        view.setError(config.Messages.MX_LINE_NUMBERS_OFF);
    }
}

/// key コマンド: キー説明モードに入る
fn cmdKeyDescribe(e: *Editor) void {
    e.mode = .mx_key_describe;
    e.getCurrentView().setError(config.Messages.MX_KEY_DESCRIBE_PROMPT);
}

/// line コマンド: 指定行へ移動
fn cmdLine(e: *Editor, arg: ?[]const u8) !void {
    if (arg) |line_str| {
        const line_num = std.fmt.parseInt(usize, line_str, 10) catch {
            e.getCurrentView().setError(config.Messages.MX_INVALID_LINE_NUMBER);
            return;
        };
        if (line_num == 0) {
            e.getCurrentView().setError(config.Messages.MX_LINE_MUST_BE_GE1);
            return;
        }
        // 0-indexedに変換
        const target_line = line_num - 1;
        const view = e.getCurrentView();
        const buffer = e.getCurrentBufferContent();
        const total_lines = buffer.lineCount();
        if (target_line >= total_lines) {
            view.moveToBufferEnd();
        } else {
            // 指定行の先頭に移動
            if (buffer.getLineStart(target_line)) |pos| {
                e.setCursorToPos(pos);
            }
        }
        e.getCurrentView().clearError();
    } else {
        // 引数なし: 現在の行番号を表示
        const view = e.getCurrentView();
        const current_line = view.top_line + view.cursor_y + 1;
        e.setPrompt("line: {d}", .{current_line});
    }
}

/// tab コマンド: タブ幅の表示/設定
fn cmdTab(e: *Editor, arg: ?[]const u8) !void {
    if (arg) |width_str| {
        const width = std.fmt.parseInt(u8, width_str, 10) catch {
            e.getCurrentView().setError(config.Messages.MX_INVALID_TAB_WIDTH);
            return;
        };
        if (width == 0 or width > config.Editor.MAX_TAB_WIDTH) {
            e.getCurrentView().setError(config.Messages.MX_TAB_WIDTH_RANGE);
            return;
        }
        e.getCurrentView().setTabWidth(width);
        e.setPrompt("tab: {d}", .{width});
    } else {
        // 引数なし: 現在のタブ幅を表示
        const width = e.getCurrentView().getTabWidth();
        e.setPrompt("tab: {d}", .{width});
    }
}

/// indent コマンド: インデントスタイルの表示/設定
fn cmdIndent(e: *Editor, arg: ?[]const u8) !void {
    if (arg) |style_str| {
        if (std.mem.eql(u8, style_str, "space") or std.mem.eql(u8, style_str, "spaces")) {
            e.getCurrentView().setIndentStyle(.space);
            e.getCurrentView().setError(config.Messages.MX_INDENT_SPACE);
        } else if (std.mem.eql(u8, style_str, "tab") or std.mem.eql(u8, style_str, "tabs")) {
            e.getCurrentView().setIndentStyle(.tab);
            e.getCurrentView().setError(config.Messages.MX_INDENT_TAB);
        } else {
            e.getCurrentView().setError(config.Messages.MX_INDENT_USAGE);
        }
    } else {
        // 引数なし: 現在のインデントスタイルを表示
        const style = e.getCurrentView().getIndentStyle();
        const style_name = switch (style) {
            .space => "space",
            .tab => "tab",
        };
        e.setPrompt("indent: {s}", .{style_name});
    }
}

/// mode コマンド: 言語モードの表示/設定
fn cmdMode(e: *Editor, arg: ?[]const u8) !void {
    if (arg) |mode_str| {
        // 部分マッチで言語を検索
        var found: ?*const syntax.LanguageDef = null;
        for (syntax.all_languages) |lang| {
            // 名前の部分マッチ（大文字小文字無視）
            if (std.ascii.indexOfIgnoreCase(lang.name, mode_str) != null) {
                found = lang;
                break;
            }
            // 拡張子マッチ
            for (lang.extensions) |ext| {
                if (std.mem.eql(u8, ext, mode_str)) {
                    found = lang;
                    break;
                }
            }
            if (found != null) break;
        }
        if (found) |lang| {
            e.getCurrentView().setLanguage(lang);
            e.setPrompt("mode: {s}", .{lang.name});
        } else {
            e.setPrompt("Unknown mode: {s}", .{mode_str});
        }
    } else {
        // 引数なし: 現在のモードを表示
        const lang = e.getCurrentView().language;
        e.setPrompt("mode: {s}", .{lang.name});
    }
}

/// revert コマンド: ファイル再読み込み
fn cmdRevert(e: *Editor) !void {
    const buffer_state = e.getCurrentBuffer();
    if (buffer_state.file.filename == null) {
        e.getCurrentView().setError(config.Messages.MX_NO_FILE_TO_REVERT);
        return;
    }
    if (buffer_state.editing_ctx.modified) {
        e.getCurrentView().setError(config.Messages.MX_BUFFER_MODIFIED);
        return;
    }

    const filename = buffer_state.file.filename.?;

    // Buffer.loadFromFileを使用（エンコーディング・改行コード処理を含む）
    const loaded_buffer = Buffer.loadFromFile(e.allocator, filename) catch |err| {
        e.setPrompt("Cannot open: {s}", .{@errorName(err)});
        return;
    };

    // 古いバッファを解放して新しいバッファに置き換え
    buffer_state.editing_ctx.buffer.deinit();
    buffer_state.editing_ctx.buffer.* = loaded_buffer;
    buffer_state.editing_ctx.modified = false;

    // Undo/Redoスタックをクリア（リロード前の編集履歴は無効）
    buffer_state.editing_ctx.clearUndoHistory();

    // ファイルの最終更新時刻を記録
    const file = std.fs.cwd().openFile(filename, .{}) catch null;
    if (file) |f| {
        defer f.close();
        const stat = f.stat() catch null;
        if (stat) |s| {
            buffer_state.file.mtime = s.mtime;
        }
    }

    // Viewのバッファ参照を更新
    e.getCurrentView().buffer = buffer_state.editing_ctx.buffer;

    // 言語検出を再実行（ファイル内容が変わった可能性があるため）
    var preview_buf: [512]u8 = undefined;
    const content_preview = buffer_state.editing_ctx.buffer.getContentPreview(&preview_buf);
    e.getCurrentView().detectLanguage(buffer_state.file.filename, content_preview);

    // カーソルを先頭に
    e.getCurrentView().moveToBufferStart();
    e.getCurrentView().setError(config.Messages.MX_REVERTED);
}

/// ro コマンド: 読み取り専用切り替え
fn cmdReadonly(e: *Editor) void {
    const buffer_state = e.getCurrentBuffer();
    buffer_state.file.readonly = !buffer_state.file.readonly;
    if (buffer_state.file.readonly) {
        e.getCurrentView().setError(config.Messages.MX_READONLY_ENABLED);
    } else {
        e.getCurrentView().setError(config.Messages.MX_READONLY_DISABLED);
    }
}

/// exit コマンド: 確認付きで終了
fn cmdExit(e: *Editor) void {
    e.mode = .exit_confirm;
    e.getCurrentView().setError(config.Messages.MX_EXIT_CONFIRM);
}

/// コマンド名補完
/// 入力プレフィックスにマッチするコマンド名を返す
pub fn completeCommand(prefix: []const u8) struct {
    matches: []const []const u8,
    common_prefix: []const u8,
} {
    // 補完結果を格納する静的配列（コマンド数 × 2 for aliases）
    const max_matches = commands.len * 2;
    const S = struct {
        var match_buf: [max_matches][]const u8 = undefined;
    };

    var count: usize = 0;

    // コマンド名とエイリアスをチェック
    inline for (commands) |cmd| {
        if (std.mem.startsWith(u8, cmd.name, prefix)) {
            S.match_buf[count] = cmd.name;
            count += 1;
        }
        if (cmd.alias) |alias| {
            if (std.mem.startsWith(u8, alias, prefix)) {
                S.match_buf[count] = alias;
                count += 1;
            }
        }
    }

    if (count == 0) {
        return .{ .matches = &[_][]const u8{}, .common_prefix = prefix };
    }

    // 共通プレフィックスを計算
    var common_len = S.match_buf[0].len;
    for (S.match_buf[1..count]) |m| {
        var i: usize = 0;
        while (i < common_len and i < m.len and S.match_buf[0][i] == m[i]) : (i += 1) {}
        common_len = i;
    }

    return .{
        .matches = S.match_buf[0..count],
        .common_prefix = S.match_buf[0][0..common_len],
    };
}
