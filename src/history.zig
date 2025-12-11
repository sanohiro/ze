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

    pub fn init(allocator: std.mem.Allocator) History {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList([]const u8).empty,
            .current_index = null,
            .temp_input = null,
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

        // ナビゲーション状態をリセット
        self.resetNavigation();
    }

    /// ナビゲーション開始（現在の入力を保存）
    pub fn startNavigation(self: *History, current_input: []const u8) !void {
        if (self.temp_input) |old| {
            self.allocator.free(old);
        }
        self.temp_input = try self.allocator.dupe(u8, current_input);
        self.current_index = null;
    }

    /// 前の履歴（C-p / Up）
    pub fn prev(self: *History) ?[]const u8 {
        if (self.entries.items.len == 0) return null;

        if (self.current_index) |idx| {
            // 既に履歴モード中
            if (idx > 0) {
                self.current_index = idx - 1;
                return self.entries.items[idx - 1];
            }
            // 最古のエントリに到達
            return self.entries.items[0];
        } else {
            // 履歴モード開始：最新のエントリを返す
            self.current_index = self.entries.items.len - 1;
            return self.entries.items[self.entries.items.len - 1];
        }
    }

    /// 次の履歴（C-n / Down）
    pub fn next(self: *History) ?[]const u8 {
        if (self.current_index) |idx| {
            if (idx + 1 < self.entries.items.len) {
                self.current_index = idx + 1;
                return self.entries.items[idx + 1];
            } else {
                // 最新を超えたら元の入力に戻る
                self.current_index = null;
                return self.temp_input;
            }
        }
        return null;
    }

    /// ナビゲーション状態をリセット
    pub fn resetNavigation(self: *History) void {
        self.current_index = null;
        if (self.temp_input) |temp| {
            self.allocator.free(temp);
            self.temp_input = null;
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
    }

    /// 履歴をファイルに保存（アトミック: temp+rename方式）
    /// HOME未設定時は何もせずに正常終了（履歴は保存されない）
    pub fn save(self: *History, history_type: HistoryType) !void {
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
        try std.fs.cwd().rename(tmp_path, path);

        // ディレクトリをsyncしてメタデータの永続化を保証
        // 注: Zigのfs.Dirにはsyncメソッドがないため、fsyncで代替
        if (std.fs.cwd().openDir(ze_dir, .{})) |dir| {
            var d = dir;
            // ディレクトリfdをfsync（POSIXのfsync(dirfd)相当）
            std.posix.fsync(d.fd) catch {};
            d.close();
        } else |_| {}
    }
};
