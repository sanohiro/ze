// ============================================================================
// Poller - 効率的なI/O待機（epoll/kqueue）
// ============================================================================
//
// 【責務】
// - stdin入力を効率的に待機（CPUを消費せずにスリープ）
// - プラットフォーム固有のAPI（macOS: kqueue、Linux: epoll）を抽象化
// - シグナル割り込み（EINTR）の自動リトライ
//
// 【なぜ必要か】
// ポーリング（VTIME=100ms）では、入力がなくても毎秒10回起きてしまう。
// epoll/kqueueを使えば、入力があるまで完全にスリープできる。
// - CPU使用率: ポーリング ~1% → epoll/kqueue ~0%
// - バッテリー消費: 大幅削減（特にラップトップで重要）
// ============================================================================

const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");
const linux = std.os.linux;

/// ポーリング結果
pub const PollResult = enum {
    ready, // 入力準備完了
    timeout, // タイムアウト
    signal, // シグナル割り込み（再試行すべき）
};

/// プラットフォーム固有のPoller実装
pub const Poller = if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd)
    KqueuePoller
else if (builtin.os.tag == .linux)
    EpollPoller
else
    // フォールバック: poll(2)を使用
    PollPoller;

/// macOS/BSD: kqueueベースのPoller
pub const KqueuePoller = struct {
    kq: i32,
    stdin_fd: i32,

    pub fn init(stdin_fd: i32) !KqueuePoller {
        const kq = try posix.kqueue();
        errdefer posix.close(kq);

        // stdinを監視対象に追加
        var changelist = [_]posix.Kevent{.{
            .ident = @intCast(stdin_fd),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};

        const result = posix.system.kevent(
            kq,
            &changelist,
            changelist.len,
            @as([*]posix.Kevent, undefined)[0..0], // eventlist (空)
            0,
            null, // timeout (即座に戻る)
        );

        if (result < 0) {
            posix.close(kq);
            return error.KqueueError;
        }

        return .{ .kq = kq, .stdin_fd = stdin_fd };
    }

    pub fn deinit(self: *KqueuePoller) void {
        posix.close(self.kq);
    }

    /// 入力を待機
    /// timeout_ms: nullなら無限待機、0なら即座にチェック
    pub fn wait(self: *KqueuePoller, timeout_ms: ?u32) PollResult {
        var eventlist: [1]posix.Kevent = undefined;

        const timeout: ?posix.timespec = if (timeout_ms) |ms| .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * 1_000_000),
        } else null;

        while (true) {
            const result = posix.system.kevent(
                self.kq,
                @as([*]posix.Kevent, undefined)[0..0], // changelist (空)
                0,
                &eventlist,
                1,
                if (timeout) |*t| t else null,
            );

            if (result < 0) {
                const err = posix.errno(result);
                if (err == .INTR) {
                    // シグナル割り込み: リトライすべき（SIGWINCHなど）
                    return .signal;
                }
                // その他のエラーはタイムアウト扱い
                return .timeout;
            }

            if (result == 0) {
                return .timeout;
            }

            // イベントあり
            return .ready;
        }
    }
};

/// Linux: epollベースのPoller
pub const EpollPoller = struct {
    epfd: i32,
    stdin_fd: i32,

    pub fn init(stdin_fd: i32) !EpollPoller {
        const epfd = try posix.epoll_create1(0);
        errdefer posix.close(epfd);

        var event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = stdin_fd },
        };

        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, stdin_fd, &event);

        return .{ .epfd = epfd, .stdin_fd = stdin_fd };
    }

    pub fn deinit(self: *EpollPoller) void {
        posix.close(self.epfd);
    }

    /// 入力を待機
    pub fn wait(self: *EpollPoller, timeout_ms: ?u32) PollResult {
        var events: [1]linux.epoll_event = undefined;

        const timeout: i32 = if (timeout_ms) |ms| @intCast(ms) else -1;

        while (true) {
            const result = linux.epoll_wait(self.epfd, &events, 1, timeout);

            if (result < 0) {
                const err = posix.errno(result);
                if (err == .INTR) {
                    return .signal;
                }
                return .timeout;
            }

            if (result == 0) {
                return .timeout;
            }

            return .ready;
        }
    }
};

/// フォールバック: poll(2)ベースのPoller
pub const PollPoller = struct {
    stdin_fd: i32,

    pub fn init(stdin_fd: i32) !PollPoller {
        return .{ .stdin_fd = stdin_fd };
    }

    pub fn deinit(_: *PollPoller) void {}

    /// 入力を待機
    pub fn wait(self: *PollPoller, timeout_ms: ?u32) PollResult {
        var fds = [_]posix.pollfd{.{
            .fd = self.stdin_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};

        const timeout: i32 = if (timeout_ms) |ms| @intCast(ms) else -1;

        while (true) {
            const result = posix.poll(&fds, timeout);

            if (result < 0) {
                const err = posix.errno(result);
                if (err == .INTR) {
                    return .signal;
                }
                return .timeout;
            }

            if (result == 0) {
                return .timeout;
            }

            if (fds[0].revents & posix.POLL.IN != 0) {
                return .ready;
            }

            return .timeout;
        }
    }
};
