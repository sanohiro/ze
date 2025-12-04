const std = @import("std");
const config = @import("config.zig");

pub const Key = union(enum) {
    char: u8,
    codepoint: u21, // UTF-8文字
    ctrl: u8,
    alt: u8,
    alt_delete,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    page_up,
    page_down,
    home,
    end_key,
    delete,
    backspace,
    enter,
    escape,
    tab,
};

pub fn readKey(stdin: std.fs.File) !?Key {
    var buf: [config.Input.BUF_SIZE]u8 = undefined;
    const n = try stdin.read(buf[0..1]);
    if (n == 0) return null;

    const ch = buf[0];

    // 特殊キーを先にチェック（Ctrlキーと重複するため）
    switch (ch) {
        '\r', '\n' => return Key.enter,  // 13 (\r) と 10 (\n)
        8, config.Input.DEL => return Key.backspace,  // 8 (Ctrl+H) と 127 (Delete)
        '\t' => return Key.tab,  // 9
        else => {},
    }

    // Ctrl キー (0x01-0x1A)
    if (ch >= 1 and ch <= 26) {
        return Key{ .ctrl = ch + 'a' - 1 };
    }

    // ESC シーケンス
    if (ch == config.Input.ESC) {
        // さらに読み込んでエスケープシーケンスを判定
        // VMIN=0, VTIME=1の設定により、100msでタイムアウト
        // バイトが分割到着する場合も、100ms以内なら正しく読み取れる
        const n2 = try stdin.read(buf[1..3]);
        if (n2 == 0) {
            // タイムアウト: ESCキー単体として扱う
            return Key.escape;
        }

        if (n2 == 1 and buf[1] >= 'a' and buf[1] <= 'z') {
            // Alt+文字
            return Key{ .alt = buf[1] };
        }

        if (n2 >= 2 and buf[1] == '[') {
            switch (buf[2]) {
                'A' => return Key.arrow_up,
                'B' => return Key.arrow_down,
                'C' => return Key.arrow_right,
                'D' => return Key.arrow_left,
                'H' => return Key.home,
                'F' => return Key.end_key,
                '1'...'9' => {
                    const n3 = try stdin.read(buf[3..4]);
                    if (n3 > 0) {
                        if (buf[3] == '~') {
                            switch (buf[2]) {
                                '1', '7' => return Key.home,
                                '4', '8' => return Key.end_key,
                                '3' => return Key.delete,
                                '5' => return Key.page_up,
                                '6' => return Key.page_down,
                                else => {},
                            }
                        } else if (buf[2] == '3' and buf[3] == ';') {
                            // M-delete (ESC [3;3~)
                            const n4 = try stdin.read(buf[4..6]);
                            if (n4 >= 2 and buf[4] == '3' and buf[5] == '~') {
                                return Key.alt_delete;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        return Key.escape;
    }

    // UTF-8マルチバイト文字の処理
    if (ch >= config.UTF8.CONTINUATION_MASK) {
        const len = std.unicode.utf8ByteSequenceLength(ch) catch {
            // 無効なUTF-8は無視
            return Key{ .char = ch };
        };

        if (len > 1) {
            // 残りのバイトを読み取る
            buf[0] = ch;
            const remaining = try stdin.read(buf[1..len]);
            if (remaining == len - 1) {
                const codepoint = std.unicode.utf8Decode(buf[0..len]) catch {
                    return Key{ .char = ch };
                };
                return Key{ .codepoint = codepoint };
            }
        }
    }

    // ASCII文字
    return Key{ .char = ch };
}

pub fn keyToString(key: Key, buf: []u8) ![]const u8 {
    return switch (key) {
        .char => |c| blk: {
            buf[0] = c;
            break :blk buf[0..1];
        },
        .ctrl => |c| try std.fmt.bufPrint(buf, "C-{c}", .{c}),
        .alt => |c| try std.fmt.bufPrint(buf, "M-{c}", .{c}),
        .alt_delete => "M-Del",
        .arrow_up => "↑",
        .arrow_down => "↓",
        .arrow_left => "←",
        .arrow_right => "→",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .home => "Home",
        .end_key => "End",
        .delete => "Del",
        .backspace => "BS",
        .enter => "Enter",
        .escape => "Esc",
        .tab => "Tab",
        .codepoint => "UTF8",
    };
}
