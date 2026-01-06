// ============================================================================
// Help - ヘルプテキストとキー説明
// ============================================================================

const input = @import("input");

/// ヘルプテキスト
pub const help_text =
    \\ze - Zero-latency Editor
    \\
    \\NAVIGATION
    \\  C-f/C-b     Forward/backward char     M-f/M-b     Forward/backward word
    \\  C-n/C-p     Next/previous line        C-v/M-v     Page down/up
    \\  C-a/C-e     Beginning/end of line     M-</M->     Beginning/end of buffer
    \\  C-l         Center cursor on screen   M-{/M-}     Backward/forward paragraph
    \\
    \\SELECTION
    \\  C-Space     Set/unset mark            C-x h       Select all
    \\  Shift+Arrow Select while moving       M-F/M-B     Select word (Shift+Alt)
    \\
    \\EDITING
    \\  C-d         Delete char               M-d         Delete word
    \\  C-k         Kill to end of line       C-u/C-/     Undo/redo
    \\  C-w/M-w     Cut/copy region           C-y         Paste
    \\  M-^         Join lines                M-;         Toggle comment
    \\  Tab/S-Tab   Indent/unindent           M-Up/Down   Move line up/down
    \\  Insert      Toggle overwrite mode     (Mac: M-x ow)
    \\
    \\SEARCH & REPLACE
    \\  C-s/C-r     Search forward/backward   M-%         Query replace
    \\  C-M-s/C-M-r Regex search fwd/bwd      C-M-%       Regex query replace
    \\  M-r         Toggle regex/literal      Up/Down     Search history
    \\
    \\FILE
    \\  C-x C-f     Open file                 C-x C-s     Save
    \\  C-x C-w     Save as                   C-x C-c     Quit
    \\  C-x C-n     New buffer
    \\
    \\WINDOW & BUFFER
    \\  C-x 2/3     Split horizontal/vertical C-x o/M-o   Next window
    \\  C-x 0/1     Close window/others       C-x b       Switch buffer
    \\  C-x C-b     Buffer list               C-x k       Kill buffer
    \\
    \\MACRO
    \\  C-x (       Start recording           C-x )       Stop recording
    \\  C-x e       Execute macro             e           Repeat (after C-x e)
    \\
    \\RECTANGLE (mark + cursor = opposite corners, no visual rect)
    \\  C-x r k     Kill (cut)                C-x r w     Copy
    \\  C-x r y     Yank at cursor
    \\
    \\SHELL (M-|)
    \\  [source] | cmd [dest]     Source: (selection), %, .  Dest: (show), >, +>, n>
    \\
    \\OTHER
    \\  M-x         Execute command           M-?         This help
    \\  C-g/Esc     Cancel
    \\
    \\M-x COMMANDS: line, tab, indent, mode, key, revert, ro, kill-buffer, overwrite, ?
    \\
    \\Note: Tab completes file paths and M-x commands.
;

/// ヘルプバッファ名
pub const help_buffer_name = "*Help*";

/// キーの説明を返す
pub fn describeKey(key: input.Key) []const u8 {
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
        .insert => "Insert: toggle-overwrite-mode",
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
