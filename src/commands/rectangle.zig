const std = @import("std");
const Editor = @import("../editor.zig").Editor;
const PieceIterator = @import("../buffer.zig").PieceIterator;

/// 矩形領域の削除（C-x r k）
pub fn killRectangle(e: *Editor) !void {
    const window = e.getCurrentWindow();
    const mark = window.mark_pos orelse {
        e.getCurrentView().setError("No mark set");
        return;
    };

    const cursor = e.getCurrentView().getCursorBufferPos();
    const buffer = e.getCurrentBufferContent();

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

    // 各行から矩形領域を抽出して削除
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

        // left_col の位置を探す
        while (iter.global_pos < line_end and current_col < left_col) {
            _ = iter.nextGraphemeCluster() catch break;
            current_col += 1;
        }
        rect_start_pos = iter.global_pos;

        // right_col の位置を探す
        while (iter.global_pos < line_end and current_col < right_col) {
            _ = iter.nextGraphemeCluster() catch break;
            current_col += 1;
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

                    // バッファから削除
                    try buffer.delete(rsp, rep - rsp);
                }
            }
        }
    }

    e.rectangle_ring = rect_ring;
    e.getCurrentView().setError("Rectangle killed");
}

/// 矩形の貼り付け（C-x r y）
pub fn yankRectangle(e: *Editor) void {
    if (e.getCurrentBuffer().readonly) {
        e.getCurrentView().setError("Buffer is read-only");
        return;
    }
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
    const cursor_line = buffer.findLineByPos(cursor_pos);
    const cursor_col = buffer.findColumnByPos(cursor_pos);

    // 各行の矩形テキストをカーソル位置から挿入
    for (rect.items, 0..) |line_text, i| {
        const target_line = cursor_line + i;

        // 対象行の開始位置を取得
        const line_start = buffer.getLineStart(target_line) orelse {
            // 行が存在しない場合は、改行を追加して新しい行を作成
            const buf_end = buffer.len();
            buffer.insert(buf_end, '\n') catch continue;
            continue;
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
            _ = iter.nextGraphemeCluster() catch break;
            current_col += 1;
        }

        const insert_pos = iter.global_pos;

        // line_text を insert_pos に挿入
        buffer.insertSlice(insert_pos, line_text) catch continue;
    }

    const buffer_state = e.getCurrentBuffer();
    buffer_state.editing_ctx.modified = true;
    e.getCurrentView().setError("Rectangle yanked");
}
