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
const unicode = @import("unicode");
const config = @import("config");
const encoding = @import("encoding");

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
    // seek()キャッシュ: 前回seekした位置からの探索を高速化
    last_sought_pos: usize,
    last_sought_piece_idx: usize,
    last_sought_piece_start: usize, // pieceの開始位置も保存

    pub fn init(buffer: *const Buffer) PieceIterator {
        return .{
            .buffer = buffer,
            .piece_idx = 0,
            .piece_offset = 0,
            .global_pos = 0,
            .last_sought_pos = 0,
            .last_sought_piece_idx = 0,
            .last_sought_piece_start = 0,
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
            return first_byte; // u8→u21 自動昇格
        }

        // UTF-8のバイト数を判定
        const len = std.unicode.utf8ByteSequenceLength(first_byte) catch return error.InvalidUtf8;

        if (len == 1) {
            return first_byte; // u8→u21 自動昇格
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

    // 指定位置にシーク（キャッシュにより連続seekを高速化）
    pub fn seek(self: *PieceIterator, target_pos: usize) void {
        if (target_pos == 0) {
            self.piece_idx = 0;
            self.piece_offset = 0;
            self.global_pos = 0;
            self.last_sought_pos = 0;
            self.last_sought_piece_idx = 0;
            self.last_sought_piece_start = 0;
            return;
        }

        // キャッシュから開始（target_pos >= last_sought_posなら高速）
        var start_idx: usize = 0;
        var pos: usize = 0;
        if (target_pos >= self.last_sought_pos and self.last_sought_piece_idx < self.buffer.pieces.items.len) {
            start_idx = self.last_sought_piece_idx;
            pos = self.last_sought_piece_start;
        }

        for (self.buffer.pieces.items[start_idx..], start_idx..) |piece, idx| {
            if (pos + piece.length > target_pos) {
                // この piece 内に target_pos がある
                self.piece_idx = idx;
                self.piece_offset = target_pos - pos;
                self.global_pos = target_pos;
                // キャッシュを更新
                self.last_sought_pos = target_pos;
                self.last_sought_piece_idx = idx;
                self.last_sought_piece_start = pos;
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
            .last_sought_pos = self.last_sought_pos,
            .last_sought_piece_idx = self.last_sought_piece_idx,
            .last_sought_piece_start = self.last_sought_piece_start,
        };
    }

    // イテレータの状態を復元（nextGraphemeCluster内部でのみ使用）
    inline fn restoreState(self: *PieceIterator, saved: PieceIterator) void {
        self.piece_idx = saved.piece_idx;
        self.piece_offset = saved.piece_offset;
        self.global_pos = saved.global_pos;
        self.last_sought_pos = saved.last_sought_pos;
        self.last_sought_piece_idx = saved.last_sought_piece_idx;
        self.last_sought_piece_start = saved.last_sought_piece_start;
    }

    /// 現在位置から指定バイト数を効率的にコピー（スライス単位でmemcpy）
    /// バイト単位のnext()より大幅に高速
    pub fn copyBytes(self: *PieceIterator, dest: []u8) usize {
        var copied: usize = 0;
        while (copied < dest.len and self.piece_idx < self.buffer.pieces.items.len) {
            const piece = self.buffer.pieces.items[self.piece_idx];
            const remaining_in_piece = piece.length - self.piece_offset;
            const to_copy = @min(remaining_in_piece, dest.len - copied);

            // ソースバッファから直接スライスコピー
            const src_slice = switch (piece.source) {
                .original => self.buffer.original[piece.start + self.piece_offset ..][0..to_copy],
                .add => self.buffer.add_buffer.items[piece.start + self.piece_offset ..][0..to_copy],
            };
            @memcpy(dest[copied..][0..to_copy], src_slice);

            copied += to_copy;
            self.piece_offset += to_copy;
            self.global_pos += to_copy;

            // piece終端に到達したら次のpieceへ
            if (self.piece_offset >= piece.length) {
                self.piece_idx += 1;
                self.piece_offset = 0;
            }
        }
        return copied;
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


/// 行インデックス: 行番号 → バイトオフセットの高速変換を提供
///
/// 【目的】
/// Piece Tableでは行の開始位置を求めるのにO(n)の走査が必要だが、
/// 行インデックスを使えばO(1)でアクセス可能になる。
///
/// 【構造】
/// line_starts[i] = i行目の開始バイト位置
/// 例: "Hello\nWorld\n" → line_starts = [0, 6, 12]
///
/// 【インクリメンタル更新】
/// 編集時に全体を再構築するのは非効率なため、valid_until_posを使って
/// 「どこまでが有効か」を追跡。編集位置以降のみ再スキャンする。
///
/// 【パフォーマンス】
/// - 初期構築: O(n) - piece毎にmemchr（SIMD最適化済み）で改行検索
/// - 編集時更新: O(k) - 変更行以降のみ再スキャン
/// - 行番号からオフセット取得: O(1)
pub const LineIndex = struct {
    line_starts: std.ArrayList(usize), // 各行の開始バイト位置
    valid: bool, // キャッシュが有効か
    valid_until_pos: usize, // インクリメンタル更新用: この位置まで有効
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
    /// 編集位置を含む行の開始位置から再スキャンが必要
    pub fn invalidateFrom(self: *LineIndex, pos: usize) void {
        // posを含む行の開始位置をバイナリサーチで見つける（O(log n)）
        const line_start_pos = blk: {
            if (self.line_starts.items.len == 0) break :blk 0;

            var left: usize = 0;
            var right: usize = self.line_starts.items.len;
            while (left < right) {
                const mid = left + (right - left) / 2;
                if (self.line_starts.items[mid] <= pos) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
            // leftはpos以下の最大のインデックス+1を指す
            break :blk if (left > 0) self.line_starts.items[left - 1] else 0;
        };

        // valid_until_posを「posを含む行の開始位置」に設定
        // これより前の行のみ保持される
        if (!self.valid) {
            // 既に無効: より早い位置なら更新
            if (self.valid_until_pos == 0 or line_start_pos < self.valid_until_pos) {
                self.valid_until_pos = line_start_pos;
            }
        } else {
            // まだ有効: 無効化して位置を設定
            self.valid_until_pos = line_start_pos;
            self.valid = false;
        }
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

            // piece毎にmemchr（SIMD最適化済み）で改行を検索
            // バイト毎のイテレーションより高速
            var global_pos: usize = 0;
            for (buffer.pieces.items) |piece| {
                const data = buffer.getPieceData(piece);

                var search_start: usize = 0;
                while (std.mem.indexOfScalar(u8, data[search_start..], '\n')) |rel_pos| {
                    const pos_in_piece = search_start + rel_pos;
                    const newline_pos = global_pos + pos_in_piece;
                    // 改行の次の位置を記録
                    try self.line_starts.append(self.allocator, newline_pos + 1);
                    search_start = pos_in_piece + 1;
                }
                global_pos += piece.length;
            }

            self.valid = true;
            self.valid_until_pos = buffer.total_len;
            return;
        }

        // インクリメンタル更新: valid_until_pos以降のみ再スキャン
        // まずvalid_until_posより後の行エントリを削除
        // 注意: valid_until_posは「編集された行の開始位置」なので、それ以前の行は保持
        var keep_count: usize = 0;
        for (self.line_starts.items, 0..) |start, i| {
            if (start >= self.valid_until_pos) break;
            keep_count = i + 1;
        }
        self.line_starts.shrinkRetainingCapacity(keep_count);

        // valid_until_posが行の開始位置なら追加（バッファの先頭でない場合のみ）
        // invalidateFromで設定されるvalid_until_posは必ず行の開始位置
        if (self.valid_until_pos > 0 and
            (keep_count == 0 or self.line_starts.items[keep_count - 1] != self.valid_until_pos))
        {
            try self.line_starts.append(self.allocator, self.valid_until_pos);
        }

        // valid_until_posから末尾まで再スキャン（piece毎にmemchr）
        if (buffer.total_len > 0 and buffer.pieces.items.len > 0) {
            var global_pos: usize = 0;
            for (buffer.pieces.items) |piece| {
                const piece_end = global_pos + piece.length;

                // このpieceがvalid_until_pos以降を含む場合のみ処理
                if (piece_end > self.valid_until_pos) {
                    const data = buffer.getPieceData(piece);

                    // piece内の開始位置を計算
                    const start_in_piece = if (global_pos >= self.valid_until_pos) 0 else self.valid_until_pos - global_pos;

                    var search_start: usize = start_in_piece;
                    while (std.mem.indexOfScalar(u8, data[search_start..], '\n')) |rel_pos| {
                        const pos_in_piece = search_start + rel_pos;
                        const newline_pos = global_pos + pos_in_piece;
                        // 改行の次の位置を記録
                        try self.line_starts.append(self.allocator, newline_pos + 1);
                        search_start = pos_in_piece + 1;
                    }
                }
                global_pos += piece.length;
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

/// バッファの内部コンポーネント（ArrayListとLineIndex）を初期化
/// エラーハンドリングを統一し、コードの重複を削減する
fn initBufferComponents(allocator: std.mem.Allocator) !struct {
    add_buffer: std.ArrayList(u8),
    pieces: std.ArrayList(Piece),
    line_index: LineIndex,
} {
    var add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer add_buffer.deinit(allocator);

    var pieces = try std.ArrayList(Piece).initCapacity(allocator, 0);
    errdefer pieces.deinit(allocator);

    const line_index = LineIndex.init(allocator);
    // line_index.init()はアロケーションしないのでerrdefer不要

    return .{
        .add_buffer = add_buffer,
        .pieces = pieces,
        .line_index = line_index,
    };
}

/// Piece Table バッファ: テキストエディタの中核データ構造
///
/// 【概要】
/// 元ファイルを不変に保ち、編集を「追加バッファへの追記」と
/// 「ピース配列の操作」で表現する。挿入・削除がO(pieces)で高速。
///
/// 【メモリレイアウト】
/// ```
/// original:   [元ファイル内容 - 読み取り専用、mmapも可]
/// add_buffer: [挿入されたテキストを蓄積]
/// pieces:     [どのバッファのどの範囲を表示するか]
/// ```
///
/// 【mmapによるゼロコピー読み込み】
/// UTF-8 + LF のファイルはmmapで直接メモリマッピング。
/// 1GBのファイルでも実際のメモリ消費は最小限（OSがページ単位で管理）。
/// is_mmap=true の場合、deinit()でmunmap()を呼ぶ必要がある。
///
/// 【エンコーディング対応】
/// UTF-8以外のファイルは読み込み時にUTF-8に変換。
/// 保存時にdetected_encodingを参照して元の形式に復元する。
pub const Buffer = struct {
    original: []const u8, // 元ファイル内容（mmapまたはヒープ）
    add_buffer: std.ArrayList(u8), // 挿入されたテキストを蓄積
    pieces: std.ArrayList(Piece), // テキストの論理的な構成
    allocator: std.mem.Allocator,
    owns_original: bool, // originalをヒープから確保したか（free必要）
    is_mmap: bool, // originalがmmapされているか（munmap必要）
    mmap_len: usize, // mmap時のサイズ（munmap用）
    total_len: usize, // バッファ全体のバイト長
    line_index: LineIndex, // 行番号→オフセットのキャッシュ
    detected_line_ending: encoding.LineEnding, // 検出した改行コード（保存時に復元）
    detected_encoding: encoding.Encoding, // 検出したエンコーディング（保存時に復元）
    loaded_mtime: i128, // ファイル読み込み時のmtime（二重I/O削減）

    pub fn init(allocator: std.mem.Allocator) !Buffer {
        // 空のArrayListで初期化（遅延アロケーション）
        // 初回編集時に自動的に拡張される
        return Buffer{
            .original = &[_]u8{},
            .add_buffer = .{},
            .pieces = .{},
            .allocator = allocator,
            .owns_original = false,
            .is_mmap = false,
            .mmap_len = 0,
            .total_len = 0,
            .line_index = LineIndex.init(allocator),
            .detected_line_ending = .LF, // デフォルトはLF
            .detected_encoding = .UTF8, // デフォルトはUTF-8
            .loaded_mtime = 0,
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

        // ディレクトリは開けない
        if (stat.kind == .directory) {
            return error.IsDir;
        }

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

                var add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
                errdefer add_buffer.deinit(allocator);

                var pieces = try std.ArrayList(Piece).initCapacity(allocator, 0);
                errdefer pieces.deinit(allocator);

                var line_index = LineIndex.init(allocator);
                errdefer line_index.deinit();

                var self = Buffer{
                    .original = mapped,
                    .add_buffer = add_buffer,
                    .pieces = pieces,
                    .allocator = allocator,
                    .owns_original = false,
                    .is_mmap = true,
                    .mmap_len = file_size,
                    .total_len = file_size,
                    .line_index = line_index,
                    .detected_line_ending = .LF,
                    .detected_encoding = .UTF8,
                    .loaded_mtime = stat.mtime,
                };

                // 初期状態：originalファイル全体を指す1つのpiece
                try self.pieces.append(allocator, .{
                    .source = .original,
                    .start = 0,
                    .length = file_size,
                });

                // LineIndexは遅延構築（初回アクセス時に自動的に構築される）

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
            const result = try loadFromMappedContent(allocator, mapped, detected, stat.mtime);
            std.posix.munmap(mapped_ptr[0..file_size]);
            return result;
        } else |_| {
            // mmapが失敗した場合もフォールバック
            return loadFromFileFallbackWithDetection(allocator, path);
        }
    }

    /// 空ファイル用の初期化
    fn loadFromFileEmpty(allocator: std.mem.Allocator) !Buffer {
        var add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer add_buffer.deinit(allocator);

        var pieces = try std.ArrayList(Piece).initCapacity(allocator, 0);
        errdefer pieces.deinit(allocator);

        return Buffer{
            .original = &[_]u8{},
            .add_buffer = add_buffer,
            .pieces = pieces,
            .allocator = allocator,
            .owns_original = false,
            .is_mmap = false,
            .mmap_len = 0,
            .total_len = 0,
            .line_index = LineIndex.init(allocator),
            .detected_line_ending = .LF,
            .detected_encoding = .UTF8,
            .loaded_mtime = 0, // 空ファイルはmtimeなし
        };
    }

    /// mmapデータから直接変換（I/O削減版）
    fn loadFromMappedContent(allocator: std.mem.Allocator, raw_content: []const u8, detected: encoding.DetectionResult, file_mtime: i128) !Buffer {
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
        errdefer allocator.free(normalized);

        var add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer add_buffer.deinit(allocator);

        var pieces = try std.ArrayList(Piece).initCapacity(allocator, 0);
        errdefer pieces.deinit(allocator);

        var line_index = LineIndex.init(allocator);
        errdefer line_index.deinit();

        var self = Buffer{
            .original = normalized,
            .add_buffer = add_buffer,
            .pieces = pieces,
            .allocator = allocator,
            .owns_original = true,
            .is_mmap = false,
            .mmap_len = 0,
            .total_len = normalized.len,
            .line_index = line_index,
            .detected_line_ending = actual_line_ending,
            .detected_encoding = detected.encoding,
            .loaded_mtime = file_mtime,
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
    fn loadFromFileFallback(allocator: std.mem.Allocator, path: []const u8, detected: encoding.DetectionResult, file_mtime: i128) !Buffer {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const raw_content = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(raw_content);

        return loadFromMappedContent(allocator, raw_content, detected, file_mtime);
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
        errdefer allocator.free(normalized);

        var add_buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
        errdefer add_buffer.deinit(allocator);

        var pieces = try std.ArrayList(Piece).initCapacity(allocator, 0);
        errdefer pieces.deinit(allocator);

        var line_index = LineIndex.init(allocator);
        errdefer line_index.deinit();

        var self = Buffer{
            .original = normalized,
            .add_buffer = add_buffer,
            .pieces = pieces,
            .allocator = allocator,
            .owns_original = true,
            .is_mmap = false,
            .mmap_len = 0,
            .total_len = normalized.len,
            .line_index = line_index,
            .detected_line_ending = actual_line_ending,
            .detected_encoding = detected.encoding,
            .loaded_mtime = stat.mtime,
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
    /// ファイルを保存し、オプションで警告メッセージを返す
    pub fn saveToFile(self: *Buffer, path: []const u8) !?[]const u8 {
        // シンボリックリンクの場合は実際のターゲットに書き込む
        const real_path = std.fs.cwd().realpathAlloc(self.allocator, path) catch path;
        const should_free_real_path = real_path.ptr != path.ptr;
        defer if (should_free_real_path) self.allocator.free(real_path);

        // PID付きの一時ファイル名（複数インスタンスの競合防止）
        const pid = if (@import("builtin").os.tag == .linux)
            std.os.linux.getpid()
        else
            std.c.getpid();
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}.tmp", .{ real_path, pid });
        defer self.allocator.free(tmp_path);

        // 元のファイルのパーミッションと所有権を取得（存在する場合）
        var original_mode: ?std.posix.mode_t = null;
        var original_uid: ?std.posix.uid_t = null;
        var original_gid: ?std.posix.gid_t = null;

        // fstatatでuid/gidを取得
        if (std.posix.fstatat(std.fs.cwd().fd, real_path, 0)) |stat_buf| {
            original_mode = stat_buf.mode;
            original_uid = stat_buf.uid;
            original_gid = stat_buf.gid;
        } else |_| {
            // ファイルが存在しない場合は新規作成なので、デフォルト
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
                    try utf8_content.appendSlice(self.allocator, self.getPieceData(piece));
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
                // UTF-8/UTF-8_BOM: Zig 0.15の新I/O API
                // バッファを提供してシステムコール回数を削減（8KBバッファ）
                var write_buffer: [8192]u8 = undefined;
                var file_writer = file.writer(&write_buffer);
                const writer = &file_writer.interface;

                // BOM付きUTF-8の場合は先頭にBOMを書き込み
                if (self.detected_encoding == .UTF8_BOM) {
                    try writer.writeAll(&[_]u8{ 0xEF, 0xBB, 0xBF });
                }

                // 改行コード変換しながら書き込み
                if (self.detected_line_ending == .LF) {
                    // LF モードはそのまま書き込み
                    for (self.pieces.items) |piece| {
                        try writer.writeAll(self.getPieceData(piece));
                    }
                } else if (self.detected_line_ending == .CRLF) {
                    // CRLF モード: LF を CRLF に変換
                    try self.writeWithLineEnding(writer, "\r\n");
                } else if (self.detected_line_ending == .CR) {
                    // CR モード: LF を CR に変換
                    try self.writeWithLineEnding(writer, "\r");
                }

                // バッファをフラッシュ
                try writer.flush();
            }

            // 元のファイルのパーミッションを一時ファイルに適用
            if (original_mode) |mode| {
                try file.chmod(mode);
            }

            // データをディスクに同期（クラッシュ時のデータ破損を防止）
            try file.sync();
        }

        // 成功したら rename で置き換え（アトミック操作）
        try std.fs.cwd().rename(tmp_path, real_path);

        // ディレクトリをfsyncして、renameの耐久性を保証
        // （クラッシュ時にディレクトリエントリが確実に永続化されるように）
        if (std.fs.path.dirname(real_path)) |dir_path| {
            if (std.fs.cwd().openDir(dir_path, .{})) |dir| {
                var d = dir;
                defer d.close();
                std.posix.fsync(d.fd) catch {};
            } else |_| {}
        }

        // 元のファイルの所有権を復元
        // 現在のプロセスのUIDと異なる場合のみ警告の可能性がある
        const current_uid = if (@import("builtin").os.tag == .linux)
            std.os.linux.getuid()
        else
            std.c.getuid();
        var ownership_warning: ?[]const u8 = null;

        if (original_uid != null or original_gid != null) {
            // 元の所有権が現在のユーザーと異なる場合
            const needs_chown = if (original_uid) |ouid| ouid != current_uid else false;
            if (needs_chown) {
                // ファイルを再度開いてfchownで所有権を復元
                if (std.fs.cwd().openFile(real_path, .{ .mode = .read_write })) |file| {
                    defer file.close();
                    std.posix.fchown(file.handle, original_uid, original_gid) catch {
                        // 権限エラー：所有権が変更されることを警告
                        ownership_warning = "Warning: file ownership changed (permission denied for chown)";
                    };
                } else |_| {}
            }
        }
        return ownership_warning;
    }

    pub fn len(self: *const Buffer) usize {
        return self.total_len;
    }

    /// ピースのデータを取得（共通パターンの統合）
    /// 内部バッファ（original/add_buffer）への直接参照を返す
    pub inline fn getPieceData(self: *const Buffer, piece: Piece) []const u8 {
        return switch (piece.source) {
            .original => self.original[piece.start..][0..piece.length],
            .add => self.add_buffer.items[piece.start..][0..piece.length],
        };
    }

    /// LF を指定の改行文字列に変換しながら書き込み（チャンクベースで高速化）
    fn writeWithLineEnding(self: *const Buffer, writer: anytype, line_ending: []const u8) !void {
        for (self.pieces.items) |piece| {
            const data = self.getPieceData(piece);
            var chunk_start: usize = 0;
            for (data, 0..) |byte, i| {
                if (byte == '\n') {
                    if (i > chunk_start) {
                        try writer.writeAll(data[chunk_start..i]);
                    }
                    try writer.writeAll(line_ending);
                    chunk_start = i + 1;
                }
            }
            if (chunk_start < data.len) {
                try writer.writeAll(data[chunk_start..]);
            }
        }
    }

    /// 指定位置のバイトを取得（O(pieces)だが、イテレータ作成よりも軽量）
    pub fn getByteAt(self: *const Buffer, pos: usize) ?u8 {
        if (pos >= self.total_len) return null;

        var current_pos: usize = 0;
        for (self.pieces.items) |piece| {
            if (pos < current_pos + piece.length) {
                const offset = pos - current_pos;
                return switch (piece.source) {
                    .original => self.original[piece.start + offset],
                    .add => self.add_buffer.items[piece.start + offset],
                };
            }
            current_pos += piece.length;
        }
        return null;
    }

    /// 指定位置からコードポイントをデコード（イテレータなし）
    pub fn decodeCodepointAt(self: *const Buffer, pos: usize) ?u21 {
        const first_byte = self.getByteAt(pos) orelse return null;

        // ASCII
        if (unicode.isAsciiByte(first_byte)) {
            return first_byte; // u8→u21 自動昇格
        }

        // UTF-8のバイト数を判定
        const byte_len = std.unicode.utf8ByteSequenceLength(first_byte) catch return null;

        if (byte_len == 1) {
            return first_byte; // u8→u21 自動昇格
        }

        // マルチバイト文字を読み取る
        var bytes: [4]u8 = undefined;
        bytes[0] = first_byte;

        var i: usize = 1;
        while (i < byte_len) : (i += 1) {
            bytes[i] = self.getByteAt(pos + i) orelse return null;
        }

        return std.unicode.utf8Decode(bytes[0..byte_len]) catch null;
    }

    /// UTF-8文字の先頭バイト位置を探す（後方移動用）
    pub fn findUtf8CharStart(self: *const Buffer, pos: usize) usize {
        if (pos == 0) return 0;
        var test_pos = pos - 1;
        // getByteAtを使用してイテレータ作成を回避
        while (test_pos > 0) : (test_pos -= 1) {
            const byte = self.getByteAt(test_pos) orelse break;
            // UTF-8の先頭バイトかチェック（continuation byteでなければ先頭）
            if (unicode.isUtf8Start(byte)) {
                return test_pos;
            }
        }
        // pos=0もチェック
        if (self.getByteAt(0)) |byte| {
            if (unicode.isUtf8Start(byte)) {
                return 0;
            }
        }
        return 0;
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

        // total_lenを更新（エラー時はロールバック）
        self.total_len -= actual_count;
        errdefer self.total_len += actual_count;

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
        // 最適化: ArrayListを使わず直接削除（アロケーション回避）

        // 終了pieceの処理
        const end_piece = self.pieces.items[end_loc.piece_idx];
        const remove_end = (end_loc.offset == end_piece.length);
        if (!remove_end) {
            self.pieces.items[end_loc.piece_idx] = .{
                .source = end_piece.source,
                .start = end_piece.start + end_loc.offset,
                .length = end_piece.length - end_loc.offset,
            };
        }

        // 開始pieceの処理
        const start_piece = self.pieces.items[start_loc.piece_idx];
        const remove_start = (start_loc.offset == 0);
        if (!remove_start) {
            self.pieces.items[start_loc.piece_idx] = .{
                .source = start_piece.source,
                .start = start_piece.start,
                .length = start_loc.offset,
            };
        }

        // 削除範囲を計算（降順で削除して後続インデックスがずれないように）
        const first_to_remove = if (remove_start) start_loc.piece_idx else start_loc.piece_idx + 1;
        const last_to_remove = if (remove_end) end_loc.piece_idx else end_loc.piece_idx - 1;

        // 削除実行（降順で削除、オーバーフロー防止）
        if (last_to_remove >= first_to_remove) {
            var i = last_to_remove;
            while (true) {
                _ = self.pieces.orderedRemove(i);
                if (i == first_to_remove) break;
                i -= 1;
            }
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
    // タブはデフォルト幅8で計算
    pub fn findColumnByPos(self: *Buffer, pos: usize) usize {
        return self.findColumnByPosWithTabWidth(pos, 8);
    }

    // バイト位置から列番号を計算（タブ幅指定版）
    pub fn findColumnByPosWithTabWidth(self: *Buffer, pos: usize, tab_width: u8) usize {
        const line_num = self.findLineByPos(pos);
        const line_start = self.getLineStart(line_num) orelse 0;

        if (pos <= line_start) return 0;

        // 行の開始位置からposまでの表示幅を計算
        var iter = PieceIterator.init(self);
        iter.seek(line_start);

        var col: usize = 0;
        const tw: usize = if (tab_width == 0) 8 else tab_width;
        while (iter.global_pos < pos) {
            const gc = iter.nextGraphemeCluster() catch break orelse break;
            // タブは次のタブストップまで進める
            if (gc.base == '\t') {
                col = (col / tw + 1) * tw;
            } else {
                col += gc.width; // 表示幅を加算（CJK=2, ASCII=1）
            }
        }
        return col;
    }

    // 指定範囲のテキストを取得（新しいメモリを確保）
    // start + length がバッファサイズを超える場合は error.OutOfRange
    // 最適化: スライス単位でmemcpyを使用（バイト単位ループより大幅に高速）
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

        // スライス単位でコピー（バイト単位ループより高速）
        _ = iter.copyBytes(result);

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
        // 現在の状態を保存（エラー時のロールバック用）
        const old_len = self.pieces.items.len;
        errdefer {
            // appendSliceが失敗した場合、元のピースは既にクリアされている
            // total_lenも更新されているため、0に設定して整合性を保つ
            if (self.pieces.items.len == 0 and old_len > 0) {
                self.total_len = 0;
            }
        }

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

    /// 検索結果（マッチした位置と長さ）
    pub const SearchMatch = struct {
        start: usize, // マッチ開始位置（バイトオフセット）
        len: usize, // マッチした長さ（バイト数）
    };

    /// 前方検索（ゼロコピー、piece毎処理）
    ///
    /// 【アルゴリズム】
    /// 1. 各piece内でstd.mem.indexOf()を使用（SIMD最適化済み）
    /// 2. piece境界をまたぐマッチも検出（overlap検査）
    ///
    /// 【パフォーマンス】
    /// - バッファ全体をコピーせずに検索可能
    /// - memchr/memcmpはCPUのSIMD命令を活用
    /// - 1GB/s以上の検索速度を実現
    pub fn searchForward(self: *const Buffer, pattern: []const u8, start_pos: usize) ?SearchMatch {
        if (pattern.len == 0 or start_pos >= self.total_len) return null;

        // piece毎にstd.mem.indexOfを使用（SIMD最適化済み）
        // piece境界をまたぐマッチにも対応
        var global_pos: usize = 0;
        var search_from = start_pos;

        for (self.pieces.items) |piece| {
            const piece_end = global_pos + piece.length;

            // このpieceがsearch_fromを含む場合のみ検索
            if (piece_end > search_from) {
                const data = self.getPieceData(piece);

                // piece内の開始位置
                const start_in_piece = if (global_pos >= search_from) 0 else search_from - global_pos;

                // piece内で検索
                if (std.mem.indexOf(u8, data[start_in_piece..], pattern)) |rel_pos| {
                    const match_pos = global_pos + start_in_piece + rel_pos;
                    return .{ .start = match_pos, .len = pattern.len };
                }

                // piece境界をまたぐマッチをチェック
                // パターンがpiece末尾から始まる可能性がある場合
                if (pattern.len > 1 and piece.length >= 1) {
                    const overlap_start = if (piece.length >= pattern.len - 1)
                        piece.length - (pattern.len - 1)
                    else
                        0;

                    // overlap部分を次のpieceと結合してチェック
                    const overlap_data = data[overlap_start..];
                    if (overlap_data.len > 0 and overlap_data.len < pattern.len) {
                        // 境界マッチの候補がある場合、バイト単位でチェック
                        var iter = PieceIterator.init(self);
                        const check_start = global_pos + overlap_start;
                        if (check_start >= search_from) {
                            iter.seek(check_start);
                            var match_idx: usize = 0;
                            var match_start: usize = check_start;
                            const max_check = pattern.len;
                            var checked: usize = 0;

                            while (checked < max_check) : (checked += 1) {
                                const byte = iter.next() orelse break;
                                if (byte == pattern[match_idx]) {
                                    if (match_idx == 0) match_start = iter.global_pos - 1;
                                    match_idx += 1;
                                    if (match_idx == pattern.len) {
                                        return .{ .start = match_start, .len = pattern.len };
                                    }
                                } else {
                                    break;
                                }
                            }
                        }
                    }
                }

                // 次のpieceからの検索開始位置を更新
                search_from = piece_end;
            }

            global_pos = piece_end;
        }

        return null;
    }

    /// 後方検索（コピーなし）
    /// 効率のため、チャンク単位で読み取って検索
    pub fn searchBackward(self: *const Buffer, pattern: []const u8, start_pos: usize) ?SearchMatch {
        if (pattern.len == 0) return null;

        const search_end = @min(start_pos, self.total_len);
        if (search_end < pattern.len) return null;

        // piece毎にstd.mem.lastIndexOfを使用して後方検索（O(n)）
        // pieceを逆順に走査し、各piece内でlastIndexOfを使う
        const pieces = self.pieces.items;
        if (pieces.len == 0) return null;

        // 各pieceの終了位置を計算しながら、search_endを含むpieceを特定
        var piece_ends: [256]usize = undefined; // 小さい固定バッファ（大きい場合はフォールバック）
        const use_stack_buf = pieces.len <= 256;

        if (use_stack_buf) {
            var cumulative: usize = 0;
            for (pieces, 0..) |piece, i| {
                cumulative += piece.length;
                piece_ends[i] = cumulative;
            }
        }

        // search_endを含むpieceのインデックスを見つける
        var piece_start: usize = 0;
        var start_piece_idx: usize = pieces.len;
        {
            var cumulative: usize = 0;
            for (pieces, 0..) |piece, i| {
                if (cumulative + piece.length >= search_end) {
                    start_piece_idx = i;
                    piece_start = cumulative;
                    break;
                }
                cumulative += piece.length;
            }
        }

        if (start_piece_idx >= pieces.len) {
            // search_endがバッファ外
            if (pieces.len > 0) {
                start_piece_idx = pieces.len - 1;
                piece_start = if (use_stack_buf and start_piece_idx > 0)
                    piece_ends[start_piece_idx - 1]
                else blk: {
                    var sum: usize = 0;
                    for (pieces[0..start_piece_idx]) |p| sum += p.length;
                    break :blk sum;
                };
            } else {
                return null;
            }
        }

        // 逆順にpieceを走査
        var current_piece_idx: usize = start_piece_idx;
        var current_piece_start: usize = piece_start;

        while (true) {
            const piece = pieces[current_piece_idx];
            const data = self.getPieceData(piece);

            // このpiece内での検索範囲を決定
            const search_limit = if (current_piece_idx == start_piece_idx)
                search_end - current_piece_start
            else
                piece.length;

            if (search_limit >= pattern.len) {
                // piece内で後方検索
                if (std.mem.lastIndexOf(u8, data[0..search_limit], pattern)) |rel_pos| {
                    const global_pos = current_piece_start + rel_pos;
                    // マッチがpiece境界をまたがないか確認
                    if (rel_pos + pattern.len <= piece.length) {
                        return .{ .start = global_pos, .len = pattern.len };
                    }
                    // 境界またぎの場合、実際にマッチするか確認
                    if (self.verifyMatch(global_pos, pattern)) {
                        return .{ .start = global_pos, .len = pattern.len };
                    }
                }
            }

            // 前のpieceへ
            if (current_piece_idx == 0) break;
            current_piece_idx -= 1;
            // 前のpieceの開始位置 = 現在位置 - 前のpieceの長さ（O(1)）
            current_piece_start -= pieces[current_piece_idx].length;

            // piece境界をまたぐパターンのチェック
            // 前のpieceの末尾 + 現在のpieceの先頭でマッチする可能性
            if (current_piece_idx + 1 < pieces.len) {
                const piece_len = pieces[current_piece_idx].length;
                // パターンがpiece長+1より長い場合、境界マッチは不可能（アンダーフロー防止）
                if (piece_len + 1 >= pattern.len) {
                    const boundary_start = current_piece_start + piece_len - pattern.len + 1;
                    if (boundary_start < current_piece_start + piece_len) {
                        const check_start = @max(boundary_start, current_piece_start);
                        var check_pos = current_piece_start + piece_len - 1;
                        while (check_pos >= check_start) {
                            // パターン長以上の位置でのみマッチ可能（アンダーフロー防止）
                            if (check_pos + 1 >= pattern.len) {
                                if (self.verifyMatch(check_pos - pattern.len + 1, pattern)) {
                                    const match_pos = check_pos - pattern.len + 1;
                                    if (match_pos + pattern.len <= search_end) {
                                        return .{ .start = match_pos, .len = pattern.len };
                                    }
                                }
                            }
                            if (check_pos == 0 or check_pos == check_start) break;
                            check_pos -= 1;
                        }
                    }
                }
            }
        }

        return null;
    }

    /// 指定位置からパターンが一致するか確認（piece境界またぎ対応）
    fn verifyMatch(self: *const Buffer, pos: usize, pattern: []const u8) bool {
        var iter = PieceIterator.init(self);
        iter.seek(pos);

        for (pattern) |expected| {
            const actual = iter.next() orelse return false;
            if (actual != expected) return false;
        }
        return true;
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
        const data = self.getPieceData(first_piece);
        return data[0..@min(data.len, max_len)];
    }
};
