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
const config = @import("config");

/// ミニバッファ
pub const Minibuffer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),
    cursor: usize,
    prompt: [config.Minibuffer.MAX_PROMPT_LEN]u8,
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
    pub inline fn getPrompt(self: *const Self) []const u8 {
        return self.prompt[0..self.prompt_len];
    }

    /// 内容を取得
    pub inline fn getContent(self: *const Self) []const u8 {
        return self.buffer.items;
    }

    /// 内容があるか確認（`getContent().len > 0`の簡略化）
    pub inline fn hasContent(self: *const Self) bool {
        return self.buffer.items.len > 0;
    }

    /// 内容を設定
    pub fn setContent(self: *Self, content: []const u8) !void {
        self.buffer.clearRetainingCapacity();
        try self.buffer.appendSlice(self.allocator, content);
        self.cursor = self.buffer.items.len; // 常にバッファの実際の長さを使用
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

        const prev_pos = unicode.findPrevGraphemeStart(self.buffer.items, self.cursor);
        const delete_len = self.cursor - prev_pos;

        const items = self.buffer.items;
        std.mem.copyForwards(u8, items[prev_pos..], items[self.cursor..]);
        self.buffer.shrinkRetainingCapacity(items.len - delete_len);
        self.cursor = prev_pos;
    }

    /// カーソル位置の1文字（グラフェム）を削除（デリート）
    pub fn delete(self: *Self) void {
        if (self.cursor >= self.buffer.items.len) return;

        const next_pos = unicode.findNextGraphemeEnd(self.buffer.items, self.cursor);
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
        self.cursor = unicode.findPrevGraphemeStart(self.buffer.items, self.cursor);
    }

    /// カーソルを1文字右に移動
    pub fn moveRight(self: *Self) void {
        if (self.cursor >= self.buffer.items.len) return;
        self.cursor = unicode.findNextGraphemeEnd(self.buffer.items, self.cursor);
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
    /// movement.zigと同じ単語境界定義（getCharType）を使用（日本語対応）
    pub fn moveWordBackward(self: *Self) void {
        if (self.cursor == 0) return;
        self.normalizeCursor();
        if (self.cursor == 0) return; // 調整後の再チェック
        const items = self.buffer.items;
        var pos = self.cursor;

        // 空白・記号をスキップ
        while (pos > 0) {
            const prev = unicode.findPrevGraphemeStart(items, pos);
            const char_type = unicode.getCharTypeAt(items, prev);
            if (char_type != .space and char_type != .other) break;
            pos = prev;
        }
        // 同じ文字種をスキップ（単語の先頭まで）
        if (pos > 0) {
            const prev = unicode.findPrevGraphemeStart(items, pos);
            const word_type = unicode.getCharTypeAt(items, prev);
            pos = prev;
            while (pos > 0) {
                const next_prev = unicode.findPrevGraphemeStart(items, pos);
                if (unicode.getCharTypeAt(items, next_prev) != word_type) break;
                pos = next_prev;
            }
        }
        self.cursor = pos;
    }

    /// カーソルを1単語後に移動
    /// movement.zigと同じ単語境界定義（getCharType）を使用（日本語対応）
    pub fn moveWordForward(self: *Self) void {
        self.cursor = findNextWordEnd(self.buffer.items, self.cursor);
    }

    /// 次の単語の終端位置を返す（moveWordForward/deleteWordForward共通）
    fn findNextWordEnd(items: []const u8, start: usize) usize {
        if (start >= items.len) return start;
        var pos = start;

        // 現在の文字種を取得して、同じ種類をスキップ
        const start_type = unicode.getCharTypeAt(items, pos);
        if (start_type != .space and start_type != .other) {
            while (pos < items.len and unicode.getCharTypeAt(items, pos) == start_type) {
                pos = unicode.findNextGraphemeEnd(items, pos);
            }
        }
        // 空白・記号をスキップ
        while (pos < items.len) {
            const char_type = unicode.getCharTypeAt(items, pos);
            if (char_type != .space and char_type != .other) break;
            pos = unicode.findNextGraphemeEnd(items, pos);
        }
        return pos;
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
        const end_pos = findNextWordEnd(items, start_pos);

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
};
