const std = @import("std");
const Editor = @import("../editor.zig").Editor;
const PieceIterator = @import("../buffer.zig").PieceIterator;
const EditingContext = @import("../editing_context.zig").EditingContext;

/// 矩形領域の削除（C-x r k）
pub fn killRectangle(e: *Editor) !void {
    if (e.isReadOnly()) return;

    const window = e.getCurrentWindow();
    const mark = window.mark_pos orelse {
        e.getCurrentView().setError("No mark set");
        return;
    };

    const cursor = e.getCurrentView().getCursorBufferPos();
    const buffer = e.getCurrentBufferContent();
    const buffer_state = e.getCurrentBuffer();
    const editing_ctx = buffer_state.editing_ctx;

    // マークとカーソルの位置から矩形の範囲を決定
    const start_pos = @min(mark, cursor);
    const end_pos = @max(mark, cursor);

    // 開始行と終了行を取得
    const start_line = buffer.findLineByPos(start_pos);
    const end_line = buffer.findLineByPos(end_pos);

    // 開始カラムと終了カラムを取得
    const start_col = buffer.findColumnByPos(start_pos);
    const end_col = buffer.findColumnByPos(end_pos);

    // カラム範囲を正規化（左から右へ）
    const left_col = @min(start_col, end_col);
    const right_col = @max(start_col, end_col);

    // 古い rectangle_ring をクリーンアップ
    if (e.rectangle_ring) |*old_ring| {
        for (old_ring.items) |line| {
            e.allocator.free(line);
        }
        old_ring.deinit(e.allocator);
    }

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
        for (delete_infos.items) |info| {
            e.allocator.free(info.text);
        }
        delete_infos.deinit(e.allocator);
    }

    // 各行から矩形領域を抽出（まだ削除しない）
    var line_num = start_line;
    while (line_num <= end_line) : (line_num += 1) {
        const line_start = buffer.getLineStart(line_num) orelse continue;

        // 次の行の開始位置（または末尾）を取得
        const next_line_start = buffer.getLineStart(line_num + 1);
        const line_end = if (next_line_start) |nls|
            if (nls > 0 and nls > line_start) nls - 1 else nls
        else
            buffer.len();

        // 行内のカラム位置を探す
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        var current_col: usize = 0;
        var rect_start_pos: ?usize = null;
        var rect_end_pos: ?usize = null;

        // left_col の位置を探す（表示幅を考慮）
        while (iter.global_pos < line_end and current_col < left_col) {
            const gc = iter.nextGraphemeCluster() catch break;
            if (gc) |cluster| {
                current_col += cluster.width;
            } else break;
        }
        rect_start_pos = iter.global_pos;

        // right_col の位置を探す（表示幅を考慮）
        while (iter.global_pos < line_end and current_col < right_col) {
            const gc = iter.nextGraphemeCluster() catch break;
            if (gc) |cluster| {
                current_col += cluster.width;
            } else break;
        }
        rect_end_pos = iter.global_pos;

        // 矩形領域のテキストを抽出
        if (rect_start_pos) |rsp| {
            if (rect_end_pos) |rep| {
                if (rep > rsp) {
                    // テキストを抽出
                    var line_buf: std.ArrayList(u8) = .{};
                    errdefer line_buf.deinit(e.allocator);

                    var extract_iter = PieceIterator.init(buffer);
                    extract_iter.seek(rsp);
                    while (extract_iter.global_pos < rep) {
                        const byte = extract_iter.next() orelse break;
                        try line_buf.append(e.allocator, byte);
                    }

                    const line_text = try line_buf.toOwnedSlice(e.allocator);
                    errdefer e.allocator.free(line_text);
                    try rect_ring.append(e.allocator, line_text);

                    // 削除情報を保存（テキストのコピーを作成）
                    const text_copy = try e.allocator.dupe(u8, line_text);
                    try delete_infos.append(e.allocator, .{
                        .pos = rsp,
                        .len = rep - rsp,
                        .text = text_copy,
                    });
                }
            }
        }
    }

    // 下から上に削除（位置がずれないように）
    const cursor_before = editing_ctx.cursor;
    var i = delete_infos.items.len;
    while (i > 0) {
        i -= 1;
        const info = delete_infos.items[i];
        // Undo履歴に記録
        try editing_ctx.recordDeleteOp(info.pos, info.text, cursor_before);
        // バッファから削除
        try buffer.delete(info.pos, info.len);
    }

    e.rectangle_ring = rect_ring;

    // modified と dirty を設定
    buffer_state.editing_ctx.modified = true;
    e.markAllViewsDirtyForBuffer(buffer_state.id, start_line, null);

    window.mark_pos = null;
    e.getCurrentView().setError("Rectangle killed");
}

/// 矩形の貼り付け（C-x r y）
pub fn yankRectangle(e: *Editor) !void {
    if (e.isReadOnly()) return;
    const rect = e.rectangle_ring orelse {
        e.getCurrentView().setError("No rectangle to yank");
        return;
    };

    if (rect.items.len == 0) {
        e.getCurrentView().setError("Rectangle is empty");
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

    // 挿入情報を収集（上から下に挿入するため、位置調整が必要）
    const InsertInfo = struct {
        pos: usize,
        text: []const u8,
    };
    var insert_infos: std.ArrayList(InsertInfo) = .{};
    defer insert_infos.deinit(e.allocator);

    // 各行の挿入位置を計算
    for (rect.items, 0..) |line_text, i| {
        const target_line = cursor_line + i;

        // 対象行の開始位置を取得
        const line_start = buffer.getLineStart(target_line) orelse blk: {
            // 行が存在しない場合は、改行を追加して新しい行を作成
            const buf_end = buffer.len();
            buffer.insert(buf_end, '\n') catch continue;
            // Undo記録
            editing_ctx.recordInsertOp(buf_end, "\n", cursor_before) catch {};
            // 新しく作成した行の開始位置を取得（改行の次の位置）
            break :blk buffer.getLineStart(target_line) orelse continue;
        };

        // 対象行のカラム cursor_col の位置を探す
        var iter = PieceIterator.init(buffer);
        iter.seek(line_start);

        // 次の行の開始位置（または末尾）を取得
        const next_line_start = buffer.getLineStart(target_line + 1);
        const line_end = if (next_line_start) |nls|
            if (nls > 0 and nls > line_start) nls - 1 else nls
        else
            buffer.len();

        var current_col: usize = 0;
        while (iter.global_pos < line_end and current_col < cursor_col) {
            const gc = iter.nextGraphemeCluster() catch break;
            if (gc) |cluster| {
                current_col += cluster.width;
            } else break;
        }

        const insert_pos = iter.global_pos;
        try insert_infos.append(e.allocator, .{ .pos = insert_pos, .text = line_text });
    }

    // 下から上に挿入（位置がずれないように）
    var i = insert_infos.items.len;
    while (i > 0) {
        i -= 1;
        const info = insert_infos.items[i];
        // Undo履歴に記録
        try editing_ctx.recordInsertOp(info.pos, info.text, cursor_before);
        // バッファに挿入
        try buffer.insertSlice(info.pos, info.text);
    }

    // modified と dirty を設定
    buffer_state.editing_ctx.modified = true;
    e.markAllViewsDirtyForBuffer(buffer_state.id, cursor_line, null);

    e.getCurrentView().setError("Rectangle yanked");
}
