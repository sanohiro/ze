# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.7] - 2025-12-18

### Fixed
- Japanese incremental search: C-s no longer skips characters (was adding +1 byte incorrectly)
- Incremental search: pattern changes now search from start position, not current cursor
- Search highlight: wrap-around correctly shows cursor color on first match
- Minibuffer cursor position calculation with grapheme clusters

## [1.0.6] - 2025-12-17

Same as 1.0.5 (version bump fix).

## [1.0.5] - 2025-12-17

### Added
- Undo grouping for atomic operations (replace, paste)
- Bracket paste mode: pasted text can be undone as a single unit

### Fixed
- Replace operation undo: now correctly restores original text with C-u
- Replace all (`!`): no longer replaces previously skipped items when wrapping around
- Search highlight: fixed display width calculation for full-width characters (Japanese, etc.)
- Full-width space: correct display width (2 columns) and selection behavior
- Tab character width calculation in various contexts
- Minibuffer backspace with tab width handling
- Search at buffer end position

### Documentation
- Added terminal tips: Option+drag for native text selection

### CI/CD
- Removed Ubuntu 22.04 build

## [1.0.4] - 2025-12-17

### Changed
- Refactor: isWordCharByte() - consolidated duplicate code from regex.zig and editing_context.zig into unicode.zig
- Refactor: isUtf8Continuation() - unified continuation byte checks in encoding.zig
- Refactor: utf8SeqLen() - replaced inline expansion with function call in unicode.zig

### Documentation
- Added release procedure to CLAUDE.md

## [1.0.3] - 2025-12-17

### Fixed
- Read-only buffer protection: undo/redo now respects read-only flag
- Read-only buffer protection: shell command output (replace/insert) blocked on read-only buffers
- Read-only buffer protection: query replace (M-%, C-M-%) blocked on read-only buffers

### CI/CD
- Homebrew tap auto-update on release
- Generate checksums.txt and ze.rb (Homebrew formula) automatically

## [1.0.2] - 2025-12-14

### Fixed
- Unicode: combining character width calculation (Extended Pictographic checked first)
- Shell integration: close pipes when output exceeds 10MB to prevent deadlock
- Macro recording: filter control keys (C-x (, ), e) from being recorded
- Buffer manager: set filename_normalized after saving new files
- Rectangle: add space padding when yanking to shorter lines
- Buffer: findColumnByPos now considers tab width
- Editing context: savepoint tracking for correct modified state after undo
- View: search highlight position accounts for tab expansion
- Regex search: chunked search with wrap-around for files larger than 1MB

## [1.0.1] - 2025-12-14

### Fixed
- 13 bugs identified by Codex code review
- Shell integration: removed stderr from n> output (stdout only)

### Documentation
- Added language mode reference (MODES.md, MODES.ja.md)
- Updated keybindings documentation
- Reduced padding in demo GIFs

### Testing
- Added category selection to integration test script
- Expanded test suite to 192 tests (32 categories)
- New test categories: M-x commands, search mode toggle (M-r), selection keys

## [1.0.0] - 2025-12-14

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
