# ze

**Zero-latency Editor**

[日本語](README.ja.md)

A lightweight, fast, modern editor that requires no configuration. Perfect for quick edits over SSH.

## Why ze?

- **Lightweight** — Under 300KB, no dependencies
- **Zero-config** — No dotfiles, just copy and use
- **Emacs-style editing** — Not just keybindings: multi-buffer, window splitting, the whole editing model
- **Shell integration** — Pipe to sort, jq, awk directly from the editor
- **Full UTF-8 support** — Japanese, emoji, grapheme clusters

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

## Shell Integration

ze follows the Unix philosophy: "Text is a stream."

Advanced text processing is delegated to existing tools like `sort`, `jq`, `awk`, `sed`. ze acts as the pipeline connecting these tools to your buffer. No reinventing the wheel.

`M-|` executes shell commands, piping selection or buffer content.

### Syntax

```
[source] | command [destination]
```

| Source | Input |
|--------|-------|
| (none) | Selection |
| `%` | Entire buffer |
| `.` | Current line |

| Destination | Output |
|-------------|--------|
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

## Keybindings

ze uses Emacs-style keybindings. `C-` means Ctrl, `M-` means Alt/Option.

| Key | Action |
|-----|--------|
| `C-f` / `C-b` / `C-n` / `C-p` | Move cursor |
| `C-s` / `C-r` | Search forward/backward |
| `M-%` | Query replace |
| `C-Space` | Start selection |
| `C-w` / `M-w` / `C-y` | Cut/copy/paste |
| `C-x 2` / `C-x 3` | Split window (horizontal/vertical) |
| `C-x b` | Switch buffer |
| `C-x C-s` | Save |
| `C-x C-c` | Quit |

**Full keybindings:** [KEYBINDINGS.md](KEYBINDINGS.md)

---

## Design Choices

### Comment-only syntax highlighting

ze highlights comments only. This is intentional:

- **Readability** — Comments stand out in config files
- **Not an IDE** — Full syntax highlighting adds complexity without benefit for ze's use case
- **Speed** — Minimal parsing overhead

### What ze won't do

- **Syntax highlighting** — ze is for config files, not coding
- **LSP** — Use VSCode for serious development
- **Plugins** — Simplicity over extensibility
- **Mouse / GUI** — Keyboard and terminal only

---

## Features

### Encoding

- Optimized for **UTF-8 + LF**. Zero-copy mmap for UTF-8+LF files.
- Auto-detects and converts: UTF-8 (with/without BOM), UTF-16 (with BOM), Shift_JIS, EUC-JP
- Auto-detects line endings (LF, CRLF, CR)
- **Saves in original encoding** (encoding, BOM, and line endings are preserved)

### M-x Commands

| Command | Description |
|---------|-------------|
| `line N` | Jump to line N |
| `tab` / `tab N` | Show/set tab width |
| `indent` | Show/set indent style |
| `revert` | Reload file |
| `ro` | Toggle read-only |
| `?` | List commands |

---

## Roadmap

### Implemented

- Piece Table buffer with Undo/Redo
- Grapheme cluster support (emoji, CJK)
- Incremental search, regex, Query Replace
- Multi-buffer, window splitting
- Shell integration (M-|)
- Comment/indent settings for 48 languages

### Planned

- [ ] In-app help (`C-h ?`)
- [ ] Keyboard macros (`C-x (` / `)` / `e`)

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
