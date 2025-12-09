// ============================================================================
// UndoManager - Undo/Redo サービス
// ============================================================================
//
// 【責務】
// - 編集操作の記録（insert/delete/replace）
// - 連続操作のマージ（コアレッシング）
// - Undo/Redo の実行
// - 保存時点の追跡
//
// 【設計原則】
// - Bufferへの直接操作は行わない（コールバック経由）
// - 状態は BufferState に保持（マルチバッファ対応）
// ============================================================================

const std = @import("std");
const config = @import("../config.zig");

/// 最大Undoエントリ数
pub const MAX_UNDO_ENTRIES: usize = 1000;

/// 編集操作の種類
pub const EditOp = union(enum) {
    insert: struct {
        pos: usize,
        text: []const u8, // allocatorで確保（解放責任あり）
    },
    delete: struct {
        pos: usize,
        text: []const u8, // 削除されたテキストを保存
    },
    replace: struct {
        pos: usize,
        old_text: []const u8, // 置換前のテキスト
        new_text: []const u8, // 置換後のテキスト
    },
};

/// Undoエントリ
pub const UndoEntry = struct {
    op: EditOp,
    cursor_pos: usize, // 操作前のカーソルバイト位置
    timestamp: i64, // 操作時のタイムスタンプ（ミリ秒）

    pub fn deinit(self: *const UndoEntry, allocator: std.mem.Allocator) void {
        switch (self.op) {
            .insert => |ins| allocator.free(ins.text),
            .delete => |del| allocator.free(del.text),
            .replace => |rep| {
                allocator.free(rep.old_text);
                allocator.free(rep.new_text);
            },
        }
    }
};

/// Undo結果（Bufferに適用する操作）
pub const UndoResult = struct {
    action: Action,
    cursor_pos: usize, // 復元すべきカーソル位置

    pub const Action = union(enum) {
        insert: struct { pos: usize, text: []const u8 },
        delete: struct { pos: usize, len: usize },
        replace: struct { pos: usize, delete_len: usize, text: []const u8 },
    };
};

/// Undo/Redo スタック（BufferStateに埋め込まれる）
pub const UndoStack = struct {
    undo_stack: std.ArrayListUnmanaged(UndoEntry),
    redo_stack: std.ArrayListUnmanaged(UndoEntry),
    save_point: ?usize, // 保存時のundoスタック深さ

    const Self = @This();

    pub fn init() Self {
        return .{
            .undo_stack = .{},
            .redo_stack = .{},
            .save_point = 0,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.undo_stack.items) |*entry| {
            entry.deinit(allocator);
        }
        self.undo_stack.deinit(allocator);

        for (self.redo_stack.items) |*entry| {
            entry.deinit(allocator);
        }
        self.redo_stack.deinit(allocator);
    }

    /// 変更されているかどうか
    pub fn isModified(self: *const Self) bool {
        if (self.save_point) |sp| {
            return self.undo_stack.items.len != sp;
        }
        return self.undo_stack.items.len > 0;
    }

    /// 保存時点をマーク
    pub fn markSaved(self: *Self) void {
        self.save_point = self.undo_stack.items.len;
    }

    /// スタックをクリア（ファイル再読み込み時等）
    pub fn clear(self: *Self, allocator: std.mem.Allocator) void {
        for (self.undo_stack.items) |*entry| {
            entry.deinit(allocator);
        }
        self.undo_stack.clearRetainingCapacity();

        for (self.redo_stack.items) |*entry| {
            entry.deinit(allocator);
        }
        self.redo_stack.clearRetainingCapacity();

        self.save_point = 0;
    }
};

/// UndoManager - Undo/Redo操作を管理
pub const UndoManager = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// 現在時刻を取得
    fn getCurrentTimeMs() i64 {
        return @divFloor(std.time.milliTimestamp(), 1);
    }

    /// 挿入操作を記録（連続挿入はマージ）
    pub fn recordInsert(
        self: *Self,
        stack: *UndoStack,
        pos: usize,
        text: []const u8,
        cursor_pos_before: usize,
    ) !void {
        const now = getCurrentTimeMs();

        // 連続挿入のコアレッシング
        if (stack.undo_stack.items.len > 0) {
            const last = &stack.undo_stack.items[stack.undo_stack.items.len - 1];
            const time_diff: u64 = @intCast(@max(0, now - last.timestamp));
            const within_timeout = time_diff < config.Editor.UNDO_COALESCE_TIMEOUT_MS;

            if (within_timeout and last.op == .insert) {
                const last_ins = last.op.insert;
                if (last_ins.pos + last_ins.text.len == pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ last_ins.text, text });
                    errdefer self.allocator.free(new_text);
                    self.allocator.free(last_ins.text);
                    last.op.insert.text = new_text;
                    last.timestamp = now;
                    return;
                }
            }
        }

        const text_copy = try self.allocator.dupe(u8, text);
        try stack.undo_stack.append(self.allocator, .{
            .op = .{ .insert = .{ .pos = pos, .text = text_copy } },
            .cursor_pos = cursor_pos_before,
            .timestamp = now,
        });

        self.trimUndoStack(stack);
        self.clearRedoStack(stack);
    }

    /// 削除操作を記録（連続削除はマージ）
    pub fn recordDelete(
        self: *Self,
        stack: *UndoStack,
        pos: usize,
        text: []const u8,
        cursor_pos_before: usize,
    ) !void {
        const now = getCurrentTimeMs();

        // 連続削除のコアレッシング
        if (stack.undo_stack.items.len > 0) {
            const last = &stack.undo_stack.items[stack.undo_stack.items.len - 1];
            const time_diff: u64 = @intCast(@max(0, now - last.timestamp));
            const within_timeout = time_diff < config.Editor.UNDO_COALESCE_TIMEOUT_MS;

            if (within_timeout and last.op == .delete) {
                const last_del = last.op.delete;
                // Backspace
                if (pos + text.len == last_del.pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ text, last_del.text });
                    errdefer self.allocator.free(new_text);
                    self.allocator.free(last_del.text);
                    last.op.delete.text = new_text;
                    last.op.delete.pos = pos;
                    last.timestamp = now;
                    return;
                }
                // Delete
                if (pos == last_del.pos) {
                    const new_text = try std.mem.concat(self.allocator, u8, &[_][]const u8{ last_del.text, text });
                    errdefer self.allocator.free(new_text);
                    self.allocator.free(last_del.text);
                    last.op.delete.text = new_text;
                    last.timestamp = now;
                    return;
                }
            }
        }

        const text_copy = try self.allocator.dupe(u8, text);
        try stack.undo_stack.append(self.allocator, .{
            .op = .{ .delete = .{ .pos = pos, .text = text_copy } },
            .cursor_pos = cursor_pos_before,
            .timestamp = now,
        });

        self.trimUndoStack(stack);
        self.clearRedoStack(stack);
    }

    /// 置換操作を記録
    pub fn recordReplace(
        self: *Self,
        stack: *UndoStack,
        pos: usize,
        old_text: []const u8,
        new_text: []const u8,
        cursor_pos_before: usize,
    ) !void {
        const now = getCurrentTimeMs();

        const old_copy = try self.allocator.dupe(u8, old_text);
        errdefer self.allocator.free(old_copy);
        const new_copy = try self.allocator.dupe(u8, new_text);

        try stack.undo_stack.append(self.allocator, .{
            .op = .{ .replace = .{ .pos = pos, .old_text = old_copy, .new_text = new_copy } },
            .cursor_pos = cursor_pos_before,
            .timestamp = now,
        });

        self.trimUndoStack(stack);
        self.clearRedoStack(stack);
    }

    /// Undoを実行（Bufferに適用する操作を返す）
    pub fn undo(self: *Self, stack: *UndoStack, current_cursor_pos: usize) !?UndoResult {
        if (stack.undo_stack.items.len == 0) return null;

        const entry = stack.undo_stack.pop() orelse return null;
        defer entry.deinit(self.allocator);

        const saved_cursor = entry.cursor_pos;
        const now = getCurrentTimeMs();

        const result: UndoResult = switch (entry.op) {
            .insert => |ins| blk: {
                // insertの取り消し: delete
                const text_copy = try self.allocator.dupe(u8, ins.text);
                try stack.redo_stack.append(self.allocator, .{
                    .op = .{ .insert = .{ .pos = ins.pos, .text = text_copy } },
                    .cursor_pos = current_cursor_pos,
                    .timestamp = now,
                });
                break :blk .{
                    .action = .{ .delete = .{ .pos = ins.pos, .len = ins.text.len } },
                    .cursor_pos = saved_cursor,
                };
            },
            .delete => |del| blk: {
                // deleteの取り消し: insert
                // redo用とresult用にテキストをコピー
                const text_for_redo = try self.allocator.dupe(u8, del.text);
                const text_for_result = try self.allocator.dupe(u8, del.text);
                try stack.redo_stack.append(self.allocator, .{
                    .op = .{ .delete = .{ .pos = del.pos, .text = text_for_redo } },
                    .cursor_pos = current_cursor_pos,
                    .timestamp = now,
                });
                break :blk .{
                    .action = .{ .insert = .{ .pos = del.pos, .text = text_for_result } },
                    .cursor_pos = saved_cursor,
                };
            },
            .replace => |rep| blk: {
                // replaceの取り消し: new_textを削除してold_textを挿入
                // redo用とresult用にテキストをコピー
                const old_for_redo = try self.allocator.dupe(u8, rep.old_text);
                const new_for_redo = try self.allocator.dupe(u8, rep.new_text);
                const old_for_result = try self.allocator.dupe(u8, rep.old_text);
                try stack.redo_stack.append(self.allocator, .{
                    .op = .{ .replace = .{ .pos = rep.pos, .old_text = old_for_redo, .new_text = new_for_redo } },
                    .cursor_pos = current_cursor_pos,
                    .timestamp = now,
                });
                break :blk .{
                    .action = .{ .replace = .{ .pos = rep.pos, .delete_len = rep.new_text.len, .text = old_for_result } },
                    .cursor_pos = saved_cursor,
                };
            },
        };

        return result;
    }

    /// Redoを実行
    pub fn redo(self: *Self, stack: *UndoStack, current_cursor_pos: usize) !?UndoResult {
        if (stack.redo_stack.items.len == 0) return null;

        const entry = stack.redo_stack.pop() orelse return null;
        defer entry.deinit(self.allocator);

        const saved_cursor = entry.cursor_pos;
        const now = getCurrentTimeMs();

        const result: UndoResult = switch (entry.op) {
            .insert => |ins| blk: {
                // redoのinsert: もう一度insert
                // undo用とresult用にテキストをコピー
                const text_for_undo = try self.allocator.dupe(u8, ins.text);
                const text_for_result = try self.allocator.dupe(u8, ins.text);
                try stack.undo_stack.append(self.allocator, .{
                    .op = .{ .insert = .{ .pos = ins.pos, .text = text_for_undo } },
                    .cursor_pos = current_cursor_pos,
                    .timestamp = now,
                });
                break :blk .{
                    .action = .{ .insert = .{ .pos = ins.pos, .text = text_for_result } },
                    .cursor_pos = saved_cursor,
                };
            },
            .delete => |del| blk: {
                // redoのdelete: もう一度delete
                const text_copy = try self.allocator.dupe(u8, del.text);
                try stack.undo_stack.append(self.allocator, .{
                    .op = .{ .delete = .{ .pos = del.pos, .text = text_copy } },
                    .cursor_pos = current_cursor_pos,
                    .timestamp = now,
                });
                // deleteはテキスト長のみ必要（テキスト内容は不要）
                break :blk .{
                    .action = .{ .delete = .{ .pos = del.pos, .len = del.text.len } },
                    .cursor_pos = saved_cursor,
                };
            },
            .replace => |rep| blk: {
                // redoのreplace: もう一度replace
                // undo用とresult用にテキストをコピー
                const old_for_undo = try self.allocator.dupe(u8, rep.old_text);
                const new_for_undo = try self.allocator.dupe(u8, rep.new_text);
                const new_for_result = try self.allocator.dupe(u8, rep.new_text);
                try stack.undo_stack.append(self.allocator, .{
                    .op = .{ .replace = .{ .pos = rep.pos, .old_text = old_for_undo, .new_text = new_for_undo } },
                    .cursor_pos = current_cursor_pos,
                    .timestamp = now,
                });
                break :blk .{
                    .action = .{ .replace = .{ .pos = rep.pos, .delete_len = rep.old_text.len, .text = new_for_result } },
                    .cursor_pos = saved_cursor,
                };
            },
        };

        return result;
    }

    fn trimUndoStack(self: *Self, stack: *UndoStack) void {
        if (stack.undo_stack.items.len > MAX_UNDO_ENTRIES) {
            const old_entry = stack.undo_stack.orderedRemove(0);
            old_entry.deinit(self.allocator);
            if (stack.save_point) |sp| {
                stack.save_point = if (sp > 0) sp - 1 else null;
            }
        }
    }

    fn clearRedoStack(self: *Self, stack: *UndoStack) void {
        for (stack.redo_stack.items) |*entry| {
            entry.deinit(self.allocator);
        }
        stack.redo_stack.clearRetainingCapacity();
    }
};

// ============================================================================
// テスト
// ============================================================================

test "UndoStack - basic insert and undo" {
    const allocator = std.testing.allocator;
    var manager = UndoManager.init(allocator);
    var stack = UndoStack.init();
    defer stack.deinit(allocator);

    // 挿入を記録
    try manager.recordInsert(&stack, 0, "hello", 0);
    try std.testing.expectEqual(@as(usize, 1), stack.undo_stack.items.len);

    // Undo
    const result = try manager.undo(&stack, 5);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 0), result.?.action.delete.pos);
    try std.testing.expectEqual(@as(usize, 5), result.?.action.delete.len);
}

test "UndoStack - coalescing" {
    const allocator = std.testing.allocator;
    var manager = UndoManager.init(allocator);
    var stack = UndoStack.init();
    defer stack.deinit(allocator);

    // 連続する挿入（マージされるはず）
    try manager.recordInsert(&stack, 0, "a", 0);
    try manager.recordInsert(&stack, 1, "b", 0);
    try manager.recordInsert(&stack, 2, "c", 0);

    // 1つのエントリにマージされているはず
    try std.testing.expectEqual(@as(usize, 1), stack.undo_stack.items.len);
    try std.testing.expectEqualStrings("abc", stack.undo_stack.items[0].op.insert.text);
}

test "UndoStack - isModified" {
    const allocator = std.testing.allocator;
    var manager = UndoManager.init(allocator);
    var stack = UndoStack.init();
    defer stack.deinit(allocator);

    try std.testing.expect(!stack.isModified());

    try manager.recordInsert(&stack, 0, "test", 0);
    try std.testing.expect(stack.isModified());

    stack.markSaved();
    try std.testing.expect(!stack.isModified());
}
