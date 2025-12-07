# ze

**Zero-latency Editor**

[日本語](README.ja.md)

A lightweight, fast, modern editor that requires no configuration. Perfect for quick edits over SSH.

## Why ze?

- **Lightweight** — Under 300KB, no dependencies
- **Zero-config** — No dotfiles, just copy and use
- **Emacs keybindings** — Natural for Bash/Readline users
- **Full UTF-8 support** — Japanese, emoji, any character
- **Shell integration** — Pipe Unix commands from within the editor

## Requirements

- Linux (x86_64, aarch64)
- macOS (Intel, Apple Silicon)
- WSL2

## Install

Download pre-built binaries from [Releases](https://github.com/sanohiro/ze/releases), or build from source:

```bash
# Build (requires Zig 0.15+)
zig build -Doptimize=ReleaseFast

# Add to PATH (optional)
cp ./zig-out/bin/ze ~/.local/bin/
```

## Quick Start

```bash
ze file.txt          # Open a file
ze                    # Start with empty buffer
```

Save and quit: `C-x C-s` → `C-x C-c`

---

## Keybindings

ze uses Emacs-style keybindings. `C-` means Ctrl, `M-` means Alt/Option.

### Movement

| Key | Action |
|-----|--------|
| `C-f` / `C-b` | Forward/backward one character |
| `C-n` / `C-p` | Next/previous line |
| `C-a` / `C-e` | Beginning/end of line |
| `M-f` / `M-b` | Forward/backward one word |
| `C-v` / `M-v` | Page down/up |
| `M-<` / `M->` | Beginning/end of buffer |
| `C-l` | Center cursor line on screen |

### Editing

| Key | Action |
|-----|--------|
| `C-d` | Delete character |
| `M-d` | Delete word |
| `C-k` | Kill to end of line |
| `C-Space` | Set/unset mark (start/end selection) |
| `C-w` / `M-w` | Cut/copy |
| `C-y` | Paste |
| `C-u` / `C-/` | Undo/Redo |
| `M-^` | Join line with previous |
| `M-↑` / `M-↓` | Move line up/down |
| `Tab` / `S-Tab` | Indent/unindent |
| `M-;` | Toggle comment |

### File

| Key | Action |
|-----|--------|
| `C-x C-f` | Open file |
| `C-x C-s` | Save |
| `C-x C-w` | Save as |
| `C-x C-c` | Quit |

### Search & Replace

| Key | Action |
|-----|--------|
| `C-s` / `C-r` | Forward/backward search |
| `M-%` | Interactive replace (y/n/!/q) |

Regex supported: `\d+` for digits, `^TODO` for TODO at line start.

### Windows & Buffers

| Key | Action |
|-----|--------|
| `C-x 2` / `C-x 3` | Split horizontal/vertical |
| `C-x o` | Switch to next window |
| `C-x 0` / `C-x 1` | Close window/close others |
| `C-x b` | Switch buffer |
| `C-x C-b` | List buffers |
| `C-x k` | Kill buffer |

---

## Shell Integration

ze follows the Unix philosophy: "Text is a stream."

Advanced text processing is delegated to existing tools like `sort`, `jq`, `awk`, `sed`. ze acts as the pipeline connecting these tools to your buffer. No reinventing the wheel.

`M-|` executes shell commands, piping selection or buffer content.

### Syntax

```
[source] | command [destination]
```

### Source

| Symbol | Input |
|--------|-------|
| (none) | Selection |
| `%` | Entire buffer |
| `.` | Current line |

### Destination

| Symbol | Output |
|--------|--------|
| (none) | Display in command buffer |
| `>` | Replace source |
| `+>` | Insert at cursor |
| `n>` | New buffer |

### Examples

```bash
| date +>              # Insert date at cursor
| sort >               # Sort selection and replace
% | jq . >             # Format entire JSON buffer
. | sh >               # Execute current line as shell
% | grep TODO n>       # Extract TODO lines to new buffer
```

**C-g** cancels at any time. Long-running processes (LLM calls, etc.) are fine.

---

## M-x Commands

`M-x` opens the command prompt.

| Command | Description |
|---------|-------------|
| `line 100` | Jump to line 100 |
| `tab` / `tab 2` | Show/set tab width |
| `indent` | Show/set indent style |
| `revert` | Reload file |
| `ro` | Toggle read-only |
| `?` | List commands |

---

## Features

### Encoding

- Optimized for **UTF-8 + LF**. Converts to UTF-8+LF on load. Zero-copy mmap for UTF-8+LF files.
- Auto-detects UTF-8 (with/without BOM), UTF-16 (with BOM), Shift_JIS, EUC-JP, and line endings (LF, CRLF, CR).
- Preserves original encoding and line endings on save.

> Other encodings not supported. Use iconv or nkf for conversion.

## Roadmap

### Implemented

- Piece Table buffer with Undo/Redo
- Grapheme cluster support (emoji, CJK)
- Incremental search, regex, Query Replace
- Multi-buffer, window splitting
- Shell integration (M-|)
- Comment/indent settings for 48 languages
- Syntax highlighting for comments only

### Planned

- [ ] In-app help (`C-h ?`)
- [ ] Keyboard macros (`C-x (` / `)` / `e`)

### Not Implementing

- Syntax highlighting — ze is a config file editor, not an IDE
- LSP — Use VSCode for serious development
- Plugins — Maintaining simplicity
- Mouse — Keyboard only
- GUI — Terminal only

---

## Philosophy

1. **Speed** — Sub-8ms response. Game-level latency.
2. **Minimal** — Do one thing well.
3. **Unix** — Text is a stream. Pipes are first-class.
4. **Zero-config** — Copy and run.

---

## Inspiration

- [mg](https://github.com/hboetes/mg) — Minimal Emacs
- [kilo](https://github.com/antirez/kilo) — 1000-line editor
- [vis](https://github.com/martanne/vis) — Structural regex

---

## License

MIT

---

*"Do one thing well. Fast."*
