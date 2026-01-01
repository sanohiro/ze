// help.zig のユニットテスト
// キー説明機能のテスト

const std = @import("std");
const testing = std.testing;
const input = @import("input");

// ========================================
// describeKey 関数のテスト用再実装
// ========================================

fn describeKey(key: input.Key) []const u8 {
    return switch (key) {
        .ctrl => |c| switch (c) {
            0, '@' => "C-Space/C-@: set-mark",
            'a' => "C-a: beginning-of-line",
            'b' => "C-b: backward-char",
            'd' => "C-d: delete-char",
            'e' => "C-e: end-of-line",
            'f' => "C-f: forward-char",
            'g' => "C-g: cancel",
            'h' => "C-h: backspace",
            'k' => "C-k: kill-line",
            'l' => "C-l: recenter",
            'n' => "C-n: next-line",
            'p' => "C-p: previous-line",
            'r' => "C-r: isearch-backward",
            's' => "C-s: isearch-forward",
            'u' => "C-u: undo",
            'v' => "C-v: scroll-down",
            'w' => "C-w: kill-region",
            'x' => "C-x: prefix",
            'y' => "C-y: yank",
            '/' => "C-/: redo",
            else => "Unknown key",
        },
        .alt => |c| switch (c) {
            '%' => "M-%: query-replace",
            ';' => "M-;: comment-toggle",
            '<' => "M-<: beginning-of-buffer",
            '>' => "M->: end-of-buffer",
            '?' => "M-?: help",
            '^' => "M-^: join-line",
            'b' => "M-b: backward-word",
            'B' => "M-B: select-backward-word",
            'd' => "M-d: kill-word",
            'f' => "M-f: forward-word",
            'F' => "M-F: select-forward-word",
            'o' => "M-o: next-window",
            'v' => "M-v: scroll-up",
            'V' => "M-V: select-scroll-up",
            'w' => "M-w: copy-region",
            'x' => "M-x: command",
            '{' => "M-{: backward-paragraph",
            '}' => "M-}: forward-paragraph",
            '|' => "M-|: shell-command",
            else => "Unknown key",
        },
        .ctrl_alt => |c| switch (c) {
            's' => "C-M-s: regex-isearch-forward",
            'r' => "C-M-r: regex-isearch-backward",
            '%' => "C-M-%: regex-query-replace",
            else => "Unknown key",
        },
        .enter => "Enter: newline",
        .backspace => "Backspace: delete-backward-char",
        .tab => "Tab: indent / insert-tab",
        .shift_tab => "S-Tab: unindent",
        .arrow_up => "Up: previous-line",
        .arrow_down => "Down: next-line",
        .arrow_left => "Left: backward-char",
        .arrow_right => "Right: forward-char",
        .home => "Home: beginning-of-line",
        .end_key => "End: end-of-line",
        .page_up => "PageUp: scroll-up",
        .page_down => "PageDown: scroll-down",
        .delete => "Delete: delete-char",
        .escape => "Escape: cancel",
        .alt_delete => "M-Delete: kill-word",
        .alt_arrow_up => "M-Up: move-line-up",
        .alt_arrow_down => "M-Down: move-line-down",
        .alt_arrow_left => "M-Left: backward-word",
        .alt_arrow_right => "M-Right: forward-word",
        .shift_arrow_up => "S-Up: select-up",
        .shift_arrow_down => "S-Down: select-down",
        .shift_arrow_left => "S-Left: select-left",
        .shift_arrow_right => "S-Right: select-right",
        .shift_alt_arrow_up => "S-M-Up: select-up",
        .shift_alt_arrow_down => "S-M-Down: select-down",
        .shift_alt_arrow_left => "S-M-Left: select-backward-word",
        .shift_alt_arrow_right => "S-M-Right: select-forward-word",
        .shift_page_up => "S-PageUp: select-page-up",
        .shift_page_down => "S-PageDown: select-page-down",
        .ctrl_tab => "C-Tab: next-window",
        .ctrl_shift_tab => "C-S-Tab: previous-window",
        else => "Unknown key",
    };
}

// ========================================
// Ctrl キーのテスト
// ========================================

test "describeKey - C-a" {
    const desc = describeKey(.{ .ctrl = 'a' });
    try testing.expectEqualStrings("C-a: beginning-of-line", desc);
}

test "describeKey - C-e" {
    const desc = describeKey(.{ .ctrl = 'e' });
    try testing.expectEqualStrings("C-e: end-of-line", desc);
}

test "describeKey - C-f" {
    const desc = describeKey(.{ .ctrl = 'f' });
    try testing.expectEqualStrings("C-f: forward-char", desc);
}

test "describeKey - C-b" {
    const desc = describeKey(.{ .ctrl = 'b' });
    try testing.expectEqualStrings("C-b: backward-char", desc);
}

test "describeKey - C-n" {
    const desc = describeKey(.{ .ctrl = 'n' });
    try testing.expectEqualStrings("C-n: next-line", desc);
}

test "describeKey - C-p" {
    const desc = describeKey(.{ .ctrl = 'p' });
    try testing.expectEqualStrings("C-p: previous-line", desc);
}

test "describeKey - C-k" {
    const desc = describeKey(.{ .ctrl = 'k' });
    try testing.expectEqualStrings("C-k: kill-line", desc);
}

test "describeKey - C-y" {
    const desc = describeKey(.{ .ctrl = 'y' });
    try testing.expectEqualStrings("C-y: yank", desc);
}

test "describeKey - C-u (undo)" {
    const desc = describeKey(.{ .ctrl = 'u' });
    try testing.expectEqualStrings("C-u: undo", desc);
}

test "describeKey - C-/ (redo)" {
    const desc = describeKey(.{ .ctrl = '/' });
    try testing.expectEqualStrings("C-/: redo", desc);
}

test "describeKey - C-x (prefix)" {
    const desc = describeKey(.{ .ctrl = 'x' });
    try testing.expectEqualStrings("C-x: prefix", desc);
}

test "describeKey - C-g (cancel)" {
    const desc = describeKey(.{ .ctrl = 'g' });
    try testing.expectEqualStrings("C-g: cancel", desc);
}

test "describeKey - C-Space (set-mark)" {
    const desc = describeKey(.{ .ctrl = 0 });
    try testing.expectEqualStrings("C-Space/C-@: set-mark", desc);
}

test "describeKey - C-@ (set-mark)" {
    const desc = describeKey(.{ .ctrl = '@' });
    try testing.expectEqualStrings("C-Space/C-@: set-mark", desc);
}

test "describeKey - 未知のCtrlキー" {
    const desc = describeKey(.{ .ctrl = 'z' });
    try testing.expectEqualStrings("Unknown key", desc);
}

// ========================================
// Alt キーのテスト
// ========================================

test "describeKey - M-f" {
    const desc = describeKey(.{ .alt = 'f' });
    try testing.expectEqualStrings("M-f: forward-word", desc);
}

test "describeKey - M-b" {
    const desc = describeKey(.{ .alt = 'b' });
    try testing.expectEqualStrings("M-b: backward-word", desc);
}

test "describeKey - M-d" {
    const desc = describeKey(.{ .alt = 'd' });
    try testing.expectEqualStrings("M-d: kill-word", desc);
}

test "describeKey - M-w" {
    const desc = describeKey(.{ .alt = 'w' });
    try testing.expectEqualStrings("M-w: copy-region", desc);
}

test "describeKey - M-x" {
    const desc = describeKey(.{ .alt = 'x' });
    try testing.expectEqualStrings("M-x: command", desc);
}

test "describeKey - M-%" {
    const desc = describeKey(.{ .alt = '%' });
    try testing.expectEqualStrings("M-%: query-replace", desc);
}

test "describeKey - M-<" {
    const desc = describeKey(.{ .alt = '<' });
    try testing.expectEqualStrings("M-<: beginning-of-buffer", desc);
}

test "describeKey - M->" {
    const desc = describeKey(.{ .alt = '>' });
    try testing.expectEqualStrings("M->: end-of-buffer", desc);
}

test "describeKey - M-; (comment)" {
    const desc = describeKey(.{ .alt = ';' });
    try testing.expectEqualStrings("M-;: comment-toggle", desc);
}

test "describeKey - M-| (shell)" {
    const desc = describeKey(.{ .alt = '|' });
    try testing.expectEqualStrings("M-|: shell-command", desc);
}

test "describeKey - M-F (select forward word)" {
    const desc = describeKey(.{ .alt = 'F' });
    try testing.expectEqualStrings("M-F: select-forward-word", desc);
}

test "describeKey - M-B (select backward word)" {
    const desc = describeKey(.{ .alt = 'B' });
    try testing.expectEqualStrings("M-B: select-backward-word", desc);
}

// ========================================
// Ctrl+Alt キーのテスト
// ========================================

test "describeKey - C-M-s" {
    const desc = describeKey(.{ .ctrl_alt = 's' });
    try testing.expectEqualStrings("C-M-s: regex-isearch-forward", desc);
}

test "describeKey - C-M-r" {
    const desc = describeKey(.{ .ctrl_alt = 'r' });
    try testing.expectEqualStrings("C-M-r: regex-isearch-backward", desc);
}

test "describeKey - C-M-%" {
    const desc = describeKey(.{ .ctrl_alt = '%' });
    try testing.expectEqualStrings("C-M-%: regex-query-replace", desc);
}

// ========================================
// 特殊キーのテスト
// ========================================

test "describeKey - Enter" {
    const desc = describeKey(.enter);
    try testing.expectEqualStrings("Enter: newline", desc);
}

test "describeKey - Backspace" {
    const desc = describeKey(.backspace);
    try testing.expectEqualStrings("Backspace: delete-backward-char", desc);
}

test "describeKey - Tab" {
    const desc = describeKey(.tab);
    try testing.expectEqualStrings("Tab: indent / insert-tab", desc);
}

test "describeKey - Shift+Tab" {
    const desc = describeKey(.shift_tab);
    try testing.expectEqualStrings("S-Tab: unindent", desc);
}

test "describeKey - Escape" {
    const desc = describeKey(.escape);
    try testing.expectEqualStrings("Escape: cancel", desc);
}

test "describeKey - Delete" {
    const desc = describeKey(.delete);
    try testing.expectEqualStrings("Delete: delete-char", desc);
}

// ========================================
// 矢印キーのテスト
// ========================================

test "describeKey - Arrow Up" {
    const desc = describeKey(.arrow_up);
    try testing.expectEqualStrings("Up: previous-line", desc);
}

test "describeKey - Arrow Down" {
    const desc = describeKey(.arrow_down);
    try testing.expectEqualStrings("Down: next-line", desc);
}

test "describeKey - Arrow Left" {
    const desc = describeKey(.arrow_left);
    try testing.expectEqualStrings("Left: backward-char", desc);
}

test "describeKey - Arrow Right" {
    const desc = describeKey(.arrow_right);
    try testing.expectEqualStrings("Right: forward-char", desc);
}

// ========================================
// ナビゲーションキーのテスト
// ========================================

test "describeKey - Home" {
    const desc = describeKey(.home);
    try testing.expectEqualStrings("Home: beginning-of-line", desc);
}

test "describeKey - End" {
    const desc = describeKey(.end_key);
    try testing.expectEqualStrings("End: end-of-line", desc);
}

test "describeKey - PageUp" {
    const desc = describeKey(.page_up);
    try testing.expectEqualStrings("PageUp: scroll-up", desc);
}

test "describeKey - PageDown" {
    const desc = describeKey(.page_down);
    try testing.expectEqualStrings("PageDown: scroll-down", desc);
}

// ========================================
// 修飾キー付き矢印キーのテスト
// ========================================

test "describeKey - Shift+Arrow Up" {
    const desc = describeKey(.shift_arrow_up);
    try testing.expectEqualStrings("S-Up: select-up", desc);
}

test "describeKey - Alt+Arrow Up" {
    const desc = describeKey(.alt_arrow_up);
    try testing.expectEqualStrings("M-Up: move-line-up", desc);
}

test "describeKey - Alt+Arrow Down" {
    const desc = describeKey(.alt_arrow_down);
    try testing.expectEqualStrings("M-Down: move-line-down", desc);
}

test "describeKey - Alt+Delete" {
    const desc = describeKey(.alt_delete);
    try testing.expectEqualStrings("M-Delete: kill-word", desc);
}

// ========================================
// タブ切り替えのテスト
// ========================================

test "describeKey - Ctrl+Tab" {
    const desc = describeKey(.ctrl_tab);
    try testing.expectEqualStrings("C-Tab: next-window", desc);
}

test "describeKey - Ctrl+Shift+Tab" {
    const desc = describeKey(.ctrl_shift_tab);
    try testing.expectEqualStrings("C-S-Tab: previous-window", desc);
}
