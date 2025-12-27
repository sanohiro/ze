# ze — Zero-latency Editor

Instant startup over SSH. No config files. Just works.

[日本語](README.ja.md)

![ze demo](demo/ze_demo.gif)

Emacs keybindings, mg-like lightness.
For those who don't want to learn vim, but find nano lacking.

---

## ze is for you if

- You want comfortable editing over SSH without configuration
- Emacs keybindings are in your muscle memory
- You prefer composing with Unix tools (sort, jq, sed)
- You're tired of managing dotfiles

## ze is NOT for you if

- You need IDE features like completion or LSP
- You want to customize everything
- You prefer vim's modal editing

---

## Features

- **Under 500KB** — No dependencies, single binary
- **Zero-config** — No dotfiles, just copy and use
- **Emacs-style editing** — Multi-buffer, window splitting, kill ring
- **Shell integration** — Pipe to sort, jq, awk directly
- **Full UTF-8 support** — Japanese, emoji, grapheme clusters

## Requirements

- Linux (x86_64, aarch64)
- macOS (Intel, Apple Silicon)
- WSL2

## Install

### Homebrew (macOS/Linux)

```bash
brew tap sanohiro/ze
brew install ze
```

### Pre-built binaries

Download from [Releases](https://github.com/sanohiro/ze/releases) and place in your PATH.

### Build from source

```bash
# Requires Zig 0.15+
zig build -Doptimize=ReleaseFast
cp ./zig-out/bin/ze ~/.local/bin/
```

## Quick Start

```bash
ze file.txt          # Open a file
ze -R file.txt       # View file (read-only)
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
| `>` | Replace source (insert at cursor if no selection) |
| `+>` | Insert at cursor |
| `n>` | New buffer |

### Examples

```bash
| date +>              # Insert date at cursor
| sort >               # Sort selection and replace
% | jq . >             # Format entire JSON buffer
. | sh >               # Execute current line as shell
% | grep TODO n>       # Extract TODO lines to new buffer
| upper >              # Convert selection to uppercase (with alias)
| lower >              # Convert selection to lowercase (with alias)
```

**C-g** cancels at any time. Long-running processes (LLM calls, etc.) are fine.

### History & Completion

**Prefix history matching**: Type part of a command, then press `↑`/`↓` to cycle through matching history only.

```
| git       # Press ↑
| git push origin main   # Only "git" commands shown
| git commit -m "fix"    # Press ↑ again
```

**Tab completion**: Press `Tab` to complete commands and file paths (uses bash's `compgen`).

```
| gi<Tab>        → git
| cat /tmp/<Tab> → shows files in /tmp/
```

### Aliases

Create `~/.ze/aliases` to define shortcuts for common operations:

```bash
alias upper='tr a-z A-Z'
alias lower='tr A-Z a-z'
alias trim='sed "s/^[[:space:]]*//;s/[[:space:]]*$//"'
alias uniq='sort | uniq'
```

When this file exists and bash is available, ze automatically loads your aliases.

**Not familiar with Unix text tools?** Check out:
- [awesome-text-tools](https://github.com/sanohiro/awesome-text-tools) — Curated list of text processing tools
- [txtk](https://github.com/sanohiro/txtk) — Simple text toolkit for common operations (includes Japanese text handling)

---

## Keybindings

ze uses Emacs-style keybindings. `C-` means Ctrl, `M-` means Alt/Option.

| Key | Action |
|-----|--------|
| `C-f` / `C-b` / `C-n` / `C-p` | Move cursor |
| `C-s` / `C-r` | Search forward/backward |
| `M-%` | Query replace |
| `M-\|` | Shell command |
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

### Terminal Tips

- **Text selection**: Drag to select text with your terminal's native selection. Copies to system clipboard.
- **Scrolling**: Use `C-v` / `M-v` or `PageDown` / `PageUp` for scrolling (trackpad scrolling is disabled).

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
| `ln` | Toggle line numbers |
| `tab` / `tab N` | Show/set tab width |
| `indent` | Show/set indent style |
| `mode` / `mode X` | Show/set language mode |
| `key` | Describe key binding |
| `revert` | Reload file |
| `ro` | Toggle read-only |
| `exit` / `quit` | Quit with confirmation |
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
- Keyboard macros (`C-x (` / `)` / `e`)
- In-app help (`M-?`)

---

## Philosophy

1. **Speed** — Responsiveness is our top priority.
2. **Minimal** — Do one thing well.
3. **Unix** — Text is a stream. Pipes are first-class.
4. **Zero-config** — Copy and run. (History stored in `~/.ze/`)

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
