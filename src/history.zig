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
    fn getZeDir(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        return std.fmt.allocPrint(allocator, "{s}/.ze", .{home});
    }

    /// 履歴ファイルのパスを取得
    fn getHistoryPath(allocator: std.mem.Allocator, history_type: HistoryType) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        const filename = switch (history_type) {
            .shell => "shell_history",
            .search => "search_history",
        };
        return std.fmt.allocPrint(allocator, "{s}/.ze/{s}", .{ home, filename });
    }

    /// ファイルから履歴を読み込み
    pub fn load(self: *History, history_type: HistoryType) !void {
        const path = try getHistoryPath(self.allocator, history_type);
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return; // ファイルがなければ空のまま
            return err;
        };
        defer file.close();

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

    /// 履歴をファイルに保存
    pub fn save(self: *History, history_type: HistoryType) !void {
        // ~/.ze ディレクトリを作成（存在しなければ）
        const ze_dir = try getZeDir(self.allocator);
        defer self.allocator.free(ze_dir);

        std.fs.cwd().makeDir(ze_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const path = try getHistoryPath(self.allocator, history_type);
        defer self.allocator.free(path);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        for (self.entries.items) |entry| {
            try file.writeAll(entry);
            try file.writeAll("\n");
        }
    }
};

// テスト
test "history basic operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var history = History.init(allocator);
    defer history.deinit();

    // 追加
    try history.add("ls -la");
    try history.add("grep foo");
    try history.add("cat bar");

    try std.testing.expectEqual(@as(usize, 3), history.entries.items.len);

    // 連続重複は追加されない
    try history.add("cat bar");
    try std.testing.expectEqual(@as(usize, 3), history.entries.items.len);

    // ナビゲーション
    try history.startNavigation("current");

    // prev: 最新から順に
    const e1 = history.prev();
    try std.testing.expectEqualStrings("cat bar", e1.?);

    const e2 = history.prev();
    try std.testing.expectEqualStrings("grep foo", e2.?);

    const e3 = history.prev();
    try std.testing.expectEqualStrings("ls -la", e3.?);

    // 最古を超えても同じ
    const e4 = history.prev();
    try std.testing.expectEqualStrings("ls -la", e4.?);

    // next: 戻る
    const e5 = history.next();
    try std.testing.expectEqualStrings("grep foo", e5.?);

    const e6 = history.next();
    try std.testing.expectEqualStrings("cat bar", e6.?);

    // 最新を超えると元の入力
    const e7 = history.next();
    try std.testing.expectEqualStrings("current", e7.?);
}
