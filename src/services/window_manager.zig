// ============================================================================
// WindowManager - ウィンドウ管理サービス
// ============================================================================
//
// 【責務】
// - 複数ウィンドウのライフサイクル管理
// - ウィンドウの分割・閉じる・切り替え
// - ウィンドウサイズの再計算（リサイズ時）
// - ウィンドウ間のナビゲーション
//
// 【設計原則】
// - Viewの初期化は呼び出し側の責務（BufferStateが必要なため）
// - WindowManagerは純粋にウィンドウの位置・サイズ管理に集中
// ============================================================================

const std = @import("std");
const View = @import("../view.zig").View;

/// ウィンドウ分割タイプ
pub const SplitType = enum {
    none, // 分割なし（単一ウィンドウまたは最初のウィンドウ）
    horizontal, // 横分割（上下に分割）で作られたウィンドウ
    vertical, // 縦分割（左右に分割）で作られたウィンドウ
};

/// ウィンドウ構造体
pub const Window = struct {
    id: usize, // ウィンドウID
    buffer_id: usize, // 表示しているバッファのID
    view: View, // 表示状態（カーソル位置、スクロールなど）
    x: usize, // 画面上のX座標
    y: usize, // 画面上のY座標
    width: usize, // ウィンドウの幅
    height: usize, // ウィンドウの高さ
    mark_pos: ?usize, // 範囲選択のマーク位置
    split_type: SplitType, // このウィンドウがどの分割で作られたか
    split_parent_id: ?usize, // 分割元ウィンドウのID

    pub fn init(id: usize, buffer_id: usize, x: usize, y: usize, width: usize, height: usize) Window {
        return Window{
            .id = id,
            .buffer_id = buffer_id,
            .view = undefined, // 後で初期化
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .mark_pos = null,
            .split_type = .none,
            .split_parent_id = null,
        };
    }

    pub fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        self.view.deinit(allocator);
    }
};

/// ウィンドウマネージャー
pub const WindowManager = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayListUnmanaged(Window),
    current_window_idx: usize,
    next_window_id: usize,
    screen_width: usize,
    screen_height: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, screen_width: usize, screen_height: usize) Self {
        return .{
            .allocator = allocator,
            .windows = .{},
            .current_window_idx = 0,
            .next_window_id = 0,
            .screen_width = screen_width,
            .screen_height = screen_height,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.windows.items) |*window| {
            window.deinit(self.allocator);
        }
        self.windows.deinit(self.allocator);
    }

    /// 新しいウィンドウを作成（Viewは呼び出し側で設定する必要がある）
    pub fn createWindow(self: *Self, buffer_id: usize, x: usize, y: usize, width: usize, height: usize) !*Window {
        const window_id = self.next_window_id;
        self.next_window_id += 1;

        const new_window = Window.init(window_id, buffer_id, x, y, width, height);
        try self.windows.append(self.allocator, new_window);

        return &self.windows.items[self.windows.items.len - 1];
    }

    /// 現在のウィンドウを取得
    pub fn getCurrentWindow(self: *Self) *Window {
        return &self.windows.items[self.current_window_idx];
    }

    /// 現在のウィンドウを取得（const版）
    pub fn getCurrentWindowConst(self: *const Self) *const Window {
        return &self.windows.items[self.current_window_idx];
    }

    /// ウィンドウ数を取得
    pub fn windowCount(self: *const Self) usize {
        return self.windows.items.len;
    }

    /// 次のウィンドウへ移動
    pub fn nextWindow(self: *Self) void {
        if (self.windows.items.len > 1) {
            self.current_window_idx = (self.current_window_idx + 1) % self.windows.items.len;
        }
    }

    /// 前のウィンドウへ移動
    pub fn prevWindow(self: *Self) void {
        if (self.windows.items.len > 1) {
            if (self.current_window_idx == 0) {
                self.current_window_idx = self.windows.items.len - 1;
            } else {
                self.current_window_idx -= 1;
            }
        }
    }

    /// 画面サイズを更新
    pub fn updateScreenSize(self: *Self, width: usize, height: usize) void {
        self.screen_width = width;
        self.screen_height = height;
    }

    /// ウィンドウサイズを再計算
    pub fn recalculateWindowSizes(self: *Self) void {
        const total_width = self.screen_width;
        const total_height = self.screen_height;

        if (self.windows.items.len == 0) return;

        // ウィンドウが1つの場合は全画面
        if (self.windows.items.len == 1) {
            self.windows.items[0].x = 0;
            self.windows.items[0].y = 0;
            self.windows.items[0].width = total_width;
            self.windows.items[0].height = total_height;
            self.windows.items[0].view.setViewport(total_width, total_height);
            return;
        }

        // 複数ウィンドウの場合：レイアウトを分析して再計算
        // 現在の相対的な位置とサイズを計算してから新しいサイズに適用

        // まず現在の全体サイズを取得（旧サイズ）
        var old_total_width: usize = 0;
        var old_total_height: usize = 0;
        for (self.windows.items) |window| {
            old_total_width = @max(old_total_width, window.x + window.width);
            old_total_height = @max(old_total_height, window.y + window.height);
        }

        // 旧サイズが0の場合はデフォルト値を使用
        if (old_total_width == 0) old_total_width = total_width;
        if (old_total_height == 0) old_total_height = total_height;

        // 各ウィンドウの比率を維持してリサイズ
        for (self.windows.items) |*window| {
            // X座標と幅を新しい幅に比例してスケール
            const new_x = (window.x * total_width) / old_total_width;
            const new_right = ((window.x + window.width) * total_width) / old_total_width;
            window.x = new_x;
            window.width = if (new_right > new_x) new_right - new_x else 1;

            // Y座標と高さを新しい高さに比例してスケール
            const new_y = (window.y * total_height) / old_total_height;
            const new_bottom = ((window.y + window.height) * total_height) / old_total_height;
            window.y = new_y;
            window.height = if (new_bottom > new_y) new_bottom - new_y else 1;

            // 最小サイズを保証
            if (window.width < 10) window.width = 10;
            if (window.height < 3) window.height = 3;

            window.view.markFullRedraw();
        }

        // 境界調整：ウィンドウが画面からはみ出ないようにする
        for (self.windows.items) |*window| {
            if (window.x + window.width > total_width) {
                if (window.x >= total_width) {
                    window.x = 0;
                    window.width = total_width;
                } else {
                    window.width = total_width - window.x;
                }
            }
            if (window.y + window.height > total_height) {
                if (window.y >= total_height) {
                    window.y = 0;
                    window.height = total_height;
                } else {
                    window.height = total_height - window.y;
                }
            }
        }

        // 全ウィンドウのビューポートを更新（カーソル制約も行う）
        for (self.windows.items) |*window| {
            window.view.setViewport(window.width, window.height);
        }
    }

    /// 現在のウィンドウを横（上下）に分割
    /// 新しいWindowを返す（Viewの初期化は呼び出し側で行う）
    pub fn splitHorizontally(self: *Self) !SplitResult {
        const current_window = &self.windows.items[self.current_window_idx];

        // ウィンドウの高さが2未満の場合は分割できない
        if (current_window.height < 2) {
            return error.WindowTooSmall;
        }

        // 分割後のサイズを計算
        const old_height = current_window.height;
        const new_height = old_height / 2;
        const buffer_id = current_window.buffer_id;

        // 新しいウィンドウID
        const new_window_id = self.next_window_id;
        self.next_window_id += 1;

        // 現在のウィンドウの高さを半分にする
        current_window.height = new_height;

        // 新しいウィンドウを下半分に作成
        var new_window = Window.init(
            new_window_id,
            buffer_id,
            current_window.x,
            current_window.y + new_height,
            current_window.width,
            old_height - new_height,
        );

        // 分割情報を設定
        new_window.split_type = .horizontal;
        new_window.split_parent_id = current_window.id;

        // ウィンドウリストに追加
        try self.windows.append(self.allocator, new_window);

        // 新しいウィンドウのインデックス
        const new_idx = self.windows.items.len - 1;

        return .{
            .new_window = &self.windows.items[new_idx],
            .original_window = &self.windows.items[self.current_window_idx],
            .new_window_idx = new_idx,
        };
    }

    /// 現在のウィンドウを縦（左右）に分割
    pub fn splitVertically(self: *Self) !SplitResult {
        const current_window = &self.windows.items[self.current_window_idx];

        // ウィンドウの幅が最小幅未満の場合は分割できない（最低10列は必要）
        if (current_window.width < 20) {
            return error.WindowTooSmall;
        }

        // 分割後のサイズを計算
        const old_width = current_window.width;
        const new_width = old_width / 2;
        const buffer_id = current_window.buffer_id;

        // 新しいウィンドウID
        const new_window_id = self.next_window_id;
        self.next_window_id += 1;

        // 現在のウィンドウの幅を半分にする
        current_window.width = new_width;

        // 新しいウィンドウを右半分に作成
        var new_window = Window.init(
            new_window_id,
            buffer_id,
            current_window.x + new_width,
            current_window.y,
            old_width - new_width,
            current_window.height,
        );

        // 分割情報を設定
        new_window.split_type = .vertical;
        new_window.split_parent_id = current_window.id;

        // ウィンドウリストに追加
        try self.windows.append(self.allocator, new_window);

        // 新しいウィンドウのインデックス
        const new_idx = self.windows.items.len - 1;

        return .{
            .new_window = &self.windows.items[new_idx],
            .original_window = &self.windows.items[self.current_window_idx],
            .new_window_idx = new_idx,
        };
    }

    /// 分割結果
    pub const SplitResult = struct {
        new_window: *Window,
        original_window: *Window,
        new_window_idx: usize,
    };

    /// 現在のウィンドウを閉じる
    pub fn closeCurrentWindow(self: *Self) !void {
        // 最後のウィンドウは閉じられない
        if (self.windows.items.len == 1) {
            return error.CannotCloseSoleWindow;
        }

        // 現在のウィンドウを閉じる
        var window = &self.windows.items[self.current_window_idx];
        window.deinit(self.allocator);
        _ = self.windows.orderedRemove(self.current_window_idx);

        // current_window_idxを調整
        if (self.current_window_idx >= self.windows.items.len) {
            self.current_window_idx = self.windows.items.len - 1;
        }

        // 残ったウィンドウのサイズを再計算
        self.recalculateWindowSizes();
    }

    /// 他のウィンドウをすべて閉じる (C-x 1)
    pub fn deleteOtherWindows(self: *Self) !void {
        // ウィンドウが1つしかなければ何もしない
        if (self.windows.items.len == 1) {
            return;
        }

        // 現在のウィンドウを保持
        const current_window = self.windows.items[self.current_window_idx];

        // 他のウィンドウをすべて解放
        for (self.windows.items, 0..) |*window, i| {
            if (i != self.current_window_idx) {
                window.deinit(self.allocator);
            }
        }

        // ウィンドウリストをクリアして現在のウィンドウだけ残す
        self.windows.clearRetainingCapacity();
        // appendが失敗した場合は致命的エラー（ウィンドウが空になる）
        try self.windows.append(self.allocator, current_window);
        self.current_window_idx = 0;

        // ウィンドウサイズを再計算（フルスクリーン）
        self.recalculateWindowSizes();
    }

    /// アクティブウィンドウを設定
    pub fn setActiveWindow(self: *Self, idx: usize) void {
        if (idx < self.windows.items.len) {
            self.current_window_idx = idx;
        }
    }

    /// IDでウィンドウを検索
    pub fn findWindowById(self: *Self, id: usize) ?*Window {
        for (self.windows.items) |*window| {
            if (window.id == id) {
                return window;
            }
        }
        return null;
    }

    /// バッファIDでウィンドウを検索
    pub fn findWindowByBufferId(self: *Self, buffer_id: usize) ?*Window {
        for (self.windows.items) |*window| {
            if (window.buffer_id == buffer_id) {
                return window;
            }
        }
        return null;
    }

    /// 全ウィンドウのイテレータ
    pub fn iterator(self: *Self) []Window {
        return self.windows.items;
    }

    /// 全ウィンドウのイテレータ（const版）
    pub fn iteratorConst(self: *const Self) []const Window {
        return self.windows.items;
    }
};

// ============================================================================
// テスト
// ============================================================================

test "WindowManager - basic operations" {
    const allocator = std.testing.allocator;
    var wm = WindowManager.init(allocator, 80, 24);
    defer wm.deinit();

    // 最初は空
    try std.testing.expectEqual(@as(usize, 0), wm.windowCount());
}

test "WindowManager - screen size update" {
    const allocator = std.testing.allocator;
    var wm = WindowManager.init(allocator, 80, 24);
    defer wm.deinit();

    wm.updateScreenSize(120, 40);
    try std.testing.expectEqual(@as(usize, 120), wm.screen_width);
    try std.testing.expectEqual(@as(usize, 40), wm.screen_height);
}
