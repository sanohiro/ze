// ============================================================================
// Terminal - 端末制御
// ============================================================================
//
// 【責務】
// - rawモードの有効化/無効化（キー入力をそのまま取得）
// - 端末サイズの取得とリサイズ検知（SIGWINCH）
// - ANSIエスケープシーケンスによる画面制御
// - 出力バッファリング（1フレーム1回のwrite()）
//
// 【rawモードとは】
// 通常の端末はラインバッファリング（Enterまで待つ）だが、
// rawモードにすると1キーずつ即座に読み取れる。
// また、Ctrl+C等の特殊キーもシグナルではなく文字として受け取れる。
//
// 【バッファリング戦略】
// 描画コマンドをバッファに蓄積し、flush()で一括書き込み。
// これにより画面のちらつきを防ぎ、システムコールを減らす。
// ============================================================================

const std = @import("std");
const posix = std.posix;
const config = @import("config");

/// グローバルリサイズフラグ（SIGWINCHハンドラから設定）
var g_resize_pending = std.atomic.Value(bool).init(false);

/// グローバル終了フラグ（SIGINT/SIGTERMハンドラから設定）
var g_terminate_pending = std.atomic.Value(bool).init(false);

/// SIGWINCHシグナルハンドラ
fn sigwinchHandler(_: c_int) callconv(.c) void {
    g_resize_pending.store(true, .release);
}

/// 終了シグナルハンドラ（SIGINT, SIGTERM, SIGHUP, SIGQUIT）
fn terminateHandler(_: c_int) callconv(.c) void {
    g_terminate_pending.store(true, .release);
}

pub const Terminal = struct {
    original_termios: posix.termios,
    width: usize,
    height: usize,
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    tty_fd: posix.fd_t, // 入力用ファイルディスクリプタ（通常はSTDIN、パイプ時は/dev/tty）

    pub fn init(allocator: std.mem.Allocator, tty_file: ?std.fs.File) !Terminal {
        // 入力用FDを決定（tty_fileがあればそれを使用、なければSTDIN）
        const tty_fd = if (tty_file) |f| f.handle else posix.STDIN_FILENO;
        const original = try posix.tcgetattr(tty_fd);

        // 出力バッファを事前確保（毎フレームのアロケーションを回避）
        var buf = try std.ArrayList(u8).initCapacity(allocator, config.Terminal.OUTPUT_BUFFER_CAPACITY);
        errdefer buf.deinit(allocator);

        var self = Terminal{
            .original_termios = original,
            .width = config.Terminal.DEFAULT_WIDTH,
            .height = config.Terminal.DEFAULT_HEIGHT,
            .buf = buf,
            .allocator = allocator,
            .tty_fd = tty_fd,
        };

        try self.enableRawMode();
        // enableRawMode成功後、以降の処理で失敗した場合はrawモードを解除する
        errdefer self.disableRawMode() catch {};

        self.getWindowSize();

        // ウィンドウサイズに基づいてバッファ容量を確保（再アロケーション削減）
        // 1セルあたり約12バイト（UTF-8文字 + ANSIシーケンス）を想定
        const estimated_capacity = @as(usize, self.width) * @as(usize, self.height) * 12;
        if (estimated_capacity > self.buf.capacity) {
            try self.buf.ensureTotalCapacity(allocator, estimated_capacity);
        }

        // シグナルハンドラを設定
        self.setupSigwinch();
        self.setupTerminateSignals();

        // 代替画面バッファを有効化（終了時に元の画面に戻る）
        // ブラケットペーストモードを有効化（ペースト時にまとめて挿入）
        // 注: マウスモードは無効（ターミナルでのテキスト選択・コピーを優先）
        const stdout: std.fs.File = .{ .handle = posix.STDOUT_FILENO };
        // スクロール領域をリセットしてから代替画面に入る
        // （パイプ入力時に前のプロセスの出力で壊れた状態をクリア）
        // 注: RESET_SCROLL_REGIONはカーソルを(1,1)に移動するため、保存/復元が必要
        stdout.writeAll(config.ANSI.SAVE_CURSOR ++ config.ANSI.RESET_SCROLL_REGION ++ config.ANSI.RESTORE_CURSOR ++ config.ANSI.ENTER_ALT_SCREEN ++ config.ANSI.ENABLE_BRACKETED_PASTE) catch {};

        return self;
    }

    /// SIGWINCHシグナルハンドラを設定
    fn setupSigwinch(_: *Terminal) void {
        const act = posix.Sigaction{
            .handler = .{ .handler = sigwinchHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        _ = posix.sigaction(posix.SIG.WINCH, &act, null);
    }

    /// 終了シグナルハンドラを設定（SIGINT, SIGTERM, SIGHUP, SIGQUIT）
    fn setupTerminateSignals(_: *Terminal) void {
        const act = posix.Sigaction{
            .handler = .{ .handler = terminateHandler },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        // SIGINT (Ctrl+C) - rawモードでは通常キャラクタとして受信されるが、
        // 他のプロセスから送られた場合に備えて設定
        _ = posix.sigaction(posix.SIG.INT, &act, null);
        // SIGTERM - killコマンドのデフォルトシグナル
        _ = posix.sigaction(posix.SIG.TERM, &act, null);
        // SIGHUP - 端末が切断された場合
        _ = posix.sigaction(posix.SIG.HUP, &act, null);
        // SIGQUIT - Ctrl+\ (通常はコアダンプだが、gracefulに終了)
        _ = posix.sigaction(posix.SIG.QUIT, &act, null);
    }

    /// 終了が要求されたかチェック
    pub fn checkTerminate(_: *Terminal) bool {
        return g_terminate_pending.load(.acquire);
    }

    pub fn deinit(self: *Terminal) void {
        // ブラケットペーストモードを無効化
        self.write(config.ANSI.DISABLE_BRACKETED_PASTE) catch {};
        // カーソルを表示
        self.showCursor() catch {};
        // 代替画面バッファを終了（元の画面に戻る）
        self.write(config.ANSI.EXIT_ALT_SCREEN) catch {};
        self.flush() catch {};

        self.disableRawMode() catch {};
        self.restoreSignalHandlers();
        self.buf.deinit(self.allocator);
    }

    /// シグナルハンドラをデフォルトに復元
    fn restoreSignalHandlers(_: *Terminal) void {
        const default_act = posix.Sigaction{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        _ = posix.sigaction(posix.SIG.WINCH, &default_act, null);
        _ = posix.sigaction(posix.SIG.INT, &default_act, null);
        _ = posix.sigaction(posix.SIG.TERM, &default_act, null);
        _ = posix.sigaction(posix.SIG.HUP, &default_act, null);
        _ = posix.sigaction(posix.SIG.QUIT, &default_act, null);
    }

    fn enableRawMode(self: *Terminal) !void {
        var raw = self.original_termios;

        // 入力フラグ: BREAK無効、CR→NL変換無効、パリティ無効、8bit文字
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // 出力フラグ: 出力処理無効
        raw.oflag.OPOST = false;

        // 制御フラグ: 8bit文字
        raw.cflag.CSIZE = .CS8;

        // ローカルフラグ: エコー無効、カノニカル無効、拡張機能無効、シグナル無効
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        // 制御文字: 最小読み取りバイト数、タイムアウト
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        try posix.tcsetattr(self.tty_fd, .FLUSH, raw);
    }

    fn disableRawMode(self: *Terminal) !void {
        try posix.tcsetattr(self.tty_fd, .FLUSH, self.original_termios);
    }

    fn getWindowSize(self: *Terminal) void {
        var ws: posix.winsize = undefined;

        // tty_fdを使用してウィンドウサイズを取得
        // パイプ入力時も/dev/ttyから正しいサイズを取得できる
        const result = posix.system.ioctl(self.tty_fd, posix.system.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            self.width = ws.col;
            self.height = ws.row;
        }
    }

    /// 端末サイズが変更されたかチェックし、変更されていればサイズを更新してtrueを返す
    /// SIGWINCHのみに依存（ioctlポーリングを削除して高速化）
    pub fn checkResize(self: *Terminal) bool {
        // SIGWINCHフラグをチェック（シグナル駆動の高速検出）
        if (g_resize_pending.swap(false, .acquire)) {
            self.getWindowSize();
            return true;
        }
        return false;
    }

    pub fn clear(self: *Terminal) !void {
        try self.buf.appendSlice(self.allocator, config.ANSI.CLEAR_SCREEN);
        try self.buf.appendSlice(self.allocator, config.ANSI.CURSOR_HOME);
    }

    pub fn hideCursor(self: *Terminal) !void {
        try self.buf.appendSlice(self.allocator, config.ANSI.HIDE_CURSOR);
    }

    pub fn showCursor(self: *Terminal) !void {
        try self.buf.appendSlice(self.allocator, config.ANSI.SHOW_CURSOR);
    }

    /// カーソル移動（最適化版：スタックバッファで1回のappendSlice）
    /// ホットパス（60fps）のためシステムコールを最小化
    pub fn moveCursor(self: *Terminal, row: usize, col: usize) !void {
        var buf: [32]u8 = undefined;
        var pos: usize = 0;

        // ESC [
        buf[pos] = '\x1b';
        buf[pos + 1] = '[';
        pos += 2;

        // row + 1
        pos += formatUint(buf[pos..], row + 1);

        // ;
        buf[pos] = ';';
        pos += 1;

        // col + 1
        pos += formatUint(buf[pos..], col + 1);

        // H
        buf[pos] = 'H';
        pos += 1;

        try self.buf.appendSlice(self.allocator, buf[0..pos]);
    }

    /// 整数をバッファにフォーマット（戻り値は書き込んだバイト数）
    fn formatUint(buf: []u8, n: usize) usize {
        if (n == 0) {
            buf[0] = '0';
            return 1;
        }
        var val = n;
        var len: usize = 0;
        // 桁数を計算
        var temp = n;
        while (temp > 0) : (temp /= 10) {
            len += 1;
        }
        // 後ろから詰める
        var i = len;
        while (val > 0) : (val /= 10) {
            i -= 1;
            buf[i] = @intCast('0' + val % 10);
        }
        return len;
    }

    pub fn write(self: *Terminal, text: []const u8) !void {
        try self.buf.appendSlice(self.allocator, text);
    }

    pub fn flush(self: *Terminal) !void {
        const stdout: std.fs.File = .{ .handle = posix.STDOUT_FILENO };
        try stdout.writeAll(self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    // ============================================================================
    // 効率的なスクロール（差分描画の最適化）
    // ============================================================================

    /// スクロール領域を設定（1-indexed）
    /// top_row から bottom_row までの範囲でスクロールが発生する
    pub fn setScrollRegion(self: *Terminal, top_row: usize, bottom_row: usize) !void {
        var buf: [32]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}r", .{ top_row + 1, bottom_row + 1 });
        try self.buf.appendSlice(self.allocator, str);
    }

    /// スクロール領域をリセット（全画面に戻す）
    pub fn resetScrollRegion(self: *Terminal) !void {
        try self.buf.appendSlice(self.allocator, config.ANSI.RESET_SCROLL_REGION);
    }

    /// 画面を上にスクロール（新しい行が下から入る）
    /// lines: スクロールする行数
    pub fn scrollUp(self: *Terminal, lines: usize) !void {
        var buf: [16]u8 = undefined;
        if (lines == 1) {
            try self.buf.appendSlice(self.allocator, config.ANSI.SCROLL_UP);
        } else {
            const str = try std.fmt.bufPrint(&buf, "\x1b[{d}S", .{lines});
            try self.buf.appendSlice(self.allocator, str);
        }
    }

    /// 画面を下にスクロール（新しい行が上から入る）
    /// lines: スクロールする行数
    pub fn scrollDown(self: *Terminal, lines: usize) !void {
        var buf: [16]u8 = undefined;
        if (lines == 1) {
            try self.buf.appendSlice(self.allocator, config.ANSI.SCROLL_DOWN);
        } else {
            const str = try std.fmt.bufPrint(&buf, "\x1b[{d}T", .{lines});
            try self.buf.appendSlice(self.allocator, str);
        }
    }
};
