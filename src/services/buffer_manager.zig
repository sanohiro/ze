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
// - バッファの内容操作はEditingContextが担当
// - BufferStateはファイル情報とEditingContextを保持
// - BufferManagerは純粋にバッファのコレクション管理に集中
// ============================================================================

const std = @import("std");
const Buffer = @import("../buffer.zig").Buffer;
const EditingContext = @import("../editing_context.zig").EditingContext;

/// バッファ状態
/// EditingContextを内包し、ファイル情報を追加する
pub const BufferState = struct {
    id: usize, // バッファID（一意）
    editing_ctx: *EditingContext, // 編集コンテキスト（Buffer + cursor + undo + kill_ring）
    filename: ?[]const u8, // ファイル名（nullなら*scratch*）
    readonly: bool, // 読み取り専用フラグ
    file_mtime: ?i128, // ファイルの最終更新時刻
    allocator: std.mem.Allocator,

    // === 後方互換性のためのプロパティアクセサ ===
    // 段階的移行のため、従来のAPIを維持
    // buffer フィールドはBufferへのポインタとして公開（getBuffer経由）

    /// バッファへの直接アクセス（EditingContext経由）
    pub fn getBuffer(self: *BufferState) *Buffer {
        return self.editing_ctx.buffer;
    }

    /// 従来のコードとの互換性のためにbufferフィールドとしてアクセス可能にする
    /// 注意: これは段階的移行のためのブリッジであり、将来的には削除される
    pub fn buffer(self: *BufferState) *Buffer {
        return self.editing_ctx.buffer;
    }

    /// 変更フラグ（EditingContext経由）
    pub fn isModified(self: *const BufferState) bool {
        return self.editing_ctx.modified;
    }

    /// 現在の状態を保存済みとしてマーク
    pub fn markSaved(self: *BufferState) void {
        self.editing_ctx.modified = false;
        // Undo履歴はクリアしない（将来的には保存位置をマーク）
    }

    pub fn init(allocator: std.mem.Allocator, id: usize) !*BufferState {
        const self = try allocator.create(BufferState);
        errdefer allocator.destroy(self);

        const editing_ctx = try EditingContext.init(allocator);
        errdefer editing_ctx.deinit();

        self.* = BufferState{
            .id = id,
            .editing_ctx = editing_ctx,
            .filename = null,
            .readonly = false,
            .file_mtime = null,
            .allocator = allocator,
        };
        return self;
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
        self.editing_ctx.deinit();
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
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

        // ファイルをロード（EditingContext内のBufferを差し替え）
        const old_buffer = buffer_state.editing_ctx.buffer;
        old_buffer.deinit();
        self.allocator.destroy(old_buffer);

        const new_buffer = try self.allocator.create(Buffer);
        new_buffer.* = try Buffer.loadFromFile(self.allocator, path);
        buffer_state.editing_ctx.buffer = new_buffer;

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
