// ============================================================================
// Minibuffer - ミニバッファ入力サービス
// ============================================================================
//
// 【責務】
// - コマンドライン風の1行入力
// - カーソル移動、削除、単語単位操作
// - プロンプト表示
//
// 【設計原則】
// - Editorから独立した入力バッファ管理
// - UTF-8/grapheme cluster対応
// ============================================================================

const std = @import("std");
const unicode = @import("unicode");
const input = @import("input");

/// ミニバッファ
pub const Minibuffer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    cursor: usize,
    prompt: [256]u8,
    prompt_len: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .buffer = .{},
            .cursor = 0,
            .prompt = undefined,
            .prompt_len = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    /// バッファをクリア
    pub fn clear(self: *Self) void {
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
    }

    /// プロンプトを設定
    pub fn setPrompt(self: *Self, prompt: []const u8) void {
        const len = @min(prompt.len, self.prompt.len);
        @memcpy(self.prompt[0..len], prompt[0..len]);
        self.prompt_len = len;
    }

    /// プロンプトを取得
    pub fn getPrompt(self: *const Self) []const u8 {
        return self.prompt[0..self.prompt_len];
    }

    /// 内容を取得
    pub fn getContent(self: *const Self) []const u8 {
        return self.buffer.items;
    }

    /// 内容を設定
    pub fn setContent(self: *Self, content: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, content);
        self.cursor = content.len;
    }

    /// カーソル位置を有効範囲に正規化
    fn normalizeCursor(self: *Self) void {
        if (self.cursor > self.buffer.items.len) {
            self.cursor = self.buffer.items.len;
        }
    }

    /// カーソル位置に文字を挿入
    pub fn insertAtCursor(self: *Self, text: []const u8) !void {
        if (text.len == 0) return;
        self.normalizeCursor();
        try self.buffer.insertSlice(self.allocator, self.cursor, text);
        self.cursor += text.len;
    }

    /// カーソル位置にコードポイントを挿入
    pub fn insertCodepointAtCursor(self: *Self, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.insertAtCursor(buf[0..len]);
    }

    /// カーソル前の1文字（グラフェム）を削除（バックスペース）
    pub fn backspace(self: *Self) void {
        if (self.cursor == 0) return;
        self.normalizeCursor();
        if (self.cursor == 0) return; // 調整後の再チェック

        const prev_pos = findPrevGraphemeStart(self.buffer.items, self.cursor);
        const delete_len = self.cursor - prev_pos;

        const items = self.buffer.items;
        std.mem.copyForwards(u8, items[prev_pos..], items[self.cursor..]);
        self.buffer.shrinkRetainingCapacity(items.len - delete_len);
        self.cursor = prev_pos;
    }

    /// カーソル位置の1文字（グラフェム）を削除（デリート）
    pub fn delete(self: *Self) void {
        if (self.cursor >= self.buffer.items.len) return;

        const next_pos = findNextGraphemeEnd(self.buffer.items, self.cursor);
        const delete_len = next_pos - self.cursor;

        const items = self.buffer.items;
        std.mem.copyForwards(u8, items[self.cursor..], items[next_pos..]);
        self.buffer.shrinkRetainingCapacity(items.len - delete_len);
    }

    /// カーソルを1文字左に移動
    pub fn moveLeft(self: *Self) void {
        if (self.cursor == 0) return;
        // cursor が範囲外の場合は末尾に調整して終了（移動はしない）
        if (self.cursor > self.buffer.items.len) {
            self.cursor = self.buffer.items.len;
            return;
        }
        self.cursor = findPrevGraphemeStart(self.buffer.items, self.cursor);
    }

    /// カーソルを1文字右に移動
    pub fn moveRight(self: *Self) void {
        if (self.cursor >= self.buffer.items.len) return;
        self.cursor = findNextGraphemeEnd(self.buffer.items, self.cursor);
    }

    /// カーソルを先頭に移動
    pub fn moveToStart(self: *Self) void {
        self.cursor = 0;
    }

    /// カーソルを末尾に移動
    pub fn moveToEnd(self: *Self) void {
        self.cursor = self.buffer.items.len;
    }

    /// カーソルを1単語前に移動
    pub fn moveWordBackward(self: *Self) void {
        if (self.cursor == 0) return;
        self.normalizeCursor();
        if (self.cursor == 0) return; // 調整後の再チェック
        const items = self.buffer.items;
        var pos = self.cursor;

        // 空白をスキップ
        while (pos > 0) {
            const prev = findPrevGraphemeStart(items, pos);
            if (!isWhitespaceAt(items, prev)) break;
            pos = prev;
        }
        // 単語文字をスキップ
        while (pos > 0) {
            const prev = findPrevGraphemeStart(items, pos);
            if (isWhitespaceAt(items, prev)) break;
            pos = prev;
        }
        self.cursor = pos;
    }

    /// カーソルを1単語後に移動
    pub fn moveWordForward(self: *Self) void {
        const items = self.buffer.items;
        if (self.cursor >= items.len) return;
        var pos = self.cursor;

        // 単語文字をスキップ
        while (pos < items.len) {
            if (isWhitespaceAt(items, pos)) break;
            pos = findNextGraphemeEnd(items, pos);
        }
        // 空白をスキップ
        while (pos < items.len) {
            if (!isWhitespaceAt(items, pos)) break;
            pos = findNextGraphemeEnd(items, pos);
        }
        self.cursor = pos;
    }

    /// 前の単語を削除（M-Backspace）
    pub fn deleteWordBackward(self: *Self) void {
        if (self.cursor == 0) return;
        self.normalizeCursor();
        if (self.cursor == 0) return; // 調整後の再チェック
        const start_pos = self.cursor;
        self.moveWordBackward();
        const delete_len = start_pos - self.cursor;
        if (delete_len > 0) {
            const items = self.buffer.items;
            std.mem.copyForwards(u8, items[self.cursor..], items[start_pos..]);
            self.buffer.shrinkRetainingCapacity(items.len - delete_len);
        }
    }

    /// 次の単語を削除（M-d）
    pub fn deleteWordForward(self: *Self) void {
        const items = self.buffer.items;
        if (self.cursor >= items.len) return;
        const start_pos = self.cursor;

        var end_pos = start_pos;
        // 単語文字をスキップ
        while (end_pos < items.len) {
            if (isWhitespaceAt(items, end_pos)) break;
            end_pos = findNextGraphemeEnd(items, end_pos);
        }
        // 空白をスキップ
        while (end_pos < items.len) {
            if (!isWhitespaceAt(items, end_pos)) break;
            end_pos = findNextGraphemeEnd(items, end_pos);
        }

        const delete_len = end_pos - start_pos;
        if (delete_len > 0) {
            std.mem.copyForwards(u8, items[start_pos..], items[end_pos..]);
            self.buffer.shrinkRetainingCapacity(items.len - delete_len);
        }
    }

    /// カーソルから行末まで削除（C-k）
    pub fn killLine(self: *Self) void {
        if (self.cursor >= self.buffer.items.len) return;
        self.buffer.shrinkRetainingCapacity(self.cursor);
    }

    /// 表示用のカーソル位置を取得（プロンプト含む）
    pub fn getDisplayCursorColumn(self: *const Self) usize {
        // プロンプトの表示幅を計算（バイト長ではなく表示幅）
        var col: usize = unicode.stringDisplayWidth(self.prompt[0..self.prompt_len]);
        var pos: usize = 0;
        while (pos < self.cursor and pos < self.buffer.items.len) {
            // グラフェムクラスタが取得できない場合はループ終了
            const cluster = unicode.nextGraphemeCluster(self.buffer.items[pos..]) orelse break;
            col += cluster.display_width;
            pos += cluster.byte_len;
        }
        return col;
    }

    // ========================================
    // ヘルパー関数
    // ========================================

    fn findPrevGraphemeStart(text: []const u8, pos: usize) usize {
        if (pos == 0) return 0;
        // pos が text.len を超えている場合は text.len から開始
        var p = @min(pos, text.len);
        if (p > 0) p -= 1;
        while (p > 0 and unicode.isUtf8Continuation(text[p])) {
            p -= 1;
        }
        return p;
    }

    fn findNextGraphemeEnd(text: []const u8, pos: usize) usize {
        if (pos >= text.len) return text.len;
        return @min(pos + unicode.utf8SeqLen(text[pos]), text.len);
    }

    fn isWhitespaceAt(text: []const u8, pos: usize) bool {
        if (pos >= text.len) return false;
        const c = text[pos];
        // ASCII空白
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') return true;
        // 全角スペース (U+3000 = 0xE3 0x80 0x80)
        if (c == 0xE3 and pos + 2 < text.len) {
            if (text[pos + 1] == 0x80 and text[pos + 2] == 0x80) {
                return true;
            }
        }
        return false;
    }
};
