# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.4] - 2025-12-27

### Fixed
- Memory safety: dupe-then-free pattern in editor.zig (4 locations) - prevents dangling pointer on allocation failure
- Infinite loop: replaceCurrentMatch with empty regex match now advances cursor correctly
- Buffer overflow: getRegion now clamps both cursor and mark positions
- State leak: cancelInput now resets completion_shown flag

### Performance
- `toggleComment`: 50-100x faster on long lines (uses extractText instead of byte-by-byte append)
- `forwardParagraph`: 2-5x faster on large files (removed redundant iterator seek)
- `view.zig`: grapheme cluster copy uses appendSlice instead of byte-by-byte append

## [1.1.3] - 2025-12-22

### Fixed
- Cross-compilation: use `std.os.linux.getpid/getuid` for Linux targets (libc not available)
- Shell service security and robustness improvements
  - Fix double-free in alias command execution path
  - Add shellQuote for eval to prevent command injection
  - Require space before `n>`, `+>`, `>` suffixes to avoid hijacking
  - Add PATH environment search for bash/sh executables
- File save improvements
  - Resolve symlinks with realpath before saving
  - Add PID suffix to temp filename to prevent race conditions
  - Add directory fsync after rename for durability
  - Warn when file ownership cannot be preserved
- Shell command output handling
  - Include `[TRUNCATED]` in status messages instead of separate warning
  - Check exit_status before creating new_buffer
  - Update all windows showing command buffer
  - Clear modified flag on command buffer
- Macro recording: prevent data loss when memory allocation fails

## [1.1.2] - 2025-12-21

### Fixed
- Shell command prefix parsing improvements
  - Trim leading whitespace before parsing prefixes
  - Distinguish `./command` from `. ` prefix (current line)
  - Distinguish `%PATH%` from `% ` prefix (buffer all)

## [1.1.1] - 2025-12-21

### Fixed
- Shell alias execution in non-interactive bash mode
  - Added `shopt -s expand_aliases` and `eval` for proper alias expansion
  - Removed `-i` flag that caused "no job control in this shell" warning
  - Changed stdin behavior from `.Close` to `.Ignore` to fix "Bad file descriptor" error

## [1.1.0] - 2025-12-21

### Added
- Alias support for M-| shell integration
  - Create `~/.ze/aliases` with standard bash alias syntax
  - Automatically loaded when bash is available
  - Enables shortcuts like `| upper >` for text processing

### Changed
- Pre-compile test harness for faster integration tests
- `movement.zig`: Reuse PieceIterator instead of reinitializing
- `regex.zig`: Use stack buffer before heap allocation for better performance
- `window_manager.zig`: Unified horizontal/vertical split logic

## [1.0.10] - 2025-12-20

### Changed
- `view.zig`: `applyRegexHighlight()` buffer reuse to reduce per-line allocations
- `shell_service.zig`: Added `readWithLimit()` helper to consolidate I/O read logic (-15 lines)

### Refactored
- Code quality improvements across 6 rounds of investigation, ~100 lines reduced total
- `editor.zig`: Added `getIsearchPrefix()`, `updateIsearchPrompt()`, `updateIsearchHighlight()` helpers
- `buffer.zig`: Added `writeWithLineEnding()` helper for CRLF/CR conversion
- `rectangle.zig`: Added `advanceToColumn()` helper for column seek operations
- `view.zig`: Added `updatePrevScreenBuffer()` helper, unified `nextTabStop()` usage

### Fixed
- Regex search prompt display and line number highlighting
- M-r now toggles between literal/regex search modes
- Fixed "Loading..." message remaining when opening non-existent files

## [1.0.9] - 2025-12-18

### Changed
- `C-k` (kill-line): Now uses `kill-whole-line` mode - at beginning of line, kills entire line including newline

### Fixed
- Rectangle operations: use view's tab width instead of hardcoded 8-column tab stop
- Backward search (C-r, C-M-r): cursor now placed at match start (Emacs-compatible)
- Regex chunked search: increased overlap from 4KB to 64KB for longer matches
- File rename (C-x C-w): `filename_normalized` now properly reset for new path
- Shell command completion: status message ("Done", "Exit 1", etc.) now visible instead of being cleared
- Windows path handling: use `std.fs.path.basename` for cross-platform compatibility
- Buffer list (C-x C-b): parse from right to handle filenames with "two spaces + digit" pattern

## [1.0.8] - 2025-12-18

### Added
- Read-only mode: `-R` command-line option to open files in read-only mode
- Line number toggle: `M-x ln` command to show/hide line numbers
- Control character visualization: displays 0x00-0x1F as ^@-^_ and 0x7F as ^?

### Changed
- Disabled mouse capture mode: terminal's native text selection now works directly (no Option/Alt+drag needed)
- Removed unused scroll-related code

### Fixed
- Regex search: `skip_current` parameter now correctly advances position to prevent infinite loops on empty matches
- Backward regex chunked search: added overlap handling at chunk boundaries to prevent match misses
- Rectangle operations: short lines now preserve row count with empty strings (fixes yank alignment issues)

### Refactored
- Consolidated ASCII/UTF8 magic numbers and ANSI escape sequences into config.zig
- Code deduplication and helper function cleanup

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
