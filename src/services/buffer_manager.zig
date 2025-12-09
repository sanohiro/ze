// ============================================================================
// BufferManager - バッファ管理サービス
// ============================================================================
//
// 【責務】
// - 複数バッファのライフサイクル管理
// - バッファの作成・削除
// - バッファIDによる検索
// - ファイルとバッファの関連付け
//
// 【設計原則】
// - バッファの内容操作はBufferStateが担当
// - BufferManagerは純粋にバッファのコレクション管理に集中
// ============================================================================

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const UndoEntry = @import("undo_manager.zig").UndoEntry;

/// バッファ状態
pub const BufferState = struct {
    id: usize, // バッファID（一意）
    buffer: Buffer, // 実際のテキスト内容
    filename: ?[]const u8, // ファイル名（nullなら*scratch*）
    modified: bool, // 変更フラグ
    readonly: bool, // 読み取り専用フラグ
    file_mtime: ?i128, // ファイルの最終更新時刻
    undo_stack: std.ArrayList(UndoEntry), // Undoスタック
    redo_stack: std.ArrayList(UndoEntry), // Redoスタック
    undo_save_point: ?usize, // 保存時のundoスタック深さ（nullなら一度も保存されていない）
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize) !*BufferState {
        const self = try allocator.create(BufferState);
        self.* = BufferState{
            .id = id,
            .buffer = try Buffer.init(allocator),
            .filename = null,
            .modified = false,
            .readonly = false,
            .file_mtime = null,
            .undo_stack = undefined, // 後で初期化
            .redo_stack = undefined, // 後で初期化
            .undo_save_point = 0, // 初期状態は保存済み扱い
            .allocator = allocator,
        };
        // ArrayListは構造体リテラル内で初期化できないため、後で初期化
        self.undo_stack = .{};
        self.redo_stack = .{};
        return self;
    }

    /// 現在の状態がディスク上のファイルと一致するかを判定
    pub fn isModified(self: *const BufferState) bool {
        if (self.undo_save_point) |save_point| {
            return self.undo_stack.items.len != save_point;
        }
        // 一度も保存されていない場合、何か変更があればmodified
        return self.undo_stack.items.len > 0;
    }

    /// 現在の状態を保存済みとしてマーク
    pub fn markSaved(self: *BufferState) void {
        self.undo_save_point = self.undo_stack.items.len;
        self.modified = false;
    }

    /// バッファ名を取得（ファイル名がなければ*scratch*）
    pub fn getName(self: *const BufferState) []const u8 {
        if (self.filename) |fname| {
            // パスからファイル名部分のみを抽出
            if (std.mem.lastIndexOf(u8, fname, "/")) |idx| {
                return fname[idx + 1 ..];
            }
            return fname;
        }
        return "*scratch*";
    }

    /// フルパスを取得
    pub fn getPath(self: *const BufferState) ?[]const u8 {
        return self.filename;
    }

    pub fn deinit(self: *BufferState) void {
        self.buffer.deinit();
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
        for (self.undo_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.redo_stack.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// バッファマネージャー
pub const BufferManager = struct {
    allocator: std.mem.Allocator,
    buffers: std.ArrayListUnmanaged(*BufferState),
    next_buffer_id: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .buffers = .{},
            .next_buffer_id = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers.items) |buffer| {
            buffer.deinit();
        }
        self.buffers.deinit(self.allocator);
    }

    /// 新しいバッファを作成
    pub fn createBuffer(self: *Self) !*BufferState {
        const buffer_id = self.next_buffer_id;
        self.next_buffer_id += 1;

        const buffer_state = try BufferState.init(self.allocator, buffer_id);
        errdefer buffer_state.deinit();

        try self.buffers.append(self.allocator, buffer_state);
        return buffer_state;
    }

    /// ファイルからバッファを作成
    pub fn createBufferFromFile(self: *Self, path: []const u8) !*BufferState {
        const buffer_id = self.next_buffer_id;
        self.next_buffer_id += 1;

        const buffer_state = try BufferState.init(self.allocator, buffer_id);
        errdefer buffer_state.deinit();

        // ファイルをロード
        buffer_state.buffer.deinit();
        buffer_state.buffer = try Buffer.loadFromFile(self.allocator, path);

        // ファイル名を設定
        buffer_state.filename = try self.allocator.dupe(u8, path);

        // ファイルのmtimeを取得
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        buffer_state.file_mtime = stat.mtime;

        try self.buffers.append(self.allocator, buffer_state);
        return buffer_state;
    }

    /// バッファをIDで検索
    pub fn findById(self: *Self, id: usize) ?*BufferState {
        for (self.buffers.items) |buffer| {
            if (buffer.id == id) {
                return buffer;
            }
        }
        return null;
    }

    /// バッファをファイル名で検索
    pub fn findByFilename(self: *Self, filename: []const u8) ?*BufferState {
        for (self.buffers.items) |buffer| {
            if (buffer.filename) |buf_filename| {
                if (std.mem.eql(u8, buf_filename, filename)) {
                    return buffer;
                }
            }
        }
        return null;
    }

    /// バッファを削除
    pub fn deleteBuffer(self: *Self, id: usize) bool {
        for (self.buffers.items, 0..) |buffer, idx| {
            if (buffer.id == id) {
                buffer.deinit();
                _ = self.buffers.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    /// 未保存の変更があるバッファがあるか
    pub fn hasUnsavedChanges(self: *const Self) bool {
        for (self.buffers.items) |buffer| {
            if (buffer.isModified()) {
                return true;
            }
        }
        return false;
    }

    /// バッファ数を取得
    pub fn bufferCount(self: *const Self) usize {
        return self.buffers.items.len;
    }

    /// 全バッファのイテレータ
    pub fn iterator(self: *Self) []*BufferState {
        return self.buffers.items;
    }

    /// 全バッファのイテレータ（const版）
    pub fn iteratorConst(self: *const Self) []const *BufferState {
        return self.buffers.items;
    }

    /// 最初のバッファを取得（初期化直後の*scratch*バッファなど）
    pub fn getFirst(self: *Self) ?*BufferState {
        if (self.buffers.items.len > 0) {
            return self.buffers.items[0];
        }
        return null;
    }

    /// バッファ名のリストを取得（補完用）
    pub fn getBufferNames(self: *Self, allocator: std.mem.Allocator) ![][]const u8 {
        var names = try allocator.alloc([]const u8, self.buffers.items.len);
        for (self.buffers.items, 0..) |buffer, i| {
            names[i] = buffer.getName();
        }
        return names;
    }
};

// ============================================================================
// テスト
// ============================================================================

test "BufferManager - create buffer" {
    const allocator = std.testing.allocator;
    var bm = BufferManager.init(allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();
    try std.testing.expectEqual(@as(usize, 0), buffer.id);
    try std.testing.expectEqual(@as(usize, 1), bm.bufferCount());
}

test "BufferManager - find by id" {
    const allocator = std.testing.allocator;
    var bm = BufferManager.init(allocator);
    defer bm.deinit();

    const buffer1 = try bm.createBuffer();
    const buffer2 = try bm.createBuffer();

    const found = bm.findById(buffer1.id);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(buffer1.id, found.?.id);

    const found2 = bm.findById(buffer2.id);
    try std.testing.expect(found2 != null);
    try std.testing.expectEqual(buffer2.id, found2.?.id);
}

test "BufferManager - delete buffer" {
    const allocator = std.testing.allocator;
    var bm = BufferManager.init(allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();
    try std.testing.expectEqual(@as(usize, 1), bm.bufferCount());

    const deleted = bm.deleteBuffer(buffer.id);
    try std.testing.expect(deleted);
    try std.testing.expectEqual(@as(usize, 0), bm.bufferCount());
}

test "BufferState - getName" {
    const allocator = std.testing.allocator;
    var bm = BufferManager.init(allocator);
    defer bm.deinit();

    const buffer = try bm.createBuffer();
    try std.testing.expectEqualStrings("*scratch*", buffer.getName());
}
