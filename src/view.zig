const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const PieceIterator = @import("buffer.zig").PieceIterator;
const Terminal = @import("terminal.zig").Terminal;
const config = @import("config.zig");

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
            .line_buffer = .{},
            .error_msg = null,
            .prev_screen = .{},
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
    fn renderLineWithIter(self: *View, term: *Terminal, screen_row: usize, iter: *PieceIterator, line_buffer: *std.ArrayList(u8)) !void {
        // 再利用バッファをクリア
        line_buffer.clearRetainingCapacity();

        // 行末まで読み取る
        while (iter.next()) |ch| {
            if (ch == '\n') break;
            try line_buffer.append(term.allocator, ch);
        }

        // Tab展開用の一時バッファ
        var expanded_line = std.ArrayList(u8){};
        defer expanded_line.deinit(self.allocator);

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

        const new_line = expanded_line.items;

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
                // UTF-8文字境界に調整（継続バイトの途中から始まらないように）
                var start = start_raw;
                while (start > 0 and new_line[start] >= 0x80 and new_line[start] < 0xC0) {
                    // 継続バイト（0x80-0xBF）の場合は前に戻る
                    start -= 1;
                }

                // バイト位置から画面カラム位置を計算
                var screen_col: usize = 0;
                var b: usize = 0;
                while (b < start) {
                    const c = new_line[b];
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
                try term.moveCursor(screen_row, screen_col);
                try term.write(new_line[start..]);

                // 古い行の方が長い場合は残りをクリア
                if (old_line.len > new_line.len) {
                    try term.write(config.ANSI.CLEAR_LINE);
                }
            }
        } else {
            // 新しい行：全体を描画
            try term.moveCursor(screen_row, 0);
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
        const empty_line = "~";

        // 前フレームと比較
        if (screen_row < self.prev_screen.items.len) {
            const old_line = self.prev_screen.items[screen_row].items;
            if (old_line.len != 1 or old_line[0] != '~') {
                // 変更あり：描画
                try term.moveCursor(screen_row, 0);
                try term.write(config.ANSI.CLEAR_LINE);
                try term.write(empty_line);

                // 前フレームバッファ更新
                self.prev_screen.items[screen_row].clearRetainingCapacity();
                try self.prev_screen.items[screen_row].appendSlice(self.allocator, empty_line);
            }
        } else {
            // 新しい行：描画
            try term.moveCursor(screen_row, 0);
            try term.write(config.ANSI.CLEAR_LINE);
            try term.write(empty_line);

            // 前フレームバッファ追加
            var new_prev_line = std.ArrayList(u8){};
            try new_prev_line.appendSlice(self.allocator, empty_line);
            try self.prev_screen.append(self.allocator, new_prev_line);
        }
    }

    pub fn render(self: *View, term: *Terminal) !void {
        try term.hideCursor();

        const max_lines = term.height - 1;

        // 全画面再描画が必要な場合
        if (self.needs_full_redraw) {
            try term.write(config.ANSI.CURSOR_HOME); // ホーム位置

            // top_lineの開始位置を取得してイテレータを初期化
            const start_pos = self.buffer.getLineStart(self.top_line) orelse self.buffer.len();
            var iter = PieceIterator.init(self.buffer);
            iter.seek(start_pos);

            // 全画面描画 - イテレータを再利用して前進のみ
            var screen_row: usize = 0;
            while (screen_row < max_lines) : (screen_row += 1) {
                const file_line = self.top_line + screen_row;
                if (file_line < self.buffer.lineCount()) {
                    try self.renderLineWithIter(term, screen_row, &iter, &self.line_buffer);
                } else {
                    try self.renderEmptyLine(term, screen_row);
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
                    max_lines
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
                        try self.renderLineWithIter(term, screen_row, &iter, &self.line_buffer);
                    } else {
                        try self.renderEmptyLine(term, screen_row);
                    }
                }
            }

            self.clearDirty();
        }

        // ステータスバーの描画
        try self.renderStatusBar(term);

        // カーソルを表示（水平スクロールを考慮、境界チェック）
        var screen_cursor_x = if (self.cursor_x >= self.top_col) self.cursor_x - self.top_col else 0;
        // 端末幅を超えないようにクリップ
        if (screen_cursor_x >= term.width) {
            screen_cursor_x = term.width - 1;
        }
        try term.moveCursor(self.cursor_y, screen_cursor_x);
        try term.showCursor();
        try term.flush();
    }

    fn renderStatusBar(self: *View, term: *Terminal) !void {
        try term.moveCursor(term.height - 1, 0);

        var status_buf: [config.Editor.STATUS_BUF_SIZE]u8 = undefined;

        // エラーメッセージがあればそれを優先表示
        const status = if (self.error_msg) |err_msg|
            try std.fmt.bufPrint(&status_buf, " ERROR: {s}", .{err_msg})
        else blk: {
            const lines = self.buffer.lineCount();
            break :blk try std.fmt.bufPrint(
                &status_buf,
                " ze | Line {d}/{d} | Pos {d},{d}",
                .{ self.top_line + self.cursor_y + 1, lines, self.cursor_y + 1, self.cursor_x + 1 },
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

            // 文字幅を加算（絵文字は2, 通常文字は1）
            display_col += gc.width;

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
                // 行移動時は水平スクロールをリセット
                self.top_col = 0;
            } else {
                // grapheme clusterの幅分進める
                self.cursor_x += gc.width;

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
                line_width += gc.width;
            } else {
                break;
            }
        }

        self.cursor_x = line_width;
    }
};
