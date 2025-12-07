const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const PieceIterator = @import("buffer.zig").PieceIterator;
const Terminal = @import("terminal.zig").Terminal;
const config = @import("config.zig");

/// 行がコメント行かどうかを判定
/// 行頭の空白を飛ばして # // ; --  があればコメント
fn isCommentLine(line: []const u8) bool {
    // 行頭の空白をスキップ
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
        i += 1;
    }

    // 残りがなければコメントではない
    if (i >= line.len) return false;

    // コメントプレフィックスをチェック
    const rest = line[i..];

    // # (シェル、Python、Ruby、Makefileなど)
    if (rest.len >= 1 and rest[0] == '#') return true;

    // // (C, C++, Java, Go, JavaScript, Zig など)
    if (rest.len >= 2 and rest[0] == '/' and rest[1] == '/') return true;

    // ; (Lisp, Assembly, INI ファイルなど)
    if (rest.len >= 1 and rest[0] == ';') return true;

    // -- (Lua, SQL, Haskell など)
    if (rest.len >= 2 and rest[0] == '-' and rest[1] == '-') return true;

    return false;
}

pub const View = struct {
    buffer: *Buffer,
    top_line: usize,
    top_col: usize, // 水平スクロールオフセット
    cursor_x: usize,
    cursor_y: usize,
    // Dirty範囲追跡（差分描画用）
    dirty_start: ?usize,
    dirty_end: ?usize,
    needs_full_redraw: bool,
    // レンダリング用の再利用バッファ（メモリ確保を減らす）
    line_buffer: std.ArrayList(u8),
    // エラーメッセージ表示用
    error_msg: ?[]const u8,
    // セルレベル差分描画用: 前フレームの画面状態
    prev_screen: std.ArrayList(std.ArrayList(u8)),
    // 検索ハイライト用
    search_highlight: ?[]const u8, // 検索文字列（nullならハイライトなし）
    // 行番号表示の幅キャッシュ（幅変更時に全画面再描画するため）
    cached_line_num_width: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, buffer: *Buffer) View {
        return View{
            .buffer = buffer,
            .top_line = 0,
            .top_col = 0,
            .cursor_x = 0,
            .cursor_y = 0,
            .dirty_start = null,
            .dirty_end = null,
            .needs_full_redraw = true,
            .line_buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable,
            .error_msg = null,
            .prev_screen = std.ArrayList(std.ArrayList(u8)).initCapacity(allocator, 0) catch unreachable,
            .search_highlight = null,
            .cached_line_num_width = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.line_buffer.deinit(allocator);
        // 前フレームバッファのクリーンアップ
        for (self.prev_screen.items) |*line| {
            line.deinit(self.allocator);
        }
        self.prev_screen.deinit(self.allocator);
    }

    // エラーメッセージを設定
    pub fn setError(self: *View, msg: []const u8) void {
        self.error_msg = msg;
    }

    // エラーメッセージをクリア
    pub fn clearError(self: *View) void {
        self.error_msg = null;
    }

    // 検索ハイライトを設定
    pub fn setSearchHighlight(self: *View, search_str: ?[]const u8) void {
        self.search_highlight = search_str;
        // ハイライトが変わったので全画面再描画
        self.markFullRedraw();
    }

    // 行番号の表示幅を計算（999行まで固定、1000行以上で動的拡張）
    fn getLineNumberWidth(self: *View) usize {
        if (!config.Editor.SHOW_LINE_NUMBERS) return 0;

        const total_lines = self.buffer.lineCount();
        if (total_lines == 0) return 0;

        // 999行まで: 3桁 + スペース2個 = 5文字固定
        if (total_lines <= 999) {
            return 5;
        }

        // 1000行以上: 桁数を動的計算
        var width: usize = 1;
        var n = total_lines;
        while (n >= 10) {
            width += 1;
            n /= 10;
        }
        return width + 2; // 行番号 + スペース2個
    }

    pub fn markDirty(self: *View, start_line: usize, end_line: ?usize) void {
        if (self.dirty_start) |ds| {
            self.dirty_start = @min(ds, start_line);
        } else {
            self.dirty_start = start_line;
        }

        // end_line が null なら EOF まで
        if (end_line) |e| {
            if (self.dirty_end) |de| {
                self.dirty_end = @max(de, e);
            } else {
                self.dirty_end = e;
            }
        } else {
            // null が渡されたら dirty_end も null (EOF まで)
            self.dirty_end = null;
        }
    }

    pub fn markFullRedraw(self: *View) void {
        self.needs_full_redraw = true;
        self.dirty_start = null;
        self.dirty_end = null;

        // 前フレームバッファをクリア（全画面再描画なので差分計算不要）
        for (self.prev_screen.items) |*line| {
            line.deinit(self.allocator);
        }
        self.prev_screen.clearRetainingCapacity();
    }

    pub fn clearDirty(self: *View) void {
        self.dirty_start = null;
        self.dirty_end = null;
        self.needs_full_redraw = false;
    }

    // イテレータを再利用して行を描画（セルレベル差分描画版）
    fn renderLineWithIter(self: *View, term: *Terminal, screen_row: usize, file_line: usize, iter: *PieceIterator, line_buffer: *std.ArrayList(u8)) !void {
        try self.renderLineWithIterOffset(term, 0, screen_row, file_line, iter, line_buffer);
    }

    // イテレータを再利用して行を描画（オフセット付き）
    fn renderLineWithIterOffset(self: *View, term: *Terminal, viewport_y: usize, screen_row: usize, file_line: usize, iter: *PieceIterator, line_buffer: *std.ArrayList(u8)) !void {
        const abs_row = viewport_y + screen_row;
        // 再利用バッファをクリア
        line_buffer.clearRetainingCapacity();

        // 行末まで読み取る
        while (iter.next()) |ch| {
            if (ch == '\n') break;
            try line_buffer.append(term.allocator, ch);
        }

        // コメント行かどうかをチェック（行頭の空白を飛ばして # // ; があればコメント）
        const is_comment = isCommentLine(line_buffer.items);

        // Tab展開用の一時バッファ
        var expanded_line = std.ArrayList(u8){};
        defer expanded_line.deinit(self.allocator);

        // 行番号を先に追加（グレー表示 + スペース2個）
        const line_num_width = self.getLineNumberWidth();
        if (line_num_width > 0) {
            var num_buf: [64]u8 = undefined;
            // グレー(\x1b[90m) + 右詰め行番号 + リセット(\x1b[m) + スペース2個
            const line_num_str = std.fmt.bufPrint(&num_buf, "\x1b[90m{d: >[1]}\x1b[m  ", .{ file_line + 1, line_num_width - 2 }) catch "";
            try expanded_line.appendSlice(self.allocator, line_num_str);
        }

        // コメント行なら暗めのグレーで開始
        if (is_comment) {
            try expanded_line.appendSlice(self.allocator, "\x1b[90m");
        }

        // grapheme-aware rendering with tab expansion and horizontal scrolling
        var byte_idx: usize = 0;
        var col: usize = 0; // 論理カラム位置（行全体での位置）
        const visible_end = self.top_col + term.width; // 表示範囲の終端

        while (byte_idx < line_buffer.items.len and col < visible_end) {
            const ch = line_buffer.items[byte_idx];
            if (ch < config.UTF8.CONTINUATION_MASK) {
                // ASCII
                if (ch == '\t') {
                    // Tabを空白に展開
                    const next_tab_stop = (col / config.Editor.TAB_WIDTH + 1) * config.Editor.TAB_WIDTH;
                    const spaces_needed = next_tab_stop - col;
                    var i: usize = 0;
                    while (i < spaces_needed) : (i += 1) {
                        // 水平スクロール範囲内なら追加
                        if (col + i >= self.top_col and col + i < visible_end) {
                            try expanded_line.append(self.allocator, ' ');
                        }
                    }
                    col = next_tab_stop;
                    byte_idx += 1;
                } else {
                    // 通常のASCII文字
                    if (col >= self.top_col) {
                        try expanded_line.append(self.allocator, ch);
                    }
                    byte_idx += 1;
                    col += 1;
                }
            } else {
                // UTF-8: calculate codepoint and width
                const len = std.unicode.utf8ByteSequenceLength(ch) catch break;
                if (byte_idx + len > line_buffer.items.len) break;
                const codepoint = std.unicode.utf8Decode(line_buffer.items[byte_idx .. byte_idx + len]) catch {
                    byte_idx += 1;
                    continue;
                };
                const width = Buffer.charWidth(codepoint);
                // 水平スクロール範囲内なら追加
                if (col >= self.top_col) {
                    // UTF-8文字をそのままコピー
                    var i: usize = 0;
                    while (i < len) : (i += 1) {
                        try expanded_line.append(self.allocator, line_buffer.items[byte_idx + i]);
                    }
                }
                byte_idx += len;
                col += width;
            }
        }

        // コメント行ならリセット
        if (is_comment) {
            try expanded_line.appendSlice(self.allocator, "\x1b[m");
        }

        var new_line = expanded_line.items;

        // 検索ハイライトの適用
        var highlighted_line = std.ArrayList(u8){};
        defer highlighted_line.deinit(self.allocator);

        if (self.search_highlight) |search_str| {
            if (search_str.len > 0 and new_line.len > 0) {
                // 行内で検索文字列を探してハイライト
                var pos: usize = 0;
                while (pos < new_line.len) {
                    if (std.mem.indexOf(u8, new_line[pos..], search_str)) |match_offset| {
                        const match_pos = pos + match_offset;
                        // マッチ前の部分をコピー
                        try highlighted_line.appendSlice(self.allocator, new_line[pos..match_pos]);
                        // 反転表示開始
                        try highlighted_line.appendSlice(self.allocator, "\x1b[7m");
                        // マッチ部分をコピー
                        try highlighted_line.appendSlice(self.allocator, new_line[match_pos..match_pos + search_str.len]);
                        // 反転表示終了
                        try highlighted_line.appendSlice(self.allocator, "\x1b[27m");
                        // 次の検索位置へ
                        pos = match_pos + search_str.len;
                    } else {
                        // これ以上マッチなし：残りをコピー
                        try highlighted_line.appendSlice(self.allocator, new_line[pos..]);
                        break;
                    }
                }
                new_line = highlighted_line.items;
            }
        }

        // 前フレームと比較してセルレベル差分描画
        if (screen_row < self.prev_screen.items.len) {
            const old_line = self.prev_screen.items[screen_row].items;

            // 差分を検出
            const min_len = @min(old_line.len, new_line.len);
            var diff_start: ?usize = null;
            var diff_end: usize = 0;

            // 前方から差分を探す
            for (0..min_len) |i| {
                if (old_line[i] != new_line[i]) {
                    if (diff_start == null) diff_start = i;
                    diff_end = i + 1;
                }
            }

            // 長さが違う場合は後ろも差分
            if (old_line.len != new_line.len) {
                if (diff_start == null) diff_start = min_len;
                diff_end = @max(old_line.len, new_line.len);
            }

            if (diff_start) |start_raw| {
                // 行番号の表示幅を取得
                const line_num_display_width = self.getLineNumberWidth();

                // 行番号がある場合は常に行全体を再描画
                // （ANSIシーケンスの計算が複雑なため、シンプルな実装を優先）
                if (line_num_display_width > 0) {
                    // 行頭から全体を再描画
                    try term.moveCursor(abs_row, 0);
                    try term.write(config.ANSI.CLEAR_LINE);
                    try term.write(new_line);
                } else {
                    // UTF-8文字境界に調整（継続バイトの途中から始まらないように）
                    var start = start_raw;
                    while (start > 0 and start < new_line.len and new_line[start] >= 0x80 and new_line[start] < 0xC0) {
                        // 継続バイト（0x80-0xBF）の場合は前に戻る
                        start -= 1;
                    }

                    // バイト位置から画面カラム位置を計算
                    // ANSIエスケープシーケンスを除外して計算
                    var screen_col: usize = 0;
                    var b: usize = 0;
                    while (b < start) {
                        const c = new_line[b];
                        // ANSIエスケープシーケンスをスキップ（ESC [ ... m）
                        if (c == 0x1B and b + 1 < new_line.len and new_line[b + 1] == '[') {
                            // ESCシーケンスの終わり('m')まで読み飛ばす
                            b += 2;
                            while (b < new_line.len and new_line[b] != 'm') {
                                b += 1;
                            }
                            if (b < new_line.len) b += 1; // 'm'をスキップ
                            continue;
                        }

                        if (c < config.UTF8.CONTINUATION_MASK) {
                            b += 1;
                            screen_col += 1;
                        } else {
                            const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                            if (b + len <= new_line.len) {
                                const cp = std.unicode.utf8Decode(new_line[b..b + len]) catch {
                                    b += 1;
                                    screen_col += 1;
                                    continue;
                                };
                                screen_col += Buffer.charWidth(cp);
                                b += len;
                            } else {
                                b += 1;
                                screen_col += 1;
                            }
                        }
                    }

                    // 差分部分のみ描画
                    try term.moveCursor(abs_row, screen_col);
                    try term.write(new_line[start..]);

                    // 古い行の方が長い場合は残りをクリア
                    if (old_line.len > new_line.len) {
                        try term.write(config.ANSI.CLEAR_LINE);
                    }
                }
            }
        } else {
            // 新しい行：全体を描画
            try term.moveCursor(abs_row, 0);
            try term.write(config.ANSI.CLEAR_LINE);
            try term.write(new_line);
        }

        // 前フレームバッファを更新
        if (screen_row < self.prev_screen.items.len) {
            self.prev_screen.items[screen_row].clearRetainingCapacity();
            try self.prev_screen.items[screen_row].appendSlice(self.allocator, new_line);
        } else {
            // 新しい行を追加
            var new_prev_line = std.ArrayList(u8){};
            try new_prev_line.appendSlice(self.allocator, new_line);
            try self.prev_screen.append(self.allocator, new_prev_line);
        }
    }

    // 空行（~）を描画（セルレベル差分版）
    fn renderEmptyLine(self: *View, term: *Terminal, screen_row: usize) !void {
        try self.renderEmptyLineOffset(term, 0, screen_row);
    }

    // 空行（~）を描画（オフセット付き）
    fn renderEmptyLineOffset(self: *View, term: *Terminal, viewport_y: usize, screen_row: usize) !void {
        const empty_line = "~";
        const abs_row = viewport_y + screen_row;

        // 前フレームと比較
        if (screen_row < self.prev_screen.items.len) {
            const old_line = self.prev_screen.items[screen_row].items;
            if (old_line.len != 1 or old_line[0] != '~') {
                // 変更あり：描画
                try term.moveCursor(abs_row, 0);
                try term.write(config.ANSI.CLEAR_LINE);
                try term.write(empty_line);

                // 前フレームバッファ更新
                self.prev_screen.items[screen_row].clearRetainingCapacity();
                try self.prev_screen.items[screen_row].appendSlice(self.allocator, empty_line);
            }
        } else {
            // 新しい行：描画
            try term.moveCursor(abs_row, 0);
            try term.write(config.ANSI.CLEAR_LINE);
            try term.write(empty_line);

            // 前フレームバッファ追加
            var new_prev_line = std.ArrayList(u8){};
            try new_prev_line.appendSlice(self.allocator, empty_line);
            try self.prev_screen.append(self.allocator, new_prev_line);
        }
    }

    /// ウィンドウ境界内にレンダリング
    /// viewport_y: ウィンドウのY座標（画面上端からのオフセット）
    /// viewport_height: ウィンドウの高さ（ステータスバー含む）
    /// is_active: アクティブウィンドウならtrue（カーソル表示）
    pub fn renderInBounds(
        self: *View,
        term: *Terminal,
        viewport_y: usize,
        viewport_height: usize,
        is_active: bool,
        modified: bool,
        readonly: bool,
        line_ending: anytype,
        filename: ?[]const u8,
    ) !void {
        // 端末サイズが0の場合は何もしない
        if (term.height == 0 or term.width == 0 or viewport_height == 0) return;

        try term.hideCursor();

        const max_lines = viewport_height - 1; // ステータスバー分を引く

        // 画面サイズ変更を検出（prev_screenの行数が変わった場合）
        if (self.prev_screen.items.len > 0 and self.prev_screen.items.len != max_lines) {
            self.markFullRedraw();
        }

        // 行番号幅の変更をチェック（999→1000行など）
        const current_width = self.getLineNumberWidth();
        if (current_width != self.cached_line_num_width) {
            self.cached_line_num_width = current_width;
            self.markFullRedraw();
        }

        // 全画面再描画が必要な場合
        if (self.needs_full_redraw) {
            // ウィンドウの開始位置に移動
            try term.moveCursor(viewport_y, 0);

            // top_lineの開始位置を取得してイテレータを初期化
            const start_pos = self.buffer.getLineStart(self.top_line) orelse self.buffer.len();
            var iter = PieceIterator.init(self.buffer);
            iter.seek(start_pos);

            // 全画面描画 - イテレータを再利用して前進のみ
            var screen_row: usize = 0;
            while (screen_row < max_lines) : (screen_row += 1) {
                const file_line = self.top_line + screen_row;
                if (file_line < self.buffer.lineCount()) {
                    try self.renderLineWithIterOffset(term, viewport_y, screen_row, file_line, &iter, &self.line_buffer);
                } else {
                    try self.renderEmptyLineOffset(term, viewport_y, screen_row);
                }
            }

            self.clearDirty();
        } else if (self.dirty_start) |start| {
            // 差分描画: dirty範囲のみ再描画
            const end_line = self.dirty_end orelse (self.top_line + max_lines);
            const end = @min(end_line, self.top_line + max_lines);

            if (start < self.top_line + max_lines and end >= self.top_line) {
                const render_start = if (start > self.top_line) start - self.top_line else 0;
                const render_end = @min(
                    if (end >= self.top_line) end - self.top_line + 1 else 0,
                    max_lines,
                );

                // dirty範囲の開始位置を取得
                const start_file_line = self.top_line + render_start;
                const start_pos = self.buffer.getLineStart(start_file_line) orelse self.buffer.len();
                var iter = PieceIterator.init(self.buffer);
                iter.seek(start_pos);

                // dirty範囲を描画 - イテレータを再利用
                var screen_row = render_start;
                while (screen_row < render_end) : (screen_row += 1) {
                    const file_line = self.top_line + screen_row;
                    if (file_line < self.buffer.lineCount()) {
                        try self.renderLineWithIterOffset(term, viewport_y, screen_row, file_line, &iter, &self.line_buffer);
                    } else {
                        try self.renderEmptyLineOffset(term, viewport_y, screen_row);
                    }
                }
            }

            self.clearDirty();
        }

        // ステータスバーの描画
        try self.renderStatusBarAt(term, viewport_y + viewport_height - 1, modified, readonly, line_ending, filename);

        // カーソルを表示（アクティブウィンドウのみ）
        if (is_active) {
            const line_num_width = self.getLineNumberWidth();
            var screen_cursor_x = line_num_width + (if (self.cursor_x >= self.top_col) self.cursor_x - self.top_col else 0);
            // 端末幅を超えないようにクリップ
            if (screen_cursor_x >= term.width) {
                screen_cursor_x = term.width - 1;
            }
            try term.moveCursor(viewport_y + self.cursor_y, screen_cursor_x);
            try term.showCursor();
        }
        try term.flush();
    }

    /// 従来のrender（後方互換性のため）- 全画面レンダリング
    pub fn render(self: *View, term: *Terminal, modified: bool, readonly: bool, line_ending: anytype, filename: ?[]const u8) !void {
        try self.renderInBounds(term, 0, term.height, true, modified, readonly, line_ending, filename);
    }

    pub fn renderStatusBar(self: *View, term: *Terminal, modified: bool, readonly: bool, line_ending: anytype, filename: ?[]const u8) !void {
        try self.renderStatusBarAt(term, term.height - 1, modified, readonly, line_ending, filename);
    }

    /// 指定行にステータスバーを描画
    pub fn renderStatusBarAt(self: *View, term: *Terminal, row: usize, modified: bool, readonly: bool, line_ending: anytype, filename: ?[]const u8) !void {
        try term.moveCursor(row, 0);

        var status_buf: [config.Editor.STATUS_BUF_SIZE]u8 = undefined;

        // メッセージがあればそれを優先表示
        const status = if (self.error_msg) |msg|
            try std.fmt.bufPrint(&status_buf, " {s}", .{msg})
        else blk: {
            const lines = self.buffer.lineCount();

            // ステータスフラグを構築
            const modified_flag = if (modified) "[+]" else "";
            const readonly_flag = if (readonly) "[RO]" else "";
            const le_str = if (@as(u32, @intFromEnum(line_ending)) == 0) "LF" else "CRLF";
            const fname = if (filename) |f| f else "[No Name]";

            break :blk try std.fmt.bufPrint(
                &status_buf,
                " {s}{s} {s} | Line {d}/{d} | {d},{d} | {s} | UTF-8",
                .{ modified_flag, readonly_flag, fname, self.top_line + self.cursor_y + 1, lines, self.cursor_y + 1, self.cursor_x + 1, le_str },
            );
        };

        // ステータスバーを反転表示
        try term.write(config.ANSI.INVERT);

        // ステータスが端末幅を超える場合は切り捨て
        const display_status = if (status.len > term.width) status[0..term.width] else status;
        try term.write(display_status);

        // 残りの部分を空白で埋める（underflow防止）
        const padding = if (display_status.len < term.width) term.width - display_status.len else 0;
        for (0..padding) |_| {
            try term.write(" ");
        }
        try term.write(config.ANSI.RESET);
    }

    pub fn getCursorBufferPos(self: *View) usize {
        const target_line = self.top_line + self.cursor_y;

        // LineIndexでO(1)行開始位置取得
        // 無効な場合はEOF（安全側に倒す）
        const line_start = self.buffer.getLineStart(target_line) orelse {
            // LineIndexが無効またはtarget_lineが範囲外
            // EOFを返すことで、編集操作が安全に失敗する
            return self.buffer.len();
        };

        // 行内のカーソル位置を計算
        // cursor_xは表示幅（絵文字=2, 通常文字=1）なので、
        // 表示幅を累積してcursor_xに到達するバイト位置を探す
        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        var display_col: usize = 0;
        while (display_col < self.cursor_x) {
            const start_pos = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster == null) break;
            const gc = cluster.?;
            if (gc.base == '\n') break;

            // タブ文字の場合は文脈依存の幅を計算
            const char_width = if (gc.base == '\t') blk: {
                const next_tab_stop = (display_col / config.Editor.TAB_WIDTH + 1) * config.Editor.TAB_WIDTH;
                break :blk next_tab_stop - display_col;
            } else gc.width;

            display_col += char_width;

            // 目標カーソル位置を超えた場合は手前で止まる
            if (display_col > self.cursor_x) {
                // イテレータを元の位置に戻す
                iter.global_pos = start_pos;
                break;
            }
        }

        return @min(iter.global_pos, self.buffer.len());
    }

    // 現在行の表示幅を取得（grapheme cluster単位）
    pub fn getCurrentLineWidth(self: *View) usize {
        const target_line = self.top_line + self.cursor_y;

        // LineIndexでO(1)行開始位置取得
        // 無効な場合は幅0（安全側に倒す）
        const line_start = self.buffer.getLineStart(target_line) orelse {
            // LineIndexが無効またはtarget_lineが範囲外
            // 幅0を返すことで、カーソルが行頭にクランプされる
            return 0;
        };

        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        // 行の表示幅を計算
        var line_width: usize = 0;
        while (true) {
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster) |gc| {
                if (gc.base == '\n') break;

                // タブ文字の場合は文脈依存の幅を計算
                const char_width = if (gc.base == '\t') blk: {
                    const next_tab_stop = (line_width / config.Editor.TAB_WIDTH + 1) * config.Editor.TAB_WIDTH;
                    break :blk next_tab_stop - line_width;
                } else gc.width;

                line_width += char_width;
            } else {
                break;
            }
        }

        return line_width;
    }

    pub fn moveCursorLeft(self: *View) void {
        if (self.cursor_x > 0) {
            // UTF-8文字幅を考慮して1文字分戻る
            const pos = self.getCursorBufferPos();
            if (pos == 0) {
                self.cursor_x = 0;
                return;
            }

            // 1つ前の文字の幅を取得
            var iter = PieceIterator.init(self.buffer);
            var line: usize = 0;
            const target_line = self.top_line + self.cursor_y;

            // 目標行まで進める
            while (line < target_line) {
                const ch = iter.next() orelse return;
                if (ch == '\n') line += 1;
            }

            // 行内でカーソル直前のgrapheme clusterを見つける
            var last_width: usize = 1;
            var display_col: usize = 0;
            while (iter.global_pos < pos) {
                const cluster = iter.nextGraphemeCluster() catch {
                    _ = iter.next();
                    last_width = 1;
                    display_col += 1;
                    continue;
                };
                if (cluster) |gc| {
                    if (gc.base == '\n') break;

                    // タブ文字の場合は文脈依存の幅を計算
                    last_width = if (gc.base == '\t') blk: {
                        const next_tab_stop = (display_col / config.Editor.TAB_WIDTH + 1) * config.Editor.TAB_WIDTH;
                        break :blk next_tab_stop - display_col;
                    } else gc.width;

                    display_col += last_width;
                    if (iter.global_pos >= pos) break;
                }
            }

            if (self.cursor_x >= last_width) {
                self.cursor_x -= last_width;
            } else {
                self.cursor_x = 0;
            }

            // 水平スクロール: カーソルが左端より左に行った場合
            if (self.cursor_x < self.top_col) {
                self.top_col = self.cursor_x;
                self.markFullRedraw();
            }
        } else {
            // cursor_x == 0、前の行に移動
            if (self.cursor_y > 0) {
                self.cursor_y -= 1;
                self.moveToLineEnd();
            } else if (self.top_line > 0) {
                // 画面最上部で、さらに上にスクロール可能
                self.top_line -= 1;
                self.moveToLineEnd();
                self.markFullRedraw(); // スクロールで全画面再描画
            }
            // 行移動時は水平スクロールをリセット
            self.top_col = 0;
        }
    }

    pub fn moveCursorRight(self: *View, term: *Terminal) void {
        const pos = self.getCursorBufferPos();
        if (pos >= self.buffer.len()) return;

        // 現在位置のgrapheme clusterを取得（O(pieces)で直接ジャンプ）
        var iter = PieceIterator.init(self.buffer);
        iter.seek(pos);

        const cluster = iter.nextGraphemeCluster() catch {
            // エラー時は安全のため移動しない
            return;
        };

        if (cluster) |gc| {
            if (gc.base == '\n') {
                // 改行の場合は次の行の先頭へ
                if (self.cursor_y < term.height - 2 and self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
                    self.cursor_y += 1;
                    self.cursor_x = 0;
                } else if (self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
                    self.top_line += 1;
                    self.cursor_x = 0;
                    self.markFullRedraw(); // スクロールで全画面再描画
                }
                // 行移動時は水平スクロールをリセット
                self.top_col = 0;
            } else {
                // タブ文字の場合は文脈依存の幅を計算
                const char_width = if (gc.base == '\t') blk: {
                    const next_tab_stop = (self.cursor_x / config.Editor.TAB_WIDTH + 1) * config.Editor.TAB_WIDTH;
                    break :blk next_tab_stop - self.cursor_x;
                } else gc.width;

                // grapheme clusterの幅分進める
                self.cursor_x += char_width;

                // 水平スクロール: カーソルが右端を超えた場合
                const visible_width = term.width;
                if (self.cursor_x >= self.top_col + visible_width) {
                    self.top_col = self.cursor_x - visible_width + 1;
                    self.markFullRedraw();
                }
            }
        }
    }

    pub fn moveCursorUp(self: *View) void {
        if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        } else if (self.top_line > 0) {
            self.top_line -= 1;
            self.markFullRedraw(); // スクロールで全画面再描画
        } else {
            return;
        }

        // カーソル位置が行の幅を超えている場合は行末に移動
        const line_width = self.getCurrentLineWidth();
        if (self.cursor_x > line_width) {
            self.cursor_x = line_width;
        }

        // 水平スクロール位置もクランプ（短い行に移動した時の空白表示を防ぐ）
        if (self.top_col > self.cursor_x) {
            self.top_col = self.cursor_x;
            self.markFullRedraw();
        }
    }

    pub fn moveCursorDown(self: *View, term: *Terminal) void {
        const max_cursor_y = if (term.height >= 2) term.height - 2 else 0;
        if (self.cursor_y < max_cursor_y and self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
            self.cursor_y += 1;
        } else if (self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
            self.top_line += 1;
            self.markFullRedraw(); // スクロールで全画面再描画
        } else {
            return;
        }

        // カーソル位置が行の幅を超えている場合は行末に移動
        const line_width = self.getCurrentLineWidth();
        if (self.cursor_x > line_width) {
            self.cursor_x = line_width;
        }

        // 水平スクロール位置もクランプ（短い行に移動した時の空白表示を防ぐ）
        if (self.top_col > self.cursor_x) {
            self.top_col = self.cursor_x;
            self.markFullRedraw();
        }
    }

    pub fn moveToLineStart(self: *View) void {
        self.cursor_x = 0;
        self.top_col = 0;
    }

    pub fn moveToLineEnd(self: *View) void {
        const target_line = self.top_line + self.cursor_y;

        // LineIndexでO(1)行開始位置取得
        // 無効な場合は行頭に留まる（安全側に倒す）
        const line_start = self.buffer.getLineStart(target_line) orelse {
            // LineIndexが無効またはtarget_lineが範囲外
            self.cursor_x = 0;
            return;
        };

        var iter = PieceIterator.init(self.buffer);
        iter.seek(line_start);

        // 行の表示幅を計算
        var line_width: usize = 0;
        while (true) {
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                // タブ文字の場合は文脈依存の幅を計算
                const char_width = if (gc.base == '\t') blk: {
                    const next_tab_stop = (line_width / config.Editor.TAB_WIDTH + 1) * config.Editor.TAB_WIDTH;
                    break :blk next_tab_stop - line_width;
                } else gc.width;
                line_width += char_width;
            } else {
                break;
            }
        }

        self.cursor_x = line_width;
    }

    // M-< (beginning-of-buffer): ファイルの先頭に移動
    pub fn moveToBufferStart(self: *View) void {
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.top_line = 0;
        self.top_col = 0;
        self.markFullRedraw();
    }

    // M-> (end-of-buffer): ファイルの終端に移動
    pub fn moveToBufferEnd(self: *View, term: *Terminal) void {
        const total_lines = self.buffer.lineCount();
        if (total_lines == 0) {
            self.cursor_x = 0;
            self.cursor_y = 0;
            self.top_line = 0;
            self.top_col = 0;
            self.markFullRedraw();
            return;
        }

        // 最終行の番号（0-indexed）
        const last_line = if (total_lines > 0) total_lines - 1 else 0;

        // 端末の表示可能行数
        const max_screen_lines = if (term.height >= 2) term.height - 2 else 0;

        // 最終行をできるだけ画面下部に表示
        if (last_line <= max_screen_lines) {
            // ファイルが画面に収まる場合
            self.top_line = 0;
            self.cursor_y = last_line;
        } else {
            // ファイルが長い場合は最終行が画面下部に来るようにスクロール
            self.top_line = last_line - max_screen_lines;
            self.cursor_y = max_screen_lines;
        }

        // 最終行の末尾にカーソルを移動
        self.moveToLineEnd();
        self.markFullRedraw();
    }
};
