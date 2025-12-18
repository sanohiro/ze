const std = @import("std");
const config = @import("config");
const Editor = @import("editor").Editor;
const PieceIterator = @import("buffer").PieceIterator;
const EditingContext = @import("editing_context").EditingContext;

// ========================================
// 共通ヘルパー関数
// ========================================

/// 文字の表示幅を計算（タブは現在列に基づいて展開）
fn getCharWidth(base: u21, width: usize, current_col: usize, tab_width: usize) usize {
    if (base == '\t') {
        // タブは次のタブストップまで進める
        return (current_col / tab_width + 1) * tab_width - current_col;
    }
    return width;
}

/// 行の境界を取得（line_start, line_end）
/// line_endは改行を含まない（行の最後の文字の次の位置）
const LineBounds = struct {
    start: usize,
    end: usize,
};

fn getLineBounds(buffer: anytype, line_num: usize) ?LineBounds {
    const line_start = buffer.getLineStart(line_num) orelse return null;
    const next_line_start = buffer.getLineStart(line_num + 1);
    const line_end = if (next_line_start) |nls|
        if (nls > 0 and nls > line_start) nls - 1 else nls
    else
        buffer.len();
    return .{ .start = line_start, .end = line_end };
}

/// 列範囲をバイト位置に変換
/// 表示幅（ダブルワイド文字、タブ展開）を考慮して、left_col〜right_colの範囲をバイト位置に変換
const ByteRange = struct {
    start: usize,
    end: usize,
};

fn getColumnByteRange(buffer: anytype, line_bounds: LineBounds, left_col: usize, right_col: usize, tab_width: usize) ByteRange {
    var iter = PieceIterator.init(buffer);
    iter.seek(line_bounds.start);

    var current_col: usize = 0;

    // left_col の位置を探す
    while (iter.global_pos < line_bounds.end and current_col < left_col) {
        const gc = iter.nextGraphemeCluster() catch break;
        if (gc) |cluster| {
            current_col += getCharWidth(cluster.base, cluster.width, current_col, tab_width);
        } else break;
    }
    const start_pos = iter.global_pos;

    // right_col の位置を探す
    while (iter.global_pos < line_bounds.end and current_col < right_col) {
        const gc = iter.nextGraphemeCluster() catch break;
        if (gc) |cluster| {
            current_col += getCharWidth(cluster.base, cluster.width, current_col, tab_width);
        } else break;
    }
    const end_pos = iter.global_pos;

    return .{ .start = start_pos, .end = end_pos };
}

/// 指定位置のカラムまで進み、バイト位置を返す
/// 行が短い場合は、到達したカラム数も返す（パディング計算用）
const ColumnSeekResult = struct {
    byte_pos: usize,
    reached_col: usize,
};

fn seekToColumn(buffer: anytype, line_bounds: LineBounds, target_col: usize, tab_width: usize) ColumnSeekResult {
    var iter = PieceIterator.init(buffer);
    iter.seek(line_bounds.start);

    var current_col: usize = 0;
    while (iter.global_pos < line_bounds.end and current_col < target_col) {
        const gc = iter.nextGraphemeCluster() catch break;
        if (gc) |cluster| {
            current_col += getCharWidth(cluster.base, cluster.width, current_col, tab_width);
        } else break;
    }

    return .{ .byte_pos = iter.global_pos, .reached_col = current_col };
}

/// バッファからバイト範囲のテキストを抽出
fn extractBytes(allocator: std.mem.Allocator, buffer: anytype, start: usize, end: usize) ![]const u8 {
    if (end <= start) return allocator.dupe(u8, "");

    var line_buf: std.ArrayList(u8) = .{};
    errdefer line_buf.deinit(allocator);

    var iter = PieceIterator.init(buffer);
    iter.seek(start);
    while (iter.global_pos < end) {
        const byte = iter.next() orelse break;
        try line_buf.append(allocator, byte);
    }

    return try line_buf.toOwnedSlice(allocator);
}

/// 古い rectangle_ring をクリーンアップ
fn cleanupRectangleRing(e: *Editor) void {
    if (e.rectangle_ring) |*old_ring| {
        for (old_ring.items) |line| {
            e.allocator.free(line);
        }
        old_ring.deinit(e.allocator);
        e.rectangle_ring = null; // use-after-free防止
    }
}

/// 矩形領域の範囲情報を取得する共通関数
fn getRectangleInfo(e: *Editor) ?struct {
    start_line: usize,
    end_line: usize,
    left_col: usize,
    right_col: usize,
} {
    const window = e.getCurrentWindow();
    const mark = window.mark_pos orelse {
        e.getCurrentView().setError(config.Messages.NO_MARK_SET);
        return null;
    };

    const cursor = e.getCurrentView().getCursorBufferPos();
    const buffer = e.getCurrentBufferContent();

    const start_pos = @min(mark, cursor);
    const end_pos = @max(mark, cursor);

    const start_line = buffer.findLineByPos(start_pos);
    const end_line = buffer.findLineByPos(end_pos);

    const start_col = buffer.findColumnByPos(start_pos);
    const end_col = buffer.findColumnByPos(end_pos);

    return .{
        .start_line = start_line,
        .end_line = end_line,
        .left_col = @min(start_col, end_col),
        .right_col = @max(start_col, end_col),
    };
}

/// 矩形領域をコピー（C-x r w）- 削除せずにコピーのみ
pub fn copyRectangle(e: *Editor) !void {
    const info = getRectangleInfo(e) orelse return;
    const buffer = e.getCurrentBufferContent();
    const tab_width: usize = e.getCurrentView().getTabWidth();

    cleanupRectangleRing(e);

    // 新しい rectangle_ring を作成
    var rect_ring: std.ArrayList([]const u8) = .{};
    errdefer {
        for (rect_ring.items) |line| {
            e.allocator.free(line);
        }
        rect_ring.deinit(e.allocator);
    }

    // 各行から矩形領域を抽出
    var line_num = info.start_line;
    while (line_num <= info.end_line) : (line_num += 1) {
        const bounds = getLineBounds(buffer, line_num) orelse continue;
        const byte_range = getColumnByteRange(buffer, bounds, info.left_col, info.right_col, tab_width);

        if (byte_range.end > byte_range.start) {
            const line_text = try extractBytes(e.allocator, buffer, byte_range.start, byte_range.end);
            try rect_ring.append(e.allocator, line_text);
        }
    }

    e.rectangle_ring = rect_ring;
    e.getCurrentWindow().mark_pos = null;
    e.getCurrentView().setError(config.Messages.RECTANGLE_COPIED);
}

/// 矩形領域の削除（C-x r k）
pub fn killRectangle(e: *Editor) !void {
    if (e.isReadOnly()) return;

    const info = getRectangleInfo(e) orelse return;
    const buffer = e.getCurrentBufferContent();
    const buffer_state = e.getCurrentBuffer();
    const editing_ctx = buffer_state.editing_ctx;
    const tab_width: usize = e.getCurrentView().getTabWidth();

    cleanupRectangleRing(e);

    // 新しい rectangle_ring を作成
    var rect_ring: std.ArrayList([]const u8) = .{};
    errdefer {
        for (rect_ring.items) |line| {
            e.allocator.free(line);
        }
        rect_ring.deinit(e.allocator);
    }

    // 削除情報を一時保存（下から削除するため）
    const DeleteInfo = struct {
        pos: usize,
        len: usize,
        text: []const u8,
    };
    var delete_infos: std.ArrayList(DeleteInfo) = .{};
    defer {
        for (delete_infos.items) |info_item| {
            e.allocator.free(info_item.text);
        }
        delete_infos.deinit(e.allocator);
    }

    // 各行から矩形領域を抽出（まだ削除しない）
    var line_num = info.start_line;
    while (line_num <= info.end_line) : (line_num += 1) {
        const bounds = getLineBounds(buffer, line_num) orelse continue;
        const byte_range = getColumnByteRange(buffer, bounds, info.left_col, info.right_col, tab_width);

        if (byte_range.end > byte_range.start) {
            // テキストを抽出してrect_ringに追加
            const line_text = try extractBytes(e.allocator, buffer, byte_range.start, byte_range.end);
            errdefer e.allocator.free(line_text);
            try rect_ring.append(e.allocator, line_text);

            // 削除情報を保存（テキストのコピーを作成）
            const text_copy = try e.allocator.dupe(u8, line_text);
            try delete_infos.append(e.allocator, .{
                .pos = byte_range.start,
                .len = byte_range.end - byte_range.start,
                .text = text_copy,
            });
        }
    }

    // 下から上に削除（位置がずれないように）
    const cursor_before = editing_ctx.cursor;
    var i = delete_infos.items.len;
    while (i > 0) {
        i -= 1;
        const del_info = delete_infos.items[i];
        // バッファから削除（先に実行、失敗時はUndo記録を残さない）
        try buffer.delete(del_info.pos, del_info.len);
        // 削除後のロールバック用errdefer（recordDeleteOpが失敗した場合）
        errdefer buffer.insertSlice(del_info.pos, del_info.text) catch {};
        // Undo履歴に記録
        try editing_ctx.recordDeleteOp(del_info.pos, del_info.text, cursor_before);
    }

    e.rectangle_ring = rect_ring;

    // modified と dirty を設定
    buffer_state.editing_ctx.modified = true;
    e.markAllViewsDirtyForBuffer(buffer_state.id, info.start_line, null);

    e.getCurrentWindow().mark_pos = null;
    e.getCurrentView().setError(config.Messages.RECTANGLE_KILLED);
}

/// 矩形の貼り付け（C-x r y）
pub fn yankRectangle(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const rect = e.rectangle_ring orelse {
        e.getCurrentView().setError(config.Messages.NO_RECTANGLE_TO_YANK);
        return;
    };

    if (rect.items.len == 0) {
        e.getCurrentView().setError(config.Messages.RECTANGLE_EMPTY);
        return;
    }

    // 現在のカーソル位置を取得
    const cursor_pos = e.getCurrentView().getCursorBufferPos();
    const buffer = e.getCurrentBufferContent();
    const buffer_state = e.getCurrentBuffer();
    const editing_ctx = buffer_state.editing_ctx;
    const cursor_line = buffer.findLineByPos(cursor_pos);
    const cursor_col = buffer.findColumnByPos(cursor_pos);
    const cursor_before = editing_ctx.cursor;
    const tab_width: usize = e.getCurrentView().getTabWidth();

    // 挿入情報を収集（上から下に挿入するため、位置調整が必要）
    const InsertInfo = struct {
        pos: usize,
        text: []const u8,
        owned: bool, // パディングで作成したテキストか（解放が必要）
    };
    var insert_infos: std.ArrayList(InsertInfo) = .{};
    defer {
        // ownedフラグが立っているテキストを解放
        for (insert_infos.items) |ins_info| {
            if (ins_info.owned) {
                e.allocator.free(ins_info.text);
            }
        }
        insert_infos.deinit(e.allocator);
    }

    // 各行の挿入位置を計算
    for (rect.items, 0..) |line_text, i| {
        const target_line = cursor_line + i;

        // 対象行の境界を取得（存在しない場合は新規作成）
        const bounds = getLineBounds(buffer, target_line) orelse blk: {
            // 行が存在しない場合は、改行を追加して新しい行を作成
            const buf_end = buffer.len();
            buffer.insert(buf_end, '\n') catch continue;
            // Undo記録
            editing_ctx.recordInsertOp(buf_end, "\n", cursor_before) catch {};
            // 新しく作成した行の境界を取得
            break :blk getLineBounds(buffer, target_line) orelse continue;
        };

        // 対象行のカラム cursor_col の位置を探す
        const seek_result = seekToColumn(buffer, bounds, cursor_col, tab_width);

        // 行が短くてcursor_colに届かない場合はスペースでパディング
        if (seek_result.reached_col < cursor_col) {
            const padding_needed = cursor_col - seek_result.reached_col;
            const padded_text = createPaddedText(e.allocator, padding_needed, line_text) orelse continue;
            try insert_infos.append(e.allocator, .{ .pos = seek_result.byte_pos, .text = padded_text, .owned = true });
        } else {
            try insert_infos.append(e.allocator, .{ .pos = seek_result.byte_pos, .text = line_text, .owned = false });
        }
    }

    // 下から上に挿入（位置がずれないように）
    var i = insert_infos.items.len;
    while (i > 0) {
        i -= 1;
        const ins_info = insert_infos.items[i];
        // バッファに挿入（先に実行、失敗時はUndo記録を残さない）
        try buffer.insertSlice(ins_info.pos, ins_info.text);
        // 挿入後のロールバック用errdefer（recordInsertOpが失敗した場合）
        errdefer buffer.delete(ins_info.pos, ins_info.text.len) catch {};
        // Undo履歴に記録
        try editing_ctx.recordInsertOp(ins_info.pos, ins_info.text, cursor_before);
    }

    // modified と dirty を設定
    buffer_state.editing_ctx.modified = true;
    e.markAllViewsDirtyForBuffer(buffer_state.id, cursor_line, null);

    e.getCurrentView().setError(config.Messages.RECTANGLE_YANKED);
}

/// パディング付きテキストを作成
fn createPaddedText(allocator: std.mem.Allocator, padding: usize, text: []const u8) ?[]const u8 {
    var padded = std.ArrayList(u8).initCapacity(allocator, padding + text.len) catch return null;
    errdefer padded.deinit(allocator);

    for (0..padding) |_| {
        padded.append(allocator, ' ') catch return null;
    }
    padded.appendSlice(allocator, text) catch return null;

    return padded.toOwnedSlice(allocator) catch null;
}
