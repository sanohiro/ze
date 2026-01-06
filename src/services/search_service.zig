// ============================================================================
// SearchService - 検索・置換サービス
// ============================================================================
//
// 【責務】
// - インクリメンタルサーチ（I-search）
// - Query Replace（対話的置換）
// - 検索履歴の管理
// - 正規表現検索のサポート
//
// 【設計原則】
// - Bufferへの直接操作は行わない（結果を返すのみ）
// - Viewへの依存を最小化
// ============================================================================

const std = @import("std");
const regex = @import("regex");
const history_mod = @import("history");
const LazyHistory = history_mod.LazyHistory;
const Buffer = @import("buffer").Buffer;
const unicode = @import("unicode");

/// 検索結果
pub const SearchMatch = struct {
    start: usize,
    len: usize,
};

/// 正規表現キャッシュエントリ（LRU用）
const RegexCacheEntry = struct {
    pattern: []const u8,
    compiled: regex.Regex,
    use_count: u32, // LRU用カウンタ
};

/// 検索サービス: 検索・置換機能を提供
///
/// 【最適化】
/// - 正規表現のコンパイル結果をLRUキャッシュ（最大3パターン、再コンパイル不要）
/// - リテラル検索はBuffer直接検索（コピーなし、SIMD最適化）
/// - 正規表現検索のみ範囲制限（1MB）で体感速度を維持
/// - 履歴は遅延ロード（起動高速化）
///
/// 【検索モード】
/// - リテラル: 特殊文字がなければそのまま文字列検索
/// - 正規表現: []、()、*、+、?、|、.、^、$、\ を含む場合
pub const SearchService = struct {
    allocator: std.mem.Allocator,
    history: LazyHistory, // 検索履歴（永続化対応、遅延ロード）
    regex_cache: [REGEX_CACHE_SIZE]?RegexCacheEntry, // LRUキャッシュ（最大3パターン）
    cache_counter: u32, // LRU用グローバルカウンタ

    const Self = @This();
    const REGEX_CACHE_SIZE = 3; // LRUキャッシュサイズ

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .history = LazyHistory.init(allocator, .search),
            .regex_cache = [_]?RegexCacheEntry{null} ** REGEX_CACHE_SIZE,
            .cache_counter = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.history.deinit();
        // LRUキャッシュを解放
        for (&self.regex_cache) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                entry.compiled.deinit();
                self.allocator.free(entry.pattern);
                entry_opt.* = null;
            }
        }
    }

    /// LRUキャッシュから正規表現を取得（必要に応じてコンパイル）
    /// 注意: 返されるポインタはキャッシュエビクション時に無効化される可能性があるため、
    /// 即座に使用し、保存しないこと。次のgetCompiledRegex呼び出し前に使用を完了すること。
    fn getCompiledRegex(self: *Self, pattern: []const u8) ?*regex.Regex {
        self.cache_counter +%= 1;

        // キャッシュヒット判定
        for (&self.regex_cache) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                if (std.mem.eql(u8, entry.pattern, pattern)) {
                    // キャッシュヒット - use_countを更新して再利用
                    entry.use_count = self.cache_counter;
                    return &entry.compiled;
                }
            }
        }

        // キャッシュミス - 新規コンパイル
        const compiled = regex.Regex.compile(self.allocator, pattern) catch return null;
        const pattern_copy = self.allocator.dupe(u8, pattern) catch {
            var r = compiled;
            r.deinit();
            return null;
        };

        // 空きスロットを探すか、LRUエントリを置換
        var target_idx: usize = 0;
        var min_use_count: u32 = std.math.maxInt(u32);
        for (self.regex_cache, 0..) |entry_opt, i| {
            if (entry_opt == null) {
                // 空きスロット発見
                target_idx = i;
                min_use_count = 0;
                break;
            }
            if (entry_opt.?.use_count < min_use_count) {
                min_use_count = entry_opt.?.use_count;
                target_idx = i;
            }
        }

        // 古いエントリを解放（存在すれば）
        if (self.regex_cache[target_idx]) |*old_entry| {
            old_entry.compiled.deinit();
            self.allocator.free(old_entry.pattern);
        }

        // 新しいエントリを設定
        self.regex_cache[target_idx] = .{
            .pattern = pattern_copy,
            .compiled = compiled,
            .use_count = self.cache_counter,
        };

        return &self.regex_cache[target_idx].?.compiled;
    }

    /// リテラル検索（前方）
    pub fn searchForward(_: *Self, content: []const u8, pattern: []const u8, start_pos: usize) ?SearchMatch {
        if (pattern.len == 0 or content.len == 0) return null;

        // まず start_pos から検索（start_posが範囲内の場合）
        if (start_pos < content.len) {
            if (std.mem.indexOf(u8, content[start_pos..], pattern)) |offset| {
                return .{
                    .start = start_pos + offset,
                    .len = pattern.len,
                };
            }
        }

        // ラップアラウンド（先頭から start_pos まで、またはEOFなら全体）
        const wrap_end = if (start_pos >= content.len) content.len else start_pos;
        if (wrap_end > 0) {
            if (std.mem.indexOf(u8, content[0..wrap_end], pattern)) |offset| {
                return .{
                    .start = offset,
                    .len = pattern.len,
                };
            }
        }

        return null;
    }

    /// リテラル検索（後方）
    pub fn searchBackward(_: *Self, content: []const u8, pattern: []const u8, start_pos: usize) ?SearchMatch {
        if (pattern.len == 0) return null;

        // まず start_pos まで後方検索
        const search_end = @min(start_pos, content.len);
        if (search_end > 0) {
            if (std.mem.lastIndexOf(u8, content[0..search_end], pattern)) |offset| {
                return .{
                    .start = offset,
                    .len = pattern.len,
                };
            }
        }

        // ラップアラウンド（start_pos から末尾まで）
        if (start_pos < content.len) {
            if (std.mem.lastIndexOf(u8, content[start_pos..], pattern)) |offset| {
                return .{
                    .start = start_pos + offset,
                    .len = pattern.len,
                };
            }
        }

        return null;
    }

    /// 正規表現検索（前方）- キャッシュを使用
    pub fn searchRegexForward(self: *Self, content: []const u8, pattern: []const u8, start_pos: usize) ?SearchMatch {
        const re = self.getCompiledRegex(pattern) orelse return null;

        // 前方検索
        if (re.search(content, start_pos)) |match| {
            return .{
                .start = match.start,
                .len = match.end - match.start,
            };
        }

        // ラップアラウンド
        if (start_pos > 0) {
            if (re.search(content, 0)) |match| {
                if (match.start < start_pos) {
                    return .{
                        .start = match.start,
                        .len = match.end - match.start,
                    };
                }
            }
        }

        return null;
    }

    /// 正規表現検索（後方）- キャッシュを使用
    pub fn searchRegexBackward(self: *Self, content: []const u8, pattern: []const u8, start_pos: usize) ?SearchMatch {
        const re = self.getCompiledRegex(pattern) orelse return null;

        // 後方検索
        if (re.searchBackward(content, start_pos)) |match| {
            return .{
                .start = match.start,
                .len = match.end - match.start,
            };
        }

        // ラップアラウンド
        if (re.searchBackward(content, content.len)) |match| {
            if (match.start >= start_pos) {
                return .{
                    .start = match.start,
                    .len = match.end - match.start,
                };
            }
        }

        return null;
    }

    /// パターンが正規表現かどうか判定
    pub inline fn isRegexPattern(pattern: []const u8) bool {
        return regex.isRegexPattern(pattern);
    }

    /// 正規表現検索（常に正規表現として処理）
    /// skip_current=true の場合、同じ位置での空マッチを回避するため位置を調整
    /// UTF-8境界を尊重して移動する
    pub fn searchRegex(self: *Self, content: []const u8, pattern: []const u8, start_pos: usize, forward: bool, skip_current: bool) ?SearchMatch {
        if (forward) {
            // 前方検索: skip_current時はUTF-8コードポイント分進めて空マッチの無限ループを防止
            const search_from = if (skip_current and start_pos < content.len) blk: {
                const byte = content[start_pos];
                if (unicode.isAsciiByte(byte)) break :blk start_pos + 1;
                // UTF-8シーケンス長を取得して全バイトをスキップ
                const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                break :blk @min(start_pos + seq_len, content.len);
            } else start_pos;
            return self.searchRegexForward(content, pattern, search_from);
        } else {
            // 後方検索: skip_current時はUTF-8境界まで戻して同位置マッチを回避
            const search_from = if (skip_current and start_pos > 0) blk: {
                // UTF-8の先頭バイトを探す（継続バイトをスキップ）
                var pos = start_pos - 1;
                while (pos > 0 and unicode.isUtf8Continuation(content[pos])) {
                    pos -= 1;
                }
                break :blk pos;
            } else start_pos;
            return self.searchRegexBackward(content, pattern, search_from);
        }
    }

    /// Buffer直接検索（コピーなし、リテラル検索専用）
    /// 呼び出し側が既にリテラル検索であることを確認している前提
    /// skip_currentはAPI互換性のためのパラメータ（この検索では不使用）
    /// - 前方検索: カーソルは既にマッチ終端にあるのでスキップ不要
    /// - 後方検索: カーソルは既にマッチ先頭にあるのでそのまま検索
    pub fn searchBuffer(_: *Self, buffer: *const Buffer, pattern: []const u8, start_pos: usize, forward: bool, _: bool) ?SearchMatch {
        if (forward) {
            // 前方検索: カーソル位置から検索（カーソルは既にマッチ終端なのでスキップ不要）
            if (buffer.searchForwardWrap(pattern, start_pos)) |match| {
                return .{ .start = match.start, .len = match.len };
            }
        } else {
            // 後方検索: カーソルはマッチ先頭にあるので、start_posより前を検索
            // searchBackwardWrapは[0..search_from)を検索するので、start_posでOK
            if (buffer.searchBackwardWrap(pattern, start_pos)) |match| {
                return .{ .start = match.start, .len = match.len };
            }
        }

        return null;
    }

};
