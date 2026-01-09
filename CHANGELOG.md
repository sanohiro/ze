# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.3] - 2026-01-10

### Fixed
- **Word movement (M-f/M-b)**: Now correctly handles grapheme clusters
  - Japanese text, emoji, and combining characters are treated as single units
  - Fixes cursor skipping issues with multi-byte characters
- **Shell service deadlock**: Fixed pipe reading that could hang when output exceeds buffer size
- **Clipboard output order**: Fixed terminal flush before OSC52 sequence for reliable clipboard operation
- **LineIndex boundary conditions**: Fixed off-by-one errors in insert/delete position tracking
- **File chmod error handling**: Non-fatal handling when chmod fails (e.g., on some filesystems)
- **Streaming file read**: Fixed short write handling by seeking on each iteration
- **findPrevGrapheme infinite loop**: Added break when iterator reaches end of buffer
- **prevCodepoint truncated UTF-8**: Now returns error instead of panic for malformed sequences
- **recent_files prompt clearing**: Prompt now persists during navigation
- **joinLine (M-^)**: Now always inserts space separator (Emacs-compatible behavior)

### Refactored
- Extracted `unicode.graphemeByteLen()` helper for consistent grapheme byte length calculation
- Added `PieceIterator.consumeGraphemeByteLen()` method
- Combined `updateIsearchPrompt` + `updateIsearchHighlight` into `updateIsearchUI`
- Optimized double ANSI RESET output in view rendering

## [1.5.2] - 2026-01-08

### Fixed
- **Escape key handling**: ESC now works as cancel in multiple modes
  - Incremental search (C-s/C-r): ESC cancels and restores cursor position
  - Query Replace confirmation: ESC exits replace mode
  - C-x/C-x r prefix modes: ESC cancels without error message
- **Query Replace improvements**:
  - Skip position calculation fixed (only advance +1 byte for empty matches)
  - State properly cleared on finish (replace_current_pos, replace_match_len)
  - Search highlight cleared on cancel
- **Multi-window synchronization**: `M-x revert` now updates all windows showing the same buffer
- **PieceIterator.prev()**: Now correctly skips zero-length pieces
- **Undo/Redo robustness**:
  - moveLineImpl: Added errdefer for undo rollback on error
  - joinLine: Now grouped as single undo operation
  - undo/redo: Clears mark_pos after operation (prevents stale selection)
  - yankRectangle: Undo group moved before loop for correct grouping
- **0-byte file mtime**: Empty files now preserve correct modification time
  - Fixes spurious "file changed on disk" warnings
- **Overflow protection**:
  - cached_line_count: Uses saturating subtraction to prevent underflow
  - Scroll amount: Uses i64+clamp to prevent i32 overflow
  - history.zig: Checks for negative stat.size
- **Memory safety**:
  - Multiple errdefer additions for allocation failure handling
  - editing_context init: Proper cleanup chain on failure
  - buffer_manager/window_manager: errdefer for init failures
  - shell_service stdin_data: errdefer on failure
- **UTF-8 validation**: Fixed overlong encoding check (0xC0-0xC1 now rejected)
- **Minibuffer moveLeft**: Consistent behavior when cursor out of range

### Refactored
- Added `unicode.isAsciiControl()` for consistent control character detection
- Removed unused functions: kill_ring.clear/isEmpty, buffer_manager.hasUnsavedChanges, etc.
- editing_context.freeData made public (required for error cleanup)

## [1.5.1] - 2026-01-06

### Fixed
- **Japanese search highlight**: Fixed highlight position mismatch when searching consecutive Japanese characters
  - Cursor position was calculated in display columns, but match positions were in bytes
  - Now uses byte positions consistently for highlight comparison
- **Empty regex match UTF-8 boundary**: Fixed infinite loop potential when regex matches empty string at multibyte character
  - Was advancing by 1 byte, could stop in middle of UTF-8 sequence
  - Now advances by full UTF-8 character length
- **Search highlight cursor tracking**: Fixed current match highlight (magenta) not working with tabs
  - `cursor_in_content` was in buffer coordinates, but compared against expanded_line coordinates
  - Added cursor position tracking during tab expansion
- **Line movement with multibyte characters**: Cursor now preserves visual column when moving between lines
  - Added `findPosByColumn()` for proper column-based positioning
- **Undo/Redo data loss on error**: Added `errdefer` to restore undo entry if operation fails
- **Shell result replace undo**: Now grouped as single undo operation (was requiring 2 undos)
- **Tab completion stdin conflict**: Fixed potential stdin competition with editor

### Refactored
- shell_service: Consolidated NONBLOCK operations into setNonBlocking/setBlocking functions
- shell_service: DRY improvement with initCommandState helper
- buffer: Consolidated insert finalization into finalizeInsert function (7 locations)
- regex: Removed unused allocator parameter from parseCharClass
- search_service: Removed unused self from searchForward/searchBackward
- editing_context: Removed unused notifyChange mechanism
- view: Consolidated control character width calculation

## [1.5.0] - 2026-01-06

### Added
- **Window title (OSC 2)**: Display filename and modified status in terminal title
  - Shows "ze - filename.txt *" when modified
  - Works with iTerm2, Terminal.app, xterm, kitty, etc.
- **Synchronized Output (DEC 2026)**: Prevents tearing on supported terminals
- **TMUX Passthrough for OSC 52**: Clipboard integration now works inside tmux
- **Focus detection**: Detects terminal focus in/out events
- **Cursor shape (DECSCUSR)**: Bar cursor in insert mode, block cursor otherwise
- **Search match count**: Shows `[3 of 10]` format during incremental search
- **Recent files history (C-x C-r)**: Navigate with Up/Down, Enter to open
  - MRU ordering, persisted to `~/.ze/file_history`
  - File locking for concurrent access safety
- **M-x kill-buffer / kb**: Kill current buffer (same as C-x k)
- **M-x overwrite / ow**: Toggle overwrite/insert mode (Mac alternative to Insert key)
- **External change detection**: Reload confirmation prompt on focus return
  - Shows "File changed on disk. Reload? (y/n)"

### Fixed
- **Boundary check bugs**: Fixed multiple boundary/slice issues
  - input.zig: CSI parameter parsing buffer overflow
  - view.zig: Search highlight slice range validation
  - edit.zig: Unindent region uninitialized memory
- **Window title not updating on M-o**: Title now updates when switching windows
- **Full-width character boundary**: Fixed UTF-8 boundary detection
- **Query Replace Japanese input**: Now handles codepoint keys correctly
- **OSC 52 simplification**: Cleaner clipboard sequence generation

### Refactored
- Editor: Added `toggleOverwriteMode()`, `killCurrentBuffer()`, `reloadCurrentBuffer()`
- Consolidated C-x k handling into shared function

## [1.4.4] - 2026-01-05

### Fixed
- **Vertical split scroll bug**: Terminal scroll optimization now disabled for non-full-width windows
  - Fixes issue where scrolling one window in a vertical split (C-x 3) would affect the other window
  - Terminal scroll regions only control rows, not columns
- Boundary value checks and error handling improvements

### Refactored
- Extracted KillRing from editor.zig to services/kill_ring.zig

## [1.4.3] - 2026-01-04

### Fixed
- Shell service: Removed redundant command parsing (was parsing twice per command)
- Shell service: Fixed EOF handling in readFromPipe (close fd to prevent busy loop)

### Performance
- Shell streaming: PieceIterator reuse for O(n) instead of O(n²) on large data
- Tab completion: Added 500ms timeout to prevent UI freeze on slow filesystems

## [1.4.2] - 2026-01-04

### Fixed
- `getRange`: Fixed crash when requesting zero-length range (safe allocation for free())
- `findByFilename`: Fixed path normalization for unsaved files (prevents duplicate buffers)
- `loadFromMemory`: Added language detection for piped input (`cat file | ze`)
- `replaceRangeWithShellOutput`: Fixed false positive modified flag when no changes occur
- `saveToFile`: Fixed orphaned .tmp files when rename fails (disk full, permission errors)

### Performance
- Shell streaming: Replaced heap allocations with stack buffer (eliminates 16KB alloc/free cycles)

## [1.4.1] - 2026-01-04

### Fixed
- Query Replace confirm mode: Prompt now persists when pressing unhandled keys (Escape, Ctrl, etc.)

## [1.4.0] - 2026-01-04

### Added
- **OSC 52 clipboard integration**: Cut (`C-w`) and copy (`M-w`) automatically copy to system clipboard
  - Works with iTerm2, kitty, alacritty, WezTerm, and most modern terminals
  - No configuration required
- PieceIterator backward traversal functions for buffer navigation

### Fixed
- Shell command status: "Running..." message now clears after command completes
- Speculative render skip on exit: Prevents unnecessary rendering during shutdown
- Rectangle undo: Fixed undo behavior for rectangle operations
- Shell stderr: Fixed stderr output handling in shell integration
- Multiple bug fixes reported by Codex analysis

### Performance
- **Startup optimization**: Pre-allocated buffers reduce allocations during initialization
- **Rendering optimization**: Pre-allocated prev_screen buffer eliminates per-frame allocations
- **Cursor movement**: O(1) moveCursorLeft via caching
- **Search optimization**: Shared visible_text mapping for literal search
- Overall improvements to startup, input handling, and drawing

### Refactored
- Consolidated duplicate code (encoding.zig UTF-16 conversion, shell_service.zig pipe reading)
- Removed unused listeners mechanism
- Code consistency improvements and DRY violations fixed
- Quality improvements across codebase

## [1.3.5] - 2026-01-01

### Fixed
- **Cursor position after exit**: Save/restore cursor around scroll region reset
  - Fixes cursor jumping to top of screen after exiting ze (especially over SSH)
  - `\x1b[r` (DECSTBM) moves cursor to (1,1) as side effect, now wrapped with DECSC/DECRC

## [1.3.4] - 2026-01-01

### Fixed
- **Mixed line endings**: Normalize all CR/CRLF to LF regardless of detected type
  - Previously only converted the detected line ending type, leaving orphaned `\r` in mixed files
- **Shell pipe blocking**: Read stdout/stderr until WouldBlock instead of fixed 16 iterations
  - Prevents child process blocking when producing large output quickly
- **Tab completion truncation**: Increased compgen output limit from 64KB to 256KB
  - Large $PATH or directory completions no longer silently truncate

### Changed
- GitHub Actions: workflow_dispatch now correctly handles tag parameter for manual releases

## [1.3.3] - 2026-01-01

### Fixed
- **Pipe input scroll issue**: Reset scroll region before entering alternate screen
  - Fixes terminal scroll becoming active when piping from curl (progress output was corrupting scroll region)
- **stdin buffer save**: Prompt for filename when saving `[stdin]` buffer with C-x C-s
- **Terminal reset**: Add alternate screen exit sequence (`?1049l`) to test harness cleanup
  - Prevents terminal state corruption after interrupted tests

### Changed
- Test harness: O_NONBLOCK now cross-platform (macOS 0x0004, Linux 0x800)
- Integration tests: Added expected value verification for Query Replace tests

### Performance
- Non-UTF-8 save: Optimized memory usage and deduplicated binary check

### Refactored
- Code quality improvements: `hasContent()`, `trimCr()` helpers, consolidated patterns

## [1.3.2] - 2026-01-01

### Added
- **stdin support**: Read content from pipe (`cat file | ze`, `git diff | ze`)
  - Automatically detects piped input and reads content before opening editor
  - Opens `/dev/tty` for keyboard input when stdin is a pipe
  - Updated help message with pipe examples

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
