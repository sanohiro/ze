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
const Buffer = @import("buffer").Buffer;
const EditingContext = @import("editing_context").EditingContext;
const config = @import("config");

/// ファイルメタデータ
/// ファイル関連の情報を管理（BufferStateから分離）
pub const FileMetadata = struct {
    filename: ?[]const u8, // ファイル名（nullなら*scratch*）
    filename_normalized: ?[]const u8, // 正規化パス（realpath結果、検索高速化用）
    readonly: bool, // 読み取り専用フラグ
    mtime: ?i128, // ファイルの最終更新時刻
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FileMetadata {
        return .{
            .filename = null,
            .filename_normalized = null,
            .readonly = false,
            .mtime = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FileMetadata) void {
        if (self.filename) |fname| {
            self.allocator.free(fname);
        }
        if (self.filename_normalized) |fname_norm| {
            self.allocator.free(fname_norm);
        }
    }

    /// バッファ名を取得（ファイル名がなければ*scratch*）
    pub inline fn getName(self: *const FileMetadata) []const u8 {
        if (self.filename) |fname| {
            return std.fs.path.basename(fname);
        }
        return config.Messages.BUFFER_SCRATCH;
    }

    /// フルパスを取得
    pub fn getPath(self: *const FileMetadata) ?[]const u8 {
        return self.filename;
    }

    /// ファイル名を安全に設定する
    /// 新しいファイル名をdupeしてから古い値をfreeする
    pub fn setFilename(self: *FileMetadata, new_filename: []const u8) !void {
        const new_name = try self.allocator.dupe(u8, new_filename);
        self.setFilenameOwned(new_name);
    }

    /// 既にアロケートされたファイル名の所有権を受け取って設定する
    pub fn setFilenameOwned(self: *FileMetadata, new_filename: []const u8) void {
        if (self.filename) |old| {
            self.allocator.free(old);
        }
        self.filename = new_filename;
        // ファイル名が変わったのでnormalized pathをリセット
        if (self.filename_normalized) |old_norm| {
            self.allocator.free(old_norm);
            self.filename_normalized = null;
        }
    }
};

/// バッファ状態
/// EditingContextを内包し、ファイル情報を追加する
pub const BufferState = struct {
    id: usize, // バッファID（一意）
    editing_ctx: *EditingContext, // 編集コンテキスト（Buffer + cursor + undo + kill_ring）
    file: FileMetadata, // ファイルメタデータ
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize) !*BufferState {
        const self = try allocator.create(BufferState);
        errdefer allocator.destroy(self);

        const editing_ctx = try EditingContext.init(allocator);
        errdefer editing_ctx.deinit();

        self.* = BufferState{
            .id = id,
            .editing_ctx = editing_ctx,
            .file = FileMetadata.init(allocator),
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *BufferState) void {
        self.editing_ctx.deinit();
        self.file.deinit();
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
        // 注意: errdeferを使わず手動でエラー処理する
        // 理由: errdeferは関数全体にスコープするため、後続のエラーでダブルフリーが発生する
        const new_buffer = try self.allocator.create(Buffer);
        new_buffer.* = Buffer.loadFromFile(self.allocator, path) catch |err| {
            // loadFromFile失敗時は新しいバッファのみ解放
            self.allocator.destroy(new_buffer);
            return err;
        };
        // ロード成功後に古いバッファを解放し、新しいバッファに差し替え
        // この順序により、失敗時もediting_ctx.bufferは常に有効なバッファを指す
        const old_buffer = buffer_state.editing_ctx.buffer;
        buffer_state.editing_ctx.buffer = new_buffer;
        old_buffer.deinit();
        self.allocator.destroy(old_buffer);

        // ファイル名を設定
        buffer_state.file.filename = try self.allocator.dupe(u8, path);
        // 正規化パスは遅延初期化: findByFilename()で必要時に計算
        // NFS等での起動時間短縮のため、ここではrealpathを呼ばない

        // ファイルのmtimeを取得（Buffer.loadFromFileで既に取得済みなので再オープン不要）
        buffer_state.file.mtime = new_buffer.loaded_mtime;

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
    /// パスを正規化して比較するため、相対/絶対パスの違いに関わらず同じファイルを検出
    pub fn findByFilename(self: *Self, filename: []const u8) ?*BufferState {
        // 高速パス: まず単純な文字列比較（realpath呼び出しを回避）
        for (self.buffers.items) |buffer| {
            if (buffer.file.filename) |buf_filename| {
                if (std.mem.eql(u8, buf_filename, filename)) {
                    return buffer;
                }
            }
        }

        // パスを正規化して比較
        // 1. まずrealpathを試す（ファイルが存在する場合の正規化）
        // 2. 失敗した場合はpath.resolveで論理的に正規化（新規ファイル対応）
        const normalized_input = std.fs.cwd().realpathAlloc(self.allocator, filename) catch blk: {
            // ファイルが存在しない場合は論理的にパスを正規化
            break :blk std.fs.path.resolve(self.allocator, &.{filename}) catch return null;
        };
        defer self.allocator.free(normalized_input);

        for (self.buffers.items) |buffer| {
            // filename_normalizedが未計算なら遅延初期化
            if (buffer.file.filename_normalized == null) {
                if (buffer.file.filename) |buf_filename| {
                    // まずrealpathを試し、失敗したらpath.resolveを使う
                    buffer.file.filename_normalized = std.fs.cwd().realpathAlloc(self.allocator, buf_filename) catch
                        std.fs.path.resolve(self.allocator, &.{buf_filename}) catch null;
                }
            }
            if (buffer.file.filename_normalized) |buf_norm| {
                if (std.mem.eql(u8, normalized_input, buf_norm)) {
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

    /// バッファ数を取得
    pub inline fn bufferCount(self: *const Self) usize {
        return self.buffers.items.len;
    }

    /// 全バッファのイテレータ
    pub fn iterator(self: *Self) []*BufferState {
        return self.buffers.items;
    }

    /// 最初のバッファを取得（初期化直後の*scratch*バッファなど）
    pub fn getFirst(self: *Self) ?*BufferState {
        if (self.buffers.items.len > 0) {
            return self.buffers.items[0];
        }
        return null;
    }
};
