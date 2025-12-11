// ============================================================================
// Piece Table バッファ実装
// ============================================================================
//
// 【Piece Tableとは】
// テキストエディタで広く使われるデータ構造。元のファイル内容を不変に保ち、
// 編集操作は「追加バッファ」への追記と「ピース配列」の操作で表現する。
//
// 【構造】
//   original: [元のファイル内容（読み取り専用、mmapも可能）]
//   add_buffer: [挿入された文字列を追記していくバッファ]
//   pieces: [{ source: original/add, start: N, length: M }, ...]
//
// 【例：「Hello World」→「Hello, Beautiful World」への編集】
//   original = "Hello World"
//   add_buffer = ", Beautiful"
//   pieces = [
//     { original, 0, 5 },    // "Hello"
//     { add, 0, 12 },        // ", Beautiful"
//     { original, 5, 6 },    // " World"
//   ]
//
// 【利点】
// - 挿入/削除がO(ピース数)で高速（ギャップバッファより安定）
// - 元ファイルをmmapすればメモリ効率が良い
// - Undo/Redoが実装しやすい（ピース配列の履歴を保持するだけ）
//
// 【LineIndex】
// 行番号 → バイトオフセットの高速変換のため、行開始位置をキャッシュ。
// 編集時に無効化され、必要に応じて再構築される（遅延評価）。
// ============================================================================

const std = @import("std");
const unicode = @import("unicode.zig");
const config = @import("config.zig");
const encoding = @import("encoding.zig");

/// ピースのソース（元ファイル or 追加バッファ）
pub const PieceSource = enum {
    original, // 元のファイル内容
    add, // 編集で追加された内容
};

/// ピース: テキストの一部分を表す
/// source + start + length で、どのバッファのどの範囲かを示す
pub const Piece = struct {
    source: PieceSource,
    start: usize, // ソースバッファ内での開始位置
    length: usize, // バイト長
};

/// バッファ内容を順次読み取るためのイテレータ
///
/// Piece Tableは複数のpieceで構成されるため、単純なスライスのように
/// 連続したメモリとしてアクセスできない。このイテレータはpiece間を
/// 自動的にまたいで、あたかも連続したバイト列のように読み取れる。
///
/// 主な機能:
/// - next(): 1バイトずつ読み取り
/// - nextCodepoint(): UTF-8コードポイント単位で読み取り
/// - nextGraphemeCluster(): グラフェムクラスタ単位で読み取り
/// - seek(): 指定位置にジャンプ
pub const PieceIterator = struct {
    buffer: *const Buffer,
    piece_idx: usize, // 現在のpiece番号
    piece_offset: usize, // 現在のpiece内でのオフセット
    global_pos: usize, // バッファ全体での位置

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

    /// 次のグラフェムクラスタを読み取る
    ///
    /// 【グラフェムクラスタとは】
    /// ユーザーが「1文字」として認識する単位。例:
    /// - "é" (e + 結合アクセント) → 1グラフェム、2コードポイント
    /// - "👨‍👩‍👧" (家族絵文字) → 1グラフェム、5コードポイント
    /// - "が" (か + 濁点) → 1グラフェム、1または2コードポイント
    ///
    /// UAX #29 (Unicode Text Segmentation) に準拠したbreak判定を使用。
    /// カーソル移動、削除、表示幅計算などで正しい文字単位を扱える。
    ///
    /// 戻り値:
    /// - base: 先頭コードポイント（表示幅計算に使用）
    /// - width: 表示幅（端末上のセル数）
    /// - byte_len: UTF-8バイト長（カーソル移動に使用）
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
        const total_width = unicode.displayWidth(base_cp);

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
    // インクリメンタル更新用: 有効な範囲の終端位置
    // valid_until_pos以降は再スキャンが必要
    valid_until_pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LineIndex {
        return .{
            // 空のArrayListを初期化（容量0なのでアロケーションなし）
            .line_starts = .{},
            .valid = false,
            .valid_until_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LineIndex) void {
        self.line_starts.deinit(self.allocator);
    }

    pub fn invalidate(self: *LineIndex) void {
        self.valid = false;
        self.valid_until_pos = 0;
    }

    /// 指定位置以降を無効化（インクリメンタル更新用）
    /// 編集位置より前のキャッシュは保持される
    pub fn invalidateFrom(self: *LineIndex, pos: usize) void {
        if (!self.valid) return; // 既に無効なら何もしない

        // posより前の行は保持
        if (pos < self.valid_until_pos) {
            self.valid_until_pos = pos;
        }
        self.valid = false;
    }

    pub fn rebuild(self: *LineIndex, buffer: *const Buffer) !void {
        errdefer self.valid = false;

        // 完全に無効（valid_until_pos == 0）なら全体を再構築
        if (self.valid_until_pos == 0) {
            self.line_starts.clearRetainingCapacity();

            // 空バッファの場合は line_starts = [0] （1行とカウント）
            try self.line_starts.append(self.allocator, 0);

            // バッファが空の場合、またはpiecesが空の場合はスキャン不要
            if (buffer.total_len == 0 or buffer.pieces.items.len == 0) {
                self.valid = true;
                self.valid_until_pos = buffer.total_len;
                return;
            }

            // 各改行の次の位置を記録
            var iter = PieceIterator.init(buffer);
            while (iter.next()) |ch| {
                if (ch == '\n') {
                    try self.line_starts.append(self.allocator, iter.global_pos);
                }
            }

            self.valid = true;
            self.valid_until_pos = buffer.total_len;
            return;
        }

        // インクリメンタル更新: valid_until_pos以降のみ再スキャン
        // まずvalid_until_pos以降の行エントリを削除
        var keep_count: usize = 0;
        for (self.line_starts.items, 0..) |start, i| {
            if (start >= self.valid_until_pos) break;
            keep_count = i + 1;
        }
        self.line_starts.shrinkRetainingCapacity(keep_count);

        // valid_until_posから末尾まで再スキャン
        if (buffer.total_len > 0 and buffer.pieces.items.len > 0) {
            var iter = PieceIterator.init(buffer);
            // valid_until_posまでスキップ
            while (iter.global_pos < self.valid_until_pos) {
                _ = iter.next() orelse break;
            }
            // 残りをスキャン
            while (iter.next()) |ch| {
                if (ch == '\n') {
                    try self.line_starts.append(self.allocator, iter.global_pos);
                }
            }
        }

        self.valid = true;
        self.valid_until_pos = buffer.total_len;
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
            .add_buffer = try std.ArrayList(u8).initCapacity(allocator, config.Buffer.INITIAL_ADD_CAPACITY),
            .pieces = try std.ArrayList(Piece).initCapacity(allocator, config.Buffer.INITIAL_PIECES_CAPACITY),
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

    /// ファイルをバッファに読み込む
    ///
    /// 【高速パス（UTF-8 + LF）】
    /// mmapでファイルをメモリマッピングし、コピーなしで直接参照。
    /// これが最も高速で、大きなファイルでもメモリ効率が良い。
    ///
    /// 【フォールバックパス】
    /// UTF-8以外のエンコーディング（UTF-16, Shift_JIS, EUC-JP等）や
    /// CRLF/CRの改行コードは、UTF-8 + LF に変換してからバッファに格納。
    /// 保存時は元のエンコーディング・改行コードに復元される。
    ///
    /// 対応エンコーディング: UTF-8, UTF-8(BOM), UTF-16LE/BE(BOM), Shift_JIS, EUC-JP
    /// 対応改行コード: LF, CRLF, CR
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

            // エンコーディングと改行コードを検出（BOM検出を先に行うため、detectEncodingを使用）
            const detected = encoding.detectEncoding(mapped);

            // バイナリファイルチェック（UTF-16等のBOM付きファイルは除外済み）
            if (detected.encoding == .Unknown) {
                std.posix.munmap(mapped_ptr[0..file_size]);
                return error.BinaryFile;
            }

            // UTF-8 + LF の場合 → mmapを直接使用（ゼロコピー高速パス）
            if (detected.encoding == .UTF8 and detected.line_ending == .LF) {
                // mmapを維持する場合のerrdefer（成功時は維持、失敗時はunmap）
                var mmap_kept = false;
                errdefer if (!mmap_kept) std.posix.munmap(mapped_ptr[0..file_size]);

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
                errdefer {
                    self.add_buffer.deinit(allocator);
                    self.pieces.deinit(allocator);
                    self.line_index.deinit();
                }

                // 初期状態：originalファイル全体を指す1つのpiece
                try self.pieces.append(allocator, .{
                    .source = .original,
                    .start = 0,
                    .length = file_size,
                });

                // LineIndexを即座に構築
                try self.line_index.rebuild(&self);

                mmap_kept = true; // 成功したのでmmapを保持
                return self;
            }

            // UTF-8 + LF以外 → mmapデータを直接変換（再読み込み不要）
            // サポート外のエンコーディングはエラー
            if (detected.encoding == .Unknown) {
                std.posix.munmap(mapped_ptr[0..file_size]);
                return error.UnsupportedEncoding;
            }

            // mmapデータから直接変換（I/O削減）
            const result = loadFromMappedContent(allocator, mapped, detected);
            std.posix.munmap(mapped_ptr[0..file_size]);
            return result;
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

    /// mmapデータから直接変換（I/O削減版）
    fn loadFromMappedContent(allocator: std.mem.Allocator, raw_content: []const u8, detected: encoding.DetectionResult) !Buffer {
        // UTF-8に変換（BOM削除、UTF-16デコード等）
        const utf8_content = try encoding.convertToUtf8(allocator, raw_content, detected.encoding);
        defer allocator.free(utf8_content);

        // UTF-16の場合、改行検出は変換後のUTF-8で行う（元のバイト列では検出できない）
        const actual_line_ending = if (detected.encoding == .UTF16LE_BOM or detected.encoding == .UTF16BE_BOM)
            encoding.detectLineEnding(utf8_content)
        else
            detected.line_ending;

        // 改行コードを正規化（LFに統一）
        const normalized = try encoding.normalizeLineEndings(allocator, utf8_content, actual_line_ending);

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
            .detected_line_ending = actual_line_ending,
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

    /// フォールバックパス: UTF-8+LF以外のファイルを変換して読み込む（mmapが使えない場合）
    fn loadFromFileFallback(allocator: std.mem.Allocator, path: []const u8, detected: encoding.DetectionResult) !Buffer {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const raw_content = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(raw_content);

        return loadFromMappedContent(allocator, raw_content, detected);
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

        // UTF-16の場合、改行検出は変換後のUTF-8で行う
        const actual_line_ending = if (detected.encoding == .UTF16LE_BOM or detected.encoding == .UTF16BE_BOM)
            encoding.detectLineEnding(utf8_content)
        else
            detected.line_ending;

        const normalized = try encoding.normalizeLineEndings(allocator, utf8_content, actual_line_ending);

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
            .detected_line_ending = actual_line_ending,
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

    /// バッファをファイルに保存
    ///
    /// 【アトミックセーブ】
    /// 1. 一時ファイル (.tmp) に書き込み
    /// 2. 成功したら rename で置き換え
    /// これによりクラッシュ時にもファイルが壊れない（元ファイルか新ファイルのどちらか）
    ///
    /// 【エンコーディング・改行コード復元】
    /// バッファ内部は常にUTF-8 + LF。保存時に元のエンコーディングと
    /// 改行コードに変換する（detected_encoding, detected_line_ending を使用）
    ///
    /// 【パーミッション保持】
    /// 元ファイルのパーミッション（chmod）を新ファイルに引き継ぐ
    pub fn saveToFile(self: *Buffer, path: []const u8) !void {
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
                    // CRLF モード: LF を CRLF に変換（チャンク書き込みで高速化）
                    for (self.pieces.items) |piece| {
                        const data = switch (piece.source) {
                            .original => self.original[piece.start .. piece.start + piece.length],
                            .add => self.add_buffer.items[piece.start .. piece.start + piece.length],
                        };
                        var chunk_start: usize = 0;
                        for (data, 0..) |byte, i| {
                            if (byte == '\n') {
                                // \n の前までを書き込み
                                if (i > chunk_start) {
                                    try file.writeAll(data[chunk_start..i]);
                                }
                                // \r\n を書き込み
                                try file.writeAll("\r\n");
                                chunk_start = i + 1;
                            }
                        }
                        // 残りのチャンクを書き込み
                        if (chunk_start < data.len) {
                            try file.writeAll(data[chunk_start..]);
                        }
                    }
                } else if (self.detected_line_ending == .CR) {
                    // CR モード: LF を CR に変換（チャンク書き込みで高速化）
                    for (self.pieces.items) |piece| {
                        const data = switch (piece.source) {
                            .original => self.original[piece.start .. piece.start + piece.length],
                            .add => self.add_buffer.items[piece.start .. piece.start + piece.length],
                        };
                        var chunk_start: usize = 0;
                        for (data, 0..) |byte, i| {
                            if (byte == '\n') {
                                // \n の前までを書き込み
                                if (i > chunk_start) {
                                    try file.writeAll(data[chunk_start..i]);
                                }
                                // \r を書き込み
                                try file.writeAll("\r");
                                chunk_start = i + 1;
                            }
                        }
                        // 残りのチャンクを書き込み
                        if (chunk_start < data.len) {
                            try file.writeAll(data[chunk_start..]);
                        }
                    }
                }
            }

            // 元のファイルのパーミッションを一時ファイルに適用
            if (original_mode) |mode| {
                try file.chmod(mode);
            }

            // データをディスクに同期（クラッシュ時のデータ破損を防止）
            try file.sync();
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

    /// 指定位置にテキストを挿入
    ///
    /// 【Piece Tableでの挿入】
    /// 1. add_buffer（追加バッファ）に新しいテキストを追記
    /// 2. 挿入位置でpieceを分割（必要な場合）
    /// 3. 新しいpieceを作成して配列に追加
    ///
    /// 例: "Hello World" の位置5に ", Beautiful" を挿入
    ///   Before: [{ original, 0, 11 }]  → "Hello World"
    ///   After:  [{ original, 0, 5 },   → "Hello"
    ///           { add, 0, 12 },        → ", Beautiful"
    ///           { original, 5, 6 }]    → " World"
    ///
    /// 元のテキストは変更されず、pieceの構成だけが変わる。
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
            self.line_index.invalidateFrom(pos);
            return;
        }

        // 挿入位置が末尾なら最後に追加
        // pos == total_len は許可するが、それを超える場合はエラー
        if (pos == self.total_len) {
            try self.pieces.append(self.allocator, new_piece);
            self.total_len += text.len;
            self.line_index.invalidateFrom(pos);
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
            self.line_index.invalidateFrom(pos);
            return;
        };

        const piece = self.pieces.items[location.piece_idx];

        // pieceの境界に挿入する場合
        if (location.offset == 0) {
            try self.pieces.insert(self.allocator, location.piece_idx, new_piece);
            self.total_len += text.len;
            self.line_index.invalidateFrom(pos);
            return;
        }

        if (location.offset == piece.length) {
            try self.pieces.insert(self.allocator, location.piece_idx + 1, new_piece);
            self.total_len += text.len;
            self.line_index.invalidateFrom(pos);
            return;
        }

        // pieceの中間に挿入する場合：pieceを分割
        // 1 pieceを3 pieceに分割するので、2つ分の追加容量が必要
        // 先に容量を確保することで、insert時のOOMによる不整合を防ぐ
        try self.pieces.ensureTotalCapacity(self.allocator, self.pieces.items.len + 2);

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

        // 元のpieceを削除して3つに分割
        // 容量は確保済みなので、以降のinsertは失敗しない
        _ = self.pieces.orderedRemove(location.piece_idx);
        self.pieces.insertAssumeCapacity(location.piece_idx, right_piece);
        self.pieces.insertAssumeCapacity(location.piece_idx, new_piece);
        self.pieces.insertAssumeCapacity(location.piece_idx, left_piece);
        self.total_len += text.len;
        self.line_index.invalidateFrom(pos);
    }

    /// 指定位置から指定バイト数を削除
    ///
    /// 【Piece Tableでの削除】
    /// 元のテキストは実際には削除されない。pieceを操作して
    /// 削除範囲を「参照しない」ようにするだけ。
    ///
    /// パターン:
    /// - piece全体を削除 → pieceを配列から除去
    /// - pieceの一部を削除 → pieceを縮小または分割
    /// - 複数pieceにまたがる削除 → 各pieceを適切に処理
    ///
    /// メモリ効率: original/add_bufferは縮小しないため、
    /// 削除を繰り返してもメモリリークはないが、無駄な領域が残る。
    /// 長時間の編集後はバッファの再構築（コンパクション）が有効。
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
                self.line_index.invalidateFrom(pos);
                return;
            }

            // pieceの先頭から削除
            if (start_loc.offset == 0) {
                self.pieces.items[start_loc.piece_idx] = .{
                    .source = piece.source,
                    .start = piece.start + actual_count,
                    .length = piece.length - actual_count,
                };
                self.line_index.invalidateFrom(pos);
                return;
            }

            // pieceの末尾から削除
            if (end_loc.offset == piece.length) {
                self.pieces.items[start_loc.piece_idx] = .{
                    .source = piece.source,
                    .start = piece.start,
                    .length = start_loc.offset,
                };
                self.line_index.invalidateFrom(pos);
                return;
            }

            // pieceの中間から削除：2つに分割
            // 1 pieceを2 pieceに分割するので、1つ分の追加容量が必要
            try self.pieces.ensureTotalCapacity(self.allocator, self.pieces.items.len + 1);

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

            // 容量は確保済みなので、以降のinsertは失敗しない
            _ = self.pieces.orderedRemove(start_loc.piece_idx);
            self.pieces.insertAssumeCapacity(start_loc.piece_idx, right_piece);
            self.pieces.insertAssumeCapacity(start_loc.piece_idx, left_piece);
            self.line_index.invalidateFrom(pos);
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
        self.line_index.invalidateFrom(pos);
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

    /// 指定位置から行末位置を取得（改行の位置、またはEOF）
    pub fn findLineEndFromPos(self: *Buffer, pos: usize) usize {
        var iter = PieceIterator.init(self);
        iter.seek(pos);
        while (iter.next()) |ch| {
            if (ch == '\n') {
                return iter.global_pos - 1;
            }
        }
        return iter.global_pos;
    }

    /// 指定位置から次の改行位置を取得（改行の次の位置、またはEOF）
    pub fn findNextLineFromPos(self: *Buffer, pos: usize) usize {
        var iter = PieceIterator.init(self);
        iter.seek(pos);
        while (iter.next()) |ch| {
            if (ch == '\n') {
                return iter.global_pos;
            }
        }
        return iter.global_pos;
    }

    // バイト位置から列番号を計算（表示幅ベース）
    // 日本語やCJK文字は2カラム、ASCII文字は1カラムとして計算
    pub fn findColumnByPos(self: *Buffer, pos: usize) usize {
        const line_num = self.findLineByPos(pos);
        const line_start = self.getLineStart(line_num) orelse 0;

        if (pos <= line_start) return 0;

        // 行の開始位置からposまでの表示幅を計算
        var iter = PieceIterator.init(self);
        iter.seek(line_start);

        var col: usize = 0;
        while (iter.global_pos < pos) {
            const gc = iter.nextGraphemeCluster() catch break orelse break;
            col += gc.width; // 表示幅を加算（CJK=2, ASCII=1）
        }
        return col;
    }

    // 指定範囲のテキストを取得（新しいメモリを確保）
    // start + length がバッファサイズを超える場合は error.OutOfRange
    pub fn getRange(self: *const Buffer, allocator: std.mem.Allocator, start: usize, length: usize) ![]u8 {
        if (length == 0) {
            return try allocator.alloc(u8, 0);
        }

        // 境界チェック: 範囲がバッファサイズを超えていないか確認
        // オーバーフローを避けるため、length > total - start の形で比較
        const total = self.len();
        if (start > total) {
            return error.OutOfRange;
        }
        if (length > total - start) {
            return error.OutOfRange;
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

    /// Undo/Redo用: pieceの配列を複製してスナップショットを作成
    ///
    /// 【Piece Tableの利点 - 効率的なUndo/Redo】
    /// pieceの配列（数十〜数百要素）をコピーするだけでスナップショットが取れる。
    /// original/add_bufferは共有されるため、メモリ効率が良い。
    ///
    /// 例: 100MBのファイルでも、Undo履歴は数KB程度で済む。
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

    // ========================================
    // 検索機能（コピーなし、PieceIterator使用）
    // ========================================

    /// 検索結果
    pub const SearchMatch = struct {
        start: usize,
        len: usize,
    };

    /// 前方検索（コピーなし）
    /// PieceIteratorを使ってpiece間を跨いで検索
    pub fn searchForward(self: *const Buffer, pattern: []const u8, start_pos: usize) ?SearchMatch {
        if (pattern.len == 0 or start_pos >= self.total_len) return null;

        var iter = PieceIterator.init(self);
        iter.seek(start_pos);

        // KMPではなくシンプルな検索（パターンが短い場合に効率的）
        var match_start: usize = start_pos;
        var match_idx: usize = 0;

        while (iter.next()) |byte| {
            if (byte == pattern[match_idx]) {
                if (match_idx == 0) {
                    match_start = iter.global_pos - 1;
                }
                match_idx += 1;
                if (match_idx == pattern.len) {
                    return .{ .start = match_start, .len = pattern.len };
                }
            } else if (match_idx > 0) {
                // マッチ失敗、match_start + 1から再開
                iter.seek(match_start + 1);
                match_idx = 0;
            }
        }

        return null;
    }

    /// 後方検索（コピーなし）
    /// 効率のため、チャンク単位で読み取って検索
    pub fn searchBackward(self: *const Buffer, pattern: []const u8, start_pos: usize) ?SearchMatch {
        if (pattern.len == 0) return null;

        const search_end = @min(start_pos, self.total_len);
        if (search_end < pattern.len) return null;

        // 後方から1文字ずつ確認（シンプルな実装）
        var pos: usize = search_end;
        while (pos >= pattern.len) {
            pos -= 1;

            // この位置からパターンが一致するか確認
            var iter = PieceIterator.init(self);
            iter.seek(pos);

            var matched = true;
            for (pattern) |expected| {
                const actual = iter.next() orelse {
                    matched = false;
                    break;
                };
                if (actual != expected) {
                    matched = false;
                    break;
                }
            }

            if (matched) {
                return .{ .start = pos, .len = pattern.len };
            }

            if (pos == 0) break;
        }

        return null;
    }

    /// 前方検索（ラップアラウンド対応）
    pub fn searchForwardWrap(self: *const Buffer, pattern: []const u8, start_pos: usize) ?SearchMatch {
        // まず start_pos から検索
        if (self.searchForward(pattern, start_pos)) |match| {
            return match;
        }

        // ラップアラウンド（先頭から start_pos まで）
        if (start_pos > 0) {
            if (self.searchForward(pattern, 0)) |match| {
                if (match.start < start_pos) {
                    return match;
                }
            }
        }

        return null;
    }

    /// 後方検索（ラップアラウンド対応）
    pub fn searchBackwardWrap(self: *const Buffer, pattern: []const u8, start_pos: usize) ?SearchMatch {
        // まず start_pos まで後方検索
        if (self.searchBackward(pattern, start_pos)) |match| {
            return match;
        }

        // ラップアラウンド（末尾から start_pos まで）
        if (start_pos < self.total_len) {
            if (self.searchBackward(pattern, self.total_len)) |match| {
                if (match.start >= start_pos) {
                    return match;
                }
            }
        }

        return null;
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
