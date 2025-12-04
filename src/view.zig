const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const PieceIterator = @import("buffer.zig").PieceIterator;
const LineIterator = @import("buffer.zig").Buffer.LineIterator;
const Terminal = @import("terminal.zig").Terminal;

pub const View = struct {
    buffer: *Buffer,
    top_line: usize,
    cursor_x: usize,
    cursor_y: usize,
    scroll_offset: usize,
    // Dirty範囲追跡（差分描画用）
    dirty_start: ?usize,
    dirty_end: ?usize,
    needs_full_redraw: bool,

    pub fn init(buffer: *Buffer) View {
        return View{
            .buffer = buffer,
            .top_line = 0,
            .cursor_x = 0,
            .cursor_y = 0,
            .scroll_offset = 0,
            .dirty_start = null,
            .dirty_end = null,
            .needs_full_redraw = true,
        };
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
    }

    pub fn clearDirty(self: *View) void {
        self.dirty_start = null;
        self.dirty_end = null;
        self.needs_full_redraw = false;
    }

    // 1行を描画（grapheme-aware）
    fn renderLine(_: *View, term: *Terminal, screen_row: usize, line_iter: *LineIterator) !void {
        try term.moveCursor(screen_row, 0);
        try term.write("\x1b[K"); // 行末までクリア

        if (try line_iter.nextLine(term.allocator)) |line| {
            defer term.allocator.free(line);
            // grapheme-aware rendering: count display width properly
            var byte_idx: usize = 0;
            var col: usize = 0;
            while (byte_idx < line.len and col < term.width) {
                const ch = line[byte_idx];
                if (ch < 0b10000000) {
                    // ASCII
                    byte_idx += 1;
                    col += 1;
                } else {
                    // UTF-8: calculate codepoint and width
                    const len = std.unicode.utf8ByteSequenceLength(ch) catch break;
                    if (byte_idx + len > line.len) break;
                    const codepoint = std.unicode.utf8Decode(line[byte_idx .. byte_idx + len]) catch {
                        byte_idx += 1;
                        continue;
                    };
                    const width = Buffer.charWidth(codepoint);
                    if (col + width > term.width) break;
                    byte_idx += len;
                    col += width;
                }
            }
            try term.write(line[0..byte_idx]);
        } else {
            try term.write("~");
        }
    }

    pub fn render(self: *View, term: *Terminal) !void {
        try term.hideCursor();

        const max_lines = term.height - 1;

        // 全画面再描画が必要な場合
        if (self.needs_full_redraw) {
            try term.write("\x1b[H"); // ホーム位置

            var line_iter = LineIterator.init(self.buffer);

            // top_lineまでスキップ
            var skip_count: usize = 0;
            while (skip_count < self.top_line) : (skip_count += 1) {
                const line = try line_iter.nextLine(term.allocator) orelse break;
                term.allocator.free(line);
            }

            // 全画面描画
            var screen_row: usize = 0;
            while (screen_row < max_lines) : (screen_row += 1) {
                try self.renderLine(term, screen_row, &line_iter);
            }

            self.clearDirty();
        } else if (self.dirty_start) |start| {
            // 差分描画: dirty範囲のみ再描画
            // dirty_end が null なら EOF まで、そうでなければその値を使う
            const end_line = self.dirty_end orelse (self.top_line + max_lines);
            const end = @min(end_line, self.top_line + max_lines);

            if (start < self.top_line + max_lines and end >= self.top_line) {
                const render_start = if (start > self.top_line) start - self.top_line else 0;
                // end >= self.top_line が保証されているので安全
                const render_end = @min(
                    if (end >= self.top_line) end - self.top_line + 1 else 0,
                    max_lines
                );

                var line_iter = LineIterator.init(self.buffer);

                // dirty開始行までスキップ
                var skip_count: usize = 0;
                const skip_to = self.top_line + render_start;
                while (skip_count < skip_to) : (skip_count += 1) {
                    const line = try line_iter.nextLine(term.allocator) orelse break;
                    term.allocator.free(line);
                }

                // dirty範囲を描画
                var screen_row = render_start;
                while (screen_row < render_end) : (screen_row += 1) {
                    try self.renderLine(term, screen_row, &line_iter);
                }
            }

            self.clearDirty();
        }

        // ステータスバーの描画
        try self.renderStatusBar(term);

        // カーソルを表示
        try term.moveCursor(self.cursor_y, self.cursor_x);
        try term.showCursor();
        try term.flush();
    }

    fn renderStatusBar(self: *View, term: *Terminal) !void {
        try term.moveCursor(term.height - 1, 0);

        var status_buf: [256]u8 = undefined;
        const lines = self.buffer.lineCount();
        const status = try std.fmt.bufPrint(
            &status_buf,
            " ze | Line {d}/{d} | Pos {d},{d}",
            .{ self.top_line + self.cursor_y + 1, lines, self.cursor_y + 1, self.cursor_x + 1 },
        );

        // ステータスバーを反転表示
        try term.write("\x1b[7m");
        try term.write(status);

        // 残りの部分を空白で埋める（underflow防止）
        const padding = if (status.len < term.width) term.width - status.len else 0;
        for (0..padding) |_| {
            try term.write(" ");
        }
        try term.write("\x1b[m");
    }

    pub fn getCursorBufferPos(self: *const View) usize {
        var pos: usize = 0;
        var line: usize = 0;
        const target_line = self.top_line + self.cursor_y;

        var iter = PieceIterator.init(self.buffer);

        // 目標行まで進める
        while (line < target_line) {
            const ch = iter.next() orelse return pos;
            if (ch == '\n') line += 1;
        }

        // 現在の位置を記録
        pos = iter.global_pos;

        // 行内の位置を追加（grapheme cluster単位で処理）
        var col: usize = 0;
        while (col < self.cursor_x) {
            const start_pos = iter.global_pos;
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster == null) break;
            const gc = cluster.?;
            if (gc.base == '\n') break;

            // 文字幅を加算
            col += gc.width;

            // 目標カーソル位置を超えた場合は手前で止まる
            if (col > self.cursor_x) {
                // イテレータを元の位置に戻す
                iter.global_pos = start_pos;
                break;
            }
        }

        return @min(iter.global_pos, self.buffer.len());
    }

    // 現在行の表示幅を取得（grapheme cluster単位）
    fn getCurrentLineWidth(self: *const View) usize {
        var iter = PieceIterator.init(self.buffer);
        var line: usize = 0;
        const target_line = self.top_line + self.cursor_y;

        // 目標行まで進める
        while (line < target_line) {
            const ch = iter.next() orelse return 0;
            if (ch == '\n') line += 1;
        }

        // 行の表示幅を計算
        var line_width: usize = 0;
        while (true) {
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                line_width += gc.width;
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
            while (iter.global_pos < pos) {
                const cluster = iter.nextGraphemeCluster() catch {
                    _ = iter.next();
                    last_width = 1;
                    continue;
                };
                if (cluster) |gc| {
                    if (gc.base == '\n') break;
                    last_width = gc.width;
                    if (iter.global_pos >= pos) break;
                }
            }

            if (self.cursor_x >= last_width) {
                self.cursor_x -= last_width;
            } else {
                self.cursor_x = 0;
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
        }
    }

    pub fn moveCursorRight(self: *View, term: *Terminal) void {
        const pos = self.getCursorBufferPos();
        if (pos >= self.buffer.len()) return;

        // 現在位置のgrapheme clusterを取得
        var iter = PieceIterator.init(self.buffer);
        while (iter.global_pos < pos) {
            _ = iter.next();
        }

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
            } else {
                // grapheme clusterの幅分進める
                self.cursor_x += gc.width;
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
    }

    pub fn moveCursorDown(self: *View, term: *Terminal) void {
        if (self.cursor_y < term.height - 2 and self.top_line + self.cursor_y + 1 < self.buffer.lineCount()) {
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
    }

    pub fn moveToLineStart(self: *View) void {
        self.cursor_x = 0;
    }

    pub fn moveToLineEnd(self: *View) void {
        // 現在行の幅を計算（grapheme cluster単位）
        var iter = PieceIterator.init(self.buffer);
        var line: usize = 0;
        const target_line = self.top_line + self.cursor_y;

        // 目標行まで進める
        while (line < target_line) {
            const ch = iter.next() orelse {
                self.cursor_x = 0;
                return;
            };
            if (ch == '\n') line += 1;
        }

        // 行の表示幅を計算
        var line_width: usize = 0;
        while (true) {
            const cluster = iter.nextGraphemeCluster() catch break;
            if (cluster) |gc| {
                if (gc.base == '\n') break;
                line_width += gc.width;
            } else {
                break;
            }
        }

        self.cursor_x = line_width;
    }
};
