# ze Keybindings

[日本語](KEYBINDINGS.ja.md)

`C-` = Ctrl, `M-` = Alt/Option

## Navigation

| Key | Action |
|-----|--------|
| `C-f` / `C-b` | Forward/backward one character |
| `C-n` / `C-p` | Next/previous line |
| `C-a` / `C-e` | Beginning/end of line |
| `M-f` / `M-b` | Forward/backward one word |
| `C-v` / `M-v` | Page down/up |
| Scroll gesture | Scroll view 3 lines, cursor stays (trackpad) |
| `M-<` / `M->` | Beginning/end of buffer |
| `M-{` / `M-}` | Backward/forward paragraph |
| `C-l` | Center cursor line on screen |

## Shift-Select (Selection Movement)

Hold Shift while moving to auto-set mark and extend selection.
Moving without Shift clears the selection.

| Key | Action |
|-----|--------|
| `Shift+Arrow` | Select character/line |
| `Shift+PageUp/Down` | Select by page |
| `Shift+Alt+Left/Right` | Select by word |
| `Shift+Alt+Up/Down` | Select line by line |
| `M-F` / `M-B` | Select by word (Alt+Shift+f/b) |
| `M-V` | Select page up (Alt+Shift+v) |
| `Alt+Left/Right` | Move by word (clears selection) |

**Note:** `Shift+C-f/b/n/p/v` not supported (indistinguishable in standard terminals).

## Editing

| Key | Action |
|-----|--------|
| `C-d` | Delete character |
| `M-d` | Delete word |
| `C-k` | Kill to end of line |
| `C-Space` | Set/unset mark (start/end selection) |
| `C-x h` | Select all |
| `C-w` / `M-w` | Cut/copy |
| `C-y` | Paste (yank) |
| `C-u` / `C-/` | Undo/redo |
| `M-^` | Join line with previous |
| `M-↑` / `M-↓` | Move line up/down |
| `Tab` / `S-Tab` | Indent/unindent |
| `M-;` | Toggle comment |

## File

| Key | Action |
|-----|--------|
| `C-x C-n` | New buffer |
| `C-x C-f` | Open file |
| `C-x C-s` | Save |
| `C-x C-w` | Save as |
| `C-x C-c` | Quit |

## Search & Replace

| Key | Action |
|-----|--------|
| `C-s` / `C-r` | Literal search forward/backward |
| `C-M-s` / `C-M-r` | Regex search forward/backward |
| `M-r` | Toggle regex/literal mode (in search mode) |
| `C-p` / `C-n` / `Up` / `Down` | Search history (in search mode) |
| `M-%` | Literal query replace (y/n/!/q) |
| `C-M-%` | Regex query replace (y/n/!/q) |

For regex search/replace, see [REGEX.md](REGEX.md) for supported syntax (`\d+`, `^TODO`, `,$`, etc.).

## Window & Buffer

| Key | Action |
|-----|--------|
| `C-x 2` | Split horizontal |
| `C-x 3` | Split vertical |
| `M-o` | Switch to next window |
| `C-x o` | Switch to next window (same as M-o) |
| `C-x 0` / `C-x 1` | Close window/close others |
| `C-x b` | Switch buffer |
| `C-x C-b` | Buffer list |
| `C-x k` | Kill buffer |

Note: `C-Tab` also works in some terminals (may require configuration).

## Shell Integration

| Key | Action |
|-----|--------|
| `M-\|` | Pipe to shell command |
| `C-p` / `C-n` | Previous/next command history |
| `C-g` | Cancel |

### Syntax

```
[source] | command [destination]
```

**Source:**
- (none): selection
- `%`: entire buffer
- `.`: current line

**Destination:**
- (none): show in command buffer
- `>`: replace source (insert at cursor if no selection)
- `+>`: insert at cursor
- `n>`: new buffer

### Examples

```bash
| date +>              # Insert date at cursor
| sort >               # Sort selection and replace
% | jq . >             # Format entire JSON
. | sh >               # Execute current line as shell
% | grep TODO n>       # Extract TODOs to new buffer
```

## Keyboard Macro

| Key | Action |
|-----|--------|
| `C-x (` | Start recording macro |
| `C-x )` | Stop recording macro |
| `C-x e` | Execute last macro |
| `e` | Repeat macro (after `C-x e`) |
| `C-g` | Cancel recording |

Record a sequence of keystrokes, then replay it. Press `e` repeatedly after `C-x e` to execute multiple times.

## Rectangle Operations

Operate on the rectangle defined by mark and cursor as opposite corners.

```
AAAA[mark]BBBBcccc        After C-x r k:     AAAAcccc
ddddEEEEffff              →                  ddddffff
ggggHHHH[cursor]iiii                         ggggiiii
```

| Key | Action |
|-----|--------|
| `C-x r k` | Kill (cut) rectangle |
| `C-x r w` | Copy rectangle (no delete) |
| `C-x r y` | Yank at cursor position |

Note: Rectangle uses separate storage from normal kill ring. C-y won't paste rectangles.

## M-x Commands

| Command | Action |
|---------|--------|
| `line N` | Jump to line N |
| `tab` / `tab N` | Show/set tab width |
| `indent` | Show/set indent style |
| `mode` / `mode X` | Show/set language mode (see [MODES.md](MODES.md)) |
| `key` | Describe key binding |
| `revert` | Reload file |
| `ro` | Toggle read-only |
| `exit` / `quit` | Quit with confirmation |
| `?` | List all commands |

**Note:** Tab key completes file paths and M-x commands.

## Other

| Key | Action |
|-----|--------|
| `M-?` | Show help |
| `C-g` | Cancel current operation |
| `Escape` | Cancel / close prompt |

## Data Files

ze stores history in `~/.ze/`:

- `shell_history` — M-| command history
- `search_history` — C-s/C-r search history
