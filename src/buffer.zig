const std = @import("std");
const unicode = @import("unicode.zig");
const config = @import("config.zig");
const encoding = @import("encoding.zig");

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
        if (first_byte < config.UTF8.CONTINUATION_MASK) {
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
            // 空のArrayListを初期化（容量0なのでアロケーションなし）
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
        errdefer self.valid = false;

        // 空バッファの場合は line_starts = [0] （1行とカウント）
        try self.line_starts.append(self.allocator, 0);

        // バッファが空の場合、またはpiecesが空の場合はスキャン不要
        if (buffer.total_len == 0 or buffer.pieces.items.len == 0) {
            self.valid = true;
            return;
        }

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
    is_mmap: bool, // originalがmmapされているかどうか
    mmap_len: usize, // mmap時の実際のマッピングサイズ（munmap用）
    total_len: usize,
    line_index: LineIndex,
    detected_line_ending: encoding.LineEnding, // ファイル読み込み時に検出した改行コード
    detected_encoding: encoding.Encoding, // ファイル読み込み時に検出したエンコーディング

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        return Buffer{
            .original = &[_]u8{},
            .add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
            .pieces = try std.ArrayList(Piece).initCapacity(allocator, 0),
            .allocator = allocator,
            .owns_original = false,
            .is_mmap = false,
            .mmap_len = 0,
            .total_len = 0,
            .line_index = LineIndex.init(allocator),
            .detected_line_ending = .LF, // デフォルトはLF
            .detected_encoding = .UTF8, // デフォルトはUTF-8
        };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.is_mmap) {
            // mmapされたメモリを解放
            const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(@constCast(self.original.ptr));
            std.posix.munmap(aligned_ptr[0..self.mmap_len]);
        } else if (self.owns_original) {
            self.allocator.free(self.original);
        }
        self.add_buffer.deinit(self.allocator);
        self.pieces.deinit(self.allocator);
        self.line_index.deinit();
    }

    /// バイナリファイルかどうかを判定（NULL バイトの有無でチェック）
    fn isBinaryFile(content: []const u8) bool {
        // 最初の8KBをチェック（全体をチェックすると大きいファイルで遅い）
        const check_size = @min(content.len, 8192);
        for (content[0..check_size]) |byte| {
            if (byte == 0) return true;
        }
        return false;
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Buffer {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // ファイルサイズを取得
        const stat = try file.stat();
        const file_size = stat.size;

        // 空ファイルの場合は特別処理（mmapできない）
        if (file_size == 0) {
            return loadFromFileEmpty(allocator);
        }

        // まずmmapを試みる（読み取り専用）
        const mmap_result = std.posix.mmap(
            null,
            file_size,
            std.posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );

        if (mmap_result) |mapped_ptr| {
            const mapped: []const u8 = mapped_ptr[0..file_size];

            // バイナリファイルチェック
            if (encoding.isBinaryContent(mapped)) {
                std.posix.munmap(mapped_ptr[0..file_size]);
                return error.BinaryFile;
            }

            // エンコーディングと改行コードを検出
            const detected = encoding.detectEncoding(mapped);

            // UTF-8 + LF の場合 → mmapを直接使用（ゼロコピー高速パス）
            if (detected.encoding == .UTF8 and detected.line_ending == .LF) {
                var self = Buffer{
                    .original = mapped,
                    .add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
                    .pieces = try std.ArrayList(Piece).initCapacity(allocator, 0),
                    .allocator = allocator,
                    .owns_original = false,
                    .is_mmap = true,
                    .mmap_len = file_size,
                    .total_len = file_size,
                    .line_index = LineIndex.init(allocator),
                    .detected_line_ending = .LF,
                    .detected_encoding = .UTF8,
                };

                // 初期状態：originalファイル全体を指す1つのpiece
                try self.pieces.append(allocator, .{
                    .source = .original,
                    .start = 0,
                    .length = file_size,
                });

                // LineIndexを即座に構築
                try self.line_index.rebuild(&self);

                return self;
            }

            // UTF-8 + LF以外 → mmapを解放してフォールバックパスへ
            std.posix.munmap(mapped_ptr[0..file_size]);

            // サポート外のエンコーディングはエラー
            if (detected.encoding == .Unknown) {
                return error.UnsupportedEncoding;
            }

            // フォールバック: ファイルを読み直して変換
            return loadFromFileFallback(allocator, path, detected);
        } else |_| {
            // mmapが失敗した場合もフォールバック
            return loadFromFileFallbackWithDetection(allocator, path);
        }
    }

    /// 空ファイル用の初期化
    fn loadFromFileEmpty(allocator: std.mem.Allocator) !Buffer {
        return Buffer{
            .original = &[_]u8{},
            .add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
            .pieces = try std.ArrayList(Piece).initCapacity(allocator, 0),
            .allocator = allocator,
            .owns_original = false,
            .is_mmap = false,
            .mmap_len = 0,
            .total_len = 0,
            .line_index = LineIndex.init(allocator),
            .detected_line_ending = .LF,
            .detected_encoding = .UTF8,
        };
    }

    /// フォールバックパス: UTF-8+LF以外のファイルを変換して読み込む
    fn loadFromFileFallback(allocator: std.mem.Allocator, path: []const u8, detected: encoding.DetectionResult) !Buffer {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const raw_content = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(raw_content);

        // UTF-8に変換（BOM削除、UTF-16デコード等）
        const utf8_content = try encoding.convertToUtf8(allocator, raw_content, detected.encoding);
        defer allocator.free(utf8_content);

        // 改行コードを正規化（LFに統一）
        const normalized = try encoding.normalizeLineEndings(allocator, utf8_content, detected.line_ending);

        var self = Buffer{
            .original = normalized,
            .add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
            .pieces = try std.ArrayList(Piece).initCapacity(allocator, 0),
            .allocator = allocator,
            .owns_original = true,
            .is_mmap = false,
            .mmap_len = 0,
            .total_len = normalized.len,
            .line_index = LineIndex.init(allocator),
            .detected_line_ending = detected.line_ending,
            .detected_encoding = detected.encoding,
        };

        if (normalized.len > 0) {
            try self.pieces.append(allocator, .{
                .source = .original,
                .start = 0,
                .length = normalized.len,
            });
        }

        try self.line_index.rebuild(&self);
        return self;
    }

    /// mmapが失敗した場合のフォールバック（検出も含む）
    fn loadFromFileFallbackWithDetection(allocator: std.mem.Allocator, path: []const u8) !Buffer {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const raw_content = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(raw_content);

        if (encoding.isBinaryContent(raw_content)) {
            return error.BinaryFile;
        }

        const detected = encoding.detectEncoding(raw_content);

        if (detected.encoding == .Unknown) {
            return error.UnsupportedEncoding;
        }

        const utf8_content = try encoding.convertToUtf8(allocator, raw_content, detected.encoding);
        defer allocator.free(utf8_content);

        const normalized = try encoding.normalizeLineEndings(allocator, utf8_content, detected.line_ending);

        var self = Buffer{
            .original = normalized,
            .add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0),
            .pieces = try std.ArrayList(Piece).initCapacity(allocator, 0),
            .allocator = allocator,
            .owns_original = true,
            .is_mmap = false,
            .mmap_len = 0,
            .total_len = normalized.len,
            .line_index = LineIndex.init(allocator),
            .detected_line_ending = detected.line_ending,
            .detected_encoding = detected.encoding,
        };

        if (normalized.len > 0) {
            try self.pieces.append(allocator, .{
                .source = .original,
                .start = 0,
                .length = normalized.len,
            });
        }

        try self.line_index.rebuild(&self);
        return self;
    }

    pub fn saveToFile(self: *Buffer, path: []const u8) !void {
        // アトミックセーブ: 一時ファイルに書き込んでから rename
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        // 元のファイルのパーミッションを取得（存在する場合）
        var original_mode: ?std.posix.mode_t = null;
        if (std.fs.cwd().statFile(path)) |stat| {
            original_mode = stat.mode;
        } else |_| {
            // ファイルが存在しない場合は新規作成なので、デフォルトパーミッション
        }

        // 一時ファイルに書き込み
        {
            var file = try std.fs.cwd().createFile(tmp_path, .{});
            errdefer {
                file.close();
                std.fs.cwd().deleteFile(tmp_path) catch {};
            }
            defer file.close();

            // UTF-16やレガシーエンコーディングの場合は一括変換が必要
            if (self.detected_encoding == .UTF16LE_BOM or
                self.detected_encoding == .UTF16BE_BOM or
                self.detected_encoding == .SHIFT_JIS or
                self.detected_encoding == .EUC_JP)
            {
                // Step 1: コンテンツをUTF-8で収集
                var utf8_content = try std.ArrayList(u8).initCapacity(self.allocator, self.total_len);
                defer utf8_content.deinit(self.allocator);

                for (self.pieces.items) |piece| {
                    const data = switch (piece.source) {
                        .original => self.original[piece.start .. piece.start + piece.length],
                        .add => self.add_buffer.items[piece.start .. piece.start + piece.length],
                    };
                    try utf8_content.appendSlice(self.allocator, data);
                }

                // Step 2: 改行コード変換（LF → CRLF/CR）
                const line_converted = try encoding.convertLineEndings(
                    self.allocator,
                    utf8_content.items,
                    self.detected_line_ending,
                );
                defer self.allocator.free(line_converted);

                // Step 3: エンコーディング変換
                const encoded = try encoding.convertFromUtf8(
                    self.allocator,
                    line_converted,
                    self.detected_encoding,
                );
                defer self.allocator.free(encoded);

                // Step 4: ファイルに書き込み
                try file.writeAll(encoded);
            } else {
                // UTF-8/UTF-8_BOM: 従来通りストリーミング書き込み
                // BOM付きUTF-8の場合は先頭にBOMを書き込み
                if (self.detected_encoding == .UTF8_BOM) {
                    try file.writeAll(&[_]u8{ 0xEF, 0xBB, 0xBF });
                }

                // 改行コード変換しながら書き込み
                if (self.detected_line_ending == .LF) {
                    // LF モードはそのまま書き込み
                    for (self.pieces.items) |piece| {
                        const data = switch (piece.source) {
                            .original => self.original[piece.start .. piece.start + piece.length],
                            .add => self.add_buffer.items[piece.start .. piece.start + piece.length],
                        };
                        try file.writeAll(data);
                    }
                } else if (self.detected_line_ending == .CRLF) {
                    // CRLF モード: LF を CRLF に変換
                    for (self.pieces.items) |piece| {
                        const data = switch (piece.source) {
                            .original => self.original[piece.start .. piece.start + piece.length],
                            .add => self.add_buffer.items[piece.start .. piece.start + piece.length],
                        };
                        for (data) |byte| {
                            if (byte == '\n') {
                                try file.writeAll("\r\n");
                            } else {
                                try file.writeAll(&[_]u8{byte});
                            }
                        }
                    }
                } else if (self.detected_line_ending == .CR) {
                    // CR モード: LF を CR に変換
                    for (self.pieces.items) |piece| {
                        const data = switch (piece.source) {
                            .original => self.original[piece.start .. piece.start + piece.length],
                            .add => self.add_buffer.items[piece.start .. piece.start + piece.length],
                        };
                        for (data) |byte| {
                            if (byte == '\n') {
                                try file.writeAll("\r");
                            } else {
                                try file.writeAll(&[_]u8{byte});
                            }
                        }
                    }
                }
            }

            // 元のファイルのパーミッションを一時ファイルに適用
            if (original_mode) |mode| {
                try file.chmod(mode);
            }
        }

        // 成功したら rename で置き換え（アトミック操作）
        try std.fs.cwd().rename(tmp_path, path);
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

        // EOF境界（pos == buffer.len()）の場合は最後のpieceの末尾を返す
        if (self.pieces.items.len > 0 and pos == current_pos) {
            const last_idx = self.pieces.items.len - 1;
            const last_piece = self.pieces.items[last_idx];
            return .{
                .piece_idx = last_idx,
                .offset = last_piece.length,
            };
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
        // pos == total_len は許可するが、それを超える場合はエラー
        if (pos == self.total_len) {
            try self.pieces.append(self.allocator, new_piece);
            self.total_len += text.len;
            self.line_index.invalidate();
            return;
        }

        // pos > total_len の場合はエラー
        if (pos > self.total_len) {
            return error.PositionOutOfBounds;
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

        // pos が範囲外の場合は何もしない
        if (pos >= self.total_len) return;

        const actual_count = @min(count, self.total_len - pos);
        if (actual_count == 0) return;

        const end_pos = pos + actual_count;

        // 削除開始位置と終了位置のpieceを見つける
        const start_loc = self.findPieceAt(pos) orelse return;
        const end_loc = self.findPieceAt(end_pos) orelse return;

        // total_lenを更新（piece操作の前に更新しても安全）
        self.total_len -= actual_count;

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
        // 後ろから削除するため、降順でインデックスを収集
        var pieces_to_remove = try std.ArrayList(usize).initCapacity(self.allocator, 0);
        defer pieces_to_remove.deinit(self.allocator);

        // 終了pieceの処理（最初に追加=最大インデックス）
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

        // 中間のpieceを降順で追加
        if (end_loc.piece_idx > start_loc.piece_idx + 1) {
            var i = end_loc.piece_idx - 1;
            while (i > start_loc.piece_idx) : (i -= 1) {
                try pieces_to_remove.append(self.allocator, i);
            }
        }

        // 開始pieceの処理（最後に追加=最小インデックス）
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

        // 既に降順なのでソート不要、そのまま削除
        for (pieces_to_remove.items) |idx| {
            _ = self.pieces.orderedRemove(idx);
        }
        self.line_index.invalidate();
    }

    // LineIndexを使った行数取得（自動rebuild）
    pub fn lineCount(self: *Buffer) usize {
        // LineIndexが無効なら再構築
        if (!self.line_index.valid) {
            self.line_index.rebuild(self) catch {
                // rebuild失敗時はフルスキャンにフォールバック
                if (self.len() == 0 or self.pieces.items.len == 0) return 1;
                var count: usize = 1;
                var iter = PieceIterator.init(self);
                while (iter.next()) |ch| {
                    if (ch == '\n') count += 1;
                }
                return count;
            };
        }

        return self.line_index.lineCount();
    }

    // LineIndexを使った行開始位置取得（自動rebuild）
    pub fn getLineStart(self: *Buffer, line_num: usize) ?usize {
        // LineIndexが無効なら再構築
        if (!self.line_index.valid) {
            self.line_index.rebuild(self) catch {
                // rebuild失敗時はnullを返す
                return null;
            };
        }

        return self.line_index.getLineStart(line_num);
    }

    // バイト位置から行番号を計算（O(log N)バイナリサーチ）
    pub fn findLineByPos(self: *Buffer, pos: usize) usize {
        // LineIndexが無効なら再構築
        if (!self.line_index.valid) {
            self.line_index.rebuild(self) catch {
                // rebuild失敗時はフォールバック（O(N)スキャン）
                if (self.pieces.items.len == 0) return 0;
                var iter = PieceIterator.init(self);
                var line: usize = 0;
                while (iter.global_pos < pos) {
                    const ch = iter.next() orelse break;
                    if (ch == '\n') line += 1;
                }
                return line;
            };
        }

        // バイナリサーチで行番号を見つける
        const line_starts = self.line_index.line_starts.items;
        if (line_starts.len == 0) return 0;

        var left: usize = 0;
        var right: usize = line_starts.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (line_starts[mid] <= pos) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        // leftは pos より大きい最初の行、なので left - 1 が pos を含む行
        return if (left > 0) left - 1 else 0;
    }

    /// 指定行の開始位置と終了位置を取得（終了位置は改行の直前または EOF）
    /// 戻り値: { .start = 行開始バイト位置, .end = 行終了バイト位置（改行含まない） }
    pub fn getLineRange(self: *Buffer, line_num: usize) ?struct { start: usize, end: usize } {
        const line_start = self.getLineStart(line_num) orelse return null;

        // 行末を探す
        var iter = PieceIterator.init(self);
        iter.seek(line_start);

        while (iter.next()) |ch| {
            if (ch == '\n') {
                return .{ .start = line_start, .end = iter.global_pos - 1 };
            }
        }
        // 改行なし（最終行またはEOF）
        return .{ .start = line_start, .end = iter.global_pos };
    }

    // バイト位置から列番号を計算（グラフェムクラスタ数）
    pub fn findColumnByPos(self: *Buffer, pos: usize) usize {
        const line_num = self.findLineByPos(pos);
        const line_start = self.getLineStart(line_num) orelse 0;

        if (pos <= line_start) return 0;

        // 行の開始位置からposまでのグラフェムクラスタ数を数える
        var iter = PieceIterator.init(self);
        iter.seek(line_start);

        var col: usize = 0;
        while (iter.global_pos < pos) {
            _ = iter.nextGraphemeCluster() catch break;
            col += 1;
        }
        return col;
    }

    // UTF-8文字幅を計算（unicode.zigに委譲）
    pub fn charWidth(codepoint: u21) usize {
        return unicode.displayWidth(codepoint);
    }

    // 指定範囲のテキストを取得（新しいメモリを確保）
    pub fn getRange(self: *const Buffer, allocator: std.mem.Allocator, start: usize, length: usize) ![]u8 {
        if (length == 0) {
            return try allocator.alloc(u8, 0);
        }

        const result = try allocator.alloc(u8, length);
        errdefer allocator.free(result);

        var iter = PieceIterator.init(self);
        iter.seek(start);

        var i: usize = 0;
        while (i < length) : (i += 1) {
            result[i] = iter.next() orelse break;
        }

        return result;
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

    /// バッファの先頭からmax_lenバイトのプレビューを取得（言語検出用）
    /// 内部バッファへの直接参照を返すのでアロケーションなし
    /// ただし、ファイルが追加バッファを跨ぐ場合はnullを返す
    pub fn getContentPreview(self: *const Buffer, max_len: usize) ?[]const u8 {
        if (self.pieces.items.len == 0) return null;

        const first_piece = self.pieces.items[0];
        const preview_len = @min(first_piece.length, max_len);

        switch (first_piece.source) {
            .original => {
                const end = first_piece.start + preview_len;
                if (end <= self.original.len) {
                    return self.original[first_piece.start..end];
                }
            },
            .add => {
                const end = first_piece.start + preview_len;
                if (end <= self.add_buffer.items.len) {
                    return self.add_buffer.items[first_piece.start..end];
                }
            },
        }
        return null;
    }
};

// 空バッファのテスト
test "empty buffer initialization" {
    const testing = std.testing;
    var buffer = try Buffer.init(testing.allocator);
    defer buffer.deinit();
    
    try testing.expectEqual(@as(usize, 0), buffer.total_len);
    try testing.expectEqual(@as(usize, 0), buffer.pieces.items.len);
    
    // lineCount を呼んでもクラッシュしないことを確認
    const lines = buffer.lineCount();
    try testing.expectEqual(@as(usize, 1), lines);
    
    // getLineStart も確認
    const start = buffer.getLineStart(0);
    try testing.expect(start != null);
    try testing.expectEqual(@as(usize, 0), start.?);
}
