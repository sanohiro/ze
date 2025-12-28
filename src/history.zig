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

/// 履歴の最大エントリ数
pub const MAX_HISTORY_SIZE: usize = 100;

/// 履歴の種類
pub const HistoryType = enum {
    shell, // M-| シェルコマンド
    search, // C-s/C-r 検索
};

/// 履歴管理
pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8),
    current_index: ?usize, // ナビゲーション中のインデックス（nullは履歴モード外）
    temp_input: ?[]const u8, // ナビゲーション開始前の入力を保持
    filter_prefix: ?[]const u8, // プレフィックスフィルタ（入力中の文字列にマッチする履歴のみ表示）
    loaded: bool, // ファイルから読み込み済みか（未読み込みで空の場合は保存しない）
    modified: bool, // 変更があったか（追加・削除があった場合のみ保存）

    pub fn init(allocator: std.mem.Allocator) History {
        return .{
            .allocator = allocator,
            // 空のArrayListを正しく初期化
            .entries = .{},
            .current_index = null,
            .temp_input = null,
            .filter_prefix = null,
            .loaded = false,
            .modified = false,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);
        if (self.temp_input) |temp| {
            self.allocator.free(temp);
        }
        if (self.filter_prefix) |prefix| {
            self.allocator.free(prefix);
        }
    }

    /// 履歴にエントリを追加
    pub fn add(self: *History, entry: []const u8) !void {
        // 空文字列は追加しない
        if (entry.len == 0) return;

        // 直前と同じなら追加しない（連続重複排除）
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, entry)) return;
        }

        // 最大数を超えたら古いエントリを削除
        if (self.entries.items.len >= MAX_HISTORY_SIZE) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old);
        }

        // エントリを複製して追加
        const duped = try self.allocator.dupe(u8, entry);
        try self.entries.append(self.allocator, duped);

        // 変更フラグを設定
        self.modified = true;

        // ナビゲーション状態をリセット
        self.resetNavigation();
    }

    /// ナビゲーション開始（現在の入力を保存、プレフィックスフィルタとして使用）
    pub fn startNavigation(self: *History, current_input: []const u8) !void {
        // 先にdupeしてからfreeする（dupe失敗時のダングリングポインタ防止）
        const new_temp = try self.allocator.dupe(u8, current_input);
        if (self.temp_input) |old| {
            self.allocator.free(old);
        }
        self.temp_input = new_temp;

        // プレフィックスフィルタを設定（空でなければ）
        if (current_input.len > 0) {
            const new_prefix = try self.allocator.dupe(u8, current_input);
            if (self.filter_prefix) |old| {
                self.allocator.free(old);
            }
            self.filter_prefix = new_prefix;
        } else {
            if (self.filter_prefix) |old| {
                self.allocator.free(old);
            }
            self.filter_prefix = null;
        }

        self.current_index = null;
    }

    /// エントリがプレフィックスにマッチするかチェック
    fn matchesPrefix(self: *const History, entry: []const u8) bool {
        if (self.filter_prefix) |prefix| {
            return std.mem.startsWith(u8, entry, prefix);
        }
        return true; // フィルタなしなら全てマッチ
    }

    /// 前の履歴（C-p / Up）- プレフィックスフィルタ対応
    pub fn prev(self: *History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;

        // 開始位置を決定
        var start_idx: usize = undefined;
        if (self.current_index) |idx| {
            if (idx == 0) {
                // 最古のエントリにいる場合、そのエントリがマッチするなら返す
                if (self.matchesPrefix(self.entries.items[0])) {
                    return self.entries.items[0];
                }
                return null;
            }
            start_idx = idx - 1;
        } else {
            // 履歴モード開始：最新から検索
            start_idx = self.entries.items.len - 1;
        }

        // マッチするエントリを後方検索
        var i: usize = start_idx;
        while (true) {
            if (self.matchesPrefix(self.entries.items[i])) {
                self.current_index = i;
                return self.entries.items[i];
            }
            if (i == 0) break;
            i -= 1;
        }

        // マッチするエントリがない場合、現在のエントリがマッチするなら返す
        if (self.current_index) |idx| {
            if (self.matchesPrefix(self.entries.items[idx])) {
                return self.entries.items[idx];
            }
        }

        return null;
    }

    /// 次の履歴（C-n / Down）- プレフィックスフィルタ対応
    pub fn next(self: *History) ?[]const u8 {
        const idx = self.current_index orelse return null;

        // マッチするエントリを前方検索
        var i = idx + 1;
        while (i < self.entries.items.len) : (i += 1) {
            if (self.matchesPrefix(self.entries.items[i])) {
                self.current_index = i;
                return self.entries.items[i];
            }
        }

        // 最新を超えたら元の入力に戻る
        self.current_index = null;
        return self.temp_input;
    }

    /// ナビゲーション状態をリセット
    pub fn resetNavigation(self: *History) void {
        self.current_index = null;
        if (self.temp_input) |temp| {
            self.allocator.free(temp);
            self.temp_input = null;
        }
        if (self.filter_prefix) |prefix| {
            self.allocator.free(prefix);
            self.filter_prefix = null;
        }
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
        };
        return std.fmt.allocPrint(allocator, "{s}/.ze/{s}", .{ home, filename }) catch null;
    }

    /// ファイルから履歴を読み込み
    /// HOME未設定時は何もせずに正常終了（履歴は空のまま）
    pub fn load(self: *History, history_type: HistoryType) !void {
        const path = getHistoryPath(self.allocator, history_type) orelse return;
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
        if (stat.size == 0) return;
        if (stat.size > 1024 * 1024) return error.FileTooLarge; // 1MB上限

        const content = try self.allocator.alloc(u8, @intCast(stat.size));
        defer self.allocator.free(content);
        const bytes_read = try file.readAll(content);

        // 行ごとに分割して追加
        var iter = std.mem.splitScalar(u8, content[0..bytes_read], '\n');
        while (iter.next()) |raw_line| {
            // CRLF対応: 末尾の\rを除去
            const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
                raw_line[0 .. raw_line.len - 1]
            else
                raw_line;
            if (line.len > 0) {
                const duped = try self.allocator.dupe(u8, line);
                try self.entries.append(self.allocator, duped);
            }
        }

        // MAX_HISTORY_SIZEを超えた古いエントリを削除
        while (self.entries.items.len > MAX_HISTORY_SIZE) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old);
        }
    }

    /// 履歴をファイルに保存（アトミック: temp+rename方式）
    /// HOME未設定時は何もせずに正常終了（履歴は保存されない）
    /// 未読み込み・未変更の場合は既存ファイルを上書きしない
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

        // 一時ファイルパスを作成（元のパス + ".tmp"）
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(tmp_path);

        // 一時ファイルに書き込み（0o600 = オーナーのみ読み書き可）
        const file = try std.fs.cwd().createFile(tmp_path, .{ .mode = 0o600 });
        errdefer {
            file.close();
            std.fs.cwd().deleteFile(tmp_path) catch {};
        }

        for (self.entries.items) |entry| {
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
        // 注: Zigのfs.Dirにはsyncメソッドがないため、fsyncで代替
        if (std.fs.cwd().openDir(ze_dir, .{})) |dir| {
            var d = dir;
            // ディレクトリfdをfsync（POSIXのfsync(dirfd)相当）
            std.posix.fsync(d.fd) catch {};
            d.close();
        } else |_| {}

        // 保存成功後にmodifiedフラグをリセット（次回の無駄な保存を防ぐ）
        self.modified = false;
    }
};
