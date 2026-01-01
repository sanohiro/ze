# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.1] - 2026-01-01

### Fixed
- Shell service: Proper error handling for pipe read errors (WouldBlock vs real errors like EIO/EBADFD)
- Temp file collision: Added nanosecond timestamp to temp file names for parallel save safety

### Performance
- searchForward: Use findPieceAt for O(1) jump to starting piece instead of O(pieces) iteration

### Refactored
- Text extraction: Consolidated duplicate extractText logic from editor.zig and editing_context.zig into Buffer.extractText()

## [1.3.0] - 2026-01-01

### Added
- **Debian/Ubuntu support**: `.deb` packages now available in GitHub Releases
  - `ze_amd64.deb` for x86_64
  - `ze_arm64.deb` for ARM64
- **apt repository**: One-line install via `curl -fsSL https://sanohiro.github.io/ze/install.sh | sudo sh`
  - Hosted on GitHub Pages
  - GPG-signed packages
  - Automatic updates via `apt upgrade`

## [1.2.3] - 2026-01-01

### Fixed
- Shell command input delay: Fixed ~0.5 second delay where characters appeared late while cursor moved immediately in M-| shell command mode
  - `setError()` and `clearError()` now set `status_bar_dirty` instead of `needs_full_redraw` for immediate status bar updates
  - `needsRedraw()` now includes `status_bar_dirty` check to trigger speculative rendering

## [1.2.2] - 2025-12-31

### Refactored
- Removed unused imports: `History`, `HistoryType` from editor.zig, `input` from minibuffer.zig, `regex` from editor.zig, `EditingContext` from rectangle.zig
- Removed unused code: `iteratorConst()` from buffer_manager/window_manager, `SearchState`/`ReplaceState` from search_service
- Deleted duplicate/implementation-less tests from input_test.zig, buffer_manager_test.zig, window_manager_test.zig
- Consolidated shell error checking into shared helper function
- Unified `.replace` and `.insert` shell output handling with `replaceRangeWithShellOutput()` helper (~50 lines reduced)
- Consolidated special buffer creation with `getOrCreateSpecialBuffer()` helper (~20 lines reduced)
- Query Replace prompts centralized in `config.QueryReplace` struct
- Confirmation messages moved to `config.Messages` constants (`CONFIRM_YES_NO`, `CONFIRM_YES_NO_CANCEL`, `CONFIRM_REPLACE`)
- Additional constants added to config.zig: `ASCII.BACKSPACE`, `Editor.MAX_TAB_WIDTH`, `Editor.INDENT_BUF_SIZE`, etc.
- Removed stale comment from editing_context.zig
- Removed unused constants from config.zig: `BYTE2_MIN`, `BYTE4_MAX`, `CTRL_MASK`
- Removed history API wrapper methods from search_service.zig and shell_service.zig (12 methods total) - now access `history` field directly
- Consolidated word movement logic in minibuffer.zig with `findNextWordEnd()` helper

### Fixed
- rectangle.zig: Fixed potential memory leak on ArrayList append failure (4 locations)
- rectangle.zig: Simplified `getLineBounds()` using `buffer.getLineRange()`
- view.zig: Added boundary checks in `applySearchHighlight()` to prevent slice overflow with ANSI sequences

### Performance
- Inline hot-path functions:
  - keymap.zig: `findCtrl()`, `findAlt()`, `findSpecial()`
  - history.zig: `matchesPrefix()`
  - syntax.zig: `hasComments()`
  - macro_service.zig: `getLastMacro()`, `isRecording()`, `beginPlayback()`, `endPlayback()`, `isPlaying()`, `recordedKeyCount()`
  - buffer.zig: `len()`
  - editing_context.zig: `len()`, `lineCount()`
  - input.zig: `available()`
  - view.zig: `getError()`, `getSearchHighlight()`, `renderControlChar()`
  - editor.zig: `isCancelKey()`
- Replaced hardcoded constants with config values for maintainability

### Added
- New test files: config_test.zig, commands/movement_test.zig, commands/mx_test.zig, commands/help_test.zig

### Fixed
- input_test.zig: Removed unused variable in Ctrl key mapping test

## [1.2.1] - 2025-12-31

### Fixed
- Test harness: Correctly decode wait status using IFEXITED/EXITSTATUS/IFSIGNALED/TERMSIG
- Test harness: Handle CRLF line endings in --input-file
- Test harness: Error when --expect used without --file or --expect-file
- Test harness: CRLF/LF normalization in expectation comparison
- File save: Preserve original GID (not just UID) when saving files
- Command window: Prevent half-initialized window on OOM (errdefer cleanup)

## [1.2.0] - 2025-12-28

### Changed
- Undo grouping now uses VSCode-style word boundaries
  - Unified with word movement (M-f, M-b) boundary definition
  - Spaces belong to the following word: "hello world" → ["hello", " world"]
  - Symbol prefixes are separate: "#include" → ["#", "include"]
  - ASCII/non-ASCII boundaries split groups: "hello日本語" → ["hello", "日本語"]
  - 300ms timeout also starts new group

### Performance
- Piece consolidation: consecutive inserts merge into single Piece (reduces memory)
- Word movement (M-f, M-b): uses PieceIterator for O(1) sequential reads
- PageUp/Down: direct cursor calculation instead of loop
- Line start/end: cache updates on C-a/C-e

### Fixed
- Binary file error now shown before entering alternate screen
- Support saving to non-existent directories (creates parent dirs)

## [1.1.5] - 2025-12-27

### Refactored
- view.zig: Split `renderLineWithIterOffset()` into 5 smaller functions
- input.zig: Extract CSI sequence parser into separate functions
- buffer.zig: Consolidate `loadFromContent()`, split `searchBackward()`
- editor.zig: Unify file input modes into `handleFileInputKey()`
- config.zig: Centralize error messages in `Messages` struct
- rectangle.zig: Define `RectangleInfo` struct
- encoding.zig: Consolidate UTF-16 surrogate pair handling
- window_manager.zig: Remove unused fields (`split_type`, etc.)

### Performance
- Regex: Add LRU cache for compiled patterns (avoids recompilation)
- Terminal: Delay fcntl settings until needed
- View: Optimize rendering pipeline

### Added
- tests/commands/edit_test.zig: 20 tests for editing operations
- tests/commands/rectangle_test.zig: 16 tests for rectangle operations
- Expanded edge case tests for buffer, input, search, and window_manager

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
