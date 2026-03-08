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
const builtin = @import("builtin");
const unicode = @import("unicode");
const config = @import("config");
const encoding = @import("encoding");

// プラットフォーム別のgetgid実装
fn getCurrentGid() std.posix.gid_t {
    if (builtin.os.tag == .linux) {
        return std.os.linux.getgid();
    } else {
        // macOS等ではlibcのgetgidを使用
        const getgid = struct {
            extern "c" fn getgid() std.posix.gid_t;
        }.getgid;
        return getgid();
    }
}

/// SIMD最適化された改行カウント
/// 32バイト単位でベクトル処理し、大きなファイルで高速
fn countNewlinesSIMD(data: []const u8) usize {
    const Vec = @Vector(32, u8);
    const newline_vec: Vec = @splat('\n');
    const ones: Vec = @splat(1);
    const zeros: Vec = @splat(0);

    var count: usize = 0;
    var i: usize = 0;

    // 32バイト単位でSIMD処理
    while (i + 32 <= data.len) : (i += 32) {
        const chunk: Vec = data[i..][0..32].*;
        const matches = chunk == newline_vec;
        // boolベクトルを0/1のu8ベクトルに変換してから合計
        const mask = @select(u8, matches, ones, zeros);
        count += @reduce(.Add, mask);
    }

    // 残りをスカラー処理
    while (i < data.len) : (i += 1) {
        if (data[i] == '\n') count += 1;
    }

    return count;
}

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

    pub inline fn next(self: *PieceIterator) ?u8 {
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

    /// 現在位置のバイトを取得（イテレータを進めない）
    pub inline fn peekByte(self: *const PieceIterator) ?u8 {
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
        if (unicode.isAsciiByte(first_byte)) {
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

    /// 指定位置がUTF-8文字の途中であれば、文字の先頭位置を返す
    /// チャンク読み込み時の境界調整に使用
    /// pos: 調整したい位置
    /// 戻り値: 調整後の位置（UTF-8文字の先頭）
    pub fn alignToUtf8Start(self: *PieceIterator, pos: usize) usize {
        if (pos == 0) return 0;

        self.seek(pos);
        const byte = self.next() orelse return pos;

        if (!unicode.isUtf8Continuation(byte)) return pos;

        // continuation byte なので、先頭を探す（最大4バイト戻る）
        var back: usize = 1;
        while (back <= 4 and pos >= back) : (back += 1) {
            self.seek(pos - back);
            const b = self.next() orelse break;
            if (!unicode.isUtf8Continuation(b)) {
                return pos - back;
            }
        }
        return pos; // 見つからなければ元の位置を返す
    }

    /// 1バイト後方に移動して、その位置のバイトを返す
    /// カーソル左移動時の高速化に使用
    /// 戻り値: 後方に移動した位置のバイト（バッファ先頭の場合はnull）
    pub inline fn prev(self: *PieceIterator) ?u8 {
        // 先頭にいる場合
        if (self.global_pos == 0) return null;

        // piece_offsetが0より大きければ、同じpiece内で後退
        if (self.piece_offset > 0) {
            self.piece_offset -= 1;
            self.global_pos -= 1;
            const piece = self.buffer.pieces.items[self.piece_idx];
            return switch (piece.source) {
                .original => self.buffer.original[piece.start + self.piece_offset],
                .add => self.buffer.add_buffer.items[piece.start + self.piece_offset],
            };
        }

        // 前のpieceに移動（長さ0のピースをスキップ）
        while (self.piece_idx > 0) {
            self.piece_idx -= 1;
            const prev_piece = self.buffer.pieces.items[self.piece_idx];
            if (prev_piece.length > 0) {
                self.piece_offset = prev_piece.length - 1;
                self.global_pos -= 1;
                return switch (prev_piece.source) {
                    .original => self.buffer.original[prev_piece.start + self.piece_offset],
                    .add => self.buffer.add_buffer.items[prev_piece.start + self.piece_offset],
                };
            }
            // 長さ0のピースはスキップして続行
        }
        return null;
    }

    /// 1コードポイント後方に移動して、そのコードポイントを返す
    /// UTF-8の可変長を考慮して後方走査
    /// 戻り値: 後方に移動した位置のコードポイント（バッファ先頭の場合はnull）
    pub fn prevCodepoint(self: *PieceIterator) !?u21 {
        const last_byte = self.prev() orelse return null;

        // ASCIIの場合は1バイト
        if (unicode.isAsciiByte(last_byte)) {
            return last_byte;
        }

        // UTF-8 continuation byteなら、先頭バイトまで戻る
        if (unicode.isUtf8Continuation(last_byte)) {
            // 先頭バイトを探す（最大3バイト追加で戻る）
            var bytes: [4]u8 = undefined;
            var byte_count: usize = 1;
            bytes[3] = last_byte;

            while (byte_count < 4) : (byte_count += 1) {
                const b = self.prev() orelse break;
                bytes[3 - byte_count] = b;
                if (!unicode.isUtf8Continuation(b)) {
                    // 先頭バイト発見
                    break;
                }
            }

            // デコード
            // byte_count == 4 の場合、先頭バイトが見つからなかった（不正なUTF-8）
            if (byte_count >= 4) {
                return error.InvalidUtf8;
            }
            const start_idx = 4 - byte_count - 1;
            const len = std.unicode.utf8ByteSequenceLength(bytes[start_idx]) catch {
                // 不正なUTF-8: 1バイト進めて戻す
                _ = self.next();
                return error.InvalidUtf8;
            };
            // 切り詰められたシーケンスの検出（バイト数が足りない場合）
            const available_bytes = byte_count + 1; // 継続バイト + 先頭バイト
            if (available_bytes < len) {
                return error.InvalidUtf8;
            }
            return std.unicode.utf8Decode(bytes[start_idx..][0..len]) catch error.InvalidUtf8;
        }

        // 先頭バイト（continuation以外）
        const len = std.unicode.utf8ByteSequenceLength(last_byte) catch return error.InvalidUtf8;
        if (len == 1) {
            return last_byte;
        }

        // マルチバイト文字の先頭: 残りを読んでデコード
        var bytes: [4]u8 = undefined;
        bytes[0] = last_byte;
        const saved = self.saveState();
        _ = self.next(); // 現在位置を1バイト進める

        var i: usize = 1;
        while (i < len) : (i += 1) {
            bytes[i] = self.next() orelse {
                self.restoreState(saved);
                return error.InvalidUtf8;
            };
        }

        // 位置を戻す（先頭バイトの位置に）
        self.restoreState(saved);

        return std.unicode.utf8Decode(bytes[0..len]) catch error.InvalidUtf8;
    }

    /// 1グラフェムクラスタ後方に移動
    /// カーソル左移動で正確な文字単位を処理するために使用
    /// 戻り値: グラフェムクラスタ情報（バッファ先頭の場合はnull）
    /// - base: 先頭コードポイント（表示幅計算に使用）
    /// - width: 表示幅（端末上のセル数）
    /// - byte_len: UTF-8バイト長
    pub fn prevGraphemeCluster(self: *PieceIterator) !?struct { base: u21, width: usize, byte_len: usize } {
        if (self.global_pos == 0) return null;

        const end_pos = self.global_pos;

        // 最後のコードポイントを取得（後方に移動）
        const last_cp = try self.prevCodepoint() orelse return null;
        var base_cp = last_cp;

        // Grapheme break判定: 後方へ走査
        // breakが発生するまで戻り続ける
        while (self.global_pos > 0) {
            const saved = self.saveState();
            const prev_cp = try self.prevCodepoint() orelse break;

            // Grapheme breakを確認（prev_cpとbase_cpの間）
            var state = unicode.State{};
            if (unicode.graphemeBreak(prev_cp, base_cp, &state)) {
                // Break発生: savedの位置（base_cpの先頭）がグラフェムの境界
                self.restoreState(saved);
                break;
            }

            // 継続: prev_cpもグラフェムの一部、そのまま位置を維持
            base_cp = prev_cp;
            // DON'T restore - we're now at the start of prev_cp
        }

        return .{
            .base = base_cp,
            .width = unicode.displayWidth(base_cp),
            .byte_len = end_pos - self.global_pos,
        };
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

    /// 現在位置のグラフェムクラスタのバイト長を取得（最低1バイト保証）
    /// イテレータ位置を進める
    pub fn consumeGraphemeByteLen(self: *PieceIterator) usize {
        if (self.nextGraphemeCluster() catch null) |gc| return gc.byte_len;
        // フォールバック: 次のバイトのUTF-8シーケンス長
        const byte = self.next() orelse return 1;
        return std.unicode.utf8ByteSequenceLength(byte) catch 1;
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

    /// line_starts内でtargetより大きい最初のインデックスを返す（upper bound）
    fn upperBound(self: *const LineIndex, target: usize) usize {
        var left: usize = 0;
        var right: usize = self.line_starts.items.len;
        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.line_starts.items[mid] <= target) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return left;
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

    /// 挿入時のインクリメンタル更新（O(改行数 + 影響行数)）
    /// 再スキャンなしで行インデックスを更新する
    pub fn updateForInsert(self: *LineIndex, pos: usize, text: []const u8) !void {
        if (!self.valid or text.len == 0) return; // 無効または空挿入なら何もしない

        // posより後のエントリのみシフト（行頭のline_start == posは動かさない）
        const shift_start = self.upperBound(pos);
        var idx = shift_start;
        while (idx < self.line_starts.items.len) : (idx += 1) {
            self.line_starts.items[idx] += text.len;
        }

        // 挿入テキスト内の改行位置を検出して追加
        var new_lines: std.ArrayList(usize) = .{};
        defer new_lines.deinit(self.allocator);

        var i: usize = 0;
        while (std.mem.indexOfScalar(u8, text[i..], '\n')) |rel| {
            const newline_pos = pos + i + rel;
            try new_lines.append(self.allocator, newline_pos + 1); // 改行の次が行開始
            i += rel + 1;
        }

        if (new_lines.items.len > 0) {
            // 新しい行をその位置に挿入
            try self.line_starts.insertSlice(self.allocator, shift_start, new_lines.items);
        }

        self.valid_until_pos += text.len;
    }

    /// 削除時のインクリメンタル更新（O(削除行数 + 影響行数)）
    /// 再スキャンなしで行インデックスを更新する
    pub fn updateForDelete(self: *LineIndex, pos: usize, count: usize, deleted_newlines: usize) void {
        if (!self.valid or count == 0) return; // 無効なら何もしない

        const end_pos = pos + count;

        // 削除範囲内の行エントリを削除
        if (deleted_newlines > 0) {
            const remove_start = self.upperBound(pos);
            var write_idx = remove_start;
            var read_idx = remove_start;
            while (read_idx < self.line_starts.items.len) : (read_idx += 1) {
                const line_start = self.line_starts.items[read_idx];
                if (line_start <= end_pos) {
                    continue; // 削除範囲内 (pos < line_start <= end_pos): エントリを落とす
                }
                self.line_starts.items[write_idx] = line_start - count;
                write_idx += 1;
            }
            self.line_starts.shrinkRetainingCapacity(write_idx);
        } else {
            // 改行削除なし: 位置の調整のみ
            const shift_start = self.upperBound(end_pos);
            var idx = shift_start;
            while (idx < self.line_starts.items.len) : (idx += 1) {
                self.line_starts.items[idx] -= count;
            }
        }

        if (self.valid_until_pos >= count) {
            self.valid_until_pos -= count;
        } else {
            self.valid_until_pos = 0;
        }
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

    // Piece統合のための追跡情報
    // 連続した文字入力で新しいPieceを作らず、既存Pieceを延長する
    // ただし一定時間（300ms）経過で統合を打ち切り、Undo粒度を確保
    last_insert_end: ?usize, // 直前の挿入終了位置（null = 統合不可）
    last_insert_piece_idx: usize, // 直前の挿入で使用/作成したPieceのインデックス
    last_insert_time: i128, // 直前の挿入時刻（ナノ秒）

    // findPieceAt高速化用キャッシュ
    // 直近アクセス位置を記憶し、近い位置へのアクセスを高速化
    last_access_piece_idx: usize, // 直近アクセスしたPieceのインデックス
    last_access_piece_start: usize, // そのPieceの開始位置

    // 変更カウンタ（キャッシュ無効化用）
    // 編集操作ごとにインクリメント、View等がキャッシュ有効性を判定
    modification_count: usize,

    // 行数キャッシュ（O(1)でlineCount取得）
    // 挿入/削除時に改行差分で更新されるため、LineIndex.rebuildを待たない
    cached_line_count: usize,

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
            .last_insert_end = null,
            .last_insert_piece_idx = 0,
            .last_insert_time = 0,
            .last_access_piece_idx = 0,
            .last_access_piece_start = 0,
            .modification_count = 0,
            .cached_line_count = 1, // 空バッファは1行
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
            return loadFromFileEmpty(allocator, stat.mtime);
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

                var add_buffer = try std.ArrayList(u8).initCapacity(allocator, config.Buffer.ADD_BUFFER_INITIAL_CAPACITY);
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
                    .last_insert_end = null,
                    .last_insert_piece_idx = 0,
                    .last_insert_time = 0,
                    .last_access_piece_idx = 0,
                    .last_access_piece_start = 0,
                    .modification_count = 0,
                    .cached_line_count = countNewlinesSIMD(mapped) + 1,
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
            // 注: .Unknownは既に上でBinaryFileとして処理済み
            const result = try loadFromMappedContent(allocator, mapped, detected, stat.mtime);
            std.posix.munmap(mapped_ptr[0..file_size]);
            return result;
        } else |_| {
            // mmapが失敗した場合もフォールバック
            return loadFromFileFallbackWithDetection(allocator, path);
        }
    }

    /// 空ファイル用の初期化
    fn loadFromFileEmpty(allocator: std.mem.Allocator, file_mtime: i128) !Buffer {
        var add_buffer = try std.ArrayList(u8).initCapacity(allocator, config.Buffer.ADD_BUFFER_INITIAL_CAPACITY);
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
            .loaded_mtime = file_mtime,
            .last_insert_end = null,
            .last_insert_piece_idx = 0,
            .last_insert_time = 0,
            .last_access_piece_idx = 0,
            .last_access_piece_start = 0,
            .modification_count = 0,
            .cached_line_count = 1, // 空バッファは1行
        };
    }

    /// メモリ上のスライスからBufferを作成（stdin入力用）
    /// UTF-8として扱い、必要に応じて正規化（CRLF→LF等）
    pub fn loadFromSlice(allocator: std.mem.Allocator, content: []const u8) !Buffer {
        if (content.len == 0) {
            return loadFromFileEmpty(allocator, 0); // stdin入力はファイルがないのでmtime=0
        }

        // エンコーディングと改行コードを検出
        // 先頭8KBでサンプリングし、UTF-8と判定された場合は全体を再検証
        const sample_len = @min(content.len, 8192);
        var detected = encoding.detectEncoding(content[0..sample_len]);

        // サンプルがUTF-8と判定された場合、全体を検証（途中からShift_JIS等になる可能性）
        if ((detected.encoding == .UTF8 or detected.encoding == .UTF8_BOM) and content.len > sample_len) {
            // 全体のUTF-8検証（エンコーディングが途中で変わるケースを検出）
            if (!encoding.isValidUtf8(content)) {
                // UTF-8として無効 → 日本語エンコーディングを再検出
                detected = encoding.detectEncoding(content);
            }
        }

        // バイナリファイルチェック
        if (detected.encoding == .Unknown) {
            return error.BinaryFile;
        }

        // UTF-8 + LF の場合 → コンテンツをコピーして使用
        if (detected.encoding == .UTF8 and detected.line_ending == .LF) {
            const copied = try allocator.dupe(u8, content);
            return createBufferFromContent(allocator, copied, .LF, .UTF8, 0);
        }

        // UTF-8でCRLF/CRの場合 → LFに正規化
        if (detected.encoding == .UTF8) {
            const normalized = try encoding.normalizeLineEndings(allocator, content, detected.line_ending);
            return createBufferFromContent(allocator, normalized, detected.line_ending, .UTF8, 0);
        }

        // 非UTF-8エンコーディング → UTF-8に変換
        const utf8_content = try encoding.convertToUtf8(allocator, content, detected.encoding);
        errdefer allocator.free(utf8_content);

        // 改行コードを正規化
        if (detected.line_ending != .LF) {
            const normalized = try encoding.normalizeLineEndings(allocator, utf8_content, detected.line_ending);
            allocator.free(utf8_content);
            return createBufferFromContent(allocator, normalized, detected.line_ending, detected.encoding, 0);
        }

        return createBufferFromContent(allocator, utf8_content, detected.line_ending, detected.encoding, 0);
    }

    /// UTF-8正規化済みコンテンツからBufferを作成（共通処理）
    /// 注: normalizedの所有権を取得する。失敗時はnormalizedを解放する。
    fn createBufferFromContent(
        allocator: std.mem.Allocator,
        normalized: []const u8,
        line_ending: encoding.LineEnding,
        detected_encoding: encoding.Encoding,
        file_mtime: i128,
    ) !Buffer {
        // 所有権を取得するため、失敗時は解放が必要
        errdefer allocator.free(normalized);

        var add_buffer = try std.ArrayList(u8).initCapacity(allocator, config.Buffer.ADD_BUFFER_INITIAL_CAPACITY);
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
            .detected_line_ending = line_ending,
            .detected_encoding = detected_encoding,
            .loaded_mtime = file_mtime,
            .last_insert_end = null,
            .last_insert_piece_idx = 0,
            .last_insert_time = 0,
            .last_access_piece_idx = 0,
            .last_access_piece_start = 0,
            .modification_count = 0,
            .cached_line_count = countNewlinesSIMD(normalized) + 1,
        };

        if (normalized.len > 0) {
            try self.pieces.append(allocator, .{
                .source = .original,
                .start = 0,
                .length = normalized.len,
            });
        }

        // LineIndexは遅延初期化: getLineStart()で自動rebuildされる
        // ここでrebuild()を呼ばないことで起動時間を短縮
        return self;
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

        return createBufferFromContent(allocator, normalized, actual_line_ending, detected.encoding, file_mtime);
    }

    /// mmapが失敗した場合のフォールバック（検出も含む）
    fn loadFromFileFallbackWithDetection(allocator: std.mem.Allocator, path: []const u8) !Buffer {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const raw_content = try file.readToEndAlloc(allocator, stat.size);
        defer allocator.free(raw_content);

        // detectEncodingが内部でisBinaryContentをチェックするので、
        // 別途のチェックは不要（二度読み排除）
        const detected = encoding.detectEncoding(raw_content);
        if (detected.encoding == .Unknown) {
            return error.BinaryFile;
        }

        // UTF-8に変換
        const utf8_content = try encoding.convertToUtf8(allocator, raw_content, detected.encoding);
        defer allocator.free(utf8_content);

        // UTF-16の場合、改行検出は変換後のUTF-8で行う
        const actual_line_ending = if (detected.encoding == .UTF16LE_BOM or detected.encoding == .UTF16BE_BOM)
            encoding.detectLineEnding(utf8_content)
        else
            detected.line_ending;

        // 改行コードを正規化
        const normalized = try encoding.normalizeLineEndings(allocator, utf8_content, actual_line_ending);
        errdefer allocator.free(normalized);

        return createBufferFromContent(allocator, normalized, actual_line_ending, detected.encoding, stat.mtime);
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

        // PID + タイムスタンプ付きの一時ファイル名（並列保存時の競合防止）
        const pid = if (@import("builtin").os.tag == .linux)
            std.os.linux.getpid()
        else
            std.c.getpid();
        const timestamp = @as(u64, @intCast(std.time.nanoTimestamp()));
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.{d}.{d}.tmp", .{ real_path, pid, timestamp });
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

        // 親ディレクトリが存在しない場合は作成
        if (std.fs.path.dirname(real_path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                // 既に存在する場合は無視、それ以外はエラー
                if (err != error.PathAlreadyExists) {
                    return err;
                }
            };
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

                // Step 2: 改行コードとエンコーディング変換
                // LFモードの場合は改行変換不要、直接エンコーディング変換（メモリ節約）
                if (self.detected_line_ending == .LF) {
                    const encoded = try encoding.convertFromUtf8(
                        self.allocator,
                        utf8_content.items,
                        self.detected_encoding,
                    );
                    defer self.allocator.free(encoded);
                    try file.writeAll(encoded);
                } else {
                    // CRLF/CRモードは改行変換が必要
                    const line_converted = try encoding.convertLineEndings(
                        self.allocator,
                        utf8_content.items,
                        self.detected_line_ending,
                    );
                    defer self.allocator.free(line_converted);

                    const encoded = try encoding.convertFromUtf8(
                        self.allocator,
                        line_converted,
                        self.detected_encoding,
                    );
                    defer self.allocator.free(encoded);
                    try file.writeAll(encoded);
                }
            } else {
                // UTF-8/UTF-8_BOM: Zig 0.15の新I/O API
                // 64KBバッファでwrite()回数を削減
                var write_buffer: [config.FileIO.WRITE_BUFFER_SIZE]u8 = undefined;
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
            // 注意: オーナーでない場合はEPERMになるが、保存は続行する
            // （グループ/ACL経由で書き込み権限を持つ共有リポジトリ等のケース）
            if (original_mode) |mode| {
                file.chmod(mode) catch {};
            }

            // データをディスクに同期（クラッシュ時のデータ破損を防止）
            try file.sync();
        }

        // 成功したら rename で置き換え（アトミック操作）
        std.fs.cwd().rename(tmp_path, real_path) catch |err| {
            if (err == error.RenameAcrossMountPoints) {
                // 異なるファイルシステム間: copyFile + deleteFileにフォールバック
                std.fs.cwd().copyFile(tmp_path, std.fs.cwd(), real_path, .{}) catch |copy_err| {
                    std.fs.cwd().deleteFile(tmp_path) catch {};
                    return copy_err;
                };
                std.fs.cwd().deleteFile(tmp_path) catch {};
            } else {
                // その他のエラー: 一時ファイルを削除してからエラーを返す
                std.fs.cwd().deleteFile(tmp_path) catch {};
                return err;
            }
        };

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
        // 現在のプロセスのUID/GIDと異なる場合のみ警告の可能性がある
        const current_uid = std.posix.getuid();
        const current_gid = getCurrentGid();
        var ownership_warning: ?[]const u8 = null;

        // 元の所有権が現在のユーザーと異なる場合のみchown
        const needs_chown = (original_uid != null and original_uid.? != current_uid) or
            (original_gid != null and original_gid.? != current_gid);
        if (needs_chown) {
            if (std.fs.cwd().openFile(real_path, .{ .mode = .read_write })) |file| {
                defer file.close();
                std.posix.fchown(file.handle, original_uid, original_gid) catch {
                    ownership_warning = "Warning: file ownership changed (permission denied for chown)";
                };
            } else |_| {}
        }
        return ownership_warning;
    }

    pub inline fn len(self: *const Buffer) usize {
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

    /// UTF-8文字の先頭バイト位置を探す（後方移動用）
    /// PieceIteratorを使って効率的に後方スキャン（O(1)のprev()を使用）
    pub fn findUtf8CharStart(self: *const Buffer, pos: usize) usize {
        if (pos == 0) return 0;

        // PieceIteratorを使って後方スキャン（getByteAtのO(piece数)を回避）
        var iter = PieceIterator.init(self);
        iter.seek(pos);

        // 後方に移動しながらUTF-8先頭バイトを探す（最大4バイト）
        var back: usize = 0;
        while (back < 4) : (back += 1) {
            const byte = iter.prev() orelse return 0;
            // UTF-8の先頭バイトかチェック（continuation byteでなければ先頭）
            if (unicode.isUtf8Start(byte)) {
                return iter.global_pos; // prev()後のglobal_posがそのバイトの位置
            }
        }
        return 0;
    }

    fn findPieceAt(self: *Buffer, pos: usize) ?struct { piece_idx: usize, offset: usize } {
        if (self.pieces.items.len == 0) return null;

        // キャッシュを活用: 検索位置がキャッシュ位置以降なら、そこから開始
        var start_idx: usize = 0;
        var current_pos: usize = 0;

        if (pos >= self.last_access_piece_start and
            self.last_access_piece_idx < self.pieces.items.len)
        {
            start_idx = self.last_access_piece_idx;
            current_pos = self.last_access_piece_start;
        }

        // 指定位置を含むPieceを検索
        for (self.pieces.items[start_idx..], start_idx..) |piece, i| {
            if (pos < current_pos + piece.length) {
                // キャッシュを更新
                self.last_access_piece_idx = i;
                self.last_access_piece_start = current_pos;
                return .{
                    .piece_idx = i,
                    .offset = pos - current_pos,
                };
            }
            current_pos += piece.length;
        }

        // EOF境界（pos == buffer.len()）の場合は最後のpieceの末尾を返す
        if (pos == current_pos) {
            // 空バッファの場合（pieces.len == 0）
            if (self.pieces.items.len == 0) {
                return null;
            }
            const last_idx = self.pieces.items.len - 1;
            const last_piece = self.pieces.items[last_idx];
            // キャッシュを更新
            self.last_access_piece_idx = last_idx;
            self.last_access_piece_start = current_pos - last_piece.length;
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

    /// 挿入操作の後処理（共通パターン）
    /// piece_idx: 更新するpiece index（nullの場合は更新しない、Piece統合時に使用）
    fn finalizeInsert(
        self: *Buffer,
        pos: usize,
        text: []const u8,
        piece_idx: ?usize,
        now: i128,
    ) !void {
        self.total_len += text.len;
        self.last_insert_end = pos + text.len;
        if (piece_idx) |idx| {
            self.last_insert_piece_idx = idx;
        }
        self.last_insert_time = now;
        try self.line_index.updateForInsert(pos, text);
    }

    /// 指定位置にテキストを挿入
    ///
    /// 【Piece Tableでの挿入】
    /// 1. add_buffer（追加バッファ）に新しいテキストを追記
    /// 2. 挿入位置でpieceを分割（必要な場合）
    /// 3. 新しいpieceを作成して配列に追加
    ///
    /// 【Piece統合】連続した文字入力（同じ位置への追記）では、
    /// 新しいPieceを作成せず既存Pieceを延長することで、Piece数の増加を抑制。
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

        // findPieceAtキャッシュを無効化（挿入によりバイトオフセットが変わるため）
        self.last_access_piece_idx = 0;
        self.last_access_piece_start = 0;

        // 変更カウンタをインクリメント（キャッシュ無効化用）
        self.modification_count +%= 1;

        // 行数キャッシュを更新（挿入テキスト内の改行数を加算）
        // エラー時にロールバックするためerrdeferを設定
        const newline_count = countNewlinesSIMD(text);
        self.cached_line_count += newline_count;
        errdefer self.cached_line_count -= newline_count;

        const now = std.time.nanoTimestamp();

        // 【Piece統合チェック】
        // 直前の挿入位置に連続して挿入し、かつ一定時間以内なら既存Pieceを延長
        if (self.last_insert_end) |last_end| {
            const time_elapsed = now - self.last_insert_time;
            if (pos == last_end and
                time_elapsed < config.Editor.UNDO_GROUP_TIMEOUT_NS and
                self.last_insert_piece_idx < self.pieces.items.len)
            {
                const last_piece = &self.pieces.items[self.last_insert_piece_idx];
                // add_bufferの末尾に連続しているか確認
                if (last_piece.source == .add and
                    last_piece.start + last_piece.length == self.add_buffer.items.len)
                {
                    // 統合可能：add_bufferに追記してPieceを延長
                    try self.add_buffer.appendSlice(self.allocator, text);
                    last_piece.length += text.len;
                    try self.finalizeInsert(pos, text, null, now);
                    return;
                }
            }
        }

        // 統合できない場合は通常の挿入処理

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
            try self.finalizeInsert(pos, text, 0, now);
            return;
        }

        // 挿入位置が末尾なら最後に追加
        // pos == total_len は許可するが、それを超える場合はエラー
        if (pos == self.total_len) {
            try self.pieces.append(self.allocator, new_piece);
            try self.finalizeInsert(pos, text, self.pieces.items.len - 1, now);
            return;
        }

        // pos > total_len の場合はエラー
        if (pos > self.total_len) {
            return error.PositionOutOfBounds;
        }

        // 挿入位置のpieceを見つける
        const location = self.findPieceAt(pos) orelse {
            try self.pieces.append(self.allocator, new_piece);
            try self.finalizeInsert(pos, text, self.pieces.items.len - 1, now);
            return;
        };

        const piece = self.pieces.items[location.piece_idx];

        // pieceの境界に挿入する場合
        if (location.offset == 0) {
            try self.pieces.insert(self.allocator, location.piece_idx, new_piece);
            try self.finalizeInsert(pos, text, location.piece_idx, now);
            return;
        }

        if (location.offset == piece.length) {
            try self.pieces.insert(self.allocator, location.piece_idx + 1, new_piece);
            try self.finalizeInsert(pos, text, location.piece_idx + 1, now);
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
        try self.finalizeInsert(pos, text, location.piece_idx + 1, now); // new_pieceの位置
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

        // 削除操作ではPiece統合状態をリセット
        self.last_insert_end = null;

        // findPieceAtキャッシュも無効化（Piece配列が変更されるため）
        self.last_access_piece_idx = 0;
        self.last_access_piece_start = 0;

        // pos が範囲外の場合は何もしない
        if (pos >= self.total_len) return;

        const actual_count = @min(count, self.total_len - pos);
        if (actual_count == 0) return;

        // 変更カウンタをインクリメント（キャッシュ無効化用）
        self.modification_count +%= 1;

        // 行数キャッシュを更新（削除範囲内の改行数を減算）
        var newlines_deleted: usize = 0;
        var iter = PieceIterator.init(self);
        iter.seek(pos);
        var remaining = actual_count;
        while (remaining > 0) {
            if (iter.next()) |ch| {
                if (ch == '\n') newlines_deleted += 1;
                remaining -= 1;
            } else break;
        }
        // 安全のためsaturating subtractionを使用（理論的にはアンダーフローしないはずだが）
        self.cached_line_count -|= newlines_deleted;

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
                self.line_index.updateForDelete(pos, actual_count, newlines_deleted);
                return;
            }

            // pieceの先頭から削除
            if (start_loc.offset == 0) {
                self.pieces.items[start_loc.piece_idx] = .{
                    .source = piece.source,
                    .start = piece.start + actual_count,
                    .length = piece.length - actual_count,
                };
                self.line_index.updateForDelete(pos, actual_count, newlines_deleted);
                return;
            }

            // pieceの末尾から削除
            if (end_loc.offset == piece.length) {
                self.pieces.items[start_loc.piece_idx] = .{
                    .source = piece.source,
                    .start = piece.start,
                    .length = start_loc.offset,
                };
                self.line_index.updateForDelete(pos, actual_count, newlines_deleted);
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
            self.line_index.updateForDelete(pos, actual_count, newlines_deleted);
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
        // end_loc.piece_idx == 0 かつ remove_end == false の場合のアンダーフロー防止
        const last_to_remove: usize = if (remove_end) end_loc.piece_idx else if (end_loc.piece_idx == 0) 0 else end_loc.piece_idx - 1;
        const should_remove = remove_end or end_loc.piece_idx > 0;

        // 削除実行（降順で削除、オーバーフロー防止）
        if (should_remove and last_to_remove >= first_to_remove) {
            var i = last_to_remove;
            while (true) {
                _ = self.pieces.orderedRemove(i);
                if (i == first_to_remove) break;
                i -= 1;
            }
        }
        self.line_index.updateForDelete(pos, actual_count, newlines_deleted);
    }

    // 行数取得（O(1)：キャッシュを直接返す）
    // 挿入/削除時に改行差分で更新されるため、LineIndex.rebuildを待たない
    pub fn lineCount(self: *const Buffer) usize {
        return self.cached_line_count;
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

    /// 指定位置から次の改行位置を検索（SIMD最適化版）
    /// 戻り値: 改行の次のバイト位置（改行がなければバッファ末尾）
    pub fn findNextLineFromPos(self: *Buffer, pos: usize) usize {
        // Piece毎にmemchrで改行検索（SIMDで高速化）
        var global_pos: usize = 0;
        for (self.pieces.items) |piece| {
            const piece_end = global_pos + piece.length;

            // このpieceがpos以降を含む場合のみ処理
            if (piece_end > pos) {
                const data = self.getPieceData(piece);
                // piece内の開始位置を計算
                const start_in_piece = if (global_pos >= pos) 0 else pos - global_pos;

                if (std.mem.indexOfScalar(u8, data[start_in_piece..], '\n')) |rel_pos| {
                    // 改行の次の位置を返す
                    return global_pos + start_in_piece + rel_pos + 1;
                }
            }
            global_pos = piece_end;
        }
        // 改行が見つからなければバッファ末尾
        return self.total_len;
    }

    // バイト位置から列番号を計算（表示幅ベース）
    // 日本語やCJK文字は2カラム、ASCII文字は1カラムとして計算
    // タブはconfig.Editor.TAB_WIDTHで計算
    pub fn findColumnByPos(self: *Buffer, pos: usize) usize {
        return self.findColumnByPosWithTabWidth(pos, config.Editor.TAB_WIDTH);
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
        const tw: usize = if (tab_width == 0) config.Editor.TAB_WIDTH else tab_width;
        while (iter.global_pos < pos) {
            const gc = iter.nextGraphemeCluster() catch break orelse break;
            // タブは次のタブストップまで進める
            if (gc.base == '\t') {
                col = (col / tw + 1) * tw;
            } else if (unicode.isAsciiControl(gc.base)) {
                col += 2; // 制御文字は ^X 形式で表示幅2
            } else {
                col += gc.width; // 表示幅を加算（CJK=2, ASCII=1）
            }
        }
        return col;
    }

    /// 指定された行の開始位置から、指定された表示カラムに最も近いバイト位置を返す
    /// target_col以下で最も近い位置を返す（target_colを超えない）
    /// 行の長さが指定カラムより短い場合は行末位置を返す
    pub fn findPosByColumn(self: *Buffer, line_start: usize, target_col: usize) usize {
        return self.findPosByColumnWithTabWidth(line_start, target_col, config.Editor.TAB_WIDTH);
    }

    /// 指定された行の開始位置から、指定された表示カラムに最も近いバイト位置を返す（タブ幅指定版）
    pub fn findPosByColumnWithTabWidth(self: *Buffer, line_start: usize, target_col: usize, tab_width: u8) usize {
        if (target_col == 0) return line_start;

        var iter = PieceIterator.init(self);
        iter.seek(line_start);

        var col: usize = 0;
        const tw: usize = if (tab_width == 0) config.Editor.TAB_WIDTH else tab_width;

        while (col < target_col) {
            const gc_start = iter.global_pos;
            const gc = iter.nextGraphemeCluster() catch break orelse break;

            // 改行に達したら停止（改行の前位置を返す）
            if (gc.base == '\n') {
                return gc_start;
            }

            const new_col = if (gc.base == '\t')
                (col / tw + 1) * tw
            else if (unicode.isAsciiControl(gc.base))
                col + 2
            else
                col + gc.width;

            // 目標カラムを超える場合は現在位置で停止
            if (new_col > target_col) {
                return gc_start;
            }

            col = new_col;
        }

        return iter.global_pos;
    }

    // 指定範囲のテキストを取得（新しいメモリを確保）
    // start + length がバッファサイズを超える場合は error.OutOfRange
    // 最適化: スライス単位でmemcpyを使用（バイト単位ループより大幅に高速）
    pub fn getRange(self: *const Buffer, allocator: std.mem.Allocator, start: usize, length: usize) ![]u8 {
        if (length == 0) {
            // 長さ0でもallocatorから確保して返す（呼び出し側がfree()しても安全）
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

    /// 指定範囲のテキストを抽出（境界クランピング付き）
    /// getRangeと異なり、範囲外アクセスはエラーではなく空スライスを返す
    /// Undo/Redo操作やテキスト削除前の保存に使用
    pub fn extractText(self: *const Buffer, allocator: std.mem.Allocator, start: usize, length: usize) ![]u8 {
        const total = self.len();

        // startがバッファ末尾を超えている場合は空の配列を返す
        if (start >= total) {
            return try allocator.alloc(u8, 0);
        }

        // 実際に読み取れるバイト数を計算（buffer末尾を超えないように）
        const actual_len = @min(length, total - start);
        if (actual_len == 0) {
            return try allocator.alloc(u8, 0);
        }

        const result = try allocator.alloc(u8, actual_len);
        errdefer allocator.free(result);

        var iter = PieceIterator.init(self);
        iter.seek(start);

        // copyBytes()でスライス単位コピー
        const copied = iter.copyBytes(result);
        if (copied != actual_len) {
            // Piece tableの不整合が発生した場合
            return error.BufferInconsistency;
        }

        return result;
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
        if (self.pieces.items.len == 0) return null;

        // findPieceAtで開始位置に直接ジャンプ（キャッシュ活用でO(1)〜O(pieces)）
        const mutable_self = @constCast(self);
        const start_info = mutable_self.findPieceAt(start_pos) orelse return null;

        var piece_idx = start_info.piece_idx;
        var global_pos = start_pos - start_info.offset; // このpieceの開始位置

        while (piece_idx < self.pieces.items.len) {
            const piece = self.pieces.items[piece_idx];
            const piece_end = global_pos + piece.length;
            const data = self.getPieceData(piece);

            // piece内の開始位置
            const start_in_piece = if (global_pos >= start_pos) 0 else start_pos - global_pos;

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
                    if (check_start >= start_pos) {
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

            global_pos = piece_end;
            piece_idx += 1;
        }

        return null;
    }

    /// 単一piece内での後方検索
    fn searchBackwardSimple(
        self: *const Buffer,
        pattern: []const u8,
        piece: Piece,
        piece_start: usize,
        search_limit: usize,
    ) ?SearchMatch {
        if (search_limit < pattern.len) return null;

        const data = self.getPieceData(piece);
        if (std.mem.lastIndexOf(u8, data[0..search_limit], pattern)) |rel_pos| {
            const global_pos = piece_start + rel_pos;
            // マッチがpiece境界をまたがないか確認
            if (rel_pos + pattern.len <= piece.length) {
                return .{ .start = global_pos, .len = pattern.len };
            }
            // 境界またぎの場合、実際にマッチするか確認
            if (self.verifyMatch(global_pos, pattern)) {
                return .{ .start = global_pos, .len = pattern.len };
            }
        }
        return null;
    }

    /// piece境界をまたぐパターンをチェック
    fn searchBackwardBoundary(
        self: *const Buffer,
        pattern: []const u8,
        current_piece_start: usize,
        piece_len: usize,
        search_end: usize,
    ) ?SearchMatch {
        // パターンがpiece長+1より長い場合、境界マッチは不可能
        if (piece_len + 1 < pattern.len) return null;

        const boundary_start = current_piece_start + piece_len - pattern.len + 1;
        if (boundary_start >= current_piece_start + piece_len) return null;

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
        return null;
    }

    /// 後方検索（コピーなし）
    /// 効率のため、チャンク単位で読み取って検索
    pub fn searchBackward(self: *const Buffer, pattern: []const u8, start_pos: usize) ?SearchMatch {
        if (pattern.len == 0) return null;

        const search_end = @min(start_pos, self.total_len);
        if (search_end < pattern.len) return null;

        const pieces = self.pieces.items;
        if (pieces.len == 0) return null;

        // 各pieceの終了位置を計算（1回のみ、後続の検索で再利用）
        var piece_ends: [config.Buffer.MAX_PIECES_STACK_BUFFER]usize = undefined;
        const use_stack_buf = pieces.len <= config.Buffer.MAX_PIECES_STACK_BUFFER;

        if (use_stack_buf) {
            var cumulative: usize = 0;
            for (pieces, 0..) |piece, i| {
                cumulative += piece.length;
                piece_ends[i] = cumulative;
            }
        }

        // search_endを含むpieceのインデックスを見つける（piece_endsを再利用）
        var piece_start: usize = 0;
        var start_piece_idx: usize = pieces.len;
        if (use_stack_buf) {
            // piece_endsを使って高速に検索
            for (piece_ends[0..pieces.len], 0..) |end_pos, i| {
                if (end_pos >= search_end) {
                    start_piece_idx = i;
                    piece_start = if (i > 0) piece_ends[i - 1] else 0;
                    break;
                }
            }
        } else {
            // piece数が256を超える場合はフォールバック
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

            // piece内での検索範囲を決定
            const search_limit = if (current_piece_idx == start_piece_idx)
                search_end - current_piece_start
            else
                piece.length;

            // piece内で検索
            if (self.searchBackwardSimple(pattern, piece, current_piece_start, search_limit)) |match| {
                return match;
            }

            // 前のpieceへ
            if (current_piece_idx == 0) break;
            current_piece_idx -= 1;
            current_piece_start -= pieces[current_piece_idx].length;

            // piece境界チェック
            if (current_piece_idx + 1 < pieces.len) {
                const piece_len = pieces[current_piece_idx].length;
                if (self.searchBackwardBoundary(pattern, current_piece_start, piece_len, search_end)) |match| {
                    return match;
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

    /// マッチ数カウント結果
    pub const MatchCountResult = struct {
        total: usize, // 総マッチ数
        current_index: ?usize, // 現在位置のマッチインデックス（1-based、なければnull）
    };

    /// パターンの総マッチ数と現在位置のインデックスをカウント
    /// max_count: 最大カウント数（パフォーマンス制限、0で無制限）
    /// cursor_pos: カーソル位置（現在マッチのインデックス計算用）
    pub fn countMatches(self: *const Buffer, pattern: []const u8, max_count: usize, cursor_pos: usize) MatchCountResult {
        var result = MatchCountResult{ .total = 0, .current_index = null };
        if (pattern.len == 0 or self.total_len == 0) return result;

        var search_pos: usize = 0;
        const limit = if (max_count == 0) std.math.maxInt(usize) else max_count;
        var found_current = false; // フラグで条件分岐を最小化

        while (result.total < limit) {
            const match = self.searchForward(pattern, search_pos) orelse break;

            result.total += 1;

            // カーソル位置がマッチ範囲内または直後にある場合、このマッチが「現在」
            // found_currentフラグで、見つかった後の不要なチェックをスキップ
            if (!found_current and cursor_pos >= match.start and cursor_pos <= match.start + match.len) {
                result.current_index = result.total; // 1-based
                found_current = true;
            }

            // 次の検索位置（空マッチ防止のため最低1バイト進める）
            search_pos = match.start + @max(match.len, 1);
            if (search_pos >= self.total_len) break;
        }

        return result;
    }

    /// バッファの先頭からmax_lenバイトのプレビューを取得（言語検出用）
    /// 複数pieceを跨ぐ場合は提供されたバッファに連結する
    /// outには連結されたデータが書き込まれ、実際に書き込まれたスライスを返す
    /// バッファが空の場合はnullを返す
    pub fn getContentPreview(self: *const Buffer, out: []u8) ?[]const u8 {
        if (self.pieces.items.len == 0) return null;

        var written: usize = 0;
        for (self.pieces.items) |piece| {
            const data = self.getPieceData(piece);
            const to_copy = @min(data.len, out.len - written);
            if (to_copy == 0) break;
            @memcpy(out[written..][0..to_copy], data[0..to_copy]);
            written += to_copy;
            if (written >= out.len) break;
        }

        return if (written > 0) out[0..written] else null;
    }
};
