// ============================================================================
// History - コマンド・検索履歴の管理
// ============================================================================
//
// 【責務】
// - ~/.ze/ ディレクトリに履歴ファイルを保存/読み込み
// - シェルコマンド履歴 (M-|)
// - 検索履歴 (C-s/C-r)
// - C-p/C-n/Up/Down でのナビゲーション
//
// 【ファイル形式】
// 1行1エントリ、最新が最後（bashと同じ）
// ============================================================================

const std = @import("std");

/// 行末のCRを除去（CRLF→LF変換）
inline fn trimCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r')
        line[0 .. line.len - 1]
    else
        line;
}

/// 履歴の最大エントリ数
pub const MAX_HISTORY_SIZE: usize = 100;

/// 履歴の種類
pub const HistoryType = enum {
    shell, // M-| シェルコマンド
    search, // C-s/C-r 検索
    file, // 最近開いたファイル
};

/// リングバッファ - 先頭削除がO(1)
/// 論理インデックス0が最古、len-1が最新
const HistoryRingBuffer = struct {
    items: [MAX_HISTORY_SIZE]?[]const u8 = [_]?[]const u8{null} ** MAX_HISTORY_SIZE,
    head: usize = 0, // 最古のエントリの物理インデックス
    len: usize = 0, // 現在のエントリ数

    /// 論理インデックスから物理インデックスへ変換
    inline fn physicalIndex(self: *const HistoryRingBuffer, logical: usize) usize {
        return (self.head + logical) % MAX_HISTORY_SIZE;
    }

    /// 論理インデックスでアクセス (0が最古、len-1が最新)
    pub fn get(self: *const HistoryRingBuffer, index: usize) ?[]const u8 {
        if (index >= self.len) return null;
        return self.items[self.physicalIndex(index)];
    }

    /// 末尾に追加、満杯なら最古を削除してその値を返す
    pub fn push(self: *HistoryRingBuffer, item: []const u8) ?[]const u8 {
        var old: ?[]const u8 = null;
        if (self.len == MAX_HISTORY_SIZE) {
            // 満杯：最古を削除
            old = self.items[self.head];
            self.items[self.head] = null;
            self.head = (self.head + 1) % MAX_HISTORY_SIZE;
        } else {
            self.len += 1;
        }
        // 新しいアイテムを末尾に追加
        const tail = self.physicalIndex(self.len - 1);
        self.items[tail] = item;
        return old;
    }

    /// 先頭に挿入（マージ用）、満杯なら最新を削除してその値を返す
    pub fn pushFront(self: *HistoryRingBuffer, item: []const u8) ?[]const u8 {
        var old: ?[]const u8 = null;
        if (self.len == MAX_HISTORY_SIZE) {
            // 満杯：最新（末尾）を削除
            const tail = self.physicalIndex(self.len - 1);
            old = self.items[tail];
            self.items[tail] = null;
        } else {
            self.len += 1;
        }
        // headを1つ前に移動して挿入
        self.head = if (self.head == 0) MAX_HISTORY_SIZE - 1 else self.head - 1;
        self.items[self.head] = item;
        return old;
    }

    /// 指定論理インデックスのエントリを削除し、その値を返す
    /// 後続のエントリを前にシフトする
    pub fn removeAt(self: *HistoryRingBuffer, logical_index: usize) ?[]const u8 {
        if (logical_index >= self.len) return null;

        const removed = self.items[self.physicalIndex(logical_index)];

        // 削除位置より後のエントリを前にシフト
        var i = logical_index;
        while (i + 1 < self.len) : (i += 1) {
            const curr = self.physicalIndex(i);
            const next = self.physicalIndex(i + 1);
            self.items[curr] = self.items[next];
        }

        // 末尾をnullに
        self.items[self.physicalIndex(self.len - 1)] = null;
        self.len -= 1;

        return removed;
    }

    /// 全エントリを順番にイテレート（最古→最新）
    pub fn iterator(self: *const HistoryRingBuffer) Iterator {
        return .{ .ring = self, .index = 0 };
    }

    const Iterator = struct {
        ring: *const HistoryRingBuffer,
        index: usize,

        pub fn next(self: *Iterator) ?[]const u8 {
            if (self.index >= self.ring.len) return null;
            const item = self.ring.get(self.index);
            self.index += 1;
            return item;
        }
    };
};

/// 履歴管理
pub const History = struct {
    allocator: std.mem.Allocator,
    ring: HistoryRingBuffer,
    current_index: ?usize, // ナビゲーション中のインデックス（nullは履歴モード外）
    temp_input: ?[]const u8, // ナビゲーション開始前の入力を保持
    filter_prefix: ?[]const u8, // プレフィックスフィルタ（入力中の文字列にマッチする履歴のみ表示）
    loaded: bool, // ファイルから読み込み済みか（未読み込みで空の場合は保存しない）
    modified: bool, // 変更があったか（追加・削除があった場合のみ保存）

    pub fn init(allocator: std.mem.Allocator) History {
        return .{
            .allocator = allocator,
            .ring = .{},
            .current_index = null,
            .temp_input = null,
            .filter_prefix = null,
            .loaded = false,
            .modified = false,
        };
    }

    pub fn deinit(self: *History) void {
        var iter = self.ring.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry);
        }
        self.clearNavState();
    }

    /// 履歴にエントリを追加
    /// 既存の同じエントリがあれば削除してから末尾に追加（MRU順序を維持）
    pub fn add(self: *History, entry: []const u8) !void {
        // 空文字列は追加しない
        if (entry.len == 0) return;

        // 既存の同じエントリを検索して削除（MRU: 最近使用したものを末尾に移動）
        var i: usize = 0;
        while (i < self.ring.len) {
            if (self.ring.get(i)) |existing| {
                if (std.mem.eql(u8, existing, entry)) {
                    // 既存エントリを削除（メモリ解放）
                    if (self.ring.removeAt(i)) |removed| {
                        self.allocator.free(removed);
                    }
                    // インデックスは進めない（シフトされるため）
                    continue;
                }
            }
            i += 1;
        }

        // エントリを複製して追加（満杯なら古いエントリが自動削除される）
        const duped = try self.allocator.dupe(u8, entry);
        if (self.ring.push(duped)) |old| {
            self.allocator.free(old);
        }

        // 変更フラグを設定
        self.modified = true;

        // ナビゲーション状態をリセット
        self.resetNavigation();
    }

    /// ナビゲーション開始（現在の入力を保存、プレフィックスフィルタとして使用）
    pub fn startNavigation(self: *History, current_input: []const u8) !void {
        // 先に両方dupeする（片方失敗時のメモリリーク防止）
        const new_temp = try self.allocator.dupe(u8, current_input);
        errdefer self.allocator.free(new_temp);

        const new_prefix: ?[]const u8 = if (current_input.len > 0)
            try self.allocator.dupe(u8, current_input)
        else
            null;

        // 両方成功したので古いものを解放して新しいものを設定
        self.clearNavState();
        self.temp_input = new_temp;
        self.filter_prefix = new_prefix;
        self.current_index = null;
    }

    /// ナビゲーション状態のメモリを解放（共通処理）
    fn clearNavState(self: *History) void {
        if (self.temp_input) |temp| {
            self.allocator.free(temp);
            self.temp_input = null;
        }
        if (self.filter_prefix) |prefix| {
            self.allocator.free(prefix);
            self.filter_prefix = null;
        }
    }

    /// エントリがプレフィックスにマッチするかチェック
    inline fn matchesPrefix(self: *const History, entry: []const u8) bool {
        if (self.filter_prefix) |prefix| {
            return std.mem.startsWith(u8, entry, prefix);
        }
        return true; // フィルタなしなら全てマッチ
    }

    /// 前の履歴（C-p / Up）- プレフィックスフィルタ対応
    pub fn prev(self: *History) ?[]const u8 {
        if (self.ring.len == 0) return null;

        // 開始位置を決定
        var start_idx: usize = undefined;
        if (self.current_index) |idx| {
            if (idx == 0) {
                // 最古のエントリにいる場合、そのエントリがマッチするなら返す
                if (self.ring.get(0)) |entry| {
                    if (self.matchesPrefix(entry)) return entry;
                }
                return null;
            }
            start_idx = idx - 1;
        } else {
            // 履歴モード開始：最新から検索
            start_idx = self.ring.len - 1;
        }

        // マッチするエントリを後方検索
        var i: usize = start_idx;
        while (true) {
            if (self.ring.get(i)) |entry| {
                if (self.matchesPrefix(entry)) {
                    self.current_index = i;
                    return entry;
                }
            }
            if (i == 0) break;
            i -= 1;
        }

        // マッチするエントリがない場合、現在のエントリがマッチするなら返す
        if (self.current_index) |idx| {
            if (self.ring.get(idx)) |entry| {
                if (self.matchesPrefix(entry)) return entry;
            }
        }

        return null;
    }

    /// 次の履歴（C-n / Down）- プレフィックスフィルタ対応
    pub fn next(self: *History) ?[]const u8 {
        const idx = self.current_index orelse return null;

        // マッチするエントリを前方検索
        var i = idx + 1;
        while (i < self.ring.len) : (i += 1) {
            if (self.ring.get(i)) |entry| {
                if (self.matchesPrefix(entry)) {
                    self.current_index = i;
                    return entry;
                }
            }
        }

        // 最新を超えたら元の入力に戻る
        self.current_index = null;
        return self.temp_input;
    }

    /// ナビゲーション状態をリセット
    pub fn resetNavigation(self: *History) void {
        self.current_index = null;
        self.clearNavState();
    }

    /// ~/.ze/ ディレクトリのパスを取得
    /// HOME未設定時はnullを返す（エディタはHOMEなしでも動作可能、履歴だけが保存されない）
    fn getZeDir(allocator: std.mem.Allocator) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        return std.fmt.allocPrint(allocator, "{s}/.ze", .{home}) catch null;
    }

    /// 履歴ファイルのパスを取得
    /// HOME未設定時はnullを返す
    fn getHistoryPath(allocator: std.mem.Allocator, history_type: HistoryType) ?[]const u8 {
        const home = std.posix.getenv("HOME") orelse return null;
        const filename = switch (history_type) {
            .shell => "shell_history",
            .search => "search_history",
            .file => "file_history",
        };
        return std.fmt.allocPrint(allocator, "{s}/.ze/{s}", .{ home, filename }) catch null;
    }

    /// ファイルから履歴を読み込み
    /// HOME未設定時は何もせずに正常終了（履歴は空のまま）
    pub fn load(self: *History, history_type: HistoryType) !void {
        const path = getHistoryPath(self.allocator, history_type) orelse {
            // HOME未設定時でもloaded=trueをセット（save時の判定で必要）
            self.loaded = true;
            return;
        };
        defer self.allocator.free(path);

        // 読み込み試行したことをマーク（ファイルが存在しなくてもtrue）
        self.loaded = true;

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // ファイルがなければ空のまま
            return err;
        };
        defer file.close();

        // 共有ロック（読み取りロック）を取得
        // 他のプロセスの書き込みをブロックし、同時読み取りは許可
        _ = std.posix.flock(file.handle, std.posix.LOCK.SH) catch {
            // ロック取得失敗は無視して続行（NFSなどロック非対応の場合）
        };
        defer {
            _ = std.posix.flock(file.handle, std.posix.LOCK.UN) catch {};
        }

        // ファイル全体を読み込み
        const stat = try file.stat();
        if (stat.size <= 0) return; // 空ファイルまたは不正なサイズ
        if (stat.size > 1024 * 1024) return error.FileTooLarge; // 1MB上限

        const content = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(content);
        const bytes_read = try file.readAll(content);

        // 行ごとに分割して追加（リングバッファがMAX_HISTORY_SIZEを自動で管理）
        var iter = std.mem.splitScalar(u8, content[0..bytes_read], '\n');
        while (iter.next()) |raw_line| {
            const line = trimCr(raw_line);
            if (line.len > 0) {
                const duped = try self.allocator.dupe(u8, line);
                if (self.ring.push(duped)) |old| {
                    self.allocator.free(old);
                }
            }
        }
    }

    /// 履歴をファイルに保存（アトミック: ロック+マージ+temp+rename方式）
    /// HOME未設定時は何もせずに正常終了（履歴は保存されない）
    /// 未読み込み・未変更の場合は既存ファイルを上書きしない
    /// 複数プロセス対応: 保存前に最新の履歴とマージする
    pub fn save(self: *History, history_type: HistoryType) !void {
        // 未読み込みかつ未変更なら保存しない（既存ファイルを誤って空にしない）
        if (!self.loaded and !self.modified) return;

        // ~/.ze ディレクトリを作成（存在しなければ）
        // HOME未設定時はnullが返るので何もせず終了
        const ze_dir = getZeDir(self.allocator) orelse return;
        defer self.allocator.free(ze_dir);

        std.fs.cwd().makeDir(ze_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const path = getHistoryPath(self.allocator, history_type) orelse return;
        defer self.allocator.free(path);

        // ロックファイルパスを作成（排他制御用）
        const lock_path = try std.fmt.allocPrint(self.allocator, "{s}.lock", .{path});
        defer self.allocator.free(lock_path);

        // ロックファイルを作成/オープンして排他ロックを取得
        // 注: ロックファイルは削除しない（削除するとinode が変わり排他制御が壊れる）
        const lock_file = std.fs.cwd().createFile(lock_path, .{ .mode = 0o600 }) catch {
            // ロックファイル作成失敗時は従来通り保存を試みる
            return self.saveWithoutLock(path, ze_dir);
        };
        defer lock_file.close();

        // 排他ロックを取得（他プロセスの読み書きをブロック）
        _ = std.posix.flock(lock_file.handle, std.posix.LOCK.EX) catch {
            // ロック取得失敗時は従来通り保存を試みる
            return self.saveWithoutLock(path, ze_dir);
        };
        defer {
            _ = std.posix.flock(lock_file.handle, std.posix.LOCK.UN) catch {};
        }

        // ロック取得後、ファイルから最新の履歴を読み込んでマージ
        try self.mergeFromFile(path);

        // マージ後の履歴を保存
        try self.saveWithoutLock(path, ze_dir);
    }

    /// ファイルから履歴を読み込んで現在の履歴とマージ
    /// 新しいエントリのみを追加（重複排除）
    fn mergeFromFile(self: *History, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // ファイルがなければマージ不要
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size <= 0) return; // 空ファイルまたは不正なサイズ
        if (stat.size > 1024 * 1024) return; // 1MB上限

        const content = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(content);
        const bytes_read = try file.readAll(content);

        // ファイルの履歴エントリを一時リストに収集
        var file_entries: std.ArrayList([]const u8) = .{};
        defer {
            for (file_entries.items) |entry| {
                self.allocator.free(entry);
            }
            file_entries.deinit(self.allocator);
        }

        var iter = std.mem.splitScalar(u8, content[0..bytes_read], '\n');
        while (iter.next()) |raw_line| {
            const line = trimCr(raw_line);
            if (line.len > 0) {
                const duped = try self.allocator.dupe(u8, line);
                errdefer self.allocator.free(duped);
                try file_entries.append(self.allocator, duped);
            }
        }

        // 現在のエントリをセットに変換（高速検索用）
        var current_set = std.StringHashMap(void).init(self.allocator);
        defer current_set.deinit();
        var ring_iter = self.ring.iterator();
        while (ring_iter.next()) |entry| {
            try current_set.put(entry, {});
        }

        // ファイルのエントリで、現在のリストにないものを先頭に挿入（逆順でpushFront）
        // （古いものが先頭、新しいものが末尾の順序を維持するため、逆順に挿入）
        var i = file_entries.items.len;
        while (i > 0) {
            i -= 1;
            const file_entry = file_entries.items[i];
            if (!current_set.contains(file_entry)) {
                const duped = try self.allocator.dupe(u8, file_entry);
                if (self.ring.pushFront(duped)) |old| {
                    self.allocator.free(old);
                }
            }
        }
    }

    /// ロックなしで履歴を保存（内部用）
    fn saveWithoutLock(self: *History, path: []const u8, ze_dir: []const u8) !void {
        // 一時ファイルパスを作成（元のパス + ".tmp"）
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        // 一時ファイルに書き込み（0o600 = オーナーのみ読み書き可）
        const file = try std.fs.cwd().createFile(tmp_path, .{ .mode = 0o600 });
        errdefer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        var iter = self.ring.iterator();
        while (iter.next()) |entry| {
            try file.writeAll(entry);
            try file.writeAll("\n");
        }

        // fsyncで確実にディスクに書き込み
        try file.sync();
        file.close();

        // アトミックにリネーム（既存ファイルを上書き）
        std.fs.cwd().rename(tmp_path, path) catch |err| {
            // リネーム失敗時は一時ファイルを削除（残存防止）
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return err;
        };

        // ディレクトリをsyncしてメタデータの永続化を保証
        if (std.fs.cwd().openDir(ze_dir, .{})) |dir| {
            var d = dir;
            std.posix.fsync(d.fd) catch {};
            d.close();
        } else |_| {}

        // 保存成功後にmodifiedフラグをリセット
        self.modified = false;
    }
};

/// 遅延ロード付き履歴ラッパー
/// 最初のアクセス時に自動的にファイルから履歴を読み込む
pub const LazyHistory = struct {
    history: History,
    history_type: HistoryType,
    loaded: bool,

    pub fn init(allocator: std.mem.Allocator, history_type: HistoryType) LazyHistory {
        return .{
            .history = History.init(allocator),
            .history_type = history_type,
            .loaded = false,
        };
    }

    /// 履歴がまだロードされていない場合にロードする
    fn ensureLoaded(self: *LazyHistory) void {
        if (self.loaded) return;
        self.loaded = true;
        self.history.load(self.history_type) catch {};
    }

    pub fn deinit(self: *LazyHistory) void {
        self.history.save(self.history_type) catch {};
        self.history.deinit();
    }

    /// 履歴にエントリを追加
    pub fn add(self: *LazyHistory, entry: []const u8) !void {
        self.ensureLoaded();
        try self.history.add(entry);
    }

    /// ナビゲーション開始
    pub fn startNavigation(self: *LazyHistory, current_input: []const u8) !void {
        self.ensureLoaded();
        try self.history.startNavigation(current_input);
    }

    /// 前の履歴へ
    pub fn prev(self: *LazyHistory) ?[]const u8 {
        self.ensureLoaded();
        return self.history.prev();
    }

    /// 次の履歴へ
    pub fn next(self: *LazyHistory) ?[]const u8 {
        self.ensureLoaded();
        return self.history.next();
    }

    /// ナビゲーションをリセット
    pub fn resetNavigation(self: *LazyHistory) void {
        self.history.resetNavigation();
    }

    /// 履歴ナビゲーション中かどうか
    pub fn isNavigating(self: *const LazyHistory) bool {
        return self.history.current_index != null;
    }
};
