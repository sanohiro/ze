const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Piece = @import("buffer.zig").Piece;
const PieceIterator = @import("buffer.zig").PieceIterator;
const View = @import("view.zig").View;
const Terminal = @import("terminal.zig").Terminal;
const input = @import("input.zig");
const config = @import("config.zig");
const regex = @import("regex.zig");

// 差分ログベースのUndo/Redo
const EditOp = union(enum) {
    insert: struct {
        pos: usize,
        text: []const u8, // owned by allocator
    },
    delete: struct {
        pos: usize,
        text: []const u8, // owned by allocator (削除されたテキストを保存)
    },
};

const UndoEntry = struct {
    op: EditOp,
    cursor_pos: usize, // 操作前のカーソルバイト位置

    fn deinit(self: *const UndoEntry, allocator: std.mem.Allocator) void {
        switch (self.op) {
            .insert => |ins| allocator.free(ins.text),
            .delete => |del| allocator.free(del.text),
        }
    }
};

const EditorMode = enum {
    normal,
    prefix_x, // C-xプレフィックス待ち
    prefix_r, // C-x rプレフィックス待ち（矩形選択コマンド）
    quit_confirm, // 終了確認中（y/n/cを待つ）
    filename_input, // ファイル名入力中（保存）
    find_file_input, // ファイル名入力中（開く）
    buffer_switch_input, // バッファ名入力中（切り替え）
    isearch_forward, // インクリメンタルサーチ（前方）
    isearch_backward, // インクリメンタルサーチ（後方）
    query_replace_input_search, // 置換：検索文字列入力中
    query_replace_input_replacement, // 置換：置換文字列入力中
    query_replace_confirm, // 置換：確認中（y/n/!/qを待つ）
    shell_command, // シェルコマンド入力中（M-|）
    shell_running, // シェルコマンド実行中（C-gでキャンセル可）
    mx_command, // M-xコマンド入力中
    mx_key_describe, // M-x key: 次のキー入力を待っている
};

/// シェルコマンド出力先
const ShellOutputDest = enum {
    command_buffer, // Command Bufferに表示（デフォルト）
    replace, // 入力元を置換 (>)
    insert, // カーソル位置に挿入 (+>)
    new_buffer, // 新規バッファ (n>)
};

/// シェルコマンド入力元
const ShellInputSource = enum {
    selection, // 選択範囲（なければ空）
    buffer_all, // バッファ全体 (%)
    current_line, // 現在行 (.)
};

// シェルコマンドの非同期実行状態
pub const ShellCommandState = struct {
    child: std.process.Child,
    input_source: ShellInputSource,
    output_dest: ShellOutputDest,
    stdin_data: ?[]const u8,
    stdin_allocated: bool,
    command: []const u8, // コマンド文字列（解放用）
};

/// 全角英数記号（U+FF01〜U+FF5E）を半角（U+0021〜U+007E）に変換
fn normalizeCodepoint(cp: u21) u21 {
    // 全角英数記号の範囲を半角に変換
    if (cp >= 0xFF01 and cp <= 0xFF5E) {
        return cp - 0xFF00 + 0x20;
    }
    return cp;
}

// ========================================
// BufferState: バッファの内容と状態
// ========================================
pub const BufferState = struct {
    id: usize, // バッファID（一意）
    buffer: Buffer, // 実際のテキスト内容
    filename: ?[]const u8, // ファイル名（nullなら*scratch*）
    modified: bool, // 変更フラグ
    readonly: bool, // 読み取り専用フラグ
    file_mtime: ?i128, // ファイルの最終更新時刻
    undo_stack: std.ArrayList(UndoEntry), // Undoスタック
    redo_stack: std.ArrayList(UndoEntry), // Redoスタック
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize) !*BufferState {
        const self = try allocator.create(BufferState);
        self.* = BufferState{
            .id = id,
            .buffer = try Buffer.init(allocator),
            .filename = null,
            .modified = false,
            .readonly = false,
            .file_mtime = null,
            .undo_stack = undefined, // 後で初期化
            .redo_stack = undefined, // 後で初期化
            .allocator = allocator,
        };
        // ArrayListは構造体リテラル内で初期化できないため、後で初期化
        // Zig 0.15では.{}で空のリストとして初期化
        self.undo_stack = .{};
        self.redo_stack = .{};
        return self;
    }

    pub fn deinit(self: *BufferState) void {
        self.buffer.deinit();
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
        for (self.undo_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.redo_stack.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

// ========================================
// Window: 画面上の表示領域
// ========================================
pub const Window = struct {
    id: usize, // ウィンドウID
    buffer_id: usize, // 表示しているバッファのID
    view: View, // 表示状態（カーソル位置、スクロールなど）
    x: usize, // 画面上のX座標
    y: usize, // 画面上のY座標
    width: usize, // ウィンドウの幅
    height: usize, // ウィンドウの高さ
    mark_pos: ?usize, // 範囲選択のマーク位置

    pub fn init(id: usize, buffer_id: usize, x: usize, y: usize, width: usize, height: usize) Window {
        return Window{
            .id = id,
            .buffer_id = buffer_id,
            .view = undefined, // 後で初期化
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .mark_pos = null,
        };
    }

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        self.view.deinit(allocator);
    }
};

// ========================================
// Editor: エディタ本体（複数バッファ・ウィンドウを管理）
// ========================================
pub const Editor = struct {
    // グローバルリソース
    terminal: Terminal,
    allocator: std.mem.Allocator,
    running: bool,

    // バッファとウィンドウの管理
    buffers: std.ArrayList(*BufferState), // 全バッファのリスト
    windows: std.ArrayList(Window), // 全ウィンドウのリスト
    current_window_idx: usize, // 現在アクティブなウィンドウのインデックス
    next_buffer_id: usize, // 次に割り当てるバッファID
    next_window_id: usize, // 次に割り当てるウィンドウID

    // エディタ状態
    mode: EditorMode,
    input_buffer: std.ArrayList(u8), // ミニバッファ入力用
    quit_after_save: bool,
    prompt_buffer: ?[]const u8, // allocPrintで作成したプロンプト文字列

    // グローバルバッファ（全バッファで共有）
    kill_ring: ?[]const u8,
    rectangle_ring: ?std.ArrayList([]const u8),

    // 検索状態（グローバル）
    search_start_pos: ?usize,
    last_search: ?[]const u8,
    compiled_regex: ?regex.Regex,

    // 置換状態（グローバル）
    replace_search: ?[]const u8,
    replace_replacement: ?[]const u8,
    replace_current_pos: ?usize,
    replace_match_count: usize,

    // シェルコマンド非同期実行状態
    shell_state: ?*ShellCommandState,

    pub fn init(allocator: std.mem.Allocator) !Editor {
        // ターミナルを先に初期化（サイズ取得のため）
        const terminal = try Terminal.init(allocator);

        // 最初のバッファを作成（ID: 0）
        const first_buffer = try BufferState.init(allocator, 0);

        // バッファリストを作成
        var buffers: std.ArrayList(*BufferState) = .{};
        try buffers.append(allocator, first_buffer);

        // 最初のウィンドウを作成（全画面、ステータスバーはheight内に含む）
        var first_window = Window.init(0, 0, 0, 0, terminal.width, terminal.height);
        first_window.view = View.init(allocator, &first_buffer.buffer);

        // ウィンドウリストを作成
        var windows: std.ArrayList(Window) = .{};
        try windows.append(allocator, first_window);

        const editor = Editor{
            .terminal = terminal,
            .allocator = allocator,
            .running = true,
            .buffers = buffers,
            .windows = windows,
            .current_window_idx = 0,
            .next_buffer_id = 1,
            .next_window_id = 1,
            .mode = .normal,
            .input_buffer = .{},
            .quit_after_save = false,
            .prompt_buffer = null,
            .kill_ring = null,
            .rectangle_ring = null,
            .search_start_pos = null,
            .last_search = null,
            .compiled_regex = null,
            .replace_search = null,
            .replace_replacement = null,
            .replace_current_pos = null,
            .replace_match_count = 0,
            .shell_state = null,
        };

        return editor;
    }

    pub fn deinit(self: *Editor) void {
        // 全ウィンドウを解放
        for (self.windows.items) |*window| {
            window.deinit(self.allocator);
        }
        self.windows.deinit(self.allocator);

        // 全バッファを解放
        for (self.buffers.items) |buffer| {
            buffer.deinit();
        }
        self.buffers.deinit(self.allocator);

        // ターミナルを解放
        self.terminal.deinit();

        // グローバルバッファの解放
        if (self.kill_ring) |text| {
            self.allocator.free(text);
        }
        if (self.rectangle_ring) |*rect| {
            for (rect.items) |line| {
                self.allocator.free(line);
            }
            rect.deinit(self.allocator);
        }

        // 検索状態の解放
        if (self.last_search) |search| {
            self.allocator.free(search);
        }
        if (self.compiled_regex) |*r| {
            var re = r.*;
            re.deinit();
        }

        // 置換状態の解放
        if (self.replace_search) |search| {
            self.allocator.free(search);
        }
        if (self.replace_replacement) |replacement| {
            self.allocator.free(replacement);
        }

        // プロンプトバッファのクリーンアップ
        if (self.prompt_buffer) |prompt| {
            self.allocator.free(prompt);
        }

        // 入力バッファのクリーンアップ
        self.input_buffer.deinit(self.allocator);

        // シェルコマンド状態のクリーンアップ
        if (self.shell_state) |state| {
            self.cleanupShellState(state);
        }
    }

    /// シェルコマンド状態をクリーンアップ
    fn cleanupShellState(self: *Editor, state: *ShellCommandState) void {
        // 子プロセスがまだ実行中ならkill
        _ = state.child.kill() catch {};

        // stdin_dataを解放
        if (state.stdin_allocated) {
            if (state.stdin_data) |data| {
                self.allocator.free(data);
            }
        }

        // コマンド文字列を解放
        self.allocator.free(state.command);

        // 状態自体を解放
        self.allocator.destroy(state);
        self.shell_state = null;
    }

    // ========================================
    // ヘルパーメソッド
    // ========================================

    /// 現在のウィンドウを取得
    pub fn getCurrentWindow(self: *Editor) *Window {
        return &self.windows.items[self.current_window_idx];
    }

    /// 現在のバッファを取得
    pub fn getCurrentBuffer(self: *Editor) *BufferState {
        const window = self.getCurrentWindow();
        for (self.buffers.items) |buffer| {
            if (buffer.id == window.buffer_id) {
                return buffer;
            }
        }
        unreachable; // ウィンドウが参照しているバッファは必ず存在する
    }

    /// 現在のビューを取得
    pub fn getCurrentView(self: *Editor) *View {
        return &self.getCurrentWindow().view;
    }

    /// 現在のバッファのBufferを取得
    pub fn getCurrentBufferContent(self: *Editor) *Buffer {
        return &self.getCurrentBuffer().buffer;
    }

    /// 新しいバッファを作成してリストに追加
    pub fn createNewBuffer(self: *Editor) !*BufferState {
        const new_buffer = try BufferState.init(self.allocator, self.next_buffer_id);
        try self.buffers.append(self.allocator, new_buffer);
        self.next_buffer_id += 1;
        return new_buffer;
    }

    /// 指定されたIDのバッファを検索
    fn findBufferById(self: *Editor, buffer_id: usize) ?*BufferState {
        for (self.buffers.items) |buf| {
            if (buf.id == buffer_id) return buf;
        }
        return null;
    }

    /// 指定されたファイル名のバッファを検索
    fn findBufferByFilename(self: *Editor, filename: []const u8) ?*BufferState {
        for (self.buffers.items) |buf| {
            if (buf.filename) |buf_filename| {
                if (std.mem.eql(u8, buf_filename, filename)) return buf;
            }
        }
        return null;
    }

    /// *Command* バッファを取得または作成
    fn getOrCreateCommandBuffer(self: *Editor) !*BufferState {
        // 既存の *Command* バッファを探す
        for (self.buffers.items) |buf| {
            if (buf.filename) |name| {
                if (std.mem.eql(u8, name, "*Command*")) return buf;
            }
        }
        // なければ新規作成
        const new_buffer = try self.createNewBuffer();
        new_buffer.filename = try self.allocator.dupe(u8, "*Command*");
        new_buffer.readonly = true; // コマンド出力は読み取り専用
        return new_buffer;
    }

    /// *Command* バッファを表示するウィンドウを探す
    fn findCommandBufferWindow(self: *Editor) ?usize {
        for (self.windows.items, 0..) |window, idx| {
            if (self.findBufferById(window.buffer_id)) |buf| {
                if (buf.filename) |name| {
                    if (std.mem.eql(u8, name, "*Command*")) return idx;
                }
            }
        }
        return null;
    }

    /// *Command* バッファウィンドウを開く（既に開いていればそれを使う）
    fn openCommandBufferWindow(self: *Editor) !usize {
        // 既にウィンドウがあればそれを返す
        if (self.findCommandBufferWindow()) |idx| {
            return idx;
        }

        // *Command* バッファを取得/作成
        const cmd_buffer = try self.getOrCreateCommandBuffer();

        // 画面下部に水平分割でウィンドウを開く
        // 現在のウィンドウの高さを縮める
        const current_window = &self.windows.items[self.current_window_idx];
        const min_height: u16 = 5; // 最小高さ
        const cmd_height: u16 = 8; // コマンドバッファの高さ

        if (current_window.height < min_height + cmd_height) {
            // 画面が小さすぎる場合は現在のウィンドウに表示
            try self.switchToBuffer(cmd_buffer.id);
            return self.current_window_idx;
        }

        // 現在のウィンドウを縮める
        const old_height = current_window.height;
        current_window.height = old_height - cmd_height;

        // 新しいウィンドウを下部に作成
        const new_window_id = self.next_window_id;
        self.next_window_id += 1;

        var new_window = Window.init(
            new_window_id,
            cmd_buffer.id,
            current_window.x,
            current_window.y + current_window.height,
            current_window.width,
            cmd_height,
        );

        new_window.view = View.init(self.allocator, &cmd_buffer.buffer);

        try self.windows.append(self.allocator, new_window);
        return self.windows.items.len - 1;
    }

    /// 現在のウィンドウを指定されたバッファに切り替え
    pub fn switchToBuffer(self: *Editor, buffer_id: usize) !void {
        const buffer_state = self.findBufferById(buffer_id) orelse return error.BufferNotFound;
        const window = self.getCurrentWindow();

        // Viewを更新
        window.view.deinit(self.allocator);
        window.view = View.init(self.allocator, &buffer_state.buffer);
        window.buffer_id = buffer_id;
    }

    /// 指定されたバッファを閉じる（削除）
    pub fn closeBuffer(self: *Editor, buffer_id: usize) !void {
        // 最後のバッファは閉じられない
        if (self.buffers.items.len == 1) return error.CannotCloseLastBuffer;

        // バッファを検索して削除
        for (self.buffers.items, 0..) |buf, i| {
            if (buf.id == buffer_id) {
                // このバッファを使用しているウィンドウを別のバッファに切り替え
                for (self.windows.items) |*window| {
                    if (window.buffer_id == buffer_id) {
                        // 次のバッファに切り替え（削除するバッファ以外）
                        const next_buffer = if (i > 0) self.buffers.items[i - 1] else self.buffers.items[1];
                        window.view.deinit(self.allocator);
                        window.view = View.init(self.allocator, &next_buffer.buffer);
                        window.buffer_id = next_buffer.id;
                    }
                }

                // バッファを削除
                buf.deinit();
                _ = self.buffers.orderedRemove(i);
                return;
            }
        }
        return error.BufferNotFound;
    }

    /// バッファ一覧を表示（C-x C-b）
    pub fn showBufferList(self: *Editor) !void {
        // バッファ一覧のテキストを生成
        var list_text = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        defer list_text.deinit(self.allocator);

        const writer = list_text.writer(self.allocator);
        try writer.writeAll("  MR Buffer           Size  File\n");
        try writer.writeAll("  -- ------           ----  ----\n");

        for (self.buffers.items) |buf| {
            // 変更フラグ
            const mod_char: u8 = if (buf.modified) '*' else '.';
            // 読み取り専用フラグ
            const ro_char: u8 = if (buf.readonly) '%' else '.';

            // バッファ名
            const buf_name = if (buf.filename) |fname| fname else "*scratch*";

            // サイズ
            const size = buf.buffer.total_len;

            // フォーマットして追加
            try std.fmt.format(writer, "  {c}{c} {s:<16} {d:>6}  {s}\n", .{
                mod_char,
                ro_char,
                buf_name,
                size,
                if (buf.filename) |fname| fname else "",
            });
        }

        // "*Buffer List*"という名前のバッファを探す
        const buffer_list_name = "*Buffer List*";
        var buffer_list: *BufferState = undefined;
        var found = false;

        for (self.buffers.items) |buf| {
            if (buf.filename) |fname| {
                if (std.mem.eql(u8, fname, buffer_list_name)) {
                    buffer_list = buf;
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            // 新しいバッファを作成
            buffer_list = try self.createNewBuffer();
            buffer_list.filename = try self.allocator.dupe(u8, buffer_list_name);
            buffer_list.readonly = true; // バッファ一覧は読み取り専用
        }

        // バッファの内容をクリアして新しい一覧を挿入
        if (buffer_list.buffer.total_len > 0) {
            try buffer_list.buffer.delete(0, buffer_list.buffer.total_len);
        }
        try buffer_list.buffer.insertSlice(0, list_text.items);
        buffer_list.modified = false; // バッファ一覧は変更扱いにしない

        // バッファ一覧に切り替え
        try self.switchToBuffer(buffer_list.id);
    }

    /// *Buffer List*からバッファを選択して切り替え
    fn selectBufferFromList(self: *Editor) !void {
        const view = self.getCurrentView();
        const buffer = self.getCurrentBufferContent();

        // 現在行を取得
        const cursor_line = view.top_line + view.cursor_y;

        // ヘッダ行（0, 1行目）は無視
        if (cursor_line < 2) {
            self.getCurrentView().setError("Select a buffer from the list");
            return;
        }

        // 現在行の開始位置を取得
        const line_start = buffer.getLineStart(cursor_line) orelse {
            self.getCurrentView().setError("Invalid line");
            return;
        };

        // 次の行の開始位置を取得（行の終わりを知るため）
        const next_line_start = buffer.getLineStart(cursor_line + 1) orelse buffer.total_len;

        // 行の長さを計算（改行を除く）
        var line_len = if (next_line_start > line_start) next_line_start - line_start else 0;
        if (line_len > 0 and next_line_start <= buffer.total_len) {
            // 改行文字を除く
            line_len = if (line_len > 0) line_len - 1 else 0;
        }

        if (line_len == 0) {
            self.getCurrentView().setError("Empty line");
            return;
        }

        // 行のテキストを取得
        const line = try buffer.getRange(self.allocator, line_start, line_len);
        defer self.allocator.free(line);

        // バッファ名を抽出
        // フォーマット: "  {c}{c} {s:<16} {d:>6}  {s}\n"
        // 長いファイル名は16文字を超える場合がある
        if (line.len < 5) {
            self.getCurrentView().setError("Invalid line format");
            return;
        }

        // バッファ名は位置5から始まる
        const name_start: usize = 5;

        // バッファ名の終端を探す（複数のスペース + 数字 = サイズ列の開始）
        var name_end: usize = name_start;
        var i: usize = name_start;
        while (i < line.len) : (i += 1) {
            if (line[i] == ' ') {
                // スペースの連続を探す
                var space_count: usize = 0;
                var j = i;
                while (j < line.len and line[j] == ' ') : (j += 1) {
                    space_count += 1;
                }
                // スペースの後に数字があればサイズ列
                if (space_count >= 2 and j < line.len and line[j] >= '0' and line[j] <= '9') {
                    name_end = i;
                    break;
                }
            }
            name_end = i + 1;
        }

        var buf_name = line[name_start..name_end];

        // 末尾の空白を除去
        while (buf_name.len > 0 and buf_name[buf_name.len - 1] == ' ') {
            buf_name = buf_name[0 .. buf_name.len - 1];
        }

        if (buf_name.len == 0) {
            self.getCurrentView().setError("No buffer name found");
            return;
        }

        // バッファを検索
        for (self.buffers.items) |buf| {
            const name = if (buf.filename) |fname| fname else "*scratch*";
            if (std.mem.eql(u8, name, buf_name)) {
                try self.switchToBuffer(buf.id);
                return;
            }
        }

        self.getCurrentView().setError("Buffer not found");
    }

    /// 現在のウィンドウを横（上下）に分割
    pub fn splitWindowHorizontally(self: *Editor) !void {
        const current_window = &self.windows.items[self.current_window_idx];

        // ウィンドウの高さが2未満の場合は分割できない
        if (current_window.height < 2) {
            return error.WindowTooSmall;
        }

        // 現在のウィンドウの高さを半分にする
        const old_height = current_window.height;
        const new_height = old_height / 2;
        current_window.height = new_height;

        // 新しいウィンドウを下半分に作成
        const new_window_id = self.next_window_id;
        self.next_window_id += 1;

        var new_window = Window.init(
            new_window_id,
            current_window.buffer_id, // 同じバッファを表示
            current_window.x,
            current_window.y + new_height,
            current_window.width,
            old_height - new_height,
        );

        // 新しいウィンドウのViewを初期化
        const buffer_state = self.findBufferById(current_window.buffer_id).?;
        new_window.view = View.init(self.allocator, &buffer_state.buffer);

        // ウィンドウリストに追加
        try self.windows.append(self.allocator, new_window);

        // 新しいウィンドウをアクティブにする
        self.current_window_idx = self.windows.items.len - 1;
    }

    /// 現在のウィンドウを縦（左右）に分割
    pub fn splitWindowVertically(self: *Editor) !void {
        const current_window = &self.windows.items[self.current_window_idx];

        // ウィンドウの幅が2未満の場合は分割できない
        if (current_window.width < 2) {
            return error.WindowTooSmall;
        }

        // 現在のウィンドウの幅を半分にする
        const old_width = current_window.width;
        const new_width = old_width / 2;
        current_window.width = new_width;

        // 新しいウィンドウを右半分に作成
        const new_window_id = self.next_window_id;
        self.next_window_id += 1;

        var new_window = Window.init(
            new_window_id,
            current_window.buffer_id, // 同じバッファを表示
            current_window.x + new_width,
            current_window.y,
            old_width - new_width,
            current_window.height,
        );

        // 新しいウィンドウのViewを初期化
        const buffer_state = self.findBufferById(current_window.buffer_id).?;
        new_window.view = View.init(self.allocator, &buffer_state.buffer);

        // ウィンドウリストに追加
        try self.windows.append(self.allocator, new_window);

        // 新しいウィンドウをアクティブにする
        self.current_window_idx = self.windows.items.len - 1;
    }

    /// 現在のウィンドウを閉じる
    pub fn closeCurrentWindow(self: *Editor) !void {
        // 最後のウィンドウは閉じられない
        if (self.windows.items.len == 1) {
            return error.CannotCloseSoleWindow;
        }

        // 現在のウィンドウを閉じる
        var window = &self.windows.items[self.current_window_idx];
        window.deinit(self.allocator);
        _ = self.windows.orderedRemove(self.current_window_idx);

        // current_window_idxを調整
        if (self.current_window_idx >= self.windows.items.len) {
            self.current_window_idx = self.windows.items.len - 1;
        }

        // 残ったウィンドウのサイズを再計算
        try self.recalculateWindowSizes();
    }

    /// 他のウィンドウをすべて閉じる (C-x 1)
    pub fn deleteOtherWindows(self: *Editor) !void {
        // ウィンドウが1つしかなければ何もしない
        if (self.windows.items.len == 1) {
            return;
        }

        // 現在のウィンドウを保持
        const current_window = self.windows.items[self.current_window_idx];

        // 他のウィンドウをすべて解放
        for (self.windows.items, 0..) |*window, i| {
            if (i != self.current_window_idx) {
                window.deinit(self.allocator);
            }
        }

        // ウィンドウリストをクリアして現在のウィンドウだけ残す
        self.windows.clearRetainingCapacity();
        try self.windows.append(self.allocator, current_window);
        self.current_window_idx = 0;

        // ウィンドウサイズを再計算（フルスクリーン）
        try self.recalculateWindowSizes();
    }

    pub fn loadFile(self: *Editor, path: []const u8) !void {
        const buffer_state = self.getCurrentBuffer();
        const view = self.getCurrentView();

        // 古いバッファを解放
        buffer_state.buffer.deinit();
        buffer_state.buffer = try Buffer.loadFromFile(self.allocator, path);
        view.buffer = &buffer_state.buffer;

        // View状態をリセット（新しいファイルを開いた時に前のカーソル位置が残らないように）
        view.top_line = 0;
        view.cursor_x = 0;
        view.cursor_y = 0;

        // 古いファイル名を解放して新しいファイル名を設定
        if (buffer_state.filename) |old_name| {
            self.allocator.free(old_name);
        }
        buffer_state.filename = try self.allocator.dupe(u8, path);
        buffer_state.modified = false;

        // ファイルの最終更新時刻を記録（外部変更検知用）
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        buffer_state.file_mtime = stat.mtime;

        // 言語検出（ファイル名とコンテンツ先頭から判定）
        const content_preview = buffer_state.buffer.getContentPreview(512);
        view.detectLanguage(path, content_preview);
    }

    pub fn saveFile(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        const view = self.getCurrentView();

        if (buffer_state.filename) |path| {
            // 外部変更チェック（新規ファイルの場合はスキップ）
            if (buffer_state.file_mtime) |original_mtime| {
                const maybe_file = std.fs.cwd().openFile(path, .{}) catch |err| blk: {
                    // ファイルが存在しない場合は外部で削除された
                    if (err == error.FileNotFound) {
                        view.error_msg = "警告: ファイルが外部で削除されています";
                        // 続行して保存する（再作成）
                        break :blk null;
                    } else {
                        return err;
                    }
                };

                if (maybe_file) |f| {
                    defer f.close();
                    const stat = try f.stat();
                    if (stat.mtime != original_mtime) {
                        view.error_msg = "警告: ファイルが外部で変更されています！";
                        // 続行して上書きする（ユーザーの編集を優先）
                    }
                }
            }

            try buffer_state.buffer.saveToFile(path);
            buffer_state.modified = false;

            // 保存後に新しい mtime を記録
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            const stat = try file.stat();
            buffer_state.file_mtime = stat.mtime;
        }
    }

    /// 全ウィンドウをレンダリング
    fn renderAllWindows(self: *Editor) !void {
        for (self.windows.items, 0..) |*window, idx| {
            const is_active = (idx == self.current_window_idx);
            const buffer_state = self.findBufferById(window.buffer_id) orelse continue;
            const buffer = &buffer_state.buffer;

            try window.view.renderInBounds(
                &self.terminal,
                window.y,
                window.height,
                is_active,
                buffer_state.modified,
                buffer_state.readonly,
                buffer.detected_line_ending,
                buffer_state.filename,
            );
        }
    }

    /// 端末サイズ変更時にウィンドウサイズを再計算
    fn recalculateWindowSizes(self: *Editor) !void {
        const total_height = self.terminal.height;

        if (self.windows.items.len == 0) return;

        // ウィンドウが1つの場合は全画面
        if (self.windows.items.len == 1) {
            self.windows.items[0].y = 0;
            self.windows.items[0].height = total_height;
            self.windows.items[0].width = self.terminal.width;
            self.windows.items[0].view.markFullRedraw();
            return;
        }

        // 複数ウィンドウの場合：均等分割（縦分割のみ対応）
        const window_count = self.windows.items.len;
        const base_height = total_height / window_count;
        var remaining = total_height % window_count;
        var current_y: usize = 0;

        for (self.windows.items) |*window| {
            window.y = current_y;
            window.height = base_height + (if (remaining > 0) @as(usize, 1) else @as(usize, 0));
            window.width = self.terminal.width;
            window.view.markFullRedraw();

            current_y += window.height;
            if (remaining > 0) remaining -= 1;
        }
    }

    pub fn run(self: *Editor) !void {
        const stdin: std.fs.File = .{ .handle = std.posix.STDIN_FILENO };

        while (self.running) {
            // 端末サイズ変更をチェック
            if (try self.terminal.checkResize()) {
                // サイズが変わったら全ウィンドウの再描画をマーク＆サイズ再計算
                try self.recalculateWindowSizes();
            }

            // カーソル位置をバッファ範囲内にクランプ（大量削除後の対策）
            self.clampCursorPosition();

            // 全ウィンドウをレンダリング
            try self.renderAllWindows();

            // シェルコマンド実行中ならポーリング
            if (self.mode == .shell_running) {
                try self.pollShellCommand();
            }

            if (try input.readKey(stdin)) |key| {
                // 何かキー入力があればエラーメッセージをクリア
                self.getCurrentView().clearError();

                // キー処理でエラーが発生したらステータスバーに表示
                self.processKey(key) catch |err| {
                    const err_name = @errorName(err);
                    self.getCurrentView().setError(err_name);
                };
            }
        }
    }

    // バッファから指定範囲のテキストを取得（削除前に使用）
    // PieceIterator.seekを使ってO(pieces + len)で効率的に取得
    fn extractText(self: *Editor, pos: usize, len: usize) ![]u8 {
        const buffer = self.getCurrentBufferContent();
        // 実際に読み取れるバイト数を計算（buffer末尾を超えないように）
        const actual_len = @min(len, buffer.len() - pos);
        var result = try self.allocator.alloc(u8, actual_len);
        errdefer self.allocator.free(result);

        var iter = PieceIterator.init(buffer);
        iter.seek(pos); // O(pieces)で直接ジャンプ

        // actual_len分読み取る（保証されている）
        var i: usize = 0;
        while (i < actual_len) : (i += 1) {
            result[i] = iter.next() orelse {
                // Piece table の不整合が発生した場合
                // メモリリークを防ぐため、エラーを返す（errdefer が解放する）
                return error.BufferInconsistency;
            };
        }

        return result;
    }

    // 現在のカーソル位置の行番号を取得（dirty tracking用）
    fn getCurrentLine(self: *const Editor) usize {
        const view = &self.windows.items[self.current_window_idx].view;
        return view.top_line + view.cursor_y;
    }

    // カーソル位置をバッファの有効範囲にクランプ（大量削除後の対策）
    fn clampCursorPosition(self: *Editor) void {
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();

        const total_lines = buffer.lineCount();
        if (total_lines == 0) return;

        // 端末サイズが0の場合は何もしない
        if (self.terminal.height == 0) return;

        const max_screen_lines = self.terminal.height - 1; // ステータスバー分を引く

        // top_lineが範囲外の場合は調整
        if (view.top_line >= total_lines) {
            if (total_lines > max_screen_lines) {
                view.top_line = total_lines - max_screen_lines;
            } else {
                view.top_line = 0;
            }
            view.markFullRedraw();
        }

        // cursor_yが範囲外の場合は調整
        const current_line = view.top_line + view.cursor_y;
        if (current_line >= total_lines) {
            if (total_lines > view.top_line) {
                view.cursor_y = total_lines - view.top_line - 1;
            } else {
                view.cursor_y = 0;
            }

            // cursor_xも行末にクランプ
            const line_width = view.getCurrentLineWidth();
            if (view.cursor_x > line_width) {
                view.cursor_x = line_width;
            }
        }
    }

    // Undoスタックの最大エントリ数
    const MAX_UNDO_ENTRIES = config.Editor.MAX_UNDO_ENTRIES;

    // 編集操作を記録（差分ベース、連続挿入はマージ）
    fn recordInsert(self: *Editor, pos: usize, text: []const u8, cursor_pos_before_edit: usize) !void {
        const buffer_state = self.getCurrentBuffer();
        const cursor_pos = cursor_pos_before_edit;

        // 連続挿入のコアレッシング: 直前の操作が連続する挿入ならマージ
        if (buffer_state.undo_stack.items.len > 0) {
            const last = &buffer_state.undo_stack.items[buffer_state.undo_stack.items.len - 1];
            if (last.op == .insert) {
                const last_ins = last.op.insert;
                // 直前の挿入の直後に続く挿入ならマージ
                if (last_ins.pos + last_ins.text.len == pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ last_ins.text, text });
                    errdefer self.allocator.free(new_text); // concat成功後の保護
                    self.allocator.free(last_ins.text);
                    last.op.insert.text = new_text;
                    // cursor_posは最初の操作のものを保持
                    return;
                }
            }
        }

        const text_copy = try self.allocator.dupe(u8, text);
        try buffer_state.undo_stack.append(self.allocator, .{
            .op = .{ .insert = .{ .pos = pos, .text = text_copy } },
            .cursor_pos = cursor_pos,
        });

        // Undoスタックが上限を超えたら古いエントリを削除
        if (buffer_state.undo_stack.items.len > MAX_UNDO_ENTRIES) {
            const old_entry = buffer_state.undo_stack.orderedRemove(0);
            old_entry.deinit(self.allocator);
        }

        // Redoスタックをクリア
        for (buffer_state.redo_stack.items) |entry| {
            entry.deinit(self.allocator);
        }
        buffer_state.redo_stack.clearRetainingCapacity();
    }

    fn recordDelete(self: *Editor, pos: usize, text: []const u8, cursor_pos_before_edit: usize) !void {
        const buffer_state = self.getCurrentBuffer();
        const cursor_pos = cursor_pos_before_edit;

        // 連続削除のコアレッシング: 直前の操作が連続する削除ならマージ
        if (buffer_state.undo_stack.items.len > 0) {
            const last = &buffer_state.undo_stack.items[buffer_state.undo_stack.items.len - 1];
            if (last.op == .delete) {
                const last_del = last.op.delete;
                // Backspace: 削除位置が前に移動（pos == last_pos - text.len）
                if (pos + text.len == last_del.pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ text, last_del.text });
                    errdefer self.allocator.free(new_text);
                    self.allocator.free(last_del.text);
                    last.op.delete.text = new_text;
                    last.op.delete.pos = pos;
                    // cursor_posは最初の操作のものを保持
                    return;
                }
                // Delete: 削除位置が同じ（連続してpos位置で削除）
                if (pos == last_del.pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ last_del.text, text });
                    errdefer self.allocator.free(new_text);
                    self.allocator.free(last_del.text);
                    last.op.delete.text = new_text;
                    // cursor_posは最初の操作のものを保持
                    return;
                }
            }
        }

        const text_copy = try self.allocator.dupe(u8, text);
        try buffer_state.undo_stack.append(self.allocator, .{
            .op = .{ .delete = .{ .pos = pos, .text = text_copy } },
            .cursor_pos = cursor_pos,
        });

        // Undoスタックが上限を超えたら古いエントリを削除
        if (buffer_state.undo_stack.items.len > MAX_UNDO_ENTRIES) {
            const old_entry = buffer_state.undo_stack.orderedRemove(0);
            old_entry.deinit(self.allocator);
        }

        // Redoスタックをクリア
        for (buffer_state.redo_stack.items) |entry| {
            entry.deinit(self.allocator);
        }
        buffer_state.redo_stack.clearRetainingCapacity();
    }

    fn undo(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        const buffer = self.getCurrentBufferContent();
        if (buffer_state.undo_stack.items.len == 0) return;

        const entry = buffer_state.undo_stack.pop() orelse return;
        defer entry.deinit(self.allocator);

        const saved_cursor = entry.cursor_pos;

        // 逆操作を実行してredoスタックに保存
        switch (entry.op) {
            .insert => |ins| {
                // insertの取り消し: deleteする
                try buffer.delete(ins.pos, ins.text.len);
                const text_copy = try self.allocator.dupe(u8, ins.text);
                try buffer_state.redo_stack.append(self.allocator, .{
                    .op = .{ .insert = .{ .pos = ins.pos, .text = text_copy } },
                    .cursor_pos = self.getCurrentView().getCursorBufferPos(),
                });
            },
            .delete => |del| {
                // deleteの取り消し: insertする
                try buffer.insertSlice(del.pos, del.text);
                const text_copy = try self.allocator.dupe(u8, del.text);
                try buffer_state.redo_stack.append(self.allocator, .{
                    .op = .{ .delete = .{ .pos = del.pos, .text = text_copy } },
                    .cursor_pos = self.getCurrentView().getCursorBufferPos(),
                });
            },
        }

        // Undoスタックが空になったら元の状態に戻ったのでmodified=false
        if (buffer_state.undo_stack.items.len == 0) {
            buffer_state.modified = false;
        } else {
            buffer_state.modified = true;
        }

        // 画面全体を再描画
        self.getCurrentView().markFullRedraw();

        // カーソル位置を復元（保存された位置へ）
        self.restoreCursorPos(saved_cursor);
    }

    fn redo(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        const buffer = self.getCurrentBufferContent();
        if (buffer_state.redo_stack.items.len == 0) return;

        const entry = buffer_state.redo_stack.pop() orelse return;
        defer entry.deinit(self.allocator);

        const saved_cursor = entry.cursor_pos;

        // 逆操作を実行してundoスタックに保存
        switch (entry.op) {
            .insert => |ins| {
                // redoのinsert: もう一度insertする
                try buffer.insertSlice(ins.pos, ins.text);
                const text_copy = try self.allocator.dupe(u8, ins.text);
                try buffer_state.undo_stack.append(self.allocator, .{
                    .op = .{ .insert = .{ .pos = ins.pos, .text = text_copy } },
                    .cursor_pos = self.getCurrentView().getCursorBufferPos(),
                });
            },
            .delete => |del| {
                // redoのdelete: もう一度deleteする
                try buffer.delete(del.pos, del.text.len);
                const text_copy = try self.allocator.dupe(u8, del.text);
                try buffer_state.undo_stack.append(self.allocator, .{
                    .op = .{ .delete = .{ .pos = del.pos, .text = text_copy } },
                    .cursor_pos = self.getCurrentView().getCursorBufferPos(),
                });
            },
        }

        // Undoスタックが空でなければ変更されている
        // （Redoによって変更が再適用されたため）
        buffer_state.modified = (buffer_state.undo_stack.items.len > 0);

        // 画面全体を再描画
        self.getCurrentView().markFullRedraw();

        // カーソル位置を復元（保存された位置へ）
        self.restoreCursorPos(saved_cursor);
    }

    // バイト位置からカーソル座標を計算して設定（grapheme cluster考慮）
    fn setCursorToPos(self: *Editor, target_pos: usize) void {
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();
        const clamped_pos = @min(target_pos, buffer.len());

        // LineIndexでO(log N)行番号計算
        const line = buffer.findLineByPos(clamped_pos);
        const line_start = buffer.getLineStart(line) orelse 0;

        // 画面内の行位置を計算
        const max_screen_lines = if (self.terminal.height >= 1) self.terminal.height - 1 else 0;
        if (max_screen_lines == 0 or line < max_screen_lines) {
            view.top_line = 0;
            view.cursor_y = line;
        } else {
            view.top_line = line - max_screen_lines / 2; // 中央に表示
            view.cursor_y = line - view.top_line;
        }

        // カーソルX位置を計算（grapheme clusterの表示幅）
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        var display_col: usize = 0;
        while (iter.global_pos < clamped_pos) {
            const cluster = iter.nextGraphemeCluster() catch {
                _ = iter.next();
                display_col += 1;
                continue;
            };
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                display_col += gc.width; // 絵文字は2、通常文字は1
            } else {
                break;
            }
        }

        view.cursor_x = display_col;
    }

    // エイリアス: restoreCursorPosはsetCursorToPosと同じ
    fn restoreCursorPos(self: *Editor, target_pos: usize) void {
        self.setCursorToPos(target_pos);
    }

    fn processKey(self: *Editor, key: input.Key) !void {
        // 古いプロンプトバッファを解放
        if (self.prompt_buffer) |old_prompt| {
            self.allocator.free(old_prompt);
            self.prompt_buffer = null;
        }

        // モード別に処理を分岐
        switch (self.mode) {
            .filename_input => {
                // ファイル名入力モード：文字とバックスペース、Enter、C-gのみ受け付ける
                switch (key) {
                    .char => |c| {
                        // 入力バッファに文字を追加
                        try self.input_buffer.append(self.allocator, c);
                        // プロンプトを更新
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Write file: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        } else {
                            self.getCurrentView().setError("Write file: ");
                        }
                    },
                    .codepoint => |cp| {
                        // UTF-8マルチバイト文字を処理
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return;
                        try self.input_buffer.appendSlice(self.allocator, buf[0..len]);
                        // プロンプトを更新
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Write file: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        } else {
                            self.getCurrentView().setError("Write file: ");
                        }
                    },
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: キャンセル
                                self.mode = .normal;
                                self.quit_after_save = false; // フラグをリセット
                                self.input_buffer.clearRetainingCapacity();
                                self.getCurrentView().clearError();
                            },
                            else => {},
                        }
                    },
                    .backspace => {
                        // バックスペース：最後の文字を削除
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Write file: {s}", .{self.input_buffer.items}) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            } else {
                                self.getCurrentView().setError("Write file: ");
                            }
                        }
                    },
                    .enter => {
                        // Enter: ファイル名確定
                        if (self.input_buffer.items.len > 0) {
                            // 既存のfilenameがあれば解放
                            const buffer_state = self.getCurrentBuffer();
                            if (buffer_state.filename) |old| {
                                self.allocator.free(old);
                            }
                            // 新しいfilenameを設定
                            buffer_state.filename = try self.allocator.dupe(u8, self.input_buffer.items);
                            self.input_buffer.clearRetainingCapacity();

                            // ファイルを保存
                            try self.saveFile();
                            self.mode = .normal;

                            // quit_after_saveフラグが立っている場合は終了
                            if (self.quit_after_save) {
                                self.quit_after_save = false;
                                self.running = false;
                            }
                        }
                    },
                    else => {},
                }
                return;
            },
            .find_file_input => {
                // ファイルを開くためのファイル名入力モード
                switch (key) {
                    .char => |c| {
                        // 通常文字を入力バッファに追加
                        try self.input_buffer.append(self.allocator, c);
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Find file: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        } else {
                            self.getCurrentView().setError("Find file: ");
                        }
                    },
                    .codepoint => |cp| {
                        // UTF-8マルチバイト文字を処理
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return;
                        try self.input_buffer.appendSlice(self.allocator, buf[0..len]);
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Find file: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                    },
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: キャンセル
                                self.mode = .normal;
                                self.input_buffer.clearRetainingCapacity();
                                self.getCurrentView().clearError();
                            },
                            else => {},
                        }
                    },
                    .backspace => {
                        // バックスペース：最後の文字を削除
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Find file: {s}", .{self.input_buffer.items}) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            } else {
                                self.getCurrentView().setError("Find file: ");
                            }
                        }
                    },
                    .enter => {
                        // Enter: ファイル名確定
                        if (self.input_buffer.items.len > 0) {
                            const filename = self.input_buffer.items;

                            // 既存のバッファでこのファイルが開かれているか検索
                            const existing_buffer = self.findBufferByFilename(filename);
                            if (existing_buffer) |buf| {
                                // 既に開かれている場合は、そのバッファに切り替え
                                try self.switchToBuffer(buf.id);
                            } else {
                                // 新しいバッファを作成
                                const new_buffer = try self.createNewBuffer();

                                // ファイルを読み込む
                                const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
                                    if (err == error.FileNotFound) {
                                        // 新規ファイルとして扱う
                                        new_buffer.filename = try self.allocator.dupe(u8, filename);
                                        try self.switchToBuffer(new_buffer.id);
                                        self.mode = .normal;
                                        self.input_buffer.clearRetainingCapacity();
                                        self.getCurrentView().clearError();
                                        return;
                                    } else {
                                        self.getCurrentView().setError(@errorName(err));
                                        self.mode = .normal;
                                        self.input_buffer.clearRetainingCapacity();
                                        return;
                                    }
                                };
                                defer file.close();

                                const stat = try file.stat();
                                const content = try file.readToEndAlloc(self.allocator, stat.size);
                                defer self.allocator.free(content);

                                // バイナリファイルチェック
                                const check_size = @min(content.len, 8192);
                                var is_binary = false;
                                for (content[0..check_size]) |byte| {
                                    if (byte == 0) {
                                        is_binary = true;
                                        break;
                                    }
                                }

                                if (is_binary) {
                                    // バイナリファイルはバッファを削除して拒否
                                    _ = try self.closeBuffer(new_buffer.id);
                                    self.getCurrentView().setError("Cannot open binary file");
                                    self.mode = .normal;
                                    self.input_buffer.clearRetainingCapacity();
                                    return;
                                }

                                // ファイル内容をバッファに挿入
                                try new_buffer.buffer.insertSlice(0, content);
                                new_buffer.filename = try self.allocator.dupe(u8, filename);
                                new_buffer.modified = false;
                                new_buffer.file_mtime = stat.mtime;

                                // バッファに切り替え
                                try self.switchToBuffer(new_buffer.id);
                            }

                            self.mode = .normal;
                            self.input_buffer.clearRetainingCapacity();
                            self.getCurrentView().clearError();
                        }
                    },
                    else => {},
                }
                return;
            },
            .buffer_switch_input => {
                // バッファ切り替えのための入力モード
                switch (key) {
                    .char => |c| {
                        // 通常文字を入力バッファに追加
                        try self.input_buffer.append(self.allocator, c);
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Switch to buffer: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        } else {
                            self.getCurrentView().setError("Switch to buffer: ");
                        }
                    },
                    .codepoint => |cp| {
                        // UTF-8マルチバイト文字を処理
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return;
                        try self.input_buffer.appendSlice(self.allocator, buf[0..len]);
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Switch to buffer: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                    },
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: キャンセル
                                self.mode = .normal;
                                self.input_buffer.clearRetainingCapacity();
                                self.getCurrentView().clearError();
                            },
                            else => {},
                        }
                    },
                    .backspace => {
                        // バックスペース：最後の文字を削除
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Switch to buffer: {s}", .{self.input_buffer.items}) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            } else {
                                self.getCurrentView().setError("Switch to buffer: ");
                            }
                        }
                    },
                    .enter => {
                        // Enter: バッファ名確定
                        if (self.input_buffer.items.len > 0) {
                            const buffer_name = self.input_buffer.items;

                            // バッファをファイル名で検索
                            const found_buffer = self.findBufferByFilename(buffer_name);
                            if (found_buffer) |buf| {
                                try self.switchToBuffer(buf.id);
                                self.mode = .normal;
                                self.input_buffer.clearRetainingCapacity();
                                self.getCurrentView().clearError();
                            } else {
                                // バッファが見つからない場合
                                self.getCurrentView().setError("No such buffer");
                                self.mode = .normal;
                                self.input_buffer.clearRetainingCapacity();
                            }
                        }
                    },
                    else => {},
                }
                return;
            },
            .isearch_forward, .isearch_backward => {
                // インクリメンタルサーチモード
                const is_forward = (self.mode == .isearch_forward);
                switch (key) {
                    .char => |c| {
                        // 検索文字列に文字を追加
                        try self.input_buffer.append(self.allocator, c);
                        // プロンプトを更新して検索実行
                        const prefix = if (is_forward) "I-search: " else "I-search backward: ";
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, self.input_buffer.items }) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                        // 検索実行（現在位置から）
                        if (self.input_buffer.items.len > 0) {
                            self.getCurrentView().setSearchHighlight(self.input_buffer.items);
                            try self.performSearch(is_forward, false);
                        }
                    },
                    .codepoint => |cp| {
                        // UTF-8マルチバイト文字を処理
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return;
                        try self.input_buffer.appendSlice(self.allocator, buf[0..len]);
                        // プロンプトを更新して検索実行
                        const prefix = if (is_forward) "I-search: " else "I-search backward: ";
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, self.input_buffer.items }) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                        // 検索実行（現在位置から）
                        if (self.input_buffer.items.len > 0) {
                            self.getCurrentView().setSearchHighlight(self.input_buffer.items);
                            try self.performSearch(is_forward, false);
                        }
                    },
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: 検索キャンセル、元の位置に戻る
                                if (self.search_start_pos) |start_pos| {
                                    self.setCursorToPos(start_pos);
                                }
                                self.mode = .normal;
                                self.input_buffer.clearRetainingCapacity();
                                self.getCurrentView().setSearchHighlight(null); // ハイライトクリア
                                self.getCurrentView().clearError();
                            },
                            's' => {
                                // C-s: 次の一致を検索（前方）
                                if (self.input_buffer.items.len > 0) {
                                    self.getCurrentView().setSearchHighlight(self.input_buffer.items);
                                    try self.performSearch(true, true);
                                }
                            },
                            'r' => {
                                // C-r: 前の一致を検索（後方）
                                if (self.input_buffer.items.len > 0) {
                                    self.getCurrentView().setSearchHighlight(self.input_buffer.items);
                                    try self.performSearch(false, true);
                                }
                            },
                            else => {},
                        }
                    },
                    .backspace => {
                        // バックスペース：検索文字列の最後の文字を削除
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            const prefix = if (is_forward) "I-search: " else "I-search backward: ";
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, self.input_buffer.items }) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            } else {
                                self.getCurrentView().clearError();
                            }
                            // 検索文字列が残っていれば再検索
                            if (self.input_buffer.items.len > 0) {
                                self.getCurrentView().setSearchHighlight(self.input_buffer.items);
                                // 開始位置から再検索
                                if (self.search_start_pos) |start_pos| {
                                    self.setCursorToPos(start_pos);
                                }
                                try self.performSearch(is_forward, false);
                            } else {
                                // 検索文字列が空になったら開始位置に戻る
                                self.getCurrentView().setSearchHighlight(null); // ハイライトクリア
                                if (self.search_start_pos) |start_pos| {
                                    self.setCursorToPos(start_pos);
                                }
                            }
                        }
                    },
                    .enter => {
                        // Enter: 検索確定（現在位置で確定）
                        // 検索文字列を保存
                        if (self.input_buffer.items.len > 0) {
                            if (self.last_search) |old_search| {
                                self.allocator.free(old_search);
                            }
                            self.last_search = self.allocator.dupe(u8, self.input_buffer.items) catch null;
                        }
                        self.mode = .normal;
                        self.input_buffer.clearRetainingCapacity();
                        self.getCurrentView().setSearchHighlight(null); // ハイライトクリア
                        self.getCurrentView().clearError();
                    },
                    else => {},
                }
                return;
            },
            .prefix_x => {
                // C-xプレフィックスモード：次のCtrlキーを待つ
                self.mode = .normal; // デフォルトでnormalに戻る
                switch (key) {
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: キャンセル
                                self.getCurrentView().clearError();
                            },
                            'b' => {
                                // C-x C-b: バッファ一覧表示
                                self.showBufferList() catch |err| {
                                    self.getCurrentView().setError(@errorName(err));
                                };
                            },
                            'f' => {
                                // C-x C-f: ファイルを開く
                                self.mode = .find_file_input;
                                self.input_buffer.clearRetainingCapacity();
                                self.getCurrentView().setError("Find file: ");
                            },
                            's' => {
                                // C-x C-s: 保存
                                const buffer_state = self.getCurrentBuffer();
                                if (buffer_state.filename == null) {
                                    // 新規ファイル：ファイル名入力モードへ
                                    self.mode = .filename_input;
                                    self.quit_after_save = false; // 保存後は終了しない
                                    self.input_buffer.clearRetainingCapacity();
                                    self.getCurrentView().setError("Write file: ");
                                } else {
                                    // 既存ファイル：そのまま保存
                                    try self.saveFile();
                                }
                            },
                            'c' => {
                                // C-x C-c: 終了
                                const buffer_state = self.getCurrentBuffer();
                                if (buffer_state.modified) {
                                    if (buffer_state.filename) |name| {
                                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Save changes to {s}? (y/n/c): ", .{name}) catch null;
                                        if (self.prompt_buffer) |prompt| {
                                            self.getCurrentView().setError(prompt);
                                        } else {
                                            self.getCurrentView().setError("Save changes? (y/n/c): ");
                                        }
                                    } else {
                                        self.getCurrentView().setError("Save changes? (y/n/c): ");
                                    }
                                    self.mode = .quit_confirm;
                                } else {
                                    self.running = false;
                                }
                            },
                            else => {
                                self.getCurrentView().setError("Unknown command");
                            },
                        }
                    },
                    .char => |c| {
                        // C-x の後に通常文字を受け付ける（C-x h、C-x r など）
                        switch (c) {
                            'h' => self.selectAll(), // C-x h 全選択
                            'r' => {
                                // C-x r: 矩形コマンドプレフィックス
                                self.mode = .prefix_r;
                                return;
                            },
                            'b' => {
                                // C-x b: バッファ切り替え
                                self.mode = .buffer_switch_input;
                                self.input_buffer.clearRetainingCapacity();
                                self.getCurrentView().setError("Switch to buffer: ");
                            },
                            'k' => {
                                // C-x k: バッファを閉じる
                                const buffer_state = self.getCurrentBuffer();
                                if (buffer_state.modified) {
                                    // 変更がある場合は確認
                                    if (buffer_state.filename) |name| {
                                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Buffer {s} modified; kill anyway? (y/n): ", .{name}) catch null;
                                        if (self.prompt_buffer) |prompt| {
                                            self.getCurrentView().setError(prompt);
                                        } else {
                                            self.getCurrentView().setError("Buffer modified; kill anyway? (y/n): ");
                                        }
                                    } else {
                                        self.getCurrentView().setError("Buffer modified; kill anyway? (y/n): ");
                                    }
                                    // TODO: 確認モードを実装
                                    self.getCurrentView().setError("Kill buffer not yet fully implemented");
                                } else {
                                    // 変更がない場合は直接閉じる
                                    const buffer_id = buffer_state.id;
                                    self.closeBuffer(buffer_id) catch |err| {
                                        self.getCurrentView().setError(@errorName(err));
                                    };
                                }
                            },
                            '2' => {
                                // C-x 2: 横分割（上下に分割）
                                self.splitWindowHorizontally() catch |err| {
                                    self.getCurrentView().setError(@errorName(err));
                                };
                            },
                            '3' => {
                                // C-x 3: 縦分割（左右に分割）
                                self.splitWindowVertically() catch |err| {
                                    self.getCurrentView().setError(@errorName(err));
                                };
                            },
                            'o' => {
                                // C-x o: 次のウィンドウに移動
                                if (self.windows.items.len > 1) {
                                    self.current_window_idx = (self.current_window_idx + 1) % self.windows.items.len;
                                }
                            },
                            '0' => {
                                // C-x 0: 現在のウィンドウを閉じる
                                self.closeCurrentWindow() catch |err| {
                                    self.getCurrentView().setError(@errorName(err));
                                };
                            },
                            '1' => {
                                // C-x 1: 他のウィンドウをすべて閉じる
                                self.deleteOtherWindows() catch |err| {
                                    self.getCurrentView().setError(@errorName(err));
                                };
                            },
                            else => {
                                self.getCurrentView().setError("Unknown command");
                            },
                        }
                    },
                    else => {
                        self.getCurrentView().setError("Expected C-x C-[key]");
                    },
                }
                return;
            },
            .quit_confirm => {
                // 終了確認モード：y/n/cのみ受け付ける
                switch (key) {
                    .char => |c| {
                        switch (c) {
                            'y', 'Y' => {
                                // 保存して終了
                                const buffer_state = self.getCurrentBuffer();
                                if (buffer_state.filename == null) {
                                    // 新規ファイル：ファイル名入力モードへ
                                    self.mode = .filename_input;
                                    self.quit_after_save = true; // 保存後に終了
                                    self.input_buffer.clearRetainingCapacity();
                                    self.getCurrentView().setError("Write file: ");
                                } else {
                                    self.saveFile() catch |err| {
                                        self.getCurrentView().setError(@errorName(err));
                                        self.mode = .normal;
                                        return;
                                    };
                                    self.running = false;
                                }
                            },
                            'n', 'N' => {
                                // 保存せずに終了
                                self.running = false;
                            },
                            'c', 'C' => {
                                // キャンセル
                                self.mode = .normal;
                                self.getCurrentView().clearError();
                            },
                            else => {
                                // 無効な入力
                                self.getCurrentView().setError("Please answer: (y)es, (n)o, (c)ancel");
                            },
                        }
                    },
                    .codepoint => |cp| {
                        // IMEがオンの状態でもy/n/cを受け付ける（全角も半角に変換して処理）
                        const normalized = normalizeCodepoint(cp);
                        switch (normalized) {
                            'y', 'Y' => {
                                // 保存して終了
                                const buffer_state = self.getCurrentBuffer();
                                if (buffer_state.filename == null) {
                                    // 新規ファイル：ファイル名入力モードへ
                                    self.mode = .filename_input;
                                    self.quit_after_save = true; // 保存後に終了
                                    self.input_buffer.clearRetainingCapacity();
                                    self.getCurrentView().setError("Write file: ");
                                } else {
                                    self.saveFile() catch |err| {
                                        self.getCurrentView().setError(@errorName(err));
                                        self.mode = .normal;
                                        return;
                                    };
                                    self.running = false;
                                }
                            },
                            'n', 'N' => {
                                // 保存せずに終了
                                self.running = false;
                            },
                            'c', 'C' => {
                                // キャンセル
                                self.mode = .normal;
                                self.getCurrentView().clearError();
                            },
                            else => {
                                // 無効な入力
                                self.getCurrentView().setError("Please answer: (y)es, (n)o, (c)ancel");
                            },
                        }
                    },
                    .ctrl => |c| {
                        // Ctrl-Gでもキャンセル
                        if (c == 'g') {
                            self.mode = .normal;
                            self.getCurrentView().clearError();
                        }
                    },
                    else => {},
                }
                return;
            },
            .prefix_r => {
                // C-x r プレフィックスモード：矩形コマンドを受け付ける
                self.mode = .normal; // 次のキーの後は通常モードに戻る
                switch (key) {
                    .char => |c| {
                        switch (c) {
                            'k' => self.killRectangle(), // C-x r k 矩形削除
                            'y' => self.yankRectangle(), // C-x r y 矩形貼り付け
                            't' => {
                                // C-x r t 矩形文字列挿入（未実装）
                                self.getCurrentView().setError("C-x r t not implemented yet");
                            },
                            else => {
                                self.getCurrentView().setError("Unknown rectangle command");
                            },
                        }
                    },
                    .ctrl => |c| {
                        // Ctrl-Gでキャンセル
                        if (c == 'g') {
                            self.getCurrentView().clearError();
                        } else {
                            self.getCurrentView().setError("Unknown rectangle command");
                        }
                    },
                    else => {
                        self.getCurrentView().setError("Unknown rectangle command");
                    },
                }
                return;
            },
            .query_replace_input_search => {
                // 置換：検索文字列入力モード
                switch (key) {
                    .char => |c| {
                        // 入力バッファに文字を追加
                        try self.input_buffer.append(self.allocator, c);
                        // プロンプトを更新
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        } else {
                            self.getCurrentView().setError("Query replace: ");
                        }
                    },
                    .codepoint => |cp| {
                        // UTF-8マルチバイト文字を処理
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return;
                        try self.input_buffer.appendSlice(self.allocator, buf[0..len]);
                        // プロンプトを更新
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace: {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        } else {
                            self.getCurrentView().setError("Query replace: ");
                        }
                    },
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: キャンセル
                                self.mode = .normal;
                                self.input_buffer.clearRetainingCapacity();
                                self.getCurrentView().clearError();
                            },
                            else => {},
                        }
                    },
                    .backspace => {
                        // バックスペース：最後の文字を削除
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace: {s}", .{self.input_buffer.items}) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            } else {
                                self.getCurrentView().setError("Query replace: ");
                            }
                        }
                    },
                    .enter => {
                        // Enter: 検索文字列確定、置換文字列入力へ
                        if (self.input_buffer.items.len > 0) {
                            // 検索文字列を保存
                            if (self.replace_search) |old| {
                                self.allocator.free(old);
                            }
                            self.replace_search = try self.allocator.dupe(u8, self.input_buffer.items);
                            self.input_buffer.clearRetainingCapacity();

                            // 置換文字列入力モードへ
                            self.mode = .query_replace_input_replacement;
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace {s} with: ", .{self.replace_search.?}) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            } else {
                                self.getCurrentView().setError("Query replace with: ");
                            }
                        }
                    },
                    else => {},
                }
                return;
            },
            .query_replace_input_replacement => {
                // 置換：置換文字列入力モード
                switch (key) {
                    .char => |c| {
                        // 入力バッファに文字を追加
                        try self.input_buffer.append(self.allocator, c);
                        // プロンプトを更新
                        if (self.replace_search) |search| {
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace {s} with: {s}", .{search, self.input_buffer.items}) catch null;
                        } else {
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace with: {s}", .{self.input_buffer.items}) catch null;
                        }
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                    },
                    .codepoint => |cp| {
                        // UTF-8マルチバイト文字を処理
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return;
                        try self.input_buffer.appendSlice(self.allocator, buf[0..len]);
                        // プロンプトを更新
                        if (self.replace_search) |search| {
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace {s} with: {s}", .{search, self.input_buffer.items}) catch null;
                        } else {
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace with: {s}", .{self.input_buffer.items}) catch null;
                        }
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                    },
                    .ctrl => |c| {
                        switch (c) {
                            'g' => {
                                // C-g: キャンセル
                                self.mode = .normal;
                                self.input_buffer.clearRetainingCapacity();
                                if (self.replace_search) |search| {
                                    self.allocator.free(search);
                                    self.replace_search = null;
                                }
                                self.getCurrentView().clearError();
                            },
                            else => {},
                        }
                    },
                    .backspace => {
                        // バックスペース：最後の文字を削除
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            if (self.replace_search) |search| {
                                self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace {s} with: {s}", .{search, self.input_buffer.items}) catch null;
                            } else {
                                self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Query replace with: {s}", .{self.input_buffer.items}) catch null;
                            }
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            }
                        }
                    },
                    .enter => {
                        // Enter: 置換文字列確定、最初の一致を検索
                        // 置換文字列を保存（空文字列も許可）
                        if (self.replace_replacement) |old| {
                            self.allocator.free(old);
                        }
                        self.replace_replacement = try self.allocator.dupe(u8, self.input_buffer.items);
                        self.input_buffer.clearRetainingCapacity();

                        // 最初の一致を検索
                        if (self.replace_search) |search| {
                            const found = try self.findNextMatch(search, self.getCurrentView().getCursorBufferPos());
                            if (found) {
                                // 一致が見つかった：確認モードへ
                                self.mode = .query_replace_confirm;
                                self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Replace? (y)es (n)ext (!)all (q)uit", .{}) catch null;
                                if (self.prompt_buffer) |prompt| {
                                    self.getCurrentView().setError(prompt);
                                } else {
                                    self.getCurrentView().setError("Replace? (y/n/!/q)");
                                }
                            } else {
                                // 一致が見つからない
                                self.mode = .normal;
                                self.getCurrentView().setError("No match found");
                            }
                        } else {
                            // 検索文字列がない（エラー）
                            self.mode = .normal;
                            self.getCurrentView().setError("No search string");
                        }
                    },
                    else => {},
                }
                return;
            },
            .query_replace_confirm => {
                // 置換：確認モード
                switch (key) {
                    .char => |c| {
                        switch (c) {
                            'y', 'Y' => {
                                // この箇所を置換して次へ
                                try self.replaceCurrentMatch();
                                const search = self.replace_search orelse {
                                    self.mode = .normal;
                                    self.getCurrentView().setError("Error: no search string");
                                    return;
                                };
                                // 次の一致を検索
                                const found = try self.findNextMatch(search, self.getCurrentView().getCursorBufferPos());
                                if (!found) {
                                    // これ以上一致がない
                                    self.mode = .normal;
                                    var msg_buf: [128]u8 = undefined;
                                    const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace done";
                                    self.getCurrentView().setError(msg);
                                } else {
                                    // 次のマッチが見つかった - 確認プロンプトを表示
                                    self.getCurrentView().setError("Replace? (y)es (n)ext (!)all (q)uit");
                                }
                            },
                            'n', 'N', ' ' => {
                                // スキップして次へ
                                const search = self.replace_search orelse {
                                    self.mode = .normal;
                                    self.getCurrentView().setError("Error: no search string");
                                    return;
                                };
                                // 現在の一致をスキップ（カーソルを一致の後ろに移動）
                                const current_pos = self.getCurrentView().getCursorBufferPos();
                                const found = try self.findNextMatch(search, current_pos + 1);
                                if (!found) {
                                    // これ以上一致がない
                                    self.mode = .normal;
                                    var msg_buf: [128]u8 = undefined;
                                    const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace done";
                                    self.getCurrentView().setError(msg);
                                } else {
                                    // 次のマッチが見つかった - 確認プロンプトを表示
                                    self.getCurrentView().setError("Replace? (y)es (n)ext (!)all (q)uit");
                                }
                            },
                            '!' => {
                                // 残りすべてを置換
                                try self.replaceCurrentMatch();
                                const search = self.replace_search orelse {
                                    self.mode = .normal;
                                    self.getCurrentView().setError("Error: no search string");
                                    return;
                                };
                                // 残りすべてを置換
                                var pos = self.getCurrentView().getCursorBufferPos();
                                while (true) {
                                    const found = try self.findNextMatch(search, pos);
                                    if (!found) break;
                                    try self.replaceCurrentMatch();
                                    pos = self.getCurrentView().getCursorBufferPos();
                                }
                                self.mode = .normal;
                                var msg_buf: [128]u8 = undefined;
                                const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace done";
                                self.getCurrentView().setError(msg);
                            },
                            'q', 'Q' => {
                                // 終了
                                self.mode = .normal;
                                var msg_buf: [128]u8 = undefined;
                                const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace cancelled";
                                self.getCurrentView().setError(msg);
                            },
                            else => {
                                // 無効な入力
                                self.getCurrentView().setError("Please answer: (y)es, (n)ext, (!)all, (q)uit");
                            },
                        }
                    },
                    .codepoint => |cp| {
                        // IMEがオンの状態でもy/n/!/qを受け付ける（全角も半角に変換して処理）
                        const normalized = normalizeCodepoint(cp);
                        switch (normalized) {
                            'y', 'Y' => {
                                // この箇所を置換して次へ
                                try self.replaceCurrentMatch();
                                const search = self.replace_search orelse {
                                    self.mode = .normal;
                                    self.getCurrentView().setError("Error: no search string");
                                    return;
                                };
                                // 次の一致を検索
                                const found = try self.findNextMatch(search, self.getCurrentView().getCursorBufferPos());
                                if (!found) {
                                    // これ以上一致がない
                                    self.mode = .normal;
                                    var msg_buf: [128]u8 = undefined;
                                    const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace done";
                                    self.getCurrentView().setError(msg);
                                } else {
                                    // 次のマッチが見つかった - 確認プロンプトを表示
                                    self.getCurrentView().setError("Replace? (y)es (n)ext (!)all (q)uit");
                                }
                            },
                            'n', 'N', ' ' => {
                                // スキップして次へ
                                const search = self.replace_search orelse {
                                    self.mode = .normal;
                                    self.getCurrentView().setError("Error: no search string");
                                    return;
                                };
                                // 現在の一致をスキップ（カーソルを一致の後ろに移動）
                                const current_pos = self.getCurrentView().getCursorBufferPos();
                                const found = try self.findNextMatch(search, current_pos + 1);
                                if (!found) {
                                    // これ以上一致がない
                                    self.mode = .normal;
                                    var msg_buf: [128]u8 = undefined;
                                    const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace done";
                                    self.getCurrentView().setError(msg);
                                } else {
                                    // 次のマッチが見つかった - 確認プロンプトを表示
                                    self.getCurrentView().setError("Replace? (y)es (n)ext (!)all (q)uit");
                                }
                            },
                            '!' => {
                                // 残りすべてを置換
                                try self.replaceCurrentMatch();
                                const search = self.replace_search orelse {
                                    self.mode = .normal;
                                    self.getCurrentView().setError("Error: no search string");
                                    return;
                                };
                                // 残りすべてを置換
                                var pos = self.getCurrentView().getCursorBufferPos();
                                while (true) {
                                    const found = try self.findNextMatch(search, pos);
                                    if (!found) break;
                                    try self.replaceCurrentMatch();
                                    pos = self.getCurrentView().getCursorBufferPos();
                                }
                                self.mode = .normal;
                                var msg_buf: [128]u8 = undefined;
                                const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace done";
                                self.getCurrentView().setError(msg);
                            },
                            'q', 'Q' => {
                                // 終了
                                self.mode = .normal;
                                var msg_buf: [128]u8 = undefined;
                                const msg = std.fmt.bufPrint(&msg_buf, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch "Replace cancelled";
                                self.getCurrentView().setError(msg);
                            },
                            else => {
                                // 無効な入力
                                self.getCurrentView().setError("Please answer: (y)es, (n)ext, (!)all, (q)uit");
                            },
                        }
                    },
                    .ctrl => |c| {
                        // Ctrl-Gで終了
                        if (c == 'g') {
                            self.mode = .normal;
                            const msg = std.fmt.allocPrint(self.allocator, "Replaced {d} occurrence(s)", .{self.replace_match_count}) catch null;
                            if (msg) |m| {
                                self.getCurrentView().setError(m);
                            } else {
                                self.getCurrentView().setError("Replace cancelled");
                            }
                        }
                    },
                    else => {},
                }
                return;
            },
            .shell_command => {
                // シェルコマンド入力モード
                switch (key) {
                    .char => |c| {
                        try self.input_buffer.append(self.allocator, c);
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "| {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                    },
                    .codepoint => |cp| {
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return;
                        try self.input_buffer.appendSlice(self.allocator, buf[0..len]);
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, "| {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                    },
                    .ctrl => |c| {
                        if (c == 'g') {
                            // C-g: キャンセル
                            self.mode = .normal;
                            self.input_buffer.clearRetainingCapacity();
                            self.getCurrentView().clearError();
                        }
                    },
                    .backspace => {
                        if (self.input_buffer.items.len > 0) {
                            // UTF-8文字の境界を考慮してバックスペース
                            var del_len: usize = 1;
                            while (del_len < self.input_buffer.items.len) {
                                const idx = self.input_buffer.items.len - del_len - 1;
                                const byte = self.input_buffer.items[idx];
                                if ((byte & 0xC0) != 0x80) break;
                                del_len += 1;
                            }
                            self.input_buffer.items.len -= del_len;
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "| {s}", .{self.input_buffer.items}) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            } else {
                                self.getCurrentView().setError("| ");
                            }
                        }
                    },
                    .enter => {
                        // Enter: コマンド実行
                        if (self.input_buffer.items.len > 0) {
                            try self.startShellCommand();
                            // startShellCommandが成功すればmode = .shell_runningになる
                            // 失敗時やコマンドが空の場合はmodeはそのまま
                        }
                        // shell_runningモードに移行しなかった場合は元に戻す
                        if (self.mode != .shell_running) {
                            self.mode = .normal;
                            self.input_buffer.clearRetainingCapacity();
                        }
                    },
                    else => {},
                }
                return;
            },
            .shell_running => {
                // シェルコマンド実行中モード
                switch (key) {
                    .ctrl => |c| {
                        if (c == 'g') {
                            // C-g: キャンセル
                            self.cancelShellCommand();
                            self.input_buffer.clearRetainingCapacity();
                        }
                    },
                    else => {
                        // 他のキーは無視（実行中は操作不可）
                    },
                }
                return;
            },
            .mx_command => {
                // M-xコマンド入力モード
                switch (key) {
                    .char => |c| {
                        try self.input_buffer.append(self.allocator, c);
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, ": {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                    },
                    .codepoint => |cp| {
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return;
                        try self.input_buffer.appendSlice(self.allocator, buf[0..len]);
                        self.prompt_buffer = std.fmt.allocPrint(self.allocator, ": {s}", .{self.input_buffer.items}) catch null;
                        if (self.prompt_buffer) |prompt| {
                            self.getCurrentView().setError(prompt);
                        }
                    },
                    .ctrl => |c| {
                        if (c == 'g') {
                            // C-g: キャンセル
                            self.mode = .normal;
                            self.input_buffer.clearRetainingCapacity();
                            self.getCurrentView().clearError();
                        }
                    },
                    .backspace => {
                        if (self.input_buffer.items.len > 0) {
                            _ = self.input_buffer.pop();
                            self.prompt_buffer = std.fmt.allocPrint(self.allocator, ": {s}", .{self.input_buffer.items}) catch null;
                            if (self.prompt_buffer) |prompt| {
                                self.getCurrentView().setError(prompt);
                            } else {
                                self.getCurrentView().setError(": ");
                            }
                        }
                    },
                    .enter => {
                        // Enter: コマンド実行
                        try self.executeMxCommand();
                    },
                    else => {},
                }
                return;
            },
            .mx_key_describe => {
                // M-x key: 次のキー入力を待っている
                const key_desc = self.describeKey(key);
                self.getCurrentView().setError(key_desc);
                self.mode = .normal;
                return;
            },
            .normal => {},
        }

        // 通常モード
        switch (key) {
            // Ctrl キー
            .ctrl => |c| {
                switch (c) {
                    0, '@' => self.setMark(), // C-Space / C-@ マーク設定
                    'x' => {
                        // C-x プレフィックスキー
                        self.mode = .prefix_x;
                        self.getCurrentView().setError("C-x-");
                    },
                    'f' => self.getCurrentView().moveCursorRight(&self.terminal), // C-f 前進
                    'b' => self.getCurrentView().moveCursorLeft(), // C-b 後退
                    'n' => self.getCurrentView().moveCursorDown(&self.terminal), // C-n 次行
                    'p' => self.getCurrentView().moveCursorUp(), // C-p 前行
                    'a' => self.getCurrentView().moveToLineStart(), // C-a 行頭
                    'e' => self.getCurrentView().moveToLineEnd(), // C-e 行末
                    'd' => try self.deleteChar(), // C-d 文字削除
                    'k' => try self.killLine(), // C-k 行削除
                    'w' => try self.killRegion(), // C-w 範囲削除（カット）
                    'y' => try self.yank(), // C-y ペースト
                    'g' => self.getCurrentView().clearError(), // C-g キャンセル
                    'u' => try self.undo(), // C-u Undo
                    31, '/' => try self.redo(), // C-/ または C-_ Redo
                    's' => {
                        // C-s インクリメンタルサーチ（前方）
                        // 前回の検索文字列がある場合は、それを使って次の一致を検索
                        if (self.last_search) |search_str| {
                            // input_bufferに前回の検索文字列をコピー
                            self.input_buffer.clearRetainingCapacity();
                            self.input_buffer.appendSlice(self.allocator, search_str) catch {};
                            self.getCurrentView().setSearchHighlight(search_str);
                            try self.performSearch(true, true); // skip_current=true で次を検索
                            // 検索ハイライトは残すが、プロンプトはクリア（Emacs風）
                            self.getCurrentView().clearError();
                        } else {
                            // 新規検索開始
                            self.mode = .isearch_forward;
                            self.search_start_pos = self.getCurrentView().getCursorBufferPos();
                            self.input_buffer.clearRetainingCapacity();
                            self.getCurrentView().setError("I-search: ");
                        }
                    },
                    'r' => {
                        // C-r インクリメンタルサーチ（後方）
                        // 前回の検索文字列がある場合は、それを使って前の一致を検索
                        if (self.last_search) |search_str| {
                            // input_bufferに前回の検索文字列をコピー
                            self.input_buffer.clearRetainingCapacity();
                            self.input_buffer.appendSlice(self.allocator, search_str) catch {};
                            self.getCurrentView().setSearchHighlight(search_str);
                            try self.performSearch(false, true); // forward=false, skip_current=true で前を検索
                            // 検索ハイライトは残すが、プロンプトはクリア（Emacs風）
                            self.getCurrentView().clearError();
                        } else {
                            // 新規検索開始
                            self.mode = .isearch_backward;
                            self.search_start_pos = self.getCurrentView().getCursorBufferPos();
                            self.input_buffer.clearRetainingCapacity();
                            self.getCurrentView().setError("I-search backward: ");
                        }
                    },
                    else => {},
                }
            },

            // Alt キー
            .alt => |c| {
                switch (c) {
                    '%' => {
                        // M-% : query-replace
                        self.mode = .query_replace_input_search;
                        self.input_buffer.clearRetainingCapacity();
                        self.replace_match_count = 0;
                        self.getCurrentView().setError("Query replace: ");
                    },
                    'f' => try self.forwardWord(), // M-f 単語前進
                    'b' => try self.backwardWord(), // M-b 単語後退
                    'd' => try self.deleteWord(), // M-d 単語削除
                    'w' => try self.copyRegion(), // M-w 範囲コピー
                    '|' => {
                        // M-| シェルコマンド入力
                        self.mode = .shell_command;
                        self.input_buffer.clearRetainingCapacity();
                        self.getCurrentView().setError("| ");
                    },
                    '<' => self.getCurrentView().moveToBufferStart(), // M-< ファイル先頭
                    '>' => self.getCurrentView().moveToBufferEnd(&self.terminal), // M-> ファイル終端
                    '{' => try self.backwardParagraph(), // M-{ 前の段落
                    '}' => try self.forwardParagraph(), // M-} 次の段落
                    '^' => try self.joinLine(), // M-^ 行の結合
                    ';' => try self.toggleComment(), // M-; コメント切り替え
                    'x' => {
                        // M-x: コマンドプロンプト
                        self.mode = .mx_command;
                        self.input_buffer.clearRetainingCapacity();
                        self.getCurrentView().setError(": ");
                    },
                    else => {},
                }
            },

            // M-delete
            .alt_delete => try self.deleteWord(),

            // Alt+矢印（行の移動）
            .alt_arrow_up => try self.moveLineUp(),
            .alt_arrow_down => try self.moveLineDown(),

            // 矢印キー
            .arrow_up => self.getCurrentView().moveCursorUp(),
            .arrow_down => self.getCurrentView().moveCursorDown(&self.terminal),
            .arrow_left => self.getCurrentView().moveCursorLeft(),
            .arrow_right => self.getCurrentView().moveCursorRight(&self.terminal),

            // 特殊キー
            .enter => {
                // *Buffer List* の場合は選択したバッファに切り替え
                const buffer_state = self.getCurrentBuffer();
                if (buffer_state.filename) |fname| {
                    if (std.mem.eql(u8, fname, "*Buffer List*")) {
                        try self.selectBufferFromList();
                        return;
                    }
                }
                // 自動インデント: 現在の行のインデントを取得
                const indent = self.getCurrentLineIndent();
                try self.insertChar('\n');
                // インデントを挿入
                if (indent.len > 0) {
                    for (indent) |ch| {
                        try self.insertChar(ch);
                    }
                }
            },
            .backspace => try self.backspace(),
            .tab => {
                // マーク選択がある場合はインデント、なければタブ挿入
                const window = self.getCurrentWindow();
                if (window.mark_pos != null) {
                    try self.indentRegion();
                } else {
                    try self.insertChar('\t');
                }
            },
            .shift_tab => try self.unindentRegion(), // アンインデント
            .ctrl_tab => {
                // Ctrl-Tab: 次のウィンドウに移動
                if (self.windows.items.len > 1) {
                    self.current_window_idx = (self.current_window_idx + 1) % self.windows.items.len;
                }
            },
            .ctrl_shift_tab => {
                // Ctrl-Shift-Tab: 前のウィンドウに移動
                if (self.windows.items.len > 1) {
                    if (self.current_window_idx == 0) {
                        self.current_window_idx = self.windows.items.len - 1;
                    } else {
                        self.current_window_idx -= 1;
                    }
                }
            },

            // 通常の文字 (ASCII)
            .char => |c| {
                if (c >= 32 and c < 127) {
                    try self.insertChar(c);
                }
            },

            // UTF-8文字
            .codepoint => |cp| {
                try self.insertCodepoint(cp);
            },

            else => {},
        }
    }

    fn insertChar(self: *Editor, ch: u8) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const current_line = self.getCurrentLine();
        const pos = self.getCurrentView().getCursorBufferPos();

        // バッファ変更を先に実行（失敗した場合はundoログに記録しない）
        try buffer.insert(pos, ch);
        errdefer buffer.delete(pos, 1) catch unreachable; // rollback失敗は致命的
        try self.recordInsert(pos, &[_]u8{ch}, pos); // 編集前のカーソル位置を記録
        buffer_state.modified = true;

        if (ch == '\n') {
            // 改行: 現在行以降すべてdirty
            self.getCurrentView().markDirty(current_line, null); // EOF まで再描画

            // 次の行の先頭に移動
            const max_screen_line = self.terminal.height - 2; // ステータスバー分を引く
            if (self.getCurrentView().cursor_y < max_screen_line) {
                self.getCurrentView().cursor_y += 1;
            } else {
                // 画面の最下部の場合はスクロール
                self.getCurrentView().top_line += 1;
            }
            self.getCurrentView().cursor_x = 0;
        } else {
            // 通常文字: 現在行のみdirty
            self.getCurrentView().markDirty(current_line, current_line);

            // タブ文字の場合は文脈依存の幅を計算
            if (ch == '\t') {
                const TAB_WIDTH = @import("config.zig").Editor.TAB_WIDTH;
                const next_tab_stop = (self.getCurrentView().cursor_x / TAB_WIDTH + 1) * TAB_WIDTH;
                self.getCurrentView().cursor_x = next_tab_stop;
            } else {
                // UTF-8文字の幅を計算してカーソルを移動
                const width = Buffer.charWidth(@as(u21, ch));
                self.getCurrentView().cursor_x += width;
            }
        }
    }

    fn insertCodepoint(self: *Editor, codepoint: u21) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const current_line = self.getCurrentLine();

        // UTF-8にエンコード
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidUtf8;

        const pos = self.getCurrentView().getCursorBufferPos();

        // バッファ変更を先に実行
        try buffer.insertSlice(pos, buf[0..len]);
        errdefer buffer.delete(pos, len) catch unreachable; // rollback失敗は致命的
        try self.recordInsert(pos, buf[0..len], pos); // 編集前のカーソル位置を記録
        buffer_state.modified = true;

        if (codepoint == '\n') {
            // 改行: 現在行以降すべてdirty
            self.getCurrentView().markDirty(current_line, null);

            // 次の行の先頭に移動
            const max_screen_line = self.terminal.height - 2; // ステータスバー分を引く
            if (self.getCurrentView().cursor_y < max_screen_line) {
                self.getCurrentView().cursor_y += 1;
            } else {
                // 画面の最下部の場合はスクロール
                self.getCurrentView().top_line += 1;
            }
            self.getCurrentView().cursor_x = 0;
        } else {
            // 通常文字: 現在行のみdirty
            self.getCurrentView().markDirty(current_line, current_line);

            // UTF-8文字の幅を計算してカーソルを移動
            const width = Buffer.charWidth(codepoint);
            self.getCurrentView().cursor_x += width;
        }
    }

    fn deleteChar(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const current_line = self.getCurrentLine();
        const pos = self.getCurrentView().getCursorBufferPos();
        if (pos >= buffer.len()) return;

        // カーソル位置のgrapheme clusterのバイト数を取得
        var iter = PieceIterator.init(buffer);
        while (iter.global_pos < pos) {
            _ = iter.next();
        }

        const cluster = iter.nextGraphemeCluster() catch {
            const deleted = try self.extractText(pos, 1);
            errdefer self.allocator.free(deleted);

            try buffer.delete(pos, 1);
            errdefer buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted, pos); // 編集前のカーソル位置を記録

            buffer_state.modified = true;
            // 改行削除の場合は末尾まで再描画
            if (std.mem.indexOf(u8, deleted, "\n") != null) {
                self.getCurrentView().markDirty(current_line, null);
            } else {
                self.getCurrentView().markDirty(current_line, current_line);
            }
            self.allocator.free(deleted);
            return;
        };

        if (cluster) |gc| {
            const deleted = try self.extractText(pos, gc.byte_len);
            errdefer self.allocator.free(deleted);

            try buffer.delete(pos, gc.byte_len);
            errdefer buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted, pos); // 編集前のカーソル位置を記録

            buffer_state.modified = true;
            // 改行削除の場合は末尾まで再描画
            if (std.mem.indexOf(u8, deleted, "\n") != null) {
                self.getCurrentView().markDirty(current_line, null);
            } else {
                self.getCurrentView().markDirty(current_line, current_line);
            }
            self.allocator.free(deleted);
        }
    }

    fn backspace(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const current_line = self.getCurrentLine();
        const pos = self.getCurrentView().getCursorBufferPos();
        if (pos == 0) return;

        // 削除するgrapheme clusterのバイト数と幅を取得
        var iter = PieceIterator.init(buffer);
        var char_start: usize = 0;
        var char_width: usize = 1;
        var char_len: usize = 1;

        while (iter.global_pos < pos) {
            char_start = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch {
                _ = iter.next();
                continue;
            };
            if (cluster) |gc| {
                char_width = gc.width;
                char_len = gc.byte_len;
            } else {
                break;
            }
        }

        const deleted = try self.extractText(char_start, char_len);
        errdefer self.allocator.free(deleted);

        // 改行削除の場合、削除後のカーソル位置を計算
        const is_newline = std.mem.indexOf(u8, deleted, "\n") != null;

        try buffer.delete(char_start, char_len);
        errdefer buffer.insertSlice(char_start, deleted) catch unreachable; // rollback失敗は致命的
        try self.recordDelete(char_start, deleted, pos); // 編集前のカーソル位置を記録

        buffer_state.modified = true;
        // 改行削除の場合は末尾まで再描画
        if (is_newline) {
            self.getCurrentView().markDirty(current_line, null);
        } else {
            self.getCurrentView().markDirty(current_line, current_line);
        }
        self.allocator.free(deleted);

        // カーソル移動
        if (self.getCurrentView().cursor_x >= char_width) {
            self.getCurrentView().cursor_x -= char_width;
        } else if (self.getCurrentView().cursor_y > 0) {
            self.getCurrentView().cursor_y -= 1;
            if (is_newline) {
                // 改行削除の場合、削除位置（char_start）が新しいカーソル位置
                // そこまでの行内の表示幅を計算
                const new_line = self.getCurrentLine();
                if (buffer.getLineStart(self.getCurrentView().top_line + new_line)) |line_start| {
                    var x: usize = 0;
                    var width_iter = PieceIterator.init(buffer);
                    width_iter.seek(line_start);
                    while (width_iter.global_pos < char_start) {
                        const cluster = width_iter.nextGraphemeCluster() catch break;
                        if (cluster) |gc| {
                            if (gc.base == '\n') break;
                            x += gc.width;
                        } else {
                            break;
                        }
                    }
                    self.getCurrentView().cursor_x = x;
                }
            } else {
                self.getCurrentView().moveToLineEnd();
            }
        }
    }

    fn killLine(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const current_line = self.getCurrentLine();
        const pos = self.getCurrentView().getCursorBufferPos();

        // PieceIteratorで行末を探す
        var iter = PieceIterator.init(buffer);
        iter.seek(pos);

        var end_pos = pos;
        while (iter.next()) |ch| {
            if (ch == '\n') {
                end_pos = iter.global_pos;
                break;
            }
        } else {
            end_pos = buffer.len();
        }

        const count = end_pos - pos;
        if (count > 0) {
            const deleted = try self.extractText(pos, count);
            errdefer self.allocator.free(deleted);

            try buffer.delete(pos, count);
            errdefer buffer.insertSlice(pos, deleted) catch unreachable; // rollback失敗は致命的
            try self.recordDelete(pos, deleted, pos); // 編集前のカーソル位置を記録

            buffer_state.modified = true;
            // 改行削除の場合は末尾まで再描画
            if (std.mem.indexOf(u8, deleted, "\n") != null) {
                self.getCurrentView().markDirty(current_line, null);
            } else {
                self.getCurrentView().markDirty(current_line, current_line);
            }
            self.allocator.free(deleted);
        }
    }

    /// M-^ 行の結合 (delete-indentation)
    /// 現在の行の先頭インデントを削除し、前の行と結合
    fn joinLine(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();

        // 現在の行の先頭位置を取得
        const current_line = self.getCurrentLine();
        if (current_line == 0) {
            // 最初の行では何もしない
            return;
        }

        // 現在の行の先頭位置を取得
        const line_start = buffer.getLineStart(current_line) orelse return;

        // 先頭のインデント（空白とタブ）をスキップして最初の非空白文字を見つける
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);
        var first_non_space = line_start;
        while (iter.next()) |ch| {
            if (ch != ' ' and ch != '\t') {
                first_non_space = iter.global_pos - 1;
                break;
            }
        }

        // 前の行の末尾位置を取得（改行の位置）
        const prev_line_end = line_start - 1; // 前の行の改行文字の位置

        // 削除範囲: 前の行の改行 + 現在の行のインデント
        const delete_start = prev_line_end;
        const delete_len = first_non_space - prev_line_end;

        if (delete_len > 0) {
            const deleted = try self.extractText(delete_start, delete_len);
            errdefer self.allocator.free(deleted);

            try buffer.delete(delete_start, delete_len);
            try self.recordDelete(delete_start, deleted, view.getCursorBufferPos());

            // 前の行の末尾にスペースを挿入（前の行の末尾が空白でない場合）
            var needs_space = true;
            if (delete_start > 0) {
                var check_iter = PieceIterator.init(buffer);
                check_iter.seek(delete_start - 1);
                if (check_iter.next()) |prev_char| {
                    if (prev_char == ' ' or prev_char == '\t') {
                        needs_space = false;
                    }
                }
            }

            if (needs_space and first_non_space > line_start) {
                try buffer.insertSlice(delete_start, " ");
                try self.recordInsert(delete_start, " ", view.getCursorBufferPos());
            }

            buffer_state.modified = true;
            view.markDirty(current_line - 1, null);

            // カーソルを結合位置に移動
            self.setCursorToPos(delete_start);

            self.allocator.free(deleted);
        }
    }

    /// 行の複製 (duplicate-line)
    fn duplicateLine(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();
        const current_line = self.getCurrentLine();

        // 現在の行の開始・終了位置を取得
        const line_start = buffer.getLineStart(current_line);
        var line_end = line_start;
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);
        while (iter.next()) |ch| {
            if (ch == '\n') {
                line_end = iter.global_pos;
                break;
            }
        } else {
            line_end = buffer.len();
        }

        // 行の内容を取得（改行を含む）
        const line_len = line_end - line_start;
        if (line_len == 0) return;

        const line_content = try self.extractText(line_start, line_len);
        defer self.allocator.free(line_content);

        // 改行後に挿入（または行末に改行+内容を挿入）
        const insert_pos = line_end;
        var to_insert: []const u8 = undefined;
        var allocated = false;

        if (line_end < buffer.len()) {
            // 改行がある場合はそのまま挿入
            to_insert = line_content;
        } else {
            // ファイル末尾の場合は改行を追加
            var with_newline = try self.allocator.alloc(u8, line_len + 1);
            with_newline[0] = '\n';
            @memcpy(with_newline[1..], line_content);
            to_insert = with_newline;
            allocated = true;
        }
        defer if (allocated) self.allocator.free(to_insert);

        try buffer.insertSlice(insert_pos, to_insert);
        try self.recordInsert(insert_pos, to_insert, view.getCursorBufferPos());

        buffer_state.modified = true;
        view.markDirty(current_line, null);

        // カーソルを複製した行に移動
        view.moveCursorDown(&self.terminal);
    }

    /// 行を上に移動
    fn moveLineUp(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();
        const current_line = self.getCurrentLine();

        if (current_line == 0) return; // 最初の行は移動できない

        // 現在の行を取得
        const line_start = buffer.getLineStart(current_line) orelse return;
        var line_end = line_start;
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);
        while (iter.next()) |ch| {
            if (ch == '\n') {
                line_end = iter.global_pos;
                break;
            }
        } else {
            line_end = buffer.len();
        }

        // 前の行の開始位置
        const prev_line_start = buffer.getLineStart(current_line - 1) orelse return;

        // 現在の行の内容を取得
        const line_len = line_end - line_start;
        const line_content = try self.extractText(line_start, line_len);
        defer self.allocator.free(line_content);

        // 現在の行を削除
        try buffer.delete(line_start, line_len);

        // 前の行の前に挿入
        try buffer.insertSlice(prev_line_start, line_content);

        // Undo記録（単純化のためdeleteとinsertを別々に記録）
        try self.recordDelete(line_start, line_content, view.getCursorBufferPos());
        try self.recordInsert(prev_line_start, line_content, view.getCursorBufferPos());

        buffer_state.modified = true;
        view.markDirty(current_line - 1, null);

        // カーソルを移動した行に合わせる
        view.moveCursorUp();
    }

    /// 行を下に移動
    fn moveLineDown(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();
        const current_line = self.getCurrentLine();
        const total_lines = buffer.lineCount();

        if (current_line >= total_lines - 1) return; // 最後の行は移動できない

        // 現在の行を取得
        const line_start = buffer.getLineStart(current_line) orelse return;
        var line_end = line_start;
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);
        while (iter.next()) |ch| {
            if (ch == '\n') {
                line_end = iter.global_pos;
                break;
            }
        } else {
            line_end = buffer.len();
        }

        // 次の行の終了位置
        var next_line_end = line_end;
        while (iter.next()) |ch| {
            if (ch == '\n') {
                next_line_end = iter.global_pos;
                break;
            }
        } else {
            next_line_end = buffer.len();
        }

        // 現在の行の内容を取得
        const line_len = line_end - line_start;
        const line_content = try self.extractText(line_start, line_len);
        defer self.allocator.free(line_content);

        // 現在の行を削除
        try buffer.delete(line_start, line_len);

        // 次の行の後ろに挿入（削除後なので位置調整）
        const new_insert_pos = next_line_end - line_len;
        try buffer.insertSlice(new_insert_pos, line_content);

        // Undo記録
        try self.recordDelete(line_start, line_content, view.getCursorBufferPos());
        try self.recordInsert(new_insert_pos, line_content, view.getCursorBufferPos());

        buffer_state.modified = true;
        view.markDirty(current_line, null);

        // カーソルを移動した行に合わせる
        view.moveCursorDown(&self.terminal);
    }

    /// 現在の行のインデント（先頭の空白）を取得
    fn getCurrentLineIndent(self: *Editor) []const u8 {
        const buffer = self.getCurrentBufferContent();
        const current_line = self.getCurrentLine();
        const line_start = buffer.getLineStart(current_line) orelse return "";

        // 行の先頭から空白文字を収集
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        var indent_end: usize = line_start;
        while (iter.next()) |ch| {
            if (ch == ' ' or ch == '\t') {
                indent_end = iter.global_pos;
            } else {
                break;
            }
        }

        // インデント部分をスライスとして返す（最大64文字）
        const indent_len = indent_end - line_start;
        if (indent_len == 0) return "";

        // 静的バッファに格納して返す
        const Static = struct {
            var buf: [64]u8 = undefined;
        };

        var idx: usize = 0;
        iter.seek(line_start);
        while (iter.next()) |ch| {
            if ((ch == ' ' or ch == '\t') and idx < Static.buf.len) {
                Static.buf[idx] = ch;
                idx += 1;
            } else {
                break;
            }
        }

        return Static.buf[0..idx];
    }

    /// インデントスタイルを検出（タブ優先かスペース優先か）
    fn detectIndentStyle(self: *Editor) u8 {
        const buffer = self.getCurrentBufferContent();
        var iter = PieceIterator.init(buffer);

        var tab_count: usize = 0;
        var space_count: usize = 0;
        var at_line_start = true;

        while (iter.next()) |ch| {
            if (ch == '\n') {
                at_line_start = true;
            } else if (at_line_start) {
                if (ch == '\t') {
                    tab_count += 1;
                    at_line_start = false;
                } else if (ch == ' ') {
                    space_count += 1;
                    // 4スペース連続でカウント
                    if (space_count >= 4) {
                        at_line_start = false;
                    }
                } else {
                    at_line_start = false;
                }
            }
        }

        // タブが多ければタブ、そうでなければスペース
        if (tab_count > space_count / 4) {
            return '\t';
        }
        return ' ';
    }

    /// 選択範囲または現在行をインデント
    fn indentRegion(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();
        const window = self.getCurrentWindow();

        // インデント文字を検出
        const indent_char = self.detectIndentStyle();
        const indent_str: []const u8 = if (indent_char == '\t') "\t" else "    ";

        // 現在行をインデント（選択範囲は将来対応）
        const current_line = self.getCurrentLine();
        const line_start = buffer.getLineStart(current_line) orelse return;

        try buffer.insertSlice(line_start, indent_str);
        try self.recordInsert(line_start, indent_str, view.getCursorBufferPos());

        buffer_state.modified = true;
        view.markDirty(current_line, current_line);

        // マークをクリア
        window.mark_pos = null;
    }

    /// 選択範囲または現在行をアンインデント
    fn unindentRegion(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();
        const window = self.getCurrentWindow();

        // 現在行をアンインデント（選択範囲は将来対応）
        const current_line = self.getCurrentLine();
        const line_start = buffer.getLineStart(current_line) orelse return;

        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        // 先頭の空白を数える
        var spaces_to_remove: usize = 0;
        if (iter.next()) |ch| {
            if (ch == '\t') {
                spaces_to_remove = 1;
            } else if (ch == ' ') {
                spaces_to_remove = 1;
                // 最大4スペースまで削除
                var count: usize = 1;
                while (count < 4) : (count += 1) {
                    if (iter.next()) |next_ch| {
                        if (next_ch == ' ') {
                            spaces_to_remove += 1;
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
            }
        }

        if (spaces_to_remove > 0) {
            const deleted = try self.extractText(line_start, spaces_to_remove);
            defer self.allocator.free(deleted);

            try buffer.delete(line_start, spaces_to_remove);
            try self.recordDelete(line_start, deleted, view.getCursorBufferPos());

            buffer_state.modified = true;
            view.markDirty(current_line, current_line);
        }

        // マークをクリア
        window.mark_pos = null;
    }

    /// コメント切り替え (M-;)
    fn toggleComment(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const view = self.getCurrentView();
        const window = self.getCurrentWindow();

        const comment_str = "# ";

        // 現在行を操作（選択範囲は将来対応）
        const current_line = self.getCurrentLine();
        const line_start = buffer.getLineStart(current_line) orelse return;

        // 行がコメントかどうかをチェック
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        // 空白をスキップして最初の非空白文字を見つける
        var first_char: ?u8 = null;
        var skip_count: usize = 0;
        while (iter.next()) |ch| {
            if (ch == ' ' or ch == '\t') {
                skip_count += 1;
            } else {
                first_char = ch;
                break;
            }
        }

        if (first_char) |ch| {
            if (ch == '#') {
                // アンコメント: "# " または "#" を削除
                const comment_pos = line_start + skip_count;

                // # の後のスペースもチェック
                var delete_len: usize = 1;
                if (iter.next()) |next_ch| {
                    if (next_ch == ' ') {
                        delete_len = 2;
                    }
                }

                const deleted = try self.extractText(comment_pos, delete_len);
                defer self.allocator.free(deleted);

                try buffer.delete(comment_pos, delete_len);
                try self.recordDelete(comment_pos, deleted, view.getCursorBufferPos());
            } else {
                // コメント: 行の先頭に "# " を挿入
                try buffer.insertSlice(line_start, comment_str);
                try self.recordInsert(line_start, comment_str, view.getCursorBufferPos());
            }

            buffer_state.modified = true;
            view.markDirty(current_line, current_line);
        }

        // マークをクリア
        window.mark_pos = null;
    }

    // マークを設定/解除（Ctrl+Space）
    fn setMark(self: *Editor) void {
        const window = self.getCurrentWindow();
        if (window.mark_pos) |_| {
            // マークがある場合は解除
            window.mark_pos = null;
            self.getCurrentView().setError("Mark deactivated");
        } else {
            // マークを設定
            window.mark_pos = self.getCurrentView().getCursorBufferPos();
            self.getCurrentView().setError("Mark set");
        }
    }

    // 全選択（C-x h）：バッファの先頭にマークを設定し、終端にカーソルを移動
    fn selectAll(self: *Editor) void {
        // バッファの先頭（位置0）にマークを設定
        const window = self.getCurrentWindow();
        window.mark_pos = 0;
        // カーソルをバッファの終端に移動
        self.getCurrentView().moveToBufferEnd(&self.terminal);
    }

    // マーク位置とカーソル位置から範囲を取得（開始位置と長さを返す）
    fn getRegion(self: *Editor) ?struct { start: usize, len: usize } {
        const window = self.getCurrentWindow();
        const mark = window.mark_pos orelse return null;
        const cursor = self.getCurrentView().getCursorBufferPos();

        if (mark < cursor) {
            return .{ .start = mark, .len = cursor - mark };
        } else if (cursor < mark) {
            return .{ .start = cursor, .len = mark - cursor };
        } else {
            return null; // 範囲が空
        }
    }

    // 範囲をコピー（M-w）
    fn copyRegion(self: *Editor) !void {
        const window = self.getCurrentWindow();
        const region = self.getRegion() orelse {
            self.getCurrentView().setError("No active region");
            return;
        };

        // 既存のkill_ringを解放
        if (self.kill_ring) |old_text| {
            self.allocator.free(old_text);
        }

        // 範囲のテキストをコピー
        self.kill_ring = try self.extractText(region.start, region.len);

        // マークを解除
        window.mark_pos = null;

        self.getCurrentView().setError("Saved text to kill ring");
    }

    // 範囲を削除（カット）（C-w）
    fn killRegion(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const buffer_state = self.getCurrentBuffer();
        const window = self.getCurrentWindow();
        const current_line = self.getCurrentLine();
        const region = self.getRegion() orelse {
            self.getCurrentView().setError("No active region");
            return;
        };

        // 既存のkill_ringを解放
        if (self.kill_ring) |old_text| {
            self.allocator.free(old_text);
        }

        // 範囲のテキストをコピー
        const deleted = try self.extractText(region.start, region.len);
        errdefer self.allocator.free(deleted);

        // バッファから削除
        try buffer.delete(region.start, region.len);
        errdefer buffer.insertSlice(region.start, deleted) catch unreachable;
        try self.recordDelete(region.start, deleted, self.getCurrentView().getCursorBufferPos());

        // kill_ringに保存（extractTextと同じデータなので、新たにdupeせずそのまま使う）
        self.kill_ring = deleted;

        buffer_state.modified = true;

        // カーソルを範囲の開始位置に移動
        self.setCursorToPos(region.start);

        // マークを解除
        window.mark_pos = null;

        // 改行が含まれる場合は末尾まで再描画
        if (std.mem.indexOf(u8, deleted, "\n") != null) {
            self.getCurrentView().markDirty(current_line, null);
        } else {
            self.getCurrentView().markDirty(current_line, current_line);
        }

        self.getCurrentView().setError("Killed region");
    }

    // kill_ringの内容をペースト（C-y）
    fn yank(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const buffer = self.getCurrentBufferContent();
        const current_line = self.getCurrentLine();
        const text = self.kill_ring orelse {
            self.getCurrentView().setError("Kill ring is empty");
            return;
        };

        const pos = self.getCurrentView().getCursorBufferPos();

        // バッファに挿入
        try buffer.insertSlice(pos, text);
        errdefer buffer.delete(pos, text.len) catch unreachable;
        try self.recordInsert(pos, text, pos);

        buffer_state.modified = true;

        // カーソルを挿入後の位置に移動
        self.setCursorToPos(pos + text.len);

        // 改行が含まれる場合は末尾まで再描画
        if (std.mem.indexOf(u8, text, "\n") != null) {
            self.getCurrentView().markDirty(current_line, null);
        } else {
            self.getCurrentView().markDirty(current_line, current_line);
        }

        self.getCurrentView().setError("Yanked text");
    }

    // インクリメンタルサーチ実行
    // forward: true=前方検索、false=後方検索
    // skip_current: true=現在位置をスキップして次を検索、false=現在位置から検索
    fn performSearch(self: *Editor, forward: bool, skip_current: bool) !void {
        const buffer = self.getCurrentBufferContent();
        const search_str = self.input_buffer.items;
        if (search_str.len == 0) return;

        // バッファの全内容を取得
        const content = try self.extractText(0, buffer.total_len);
        defer self.allocator.free(content);

        const start_pos = self.getCurrentView().getCursorBufferPos();
        const search_from = if (skip_current and start_pos < content.len) start_pos + 1 else start_pos;

        // 正規表現パターンかチェック
        const is_regex = regex.isRegexPattern(search_str);

        if (is_regex) {
            // 正規表現検索
            // 古いコンパイル済み正規表現を解放
            if (self.compiled_regex) |*r| {
                var re = r.*;
                re.deinit();
                self.compiled_regex = null;
            }

            // 新しい正規表現をコンパイル
            self.compiled_regex = regex.Regex.compile(self.allocator, search_str) catch {
                self.getCurrentView().setError("Invalid regex pattern");
                return;
            };

            const re = &self.compiled_regex.?;

            if (forward) {
                // 前方検索
                if (re.search(content, search_from)) |match| {
                    self.setCursorToPos(match.start);
                    return;
                }
                // ラップアラウンド
                if (start_pos > 0) {
                    if (re.search(content, 0)) |match| {
                        if (match.start < start_pos) {
                            self.setCursorToPos(match.start);
                            return;
                        }
                    }
                }
                self.getCurrentView().setError("Failing I-search (regex)");
            } else {
                // 後方検索
                if (re.searchBackward(content, search_from)) |match| {
                    self.setCursorToPos(match.start);
                    return;
                }
                // ラップアラウンド
                if (re.searchBackward(content, content.len)) |match| {
                    if (match.start > start_pos) {
                        self.setCursorToPos(match.start);
                        return;
                    }
                }
                self.getCurrentView().setError("Failing I-search backward (regex)");
            }
        } else {
            // リテラル検索（従来の動作）
            if (forward) {
                // 前方検索
                if (search_from < content.len) {
                    if (std.mem.indexOf(u8, content[search_from..], search_str)) |offset| {
                        const found_pos = search_from + offset;
                        self.setCursorToPos(found_pos);
                        return;
                    }
                }
                // 見つからなかったら先頭から検索（ラップアラウンド）
                if (start_pos > 0) {
                    if (std.mem.indexOf(u8, content[0..start_pos], search_str)) |offset| {
                        self.setCursorToPos(offset);
                        return;
                    }
                }
                // それでも見つからない
                self.getCurrentView().setError("Failing I-search");
            } else {
                // 後方検索
                if (search_from > 0) {
                    if (std.mem.lastIndexOf(u8, content[0..search_from], search_str)) |offset| {
                        self.setCursorToPos(offset);
                        return;
                    }
                }
                // 見つからなかったら末尾から検索（ラップアラウンド）
                if (start_pos < content.len) {
                    if (std.mem.lastIndexOf(u8, content[start_pos..], search_str)) |offset| {
                        self.setCursorToPos(start_pos + offset);
                        return;
                    }
                }
                // それでも見つからない
                self.getCurrentView().setError("Failing I-search backward");
            }
        }
    }

    // カーソルの現在のバイト位置を取得
    fn getCursorPos(self: *Editor) usize {
        const view = self.getCurrentView();
        const buffer = self.getCurrentBufferContent();
        const line_num = view.top_line + view.cursor_y;
        const line_start = buffer.getLineStart(line_num) orelse 0;

        // 行の開始位置から cursor_x グラフェムクラスタ分進む
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        var col: usize = 0;
        while (col < view.cursor_x) : (col += 1) {
            _ = iter.nextGraphemeCluster() catch break;
        }

        return iter.global_pos;
    }

    // 矩形領域の削除（C-x r k）
    fn killRectangle(self: *Editor) void {
        const window = self.getCurrentWindow();
        const mark = window.mark_pos orelse {
            self.getCurrentView().setError("No mark set");
            return;
        };

        const cursor = self.getCursorPos();
        const buffer = self.getCurrentBufferContent();

        // マークとカーソルの位置から矩形の範囲を決定
        const start_pos = @min(mark, cursor);
        const end_pos = @max(mark, cursor);

        // 開始行と終了行を取得
        const start_line = buffer.findLineByPos(start_pos);
        const end_line = buffer.findLineByPos(end_pos);

        // 開始カラムと終了カラムを取得
        const start_col = buffer.findColumnByPos(start_pos);
        const end_col = buffer.findColumnByPos(end_pos);

        // カラム範囲を正規化（左から右へ）
        const left_col = @min(start_col, end_col);
        const right_col = @max(start_col, end_col);

        // 古い rectangle_ring をクリーンアップ
        if (self.rectangle_ring) |*old_ring| {
            for (old_ring.items) |line| {
                self.allocator.free(line);
            }
            old_ring.deinit(self.allocator);
        }

        // 新しい rectangle_ring を作成
        var rect_ring: std.ArrayList([]const u8) = .{};
        errdefer {
            for (rect_ring.items) |line| {
                self.allocator.free(line);
            }
            rect_ring.deinit();
        }

        // 各行から矩形領域を抽出して削除
        var line_num = start_line;
        while (line_num <= end_line) : (line_num += 1) {
            const line_start = buffer.getLineStart(line_num) orelse continue;

            // 次の行の開始位置（または末尾）を取得
            const next_line_start = buffer.getLineStart(line_num + 1);
            const line_end = if (next_line_start) |nls|
                if (nls > 0 and nls > line_start) nls - 1 else nls
            else
                buffer.len();

            // 行内のカラム位置を探す
            var iter = PieceIterator.init(buffer);
            iter.seek(line_start);

            var current_col: usize = 0;
            var rect_start_pos: ?usize = null;
            var rect_end_pos: ?usize = null;

            // left_col の位置を探す
            while (iter.global_pos < line_end and current_col < left_col) {
                _ = iter.nextGraphemeCluster() catch break;
                current_col += 1;
            }
            rect_start_pos = iter.global_pos;

            // right_col の位置を探す
            while (iter.global_pos < line_end and current_col < right_col) {
                _ = iter.nextGraphemeCluster() catch break;
                current_col += 1;
            }
            rect_end_pos = iter.global_pos;

            // 矩形領域のテキストを抽出
            if (rect_start_pos) |rsp| {
                if (rect_end_pos) |rep| {
                    if (rep > rsp) {
                        // テキストを抽出
                        var line_buf: std.ArrayList(u8) = .{};
                        errdefer line_buf.deinit();

                        var extract_iter = PieceIterator.init(buffer);
                        extract_iter.seek(rsp);
                        while (extract_iter.global_pos < rep) {
                            const byte = extract_iter.next() orelse break;
                            line_buf.append(self.allocator, byte) catch break;
                        }

                        const line_text = line_buf.toOwnedSlice(self.allocator) catch "";
                        rect_ring.append(self.allocator, line_text) catch {
                            self.allocator.free(line_text);
                        };

                        // バッファから削除
                        buffer.delete(rsp, rep - rsp) catch {};
                    }
                }
            }
        }

        self.rectangle_ring = rect_ring;
        self.getCurrentView().setError("Rectangle killed");
    }

    // 矩形の貼り付け（C-x r y）
    fn yankRectangle(self: *Editor) void {
        if (self.getCurrentBuffer().readonly) {
            self.getCurrentView().setError("Buffer is read-only");
            return;
        }
        const rect = self.rectangle_ring orelse {
            self.getCurrentView().setError("No rectangle to yank");
            return;
        };

        if (rect.items.len == 0) {
            self.getCurrentView().setError("Rectangle is empty");
            return;
        }

        // 現在のカーソル位置を取得
        const cursor_pos = self.getCursorPos();
        const buffer = self.getCurrentBufferContent();
        const cursor_line = buffer.findLineByPos(cursor_pos);
        const cursor_col = buffer.findColumnByPos(cursor_pos);

        // 各行の矩形テキストをカーソル位置から挿入
        for (rect.items, 0..) |line_text, i| {
            const target_line = cursor_line + i;

            // 対象行の開始位置を取得
            const line_start = buffer.getLineStart(target_line) orelse {
                // 行が存在しない場合は、改行を追加して新しい行を作成
                const buf_end = buffer.len();
                buffer.insert(buf_end, '\n') catch continue;
                continue;
            };

            // 対象行のカラム cursor_col の位置を探す
            var iter = PieceIterator.init(buffer);
            iter.seek(line_start);

            // 次の行の開始位置（または末尾）を取得
            const next_line_start = buffer.getLineStart(target_line + 1);
            const line_end = if (next_line_start) |nls|
                if (nls > 0 and nls > line_start) nls - 1 else nls
            else
                buffer.len();

            var current_col: usize = 0;
            while (iter.global_pos < line_end and current_col < cursor_col) {
                _ = iter.nextGraphemeCluster() catch break;
                current_col += 1;
            }

            const insert_pos = iter.global_pos;

            // line_text を insert_pos に挿入
            buffer.insertSlice(insert_pos, line_text) catch continue;
        }

        const buffer_state = self.getCurrentBuffer();
        buffer_state.modified = true;
        self.getCurrentView().setError("Rectangle yanked");
    }

    // 置換：次の一致を検索してカーソルを移動
    fn findNextMatch(self: *Editor, search: []const u8, start_pos: usize) !bool {
        if (search.len == 0) return false;

        const buffer = self.getCurrentBufferContent();
        const buf_len = buffer.len();
        if (start_pos >= buf_len) return false;

        // バッファを検索
        var iter = PieceIterator.init(buffer);
        iter.seek(start_pos);

        var match_start: ?usize = null;
        var match_len: usize = 0;

        while (iter.global_pos < buf_len) {
            const start = iter.global_pos;

            // 一致を確認
            var temp_iter = PieceIterator.init(buffer);
            temp_iter.seek(start);

            var matched = true;
            for (search) |ch| {
                const next_byte = temp_iter.next();
                if (next_byte == null or next_byte.? != ch) {
                    matched = false;
                    break;
                }
            }

            if (matched) {
                match_start = start;
                match_len = search.len;
                break;
            }

            _ = iter.next();
        }

        if (match_start) |pos| {
            // 一致が見つかった：カーソルを移動
            self.setCursorToPos(pos);
            self.replace_current_pos = pos;
            return true;
        }

        return false;
    }

    // 置換：現在の一致を置換
    fn replaceCurrentMatch(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const buffer_state = self.getCurrentBuffer();
        const search = self.replace_search orelse return error.NoSearchString;
        const replacement = self.replace_replacement orelse return error.NoReplacementString;
        const match_pos = self.replace_current_pos orelse return error.NoMatchPosition;

        // Undo記録のために現在のカーソル位置を保存
        const cursor_pos_before = match_pos;

        // 一致部分を削除
        const deleted_text = try self.extractText(match_pos, search.len);
        defer self.allocator.free(deleted_text);

        try buffer.delete(match_pos, search.len);
        try self.recordDelete(match_pos, deleted_text, cursor_pos_before);

        // 置換文字列を挿入
        if (replacement.len > 0) {
            try buffer.insertSlice(match_pos, replacement);
            try self.recordInsert(match_pos, replacement, match_pos);
        }

        buffer_state.modified = true;
        self.replace_match_count += 1;

        // カーソルを置換後の位置に移動
        self.setCursorToPos(match_pos + replacement.len);

        // 全画面再描画
        self.getCurrentView().markFullRedraw();
    }

    // ========================================
    // 単語移動・削除（日本語対応）
    // ========================================

    /// 文字種を判定（単語境界の検出用）
    const CharType = enum {
        alnum, // 英数字・アンダースコア
        hiragana, // ひらがな
        katakana, // カタカナ
        kanji, // 漢字
        space, // 空白
        other, // その他（記号など）
    };

    fn getCharType(cp: u21) CharType {
        // 英数字とアンダースコア
        if ((cp >= 'a' and cp <= 'z') or
            (cp >= 'A' and cp <= 'Z') or
            (cp >= '0' and cp <= '9') or
            cp == '_')
        {
            return .alnum;
        }

        // 空白文字
        if (cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r') {
            return .space;
        }

        // ひらがな（U+3040〜U+309F）
        if (cp >= 0x3040 and cp <= 0x309F) {
            return .hiragana;
        }

        // カタカナ（U+30A0〜U+30FF）
        if (cp >= 0x30A0 and cp <= 0x30FF) {
            return .katakana;
        }

        // 漢字（CJK統合漢字）
        // U+4E00〜U+9FFF: CJK Unified Ideographs
        // U+3400〜U+4DBF: CJK Unified Ideographs Extension A
        if ((cp >= 0x4E00 and cp <= 0x9FFF) or
            (cp >= 0x3400 and cp <= 0x4DBF))
        {
            return .kanji;
        }

        // その他の記号
        return .other;
    }

    /// 前方の単語へ移動（M-f）
    fn forwardWord(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const start_pos = self.getCurrentView().getCursorBufferPos();
        const buf_len = buffer.len();
        if (start_pos >= buf_len) return;

        var iter = PieceIterator.init(buffer);
        iter.seek(start_pos);

        var pos = start_pos;
        var prev_type: ?CharType = null;

        // 現在位置の文字種を取得
        while (iter.next()) |byte| {
            const cp = blk: {
                if (byte < 0x80) {
                    // ASCII
                    break :blk @as(u21, byte);
                } else {
                    // UTF-8マルチバイト
                    var utf8_buf: [4]u8 = undefined;
                    utf8_buf[0] = byte;
                    var utf8_len: usize = 1;

                    // 残りのバイトを読む
                    const expected_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                        pos += 1;
                        continue;
                    };

                    while (utf8_len < expected_len) : (utf8_len += 1) {
                        const next_byte = iter.next() orelse break;
                        utf8_buf[utf8_len] = next_byte;
                    }

                    if (utf8_len != expected_len) {
                        pos += utf8_len;
                        continue;
                    }

                    break :blk std.unicode.utf8Decode(utf8_buf[0..expected_len]) catch {
                        pos += expected_len;
                        continue;
                    };
                }
            };

            const current_type = getCharType(cp);

            if (prev_type) |pt| {
                // 文字種が変わったら停止（ただし空白は飛ばす）
                if (current_type != .space and pt != .space and current_type != pt) {
                    break;
                }
            }

            prev_type = current_type;
            pos += if (cp < 0x80) 1 else std.unicode.utf8CodepointSequenceLength(cp) catch 1;

            // 空白から非空白に変わる場合、その位置で停止
            if (prev_type == .space and current_type != .space) {
                break;
            }
        }

        // カーソル位置を更新
        if (pos > start_pos) {
            self.setCursorToPos(pos);
        }
    }

    /// 後方の単語へ移動（M-b）
    fn backwardWord(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const start_pos = self.getCurrentView().getCursorBufferPos();
        if (start_pos == 0) return;

        // 後方移動のため、逆方向に文字を読む
        var pos = start_pos;
        var prev_type: ?CharType = null;
        var found_non_space = false;

        while (pos > 0) {
            // 1文字戻る（UTF-8考慮）
            const char_start = blk: {
                var test_pos = if (pos > 0) pos - 1 else 0;
                while (test_pos > 0) : (test_pos -= 1) {
                    var iter = PieceIterator.init(buffer);
                    iter.seek(test_pos);
                    const byte = iter.next() orelse break;
                    // UTF-8の先頭バイトかチェック
                    if (byte < 0x80 or (byte & 0xC0) == 0xC0) {
                        break :blk test_pos;
                    }
                }
                break :blk 0;
            };

            // 文字を読み取る
            var iter = PieceIterator.init(buffer);
            iter.seek(char_start);
            const first_byte = iter.next() orelse break;

            const cp = blk: {
                if (first_byte < 0x80) {
                    break :blk @as(u21, first_byte);
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    utf8_buf[0] = first_byte;
                    var utf8_len: usize = 1;

                    const expected_len = std.unicode.utf8ByteSequenceLength(first_byte) catch break :blk @as(u21, first_byte);

                    while (utf8_len < expected_len) : (utf8_len += 1) {
                        const next_byte = iter.next() orelse break;
                        utf8_buf[utf8_len] = next_byte;
                    }

                    if (utf8_len != expected_len) break :blk @as(u21, first_byte);

                    break :blk std.unicode.utf8Decode(utf8_buf[0..expected_len]) catch @as(u21, first_byte);
                }
            };

            const current_type = getCharType(cp);

            // 空白をスキップ
            if (!found_non_space and current_type == .space) {
                pos = char_start;
                continue;
            }

            found_non_space = true;

            if (prev_type) |pt| {
                // 文字種が変わったら停止
                if (current_type != pt) {
                    break;
                }
            }

            prev_type = current_type;
            pos = char_start;
        }

        // カーソル位置を更新
        if (pos < start_pos) {
            self.setCursorToPos(pos);
        }
    }

    /// カーソル位置から次の単語までを削除（M-d）
    fn deleteWord(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const buffer_state = self.getCurrentBuffer();
        const start_pos = self.getCurrentView().getCursorBufferPos();
        const buf_len = buffer.len();
        if (start_pos >= buf_len) return;

        // forwardWordと同じロジックで終了位置を見つける
        var iter = PieceIterator.init(buffer);
        iter.seek(start_pos);

        var pos = start_pos;
        var prev_type: ?CharType = null;

        while (iter.next()) |byte| {
            const cp = blk: {
                if (byte < 0x80) {
                    break :blk @as(u21, byte);
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    utf8_buf[0] = byte;
                    var utf8_len: usize = 1;

                    const expected_len = std.unicode.utf8ByteSequenceLength(byte) catch {
                        pos += 1;
                        continue;
                    };

                    while (utf8_len < expected_len) : (utf8_len += 1) {
                        const next_byte = iter.next() orelse break;
                        utf8_buf[utf8_len] = next_byte;
                    }

                    if (utf8_len != expected_len) {
                        pos += utf8_len;
                        continue;
                    }

                    break :blk std.unicode.utf8Decode(utf8_buf[0..expected_len]) catch {
                        pos += expected_len;
                        continue;
                    };
                }
            };

            const current_type = getCharType(cp);

            if (prev_type) |pt| {
                if (current_type != .space and pt != .space and current_type != pt) {
                    break;
                }
            }

            prev_type = current_type;
            pos += if (cp < 0x80) 1 else std.unicode.utf8CodepointSequenceLength(cp) catch 1;

            if (prev_type == .space and current_type != .space) {
                break;
            }
        }

        // 削除する範囲が存在する場合のみ削除
        if (pos > start_pos) {
            const delete_len = pos - start_pos;
            const deleted_text = try self.extractText(start_pos, delete_len);
            defer self.allocator.free(deleted_text);

            try buffer.delete(start_pos, delete_len);
            try self.recordDelete(start_pos, deleted_text, start_pos);

            buffer_state.modified = true;
            self.getCurrentView().markFullRedraw();
        }
    }

    /// 次の段落へ移動（M-}）
    fn forwardParagraph(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const start_pos = self.getCurrentView().getCursorBufferPos();
        const buf_len = buffer.len();
        if (start_pos >= buf_len) return;

        var iter = PieceIterator.init(buffer);
        iter.seek(start_pos);

        var pos = start_pos;
        var in_blank_line = false;
        var found_blank_section = false;

        // 現在行の終わりまで移動
        while (iter.next()) |byte| {
            pos += 1;
            if (byte == '\n') break;
        }

        // 空行のブロックを探し、その後の非空白行の先頭へ移動
        while (pos < buf_len) {
            iter = PieceIterator.init(buffer);
            iter.seek(pos);

            // 現在行が空行かチェック
            const line_start = pos;
            var is_blank = true;
            var line_end = pos;

            while (iter.next()) |byte| {
                line_end += 1;
                if (byte == '\n') break;
                if (byte != ' ' and byte != '\t' and byte != '\r') {
                    is_blank = false;
                }
            }

            if (is_blank) {
                in_blank_line = true;
                found_blank_section = true;
                pos = line_end;
            } else if (found_blank_section) {
                // 空行の後の最初の非空白行に到達
                self.setCursorToPos(line_start);
                return;
            } else {
                pos = line_end;
            }

            if (pos >= buf_len) break;
        }

        // バッファの終端に到達
        if (pos > start_pos) {
            self.setCursorToPos(pos);
        }
    }

    /// 前の段落へ移動（M-{）
    fn backwardParagraph(self: *Editor) !void {
        const buffer = self.getCurrentBufferContent();
        const start_pos = self.getCurrentView().getCursorBufferPos();
        if (start_pos == 0) return;

        var pos = start_pos;
        var found_blank_section = false;

        // 現在行の先頭に移動
        while (pos > 0) {
            var iter = PieceIterator.init(buffer);
            iter.seek(pos - 1);
            const byte = iter.next() orelse break;
            if (byte == '\n') break;
            pos -= 1;
        }

        // 1つ前の行から開始
        if (pos > 0) pos -= 1;

        // 空行のブロックを見つけて、その前の段落の先頭へ移動
        while (pos > 0) {
            // 現在行の先頭を見つける
            var line_start = pos;
            while (line_start > 0) {
                var iter = PieceIterator.init(buffer);
                iter.seek(line_start - 1);
                const byte = iter.next() orelse break;
                if (byte == '\n') break;
                line_start -= 1;
            }

            // 現在行が空行かチェック
            var iter = PieceIterator.init(buffer);
            iter.seek(line_start);
            var is_blank = true;

            while (iter.next()) |byte| {
                if (byte == '\n') break;
                if (byte != ' ' and byte != '\t' and byte != '\r') {
                    is_blank = false;
                    break;
                }
            }

            if (is_blank) {
                found_blank_section = true;
                if (line_start > 0) {
                    pos = line_start - 1;
                } else {
                    break;
                }
            } else if (found_blank_section) {
                // 空行の前の非空白行に到達
                self.setCursorToPos(line_start);
                return;
            } else {
                if (line_start > 0) {
                    pos = line_start - 1;
                } else {
                    // バッファの先頭に到達
                    self.setCursorToPos(0);
                    return;
                }
            }
        }

        // バッファの先頭に到達
        self.setCursorToPos(0);
    }

    // ========================================
    // Shell Integration
    // ========================================

    /// コマンド文字列をパースしてプレフィックス/サフィックスを取り出す
    fn parseShellCommand(cmd: []const u8) struct {
        input_source: ShellInputSource,
        output_dest: ShellOutputDest,
        command: []const u8,
    } {
        var input_source: ShellInputSource = .selection;
        var output_dest: ShellOutputDest = .command_buffer;
        var start: usize = 0;
        var end: usize = cmd.len;

        // プレフィックス解析
        if (cmd.len > 0) {
            if (cmd[0] == '%') {
                input_source = .buffer_all;
                start = 1;
                // スペースをスキップ
                while (start < cmd.len and cmd[start] == ' ') : (start += 1) {}
            } else if (cmd[0] == '.') {
                input_source = .current_line;
                start = 1;
                while (start < cmd.len and cmd[start] == ' ') : (start += 1) {}
            }
        }

        // パイプ記号 '|' をスキップ（構文セパレータ）
        if (start < cmd.len and cmd[start] == '|') {
            start += 1;
            // パイプ後のスペースをスキップ
            while (start < cmd.len and cmd[start] == ' ') : (start += 1) {}
        }

        // サフィックス解析（末尾から）
        if (end > start) {
            // 末尾の空白をスキップ
            while (end > start and cmd[end - 1] == ' ') : (end -= 1) {}

            if (end > start) {
                // "n>" チェック
                if (end >= 2 and cmd[end - 2] == 'n' and cmd[end - 1] == '>') {
                    output_dest = .new_buffer;
                    end -= 2;
                }
                // "+>" チェック
                else if (end >= 2 and cmd[end - 2] == '+' and cmd[end - 1] == '>') {
                    output_dest = .insert;
                    end -= 2;
                }
                // ">" チェック（末尾が > で、その後ろに何もない場合のみ）
                else if (cmd[end - 1] == '>') {
                    // "> file" のようなシェルリダイレクトではないことを確認
                    // 末尾が ">" で終わっていて、その前がスペースか行頭
                    if (end >= 2 and cmd[end - 2] == ' ') {
                        output_dest = .replace;
                        end -= 1;
                    } else if (end == 1) {
                        output_dest = .replace;
                        end -= 1;
                    }
                }
            }

            // サフィックス前の空白をスキップ
            while (end > start and cmd[end - 1] == ' ') : (end -= 1) {}
        }

        return .{
            .input_source = input_source,
            .output_dest = output_dest,
            .command = if (end > start) cmd[start..end] else "",
        };
    }

    /// シェルコマンドを非同期で開始
    fn startShellCommand(self: *Editor) !void {
        const cmd_input = self.input_buffer.items;
        if (cmd_input.len == 0) return;

        // コマンドをパース
        const parsed = parseShellCommand(cmd_input);

        if (parsed.command.len == 0) {
            self.getCurrentView().setError("No command specified");
            return;
        }

        // 入力データを取得
        var stdin_data: ?[]const u8 = null;
        var stdin_allocated = false;

        const window = &self.windows.items[self.current_window_idx];

        switch (parsed.input_source) {
            .selection => {
                // 選択範囲（マークがあれば）
                if (window.mark_pos) |mark| {
                    const cursor_pos = self.getCurrentView().getCursorBufferPos();
                    const start = @min(mark, cursor_pos);
                    const end_pos = @max(mark, cursor_pos);
                    if (end_pos > start) {
                        stdin_data = try self.getCurrentBufferContent().getRange(self.allocator, start, end_pos - start);
                        stdin_allocated = true;
                    }
                }
                // 選択なければ stdin は空
            },
            .buffer_all => {
                // バッファ全体
                const total_len = self.getCurrentBufferContent().total_len;
                if (total_len > 0) {
                    stdin_data = try self.getCurrentBufferContent().getRange(self.allocator, 0, total_len);
                    stdin_allocated = true;
                }
            },
            .current_line => {
                // 現在行
                const line_num = self.getCurrentView().top_line + self.getCurrentView().cursor_y;
                const line_start = self.getCurrentBufferContent().line_index.getLineStart(line_num) orelse 0;
                const next_line_start = self.getCurrentBufferContent().line_index.getLineStart(line_num + 1);
                const line_end = if (next_line_start) |ns| ns else self.getCurrentBufferContent().total_len;
                if (line_end > line_start) {
                    stdin_data = try self.getCurrentBufferContent().getRange(self.allocator, line_start, line_end - line_start);
                    stdin_allocated = true;
                }
            },
        }

        // コマンドをヒープにコピー（input_bufferは再利用されるため）
        const command_copy = try self.allocator.dupe(u8, parsed.command);
        errdefer self.allocator.free(command_copy);

        // シェルコマンド状態を作成
        const state = try self.allocator.create(ShellCommandState);
        errdefer self.allocator.destroy(state);

        // 子プロセスを起動
        const argv = [_][]const u8{ "/bin/sh", "-c", command_copy };
        state.child = std.process.Child.init(&argv, self.allocator);
        state.child.stdin_behavior = if (stdin_data != null) .Pipe else .Close;
        state.child.stdout_behavior = .Pipe;
        state.child.stderr_behavior = .Pipe;
        state.input_source = parsed.input_source;
        state.output_dest = parsed.output_dest;
        state.stdin_data = stdin_data;
        state.stdin_allocated = stdin_allocated;
        state.command = command_copy;

        try state.child.spawn();

        // stdin にデータを書き込んで閉じる
        if (state.child.stdin) |stdin| {
            if (stdin_data) |data| {
                stdin.writeAll(data) catch {};
            }
            // stdin を閉じないと cat などが終了しない
            stdin.close();
            state.child.stdin = null;
        }

        // 状態を保存してモード変更
        self.shell_state = state;
        self.mode = .shell_running;
        self.getCurrentView().setError("Running... (C-g to cancel)");
    }

    /// シェルコマンドの完了をポーリング
    fn pollShellCommand(self: *Editor) !void {
        const state = self.shell_state orelse return;

        // waitpidでプロセス終了をチェック（WNOHANG）
        const result = std.posix.waitpid(state.child.id, std.c.W.NOHANG);

        if (result.pid == 0) {
            // プロセスはまだ実行中
            return;
        }

        // プロセス終了 - 結果を取得して処理
        try self.finishShellCommand();
    }

    /// シェルコマンド完了後の処理
    fn finishShellCommand(self: *Editor) !void {
        const state = self.shell_state orelse return;
        defer {
            self.cleanupShellState(state);
            self.mode = .normal;
        }

        // stdout と stderr を読み取る（nullの場合は空文字列）
        var stdout: []const u8 = "";
        var stdout_allocated = false;
        if (state.child.stdout) |stdout_file| {
            stdout = stdout_file.readToEndAlloc(self.allocator, 1024 * 1024) catch "";
            stdout_allocated = stdout.len > 0;
        }
        defer if (stdout_allocated) self.allocator.free(@constCast(stdout));

        var stderr: []const u8 = "";
        var stderr_allocated = false;
        if (state.child.stderr) |stderr_file| {
            stderr = stderr_file.readToEndAlloc(self.allocator, 1024 * 1024) catch "";
            stderr_allocated = stderr.len > 0;
        }
        defer if (stderr_allocated) self.allocator.free(@constCast(stderr));

        // 注意: waitpidで既にプロセスはreapされているので、wait()は呼ばない

        // 結果を処理
        try self.processShellResult(stdout, stderr, state.input_source, state.output_dest);
    }

    /// シェルコマンドをキャンセル
    fn cancelShellCommand(self: *Editor) void {
        if (self.shell_state) |state| {
            // 子プロセスをkill
            _ = state.child.kill() catch {};
            self.cleanupShellState(state);
        }
        self.mode = .normal;
        self.getCurrentView().setError("Cancelled");
    }

    /// シェル実行結果を処理
    fn processShellResult(self: *Editor, stdout: []const u8, stderr: []const u8, input_source: ShellInputSource, output_dest: ShellOutputDest) !void {
        const window = &self.windows.items[self.current_window_idx];

        // 結果を処理
        switch (output_dest) {
            .command_buffer => {
                // *Command* バッファに出力を表示
                const output = if (stderr.len > 0) stderr else stdout;
                if (output.len == 0) {
                    self.getCurrentView().setError("(no output)");
                    return;
                }

                // コマンドバッファを取得/作成
                const cmd_buffer = try self.getOrCreateCommandBuffer();

                // バッファをクリアして新しい内容を設定
                if (cmd_buffer.buffer.total_len > 0) {
                    cmd_buffer.buffer.delete(0, cmd_buffer.buffer.total_len) catch {};
                }

                // 出力を挿入
                cmd_buffer.buffer.insertSlice(0, output) catch {};

                // *Command* バッファがどこかのウィンドウに表示されているか確認
                var cmd_window_idx: ?usize = null;
                for (self.windows.items, 0..) |win, idx| {
                    if (win.buffer_id == cmd_buffer.id) {
                        cmd_window_idx = idx;
                        break;
                    }
                }

                if (cmd_window_idx) |idx| {
                    // 既に表示されている：そのウィンドウを更新
                    self.windows.items[idx].view.markFullRedraw();
                    self.windows.items[idx].view.cursor_x = 0;
                    self.windows.items[idx].view.cursor_y = 0;
                    self.windows.items[idx].view.top_line = 0;
                    self.windows.items[idx].view.top_col = 0;
                } else {
                    // 表示されていない：ウィンドウを分割して下に *Command* を表示
                    const new_win_idx = try self.openCommandBufferWindow();
                    // 新しいウィンドウのビューを更新（バッファが更新されているため）
                    self.windows.items[new_win_idx].view.buffer = &cmd_buffer.buffer;
                    self.windows.items[new_win_idx].view.markFullRedraw();
                    self.windows.items[new_win_idx].view.cursor_x = 0;
                    self.windows.items[new_win_idx].view.cursor_y = 0;
                    self.windows.items[new_win_idx].view.top_line = 0;
                    self.windows.items[new_win_idx].view.top_col = 0;
                }

                // カレントウィンドウはそのまま（移動しない）
                // stderrの場合はエラー表示
                if (stderr.len > 0) {
                    self.getCurrentView().setError("Command failed (see below)");
                } else {
                    self.getCurrentView().setError("Command output below");
                }
            },
            .replace => {
                // 入力元を置換
                switch (input_source) {
                    .selection => {
                        if (window.mark_pos) |mark| {
                            const cursor_pos = self.getCurrentView().getCursorBufferPos();
                            const start = @min(mark, cursor_pos);
                            const end_pos = @max(mark, cursor_pos);
                            if (end_pos > start) {
                                // 削除してから挿入
                                const buf = self.getCurrentBufferContent();
                                const deleted = try buf.getRange(self.allocator, start, end_pos - start);
                                defer self.allocator.free(deleted);
                                try buf.delete(start, end_pos - start);
                                try self.recordDelete(start, deleted, cursor_pos);

                                if (stdout.len > 0) {
                                    try buf.insertSlice(start, stdout);
                                    try self.recordInsert(start, stdout, start);
                                }
                                self.getCurrentBuffer().modified = true;
                                self.setCursorToPos(start);
                                self.windows.items[self.current_window_idx].mark_pos = null; // マークをクリア
                                self.getCurrentView().markDirty(0, null);
                            }
                        } else {
                            self.getCurrentView().setError("No selection");
                        }
                    },
                    .buffer_all => {
                        // バッファ全体を置換
                        const buf = self.getCurrentBufferContent();
                        const total_len = buf.total_len;
                        if (total_len > 0) {
                            const old_content = try buf.getRange(self.allocator, 0, total_len);
                            defer self.allocator.free(old_content);
                            try buf.delete(0, total_len);
                            try self.recordDelete(0, old_content, self.getCurrentView().getCursorBufferPos());
                        }
                        if (stdout.len > 0) {
                            try buf.insertSlice(0, stdout);
                            try self.recordInsert(0, stdout, 0);
                        }
                        self.getCurrentBuffer().modified = true;
                        self.setCursorToPos(0);
                        self.getCurrentView().markDirty(0, null);
                    },
                    .current_line => {
                        // 現在行を置換
                        const line_num = self.getCurrentView().top_line + self.getCurrentView().cursor_y;
                        const line_start = self.getCurrentBufferContent().line_index.getLineStart(line_num) orelse 0;
                        const next_line_start = self.getCurrentBufferContent().line_index.getLineStart(line_num + 1);
                        const line_end = if (next_line_start) |ns| ns else self.getCurrentBufferContent().total_len;
                        const buf = self.getCurrentBufferContent();
                        if (line_end > line_start) {
                            const old_line = try buf.getRange(self.allocator, line_start, line_end - line_start);
                            defer self.allocator.free(old_line);
                            try buf.delete(line_start, line_end - line_start);
                            try self.recordDelete(line_start, old_line, self.getCurrentView().getCursorBufferPos());
                        }
                        if (stdout.len > 0) {
                            try buf.insertSlice(line_start, stdout);
                            try self.recordInsert(line_start, stdout, line_start);
                        }
                        self.getCurrentBuffer().modified = true;
                        self.setCursorToPos(line_start);
                        self.getCurrentView().markDirty(line_num, null);
                    },
                }
            },
            .insert => {
                // カーソル位置に挿入
                if (stdout.len > 0) {
                    const pos = self.getCurrentView().getCursorBufferPos();
                    const buf = self.getCurrentBufferContent();
                    try buf.insertSlice(pos, stdout);
                    try self.recordInsert(pos, stdout, pos);
                    self.getCurrentBuffer().modified = true;
                    self.getCurrentView().markDirty(0, null);
                }
            },
            .new_buffer => {
                // 新規バッファに出力
                if (stdout.len > 0) {
                    const new_buffer = try self.createNewBuffer();
                    try new_buffer.buffer.insertSlice(0, stdout);
                    new_buffer.filename = try self.allocator.dupe(u8, "*shell output*");
                    try self.switchToBuffer(new_buffer.id);
                } else if (stderr.len > 0) {
                    const new_buffer = try self.createNewBuffer();
                    try new_buffer.buffer.insertSlice(0, stderr);
                    new_buffer.filename = try self.allocator.dupe(u8, "*shell error*");
                    try self.switchToBuffer(new_buffer.id);
                }
            },
        }
    }

    /// シェルコマンドを実行して結果を返す
    fn runShellCommand(self: *Editor, command: []const u8, stdin_data: ?[]const u8) !struct {
        stdout: []const u8,
        stderr: []const u8,
    } {
        const argv = [_][]const u8{ "/bin/sh", "-c", command };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdin_behavior = if (stdin_data != null) .Pipe else .Close;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // stdin にデータを書き込む
        if (stdin_data) |data| {
            if (child.stdin) |stdin| {
                stdin.writeAll(data) catch {};
                stdin.close();
                child.stdin = null;
            }
        }

        // stdout と stderr を読み取る
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);

        _ = try child.wait();

        return .{
            .stdout = stdout,
            .stderr = stderr,
        };
    }

    // ========================================
    // M-x コマンド
    // ========================================

    /// M-xコマンドを実行
    fn executeMxCommand(self: *Editor) !void {
        const cmd_line = self.input_buffer.items;
        self.input_buffer.clearRetainingCapacity();
        self.mode = .normal;

        if (cmd_line.len == 0) {
            self.getCurrentView().clearError();
            return;
        }

        // コマンドと引数を分割
        var parts = std.mem.splitScalar(u8, cmd_line, ' ');
        const cmd = parts.next() orelse "";
        const arg = parts.next();

        // コマンド実行
        if (std.mem.eql(u8, cmd, "?") or std.mem.eql(u8, cmd, "help")) {
            self.getCurrentView().setError("Commands: line tab indent mode revert key ro ?");
        } else if (std.mem.eql(u8, cmd, "line")) {
            try self.mxCmdLine(arg);
        } else if (std.mem.eql(u8, cmd, "tab")) {
            self.mxCmdTab(arg);
        } else if (std.mem.eql(u8, cmd, "indent")) {
            self.mxCmdIndent(arg);
        } else if (std.mem.eql(u8, cmd, "mode")) {
            self.mxCmdMode(arg);
        } else if (std.mem.eql(u8, cmd, "revert")) {
            try self.mxCmdRevert();
        } else if (std.mem.eql(u8, cmd, "key")) {
            self.mode = .mx_key_describe;
            self.getCurrentView().setError("Press key: ");
        } else if (std.mem.eql(u8, cmd, "ro")) {
            self.mxCmdReadonly();
        } else {
            // 未知のコマンド
            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Unknown command: {s}", .{cmd}) catch null;
            if (self.prompt_buffer) |msg| {
                self.getCurrentView().setError(msg);
            }
        }
    }

    /// line コマンド: 指定行へ移動
    fn mxCmdLine(self: *Editor, arg: ?[]const u8) !void {
        if (arg) |line_str| {
            const line_num = std.fmt.parseInt(usize, line_str, 10) catch {
                self.getCurrentView().setError("Invalid line number");
                return;
            };
            if (line_num == 0) {
                self.getCurrentView().setError("Line number must be >= 1");
                return;
            }
            // 0-indexedに変換
            const target_line = line_num - 1;
            const view = self.getCurrentView();
            const buffer = self.getCurrentBufferContent();
            const total_lines = buffer.lineCount();
            if (target_line >= total_lines) {
                view.moveToBufferEnd(&self.terminal);
            } else {
                // 指定行の先頭に移動
                if (buffer.getLineStart(target_line)) |pos| {
                    self.setCursorToPos(pos);
                }
            }
            self.getCurrentView().clearError();
        } else {
            // 引数なし: 現在の行番号を表示
            const view = self.getCurrentView();
            const current_line = view.top_line + view.cursor_y + 1;
            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "line: {d}", .{current_line}) catch null;
            if (self.prompt_buffer) |msg| {
                self.getCurrentView().setError(msg);
            }
        }
    }

    /// tab コマンド: タブ幅の表示/設定
    fn mxCmdTab(self: *Editor, arg: ?[]const u8) void {
        if (arg) |width_str| {
            const width = std.fmt.parseInt(u8, width_str, 10) catch {
                self.getCurrentView().setError("Invalid tab width");
                return;
            };
            if (width == 0 or width > 16) {
                self.getCurrentView().setError("Tab width must be 1-16");
                return;
            }
            self.getCurrentView().setTabWidth(width);
            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "tab: {d}", .{width}) catch null;
            if (self.prompt_buffer) |msg| {
                self.getCurrentView().setError(msg);
            }
        } else {
            // 引数なし: 現在のタブ幅を表示
            const width = self.getCurrentView().getTabWidth();
            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "tab: {d}", .{width}) catch null;
            if (self.prompt_buffer) |msg| {
                self.getCurrentView().setError(msg);
            }
        }
    }

    /// indent コマンド: インデントスタイルの表示/設定
    fn mxCmdIndent(self: *Editor, arg: ?[]const u8) void {
        const syntax = @import("syntax.zig");
        if (arg) |style_str| {
            if (std.mem.eql(u8, style_str, "space") or std.mem.eql(u8, style_str, "spaces")) {
                self.getCurrentView().setIndentStyle(.space);
                self.getCurrentView().setError("indent: space");
            } else if (std.mem.eql(u8, style_str, "tab") or std.mem.eql(u8, style_str, "tabs")) {
                self.getCurrentView().setIndentStyle(.tab);
                self.getCurrentView().setError("indent: tab");
            } else {
                self.getCurrentView().setError("Usage: indent space|tab");
            }
        } else {
            // 引数なし: 現在のインデントスタイルを表示
            const style = self.getCurrentView().getIndentStyle();
            const style_name = switch (style) {
                .space => "space",
                .tab => "tab",
            };
            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "indent: {s}", .{style_name}) catch null;
            if (self.prompt_buffer) |msg| {
                self.getCurrentView().setError(msg);
            }
        }
        _ = syntax;
    }

    /// mode コマンド: 言語モードの表示/設定
    fn mxCmdMode(self: *Editor, arg: ?[]const u8) void {
        const syntax = @import("syntax.zig");
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
                self.getCurrentView().setLanguage(lang);
                self.prompt_buffer = std.fmt.allocPrint(self.allocator, "mode: {s}", .{lang.name}) catch null;
                if (self.prompt_buffer) |msg| {
                    self.getCurrentView().setError(msg);
                }
            } else {
                self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Unknown mode: {s}", .{mode_str}) catch null;
                if (self.prompt_buffer) |msg| {
                    self.getCurrentView().setError(msg);
                }
            }
        } else {
            // 引数なし: 現在のモードを表示
            const lang = self.getCurrentView().language;
            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "mode: {s}", .{lang.name}) catch null;
            if (self.prompt_buffer) |msg| {
                self.getCurrentView().setError(msg);
            }
        }
    }

    /// revert コマンド: ファイル再読み込み
    fn mxCmdRevert(self: *Editor) !void {
        const buffer_state = self.getCurrentBuffer();
        if (buffer_state.filename == null) {
            self.getCurrentView().setError("No file to revert");
            return;
        }
        if (buffer_state.modified) {
            self.getCurrentView().setError("Buffer modified. Save first or use C-x k");
            return;
        }

        const filename = buffer_state.filename.?;
        const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            self.prompt_buffer = std.fmt.allocPrint(self.allocator, "Cannot open: {s}", .{@errorName(err)}) catch null;
            if (self.prompt_buffer) |msg| {
                self.getCurrentView().setError(msg);
            }
            return;
        };
        defer file.close();

        const stat = try file.stat();
        const content = try file.readToEndAlloc(self.allocator, stat.size);
        defer self.allocator.free(content);

        // バッファをクリアして再読み込み
        const buffer = self.getCurrentBufferContent();
        const len = buffer.len();
        if (len > 0) {
            try buffer.delete(0, len);
        }
        try buffer.insertSlice(0, content);
        buffer_state.modified = false;
        buffer_state.file_mtime = stat.mtime;

        // カーソルを先頭に
        self.getCurrentView().moveToBufferStart();
        self.getCurrentView().setError("Reverted");
    }

    /// ro コマンド: 読み取り専用切り替え
    fn mxCmdReadonly(self: *Editor) void {
        const buffer_state = self.getCurrentBuffer();
        buffer_state.readonly = !buffer_state.readonly;
        if (buffer_state.readonly) {
            self.getCurrentView().setError("[RO] Read-only enabled");
        } else {
            self.getCurrentView().setError("Read-only disabled");
        }
    }

    /// キーの説明を返す
    fn describeKey(self: *Editor, key: input.Key) []const u8 {
        _ = self;
        return switch (key) {
            .ctrl => |c| switch (c) {
                0, '@' => "C-Space/C-@: set-mark",
                'a' => "C-a: beginning-of-line",
                'b' => "C-b: backward-char",
                'd' => "C-d: delete-char",
                'e' => "C-e: end-of-line",
                'f' => "C-f: forward-char",
                'g' => "C-g: cancel",
                'h' => "C-h: backspace",
                'k' => "C-k: kill-line",
                'l' => "C-l: recenter",
                'n' => "C-n: next-line",
                'p' => "C-p: previous-line",
                'r' => "C-r: isearch-backward",
                's' => "C-s: isearch-forward",
                'u' => "C-u: undo",
                'v' => "C-v: scroll-down",
                'w' => "C-w: kill-region",
                'x' => "C-x: prefix",
                'y' => "C-y: yank",
                '/' => "C-/: redo",
                else => "Unknown key",
            },
            .alt => |c| switch (c) {
                '%' => "M-%: query-replace",
                ';' => "M-;: comment-toggle",
                '<' => "M-<: beginning-of-buffer",
                '>' => "M->: end-of-buffer",
                '^' => "M-^: join-line",
                'b' => "M-b: backward-word",
                'd' => "M-d: kill-word",
                'f' => "M-f: forward-word",
                'v' => "M-v: scroll-up",
                'w' => "M-w: copy-region",
                'x' => "M-x: command",
                '{' => "M-{: backward-paragraph",
                '}' => "M-}: forward-paragraph",
                '|' => "M-|: shell-command",
                else => "Unknown key",
            },
            .enter => "Enter: newline",
            .backspace => "Backspace: delete-backward-char",
            .tab => "Tab: indent / insert-tab",
            .shift_tab => "S-Tab: unindent",
            .arrow_up => "Up: previous-line",
            .arrow_down => "Down: next-line",
            .arrow_left => "Left: backward-char",
            .arrow_right => "Right: forward-char",
            .home => "Home: beginning-of-line",
            .end_key => "End: end-of-line",
            .page_up => "PageUp: scroll-up",
            .page_down => "PageDown: scroll-down",
            .delete => "Delete: delete-char",
            .escape => "Escape: cancel",
            .alt_delete => "M-Delete: kill-word",
            .alt_arrow_up => "M-Up: move-line-up",
            .alt_arrow_down => "M-Down: move-line-down",
            .ctrl_tab => "C-Tab: next-window",
            .ctrl_shift_tab => "C-S-Tab: previous-window",
            else => "Unknown key",
        };
    }
};
