const std = @import("std");
const unicode = @import("unicode.zig");

pub const PieceSource = enum {
    original,
    add,
};

pub const Piece = struct {
    source: PieceSource,
    start: usize,
    length: usize,
};

pub const PieceIterator = struct {
    buffer: *const Buffer,
    piece_idx: usize,
    piece_offset: usize,
    global_pos: usize,

    pub fn init(buffer: *const Buffer) PieceIterator {
        return .{
            .buffer = buffer,
            .piece_idx = 0,
            .piece_offset = 0,
            .global_pos = 0,
        };
    }

    pub fn next(self: *PieceIterator) ?u8 {
        while (self.piece_idx < self.buffer.pieces.items.len) {
            const piece = self.buffer.pieces.items[self.piece_idx];

            if (self.piece_offset < piece.length) {
                const ch = switch (piece.source) {
                    .original => self.buffer.original[piece.start + self.piece_offset],
                    .add => self.buffer.add_buffer.items[piece.start + self.piece_offset],
                };
                self.piece_offset += 1;
                self.global_pos += 1;
                return ch;
            }

            self.piece_idx += 1;
            self.piece_offset = 0;
        }

        return null;
    }

    pub fn peek(self: *const PieceIterator) ?u8 {
        if (self.piece_idx >= self.buffer.pieces.items.len) return null;

        const piece = self.buffer.pieces.items[self.piece_idx];
        if (self.piece_offset >= piece.length) return null;

        return switch (piece.source) {
            .original => self.buffer.original[piece.start + self.piece_offset],
            .add => self.buffer.add_buffer.items[piece.start + self.piece_offset],
        };
    }

    // UTF-8文字を取得（バイト単位のnextを使って構築）
    pub fn nextCodepoint(self: *PieceIterator) !?u21 {
        const first_byte = self.next() orelse return null;

        // ASCIIの場合は1バイト
        if (first_byte < 0b10000000) {
            return @as(u21, first_byte);
        }

        // UTF-8のバイト数を判定
        const len = std.unicode.utf8ByteSequenceLength(first_byte) catch return error.InvalidUtf8;

        if (len == 1) {
            return @as(u21, first_byte);
        }

        // 残りのバイトを読み取る
        var bytes: [4]u8 = undefined;
        bytes[0] = first_byte;

        var i: usize = 1;
        while (i < len) : (i += 1) {
            bytes[i] = self.next() orelse return error.InvalidUtf8;
        }

        return std.unicode.utf8Decode(bytes[0..len]) catch return error.InvalidUtf8;
    }

    // 指定位置にシーク（O(pieces)で効率的）
    pub fn seek(self: *PieceIterator, target_pos: usize) void {
        if (target_pos == 0) {
            self.piece_idx = 0;
            self.piece_offset = 0;
            self.global_pos = 0;
            return;
        }

        var pos: usize = 0;
        for (self.buffer.pieces.items, 0..) |piece, idx| {
            if (pos + piece.length > target_pos) {
                // この piece 内に target_pos がある
                self.piece_idx = idx;
                self.piece_offset = target_pos - pos;
                self.global_pos = target_pos;
                return;
            }
            pos += piece.length;
        }

        // target_pos が EOF を超える場合は EOF に移動
        self.piece_idx = self.buffer.pieces.items.len;
        self.piece_offset = 0;
        self.global_pos = self.buffer.len();
    }

    // イテレータの状態を保存（nextGraphemeCluster内部でのみ使用）
    inline fn saveState(self: *const PieceIterator) PieceIterator {
        return PieceIterator{
            .buffer = self.buffer,
            .piece_idx = self.piece_idx,
            .piece_offset = self.piece_offset,
            .global_pos = self.global_pos,
        };
    }

    // イテレータの状態を復元（nextGraphemeCluster内部でのみ使用）
    inline fn restoreState(self: *PieceIterator, saved: PieceIterator) void {
        self.piece_idx = saved.piece_idx;
        self.piece_offset = saved.piece_offset;
        self.global_pos = saved.global_pos;
    }

    // Grapheme cluster全体をスキップ（完全なUnicode対応）
    // ziglyphのアルゴリズムを使用
    pub fn nextGraphemeCluster(self: *PieceIterator) !?struct { base: u21, width: usize, byte_len: usize } {
        const start_pos = self.global_pos;

        // 最初のcodepoint
        const first_cp = try self.nextCodepoint() orelse return null;
        const base_cp = first_cp;

        // Grapheme break判定用のstate
        var state = unicode.State{};

        // graphemeBreakがtrueを返すまでループ
        var prev_cp = first_cp;
        while (true) {
            const saved_state = self.saveState();
            const next_cp = try self.nextCodepoint() orelse break;

            if (unicode.graphemeBreak(prev_cp, next_cp, &state)) {
                // Break発生、巻き戻して終了
                self.restoreState(saved_state);
                break;
            }

            // 継続（next_cpは grapheme clusterの一部）
            prev_cp = next_cp;
        }

        // 幅の計算（最初のcodepointの幅、残りは幅0のはず）
        const total_width = Buffer.charWidth(base_cp);

        return .{
            .base = base_cp,
            .width = total_width,
            .byte_len = self.global_pos - start_pos,
        };
    }
};


// 行キャッシュ: 各行の開始バイト位置を記録してO(1)アクセス
pub const LineIndex = struct {
    line_starts: std.ArrayList(usize),
    valid: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LineIndex {
        return .{
            .line_starts = .{},
            .valid = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LineIndex) void {
        self.line_starts.deinit(self.allocator);
    }

    pub fn invalidate(self: *LineIndex) void {
        self.valid = false;
    }

    pub fn rebuild(self: *LineIndex, buffer: *const Buffer) !void {
        self.line_starts.clearRetainingCapacity();
        errdefer {
            self.valid = false;
            self.line_starts.clearRetainingCapacity();
        }

        // 空バッファの場合は line_starts = [0] （1行とカウント）
        try self.line_starts.append(self.allocator, 0);

        // 各改行の次の位置を記録
        var iter = PieceIterator.init(buffer);
        while (iter.next()) |ch| {
            if (ch == '\n') {
                try self.line_starts.append(self.allocator, iter.global_pos);
            }
        }

        // 最終行が改行で終わっていない場合、line_startsの最後は最終改行の次
        // = ファイル末尾になる。これでlineCount()と整合する
        self.valid = true;
    }

    pub fn getLineStart(self: *const LineIndex, line_num: usize) ?usize {
        if (!self.valid or line_num >= self.line_starts.items.len) return null;
        return self.line_starts.items[line_num];
    }

    pub fn lineCount(self: *const LineIndex) usize {
        if (!self.valid) return 0;
        return self.line_starts.items.len;
    }
};

pub const Buffer = struct {
    original: []const u8,
    add_buffer: std.ArrayList(u8),
    pieces: std.ArrayList(Piece),
    allocator: std.mem.Allocator,
    owns_original: bool,
    total_len: usize,
    line_index: LineIndex,

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        return Buffer{
            .original = &[_]u8{},
            .add_buffer = .{},
            .pieces = .{},
            .allocator = allocator,
            .owns_original = false,
            .total_len = 0,
            .line_index = LineIndex.init(allocator),
        };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.owns_original) {
            self.allocator.free(self.original);
        }
        self.add_buffer.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.line_index.deinit();
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Buffer {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // ファイルサイズを取得
        const stat = try file.stat();
        const content = try file.readToEndAlloc(allocator, stat.size);

        var self = Buffer{
            .original = content,
            .add_buffer = .{},
            .pieces = .{},
            .allocator = allocator,
            .owns_original = true,
            .total_len = content.len,
            .line_index = LineIndex.init(allocator),
        };

        // 初期状態：originalファイル全体を指す1つのpiece
        if (content.len > 0) {
            try self.pieces.append(allocator, .{
                .source = .original,
                .start = 0,
                .length = content.len,
            });
        }

        // LineIndexを即座に構築
        try self.line_index.rebuild(&self);

        return self;
    }

    pub fn saveToFile(self: *Buffer, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        for (self.pieces.items) |piece| {
            const data = switch (piece.source) {
                .original => self.original[piece.start .. piece.start + piece.length],
                .add => self.add_buffer.items[piece.start .. piece.start + piece.length],
            };
            try file.writeAll(data);
        }
    }

    pub fn len(self: *const Buffer) usize {
        return self.total_len;
    }

    fn findPieceAt(self: *const Buffer, pos: usize) ?struct { piece_idx: usize, offset: usize } {
        var current_pos: usize = 0;

        for (self.pieces.items, 0..) |piece, i| {
            // pos が [current_pos, current_pos + piece.length) の範囲内にあるか
            if (pos < current_pos + piece.length) {
                return .{
                    .piece_idx = i,
                    .offset = pos - current_pos,
                };
            }
            current_pos += piece.length;
        }

        return null;
    }

    pub fn insert(self: *Buffer, pos: usize, ch: u8) !void {
        try self.insertSlice(pos, &[_]u8{ch});
        // insertSlice内でinvalidateされるのでここでは不要
    }

    pub fn insertSlice(self: *Buffer, pos: usize, text: []const u8) !void {
        if (text.len == 0) return;

        // add_bufferに追加（失敗時のロールバック用に長さを記録）
        const add_start = self.add_buffer.items.len;
        errdefer self.add_buffer.shrinkRetainingCapacity(add_start);
        try self.add_buffer.appendSlice(self.allocator, text);

        const new_piece = Piece{
            .source = .add,
            .start = add_start,
            .length = text.len,
        };

        // 挿入位置が0なら先頭に追加
        if (pos == 0) {
            try self.pieces.insert(self.allocator, 0, new_piece);
            self.total_len += text.len;
            self.line_index.invalidate();
            return;
        }

        // 挿入位置が末尾なら最後に追加
        if (pos >= self.total_len) {
            try self.pieces.append(self.allocator, new_piece);
            self.total_len += text.len;
            self.line_index.invalidate();
            return;
        }

        // 挿入位置のpieceを見つける
        const location = self.findPieceAt(pos) orelse {
            try self.pieces.append(self.allocator, new_piece);
            self.total_len += text.len;
            self.line_index.invalidate();
            return;
        };

        const piece = self.pieces.items[location.piece_idx];

        // pieceの境界に挿入する場合
        if (location.offset == 0) {
            try self.pieces.insert(self.allocator, location.piece_idx, new_piece);
            self.total_len += text.len;
            self.line_index.invalidate();
            return;
        }

        if (location.offset == piece.length) {
            try self.pieces.insert(self.allocator, location.piece_idx + 1, new_piece);
            self.total_len += text.len;
            self.line_index.invalidate();
            return;
        }

        // pieceの中間に挿入する場合：pieceを分割
        const left_piece = Piece{
            .source = piece.source,
            .start = piece.start,
            .length = location.offset,
        };

        const right_piece = Piece{
            .source = piece.source,
            .start = piece.start + location.offset,
            .length = piece.length - location.offset,
        };

        // 元のpieceを削除して3つに分割（全てのinsertが成功してからtotal_len更新）
        _ = self.pieces.orderedRemove(location.piece_idx);
        try self.pieces.insert(self.allocator, location.piece_idx, right_piece);
        try self.pieces.insert(self.allocator, location.piece_idx, new_piece);
        try self.pieces.insert(self.allocator, location.piece_idx, left_piece);
        self.total_len += text.len;
        self.line_index.invalidate();
    }

    pub fn delete(self: *Buffer, pos: usize, count: usize) !void {
        if (count == 0) return;

        const actual_count = @min(count, self.total_len - pos);
        if (actual_count == 0) return;

        // total_lenを更新
        self.total_len -= actual_count;

        const end_pos = pos + actual_count;

        // 削除開始位置と終了位置のpieceを見つける
        const start_loc = self.findPieceAt(pos) orelse return;
        const end_loc = self.findPieceAt(end_pos) orelse return;

        // 同じpiece内での削除
        if (start_loc.piece_idx == end_loc.piece_idx) {
            const piece = self.pieces.items[start_loc.piece_idx];

            // piece全体を削除
            if (start_loc.offset == 0 and end_loc.offset == piece.length) {
                _ = self.pieces.orderedRemove(start_loc.piece_idx);
                self.line_index.invalidate();
                return;
            }

            // pieceの先頭から削除
            if (start_loc.offset == 0) {
                self.pieces.items[start_loc.piece_idx] = .{
                    .source = piece.source,
                    .start = piece.start + actual_count,
                    .length = piece.length - actual_count,
                };
                self.line_index.invalidate();
                return;
            }

            // pieceの末尾から削除
            if (end_loc.offset == piece.length) {
                self.pieces.items[start_loc.piece_idx] = .{
                    .source = piece.source,
                    .start = piece.start,
                    .length = start_loc.offset,
                };
                self.line_index.invalidate();
                return;
            }

            // pieceの中間から削除：2つに分割
            const left_piece = Piece{
                .source = piece.source,
                .start = piece.start,
                .length = start_loc.offset,
            };

            const right_piece = Piece{
                .source = piece.source,
                .start = piece.start + end_loc.offset,
                .length = piece.length - end_loc.offset,
            };

            _ = self.pieces.orderedRemove(start_loc.piece_idx);
            try self.pieces.insert(self.allocator, start_loc.piece_idx, right_piece);
            try self.pieces.insert(self.allocator, start_loc.piece_idx, left_piece);
            self.line_index.invalidate();
            return;
        }

        // 複数pieceにまたがる削除
        var pieces_to_remove: std.ArrayList(usize) = .{};
        defer pieces_to_remove.deinit(self.allocator);

        // 中間のpieceをすべて削除対象に
        var i = start_loc.piece_idx + 1;
        while (i < end_loc.piece_idx) : (i += 1) {
            try pieces_to_remove.append(self.allocator, i);
        }

        // 開始pieceの処理
        const start_piece = self.pieces.items[start_loc.piece_idx];
        if (start_loc.offset == 0) {
            try pieces_to_remove.append(self.allocator, start_loc.piece_idx);
        } else {
            self.pieces.items[start_loc.piece_idx] = .{
                .source = start_piece.source,
                .start = start_piece.start,
                .length = start_loc.offset,
            };
        }

        // 終了pieceの処理
        const end_piece = self.pieces.items[end_loc.piece_idx];
        if (end_loc.offset == end_piece.length) {
            try pieces_to_remove.append(self.allocator, end_loc.piece_idx);
        } else {
            self.pieces.items[end_loc.piece_idx] = .{
                .source = end_piece.source,
                .start = end_piece.start + end_loc.offset,
                .length = end_piece.length - end_loc.offset,
            };
        }

        // 後ろから削除（インデックスがずれないように）
        var j = pieces_to_remove.items.len;
        while (j > 0) {
            j -= 1;
            _ = self.pieces.orderedRemove(pieces_to_remove.items[j]);
        }
        self.line_index.invalidate();
    }

    pub fn lineCount(self: *const Buffer) usize {
        // 空バッファは1行
        if (self.len() == 0) return 1;

        var count: usize = 1;
        var iter = PieceIterator.init(self);

        while (iter.next()) |ch| {
            if (ch == '\n') count += 1;
        }

        return count;
    }

    // UTF-8文字幅を計算（unicode.zigに委譲）
    pub fn charWidth(codepoint: u21) usize {
        return unicode.displayWidth(codepoint);
    }

    // Undo/Redo用のスナップショット
    pub fn clonePieces(self: *const Buffer, allocator: std.mem.Allocator) ![]Piece {
        return try allocator.dupe(Piece, self.pieces.items);
    }

    pub fn restorePieces(self: *Buffer, pieces: []const Piece) !void {
        self.pieces.clearRetainingCapacity();
        try self.pieces.appendSlice(self.allocator, pieces);

        // total_lenを再計算（Undo/Redo後の整合性確保）
        self.total_len = 0;
        for (self.pieces.items) |piece| {
            self.total_len += piece.length;
        }

        // Undo/Redo後は行キャッシュを無効化
        self.line_index.invalidate();
    }
};
