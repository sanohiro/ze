# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - Unreleased

Initial release of ze - a fast, minimal text editor inspired by mg and Unix philosophy.

### Features

#### Core Editing
- Emacs-style keybindings (C-f/b/n/p, C-a/e, M-f/b, etc.)
- Undo/Redo (C-u / C-/)
- Kill ring (C-k, C-w, M-w, C-y)
- Mark and region selection (C-Space)
- Shift-select for mouse-like selection
- Rectangle operations (C-x r k/w/y)
- Keyboard macros (C-x ( / C-x ) / C-x e)
- Comment toggle (M-;)
- Line operations (M-^, M-Up/Down)
- Indent/unindent (Tab / S-Tab)

#### Navigation
- Character/word/line/paragraph movement
- Page up/down (C-v / M-v)
- Beginning/end of buffer (M-< / M->)
- Go to line (M-x line N)
- Center cursor (C-l)

#### Search & Replace
- Incremental search forward/backward (C-s / C-r)
- Regex search (C-M-s / C-M-r)
- Query replace with literal (M-%)
- Query replace with regex (C-M-%)
- Search history (C-p / C-n in search mode)

#### File Operations
- Open file with completion (C-x C-f)
- Save (C-x C-s)
- Save as (C-x C-w)
- New buffer (C-x C-n)
- Overwrite confirmation for existing files
- Revert file (M-x revert)

#### Window & Buffer Management
- Horizontal/vertical split (C-x 2 / C-x 3)
- Window navigation (M-o, C-x o)
- Close window (C-x 0 / C-x 1)
- Buffer switching with completion (C-x b)
- Buffer list (C-x C-b)
- Kill buffer (C-x k)

#### Shell Integration
- Pipe to shell command (M-|)
- Source specifiers: selection, buffer (%), line (.)
- Destination specifiers: display, replace (>), insert (+>), new buffer (n>)
- Command history

#### Display
- Comment highlighting (gray)
- Line numbers
- Status bar with file info
- Unicode support (CJK, emoji)
- Configurable tab width and indent style

#### M-x Commands
- `line N` - Go to line
- `tab [N]` - Show/set tab width
- `indent` - Show/set indent style
- `mode [X]` - Show/set language mode
- `key` - Describe key binding
- `revert` - Reload file
- `ro` - Toggle read-only

### Technical
- Written in Zig (0.15)
- Piece table buffer for efficient editing
- Cell-level differential rendering
- Single binary, no dependencies
- Cross-platform (macOS, Linux)
