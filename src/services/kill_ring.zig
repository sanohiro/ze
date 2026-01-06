// ============================================================================
// KillRing - キルリング（クリップボード）管理
// ============================================================================
//
// 【責務】
// - kill/yankで使用するテキストの一時保存
// - メモリの効率的な再利用（連続kill操作で毎回alloc/freeしない）
//
// 【設計】
// - 容量が足りなければ拡大、足りていれば再利用
// - +50%の予備容量で再アロケーション頻度を削減
// ============================================================================

const std = @import("std");

/// キルリング - 連続kill操作でのメモリ再利用を実現
/// 毎回alloc/freeする代わりに、容量を確保して再利用する。
pub const KillRing = struct {
    data: ?[]u8,
    capacity: usize,
    len: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KillRing {
        return .{
            .data = null,
            .capacity = 0,
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KillRing) void {
        if (self.data) |d| {
            self.allocator.free(d);
        }
    }

    /// テキストを保存（容量が足りなければ拡大、足りていれば再利用）
    pub fn store(self: *KillRing, text: []const u8) !void {
        if (self.capacity < text.len) {
            // サイズ拡大時のみrealloc（+50%予備で再アロケーション頻度を削減）
            const new_capacity = text.len + (text.len / 2) + 64; // 最低64バイトは余裕を持つ
            if (self.data) |old| {
                // reallocで効率的にサイズ変更
                if (self.allocator.resize(old, new_capacity)) {
                    // resizeが成功した場合（インプレース拡張）
                    // 重要: スライスの長さも更新する必要がある
                    self.data = old.ptr[0..new_capacity];
                    self.capacity = new_capacity;
                } else {
                    // resizeが失敗した場合は新規アロケーション
                    const new_data = try self.allocator.alloc(u8, new_capacity);
                    self.allocator.free(old);
                    self.data = new_data;
                    self.capacity = new_capacity;
                }
            } else {
                self.data = try self.allocator.alloc(u8, new_capacity);
                self.capacity = new_capacity;
            }
        }
        @memcpy(self.data.?[0..text.len], text);
        self.len = text.len;
    }

    /// 保存されたテキストを取得
    pub fn get(self: *const KillRing) ?[]const u8 {
        if (self.data) |d| {
            if (self.len > 0) {
                return d[0..self.len];
            }
        }
        return null;
    }
};
