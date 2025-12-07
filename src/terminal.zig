const std = @import("std");
const posix = std.posix;
const io = std.io;
const config = @import("config.zig");

/// グローバルリサイズフラグ（SIGWINCHハンドラから設定）
var g_resize_pending: bool = false;

/// SIGWINCHシグナルハンドラ
fn sigwinchHandler(_: c_int) callconv(.c) void {
    g_resize_pending = true;
}

pub const Terminal = struct {
    original_termios: posix.termios,
    width: usize,
    height: usize,
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Terminal {
        const stdin: std.fs.File = .{ .handle = posix.STDIN_FILENO };

        // stdin が TTY かどうかを確認
        if (!posix.isatty(stdin.handle)) {
            std.debug.print("Error: stdin is not a TTY. ze requires a terminal.\n", .{});
            return error.NotATty;
        }

        const original = try posix.tcgetattr(stdin.handle);

        var self = Terminal{
            .original_termios = original,
            .width = config.Terminal.DEFAULT_WIDTH,
            .height = config.Terminal.DEFAULT_HEIGHT,
            .buf = std.ArrayList(u8){},
            .allocator = allocator,
        };

        try self.enableRawMode();
        try self.getWindowSize();

        // SIGWINCHハンドラを設定
        self.setupSigwinch();

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

    pub fn deinit(self: *Terminal) void {
        // 画面をクリアしてカーソルを表示
        self.clear() catch {};
        self.showCursor() catch {};
        self.flush() catch {};

        // 改行を出力（zshの%記号を防ぐ）
        const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
        stdout.writeAll("\n") catch {};

        self.disableRawMode() catch {};
        self.buf.deinit(self.allocator);
    }

    fn enableRawMode(self: *Terminal) !void {
        const stdin: std.fs.File = .{ .handle = posix.STDIN_FILENO };
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

        try posix.tcsetattr(stdin.handle, .FLUSH, raw);
    }

    fn disableRawMode(self: *Terminal) !void {
        const stdin: std.fs.File = .{ .handle = posix.STDIN_FILENO };
        try posix.tcsetattr(stdin.handle, .FLUSH, self.original_termios);
    }

    fn getWindowSize(self: *Terminal) !void {
        var ws: posix.winsize = undefined;
        const stdout: std.fs.File = .{ .handle = posix.STDOUT_FILENO };

        const result = posix.system.ioctl(stdout.handle, posix.system.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            self.width = ws.col;
            self.height = ws.row;
        }
    }

    /// 端末サイズが変更されたかチェックし、変更されていればサイズを更新してtrueを返す
    pub fn checkResize(self: *Terminal) !bool {
        // SIGWINCHフラグをチェック（シグナル駆動の高速検出）
        if (g_resize_pending) {
            g_resize_pending = false;
            try self.getWindowSize();
            return true;
        }

        // ポーリングでも確認（フォールバック）
        var ws: posix.winsize = undefined;
        const stdout: std.fs.File = .{ .handle = posix.STDOUT_FILENO };

        const result = posix.system.ioctl(stdout.handle, posix.system.T.IOCGWINSZ, @intFromPtr(&ws));
        if (result == 0) {
            const new_width = ws.col;
            const new_height = ws.row;

            if (new_width != self.width or new_height != self.height) {
                self.width = new_width;
                self.height = new_height;
                return true;
            }
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

    pub fn moveCursor(self: *Terminal, row: usize, col: usize) !void {
        var buf: [config.Terminal.CURSOR_BUF_SIZE]u8 = undefined;
        const str = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
        try self.buf.appendSlice(self.allocator, str);
    }

    pub fn write(self: *Terminal, text: []const u8) !void {
        try self.buf.appendSlice(self.allocator, text);
    }

    pub fn flush(self: *Terminal) !void {
        const stdout: std.fs.File = .{ .handle = posix.STDOUT_FILENO };
        try stdout.writeAll(self.buf.items);
        self.buf.clearRetainingCapacity();
    }
};
