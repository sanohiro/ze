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
| `M-<` / `M->` | Beginning/end of buffer |
| `C-l` | Center cursor line on screen |

## Editing

| Key | Action |
|-----|--------|
| `C-d` | Delete character |
| `M-d` | Delete word |
| `C-k` | Kill to end of line |
| `C-Space` | Set/unset mark (start/end selection) |
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
| `C-x C-f` | Open file |
| `C-x C-s` | Save |
| `C-x C-w` | Save as |
| `C-x C-c` | Quit |

## Search & Replace

| Key | Action |
|-----|--------|
| `C-s` / `C-r` | Search forward/backward |
| `M-%` | Query replace (y/n/!/q) |

Regex supported: `\d+` for digits, `^TODO` for TODO at line start.

## Window & Buffer

| Key | Action |
|-----|--------|
| `C-x 2` / `C-x 3` | Split horizontal/vertical |
| `C-x o` | Switch to next window |
| `C-x 0` / `C-x 1` | Close window/close others |
| `C-x b` | Switch buffer |
| `C-x C-b` | Buffer list |
| `C-x k` | Kill buffer |

## Shell Integration

| Key | Action |
|-----|--------|
| `M-\|` | Pipe to shell command |
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
- `>`: replace source
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

## M-x Commands

| Command | Action |
|---------|--------|
| `line N` | Jump to line N |
| `tab` / `tab N` | Show/set tab width |
| `indent` | Show/set indent style |
| `revert` | Reload file |
| `ro` | Toggle read-only |
| `?` | List all commands |

## Other

| Key | Action |
|-----|--------|
| `C-g` | Cancel current operation |
| `Escape` | Cancel / close prompt |
