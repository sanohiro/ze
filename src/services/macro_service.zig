// ============================================================================
// MacroService - キーボードマクロサービス
// ============================================================================
//
// 【責務】
// - キーボードマクロの記録・再生
// - Emacs互換のC-x (, C-x ), C-x eキーバインド
//
// 【設計原則】
// - シンプルな実装（最後に記録したマクロのみ保持）
// - Editorから独立したサービス
// ============================================================================

const std = @import("std");
const input = @import("input");

/// キーボードマクロサービス
pub const MacroService = struct {
    allocator: std.mem.Allocator,
    recording: std.ArrayListUnmanaged(input.Key), // 記録中のキー
    last_macro: ?[]input.Key, // 最後に記録したマクロ
    is_recording: bool,
    is_playing: bool, // 再生中フラグ（再帰防止）

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .recording = .{},
            .last_macro = null,
            .is_recording = false,
            .is_playing = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.recording.deinit(self.allocator);
        if (self.last_macro) |macro| {
            self.allocator.free(macro);
        }
    }

    /// マクロ記録を開始
    pub fn startRecording(self: *Self) void {
        // 再生中は記録開始しない
        if (self.is_playing) return;

        self.recording.clearRetainingCapacity();
        self.is_recording = true;
    }

    /// キーを記録
    pub fn recordKey(self: *Self, key: input.Key) !void {
        if (!self.is_recording) return;
        try self.recording.append(self.allocator, key);
    }

    /// マクロ記録を終了
    pub fn stopRecording(self: *Self) void {
        if (!self.is_recording) return;

        self.is_recording = false;

        // 空のマクロは保存しない（前のマクロを保持）
        if (self.recording.items.len == 0) return;

        // 前のマクロを解放
        if (self.last_macro) |macro| {
            self.allocator.free(macro);
        }

        // 記録をコピーして保存
        self.last_macro = self.allocator.dupe(input.Key, self.recording.items) catch null;
    }

    /// 記録をキャンセル
    pub fn cancelRecording(self: *Self) void {
        self.is_recording = false;
        self.recording.clearRetainingCapacity();
    }

    /// 最後に記録したマクロを取得
    pub fn getLastMacro(self: *const Self) ?[]const input.Key {
        return self.last_macro;
    }

    /// 記録中かどうか
    pub fn isRecording(self: *const Self) bool {
        return self.is_recording;
    }

    /// 再生開始をマーク
    pub fn beginPlayback(self: *Self) void {
        self.is_playing = true;
    }

    /// 再生終了をマーク
    pub fn endPlayback(self: *Self) void {
        self.is_playing = false;
    }

    /// 再生中かどうか
    pub fn isPlaying(self: *const Self) bool {
        return self.is_playing;
    }

    /// 記録されたキー数を取得
    pub fn recordedKeyCount(self: *const Self) usize {
        return self.recording.items.len;
    }

    /// 最後のマクロのキー数を取得
    pub fn lastMacroKeyCount(self: *const Self) usize {
        if (self.last_macro) |macro| {
            return macro.len;
        }
        return 0;
    }
};
