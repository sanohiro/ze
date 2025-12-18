// ============================================================================
// Input - キー入力のパース
// ============================================================================
//
// 【責務】
// - stdinからのバイト列をKey型に変換
// - エスケープシーケンスの解釈（矢印キー、ファンクションキー等）
// - Ctrl/Altキー修飾の検出
// - UTF-8マルチバイト文字の処理
//
// 【エスケープシーケンス】
// 端末は特殊キーをESC（0x1B）で始まるシーケンスとして送信:
// - ESC [ A → 上矢印
// - ESC [ 1 ; 3 A → Alt+上矢印
// - ESC <char> → Alt+<char>
//
// 【タイムアウト処理】
// ESCキー単体とエスケープシーケンス開始を区別するため、
// 後続バイトを100ms待つ（VTIME=1で設定）。
// タイムアウトしたらESCキーとして扱う。
// ============================================================================

const std = @import("std");
const config = @import("config");
const unicode = @import("unicode");

/// 入力バッファ付きリーダー（リングバッファ方式）
///
/// 【目的】
/// stdinからの読み取りでシステムコール回数を削減する。
/// 大量入力（ペースト操作など）で特に効果的。
///
/// 【動作】
/// - バッファサイズ: 4KB（config.Input.RING_BUF_SIZE）
/// - 半分以上消費したらデータを先頭に移動（compaction）
/// - EINTR（シグナル割り込み）は自動リトライ
///
/// 【パフォーマンス効果】
/// - 1バイトずつread()を呼ぶ場合: 毎回システムコール発生
/// - バッファ付き: 4KB分まとめて読んで使い回し
/// - ペースト時の速度が大幅に向上
pub const InputReader = struct {
    stdin: std.fs.File,
    buf: [config.Input.RING_BUF_SIZE]u8 = undefined, // 4KBの固定バッファ
    start: usize = 0, // 読み取り開始位置（消費済み）
    end: usize = 0, // データ終端位置（書き込み済み）
    pushed_back_byte: ?u8 = null, // 戻されたバイト（UTF-8エラー時に次のキー入力を保存）

    pub fn init(stdin: std.fs.File) InputReader {
        return .{ .stdin = stdin };
    }

    /// 1バイトをバッファに戻す（次のreadByte()で返される）
    /// UTF-8デコードエラー時に、次のキー入力の先頭バイトを失わないために使用
    pub fn unreadByte(self: *InputReader, byte: u8) void {
        self.pushed_back_byte = byte;
    }

    /// バッファ内のデータ量
    pub fn available(self: *const InputReader) usize {
        return self.end - self.start;
    }

    /// バッファにデータがあるかチェック
    pub fn hasData(self: *const InputReader) bool {
        return self.available() > 0;
    }

    /// stdinから利用可能なデータをバッファに読み込む
    /// シグナル割り込み(error.Interrupted)は自動的にリトライする
    fn fill(self: *InputReader) !usize {
        if (self.start > 0 and self.end == self.start) {
            // バッファが空なら先頭にリセット
            self.start = 0;
            self.end = 0;
        } else if (self.start > config.Input.RING_BUF_SIZE / 2) {
            // 半分以上消費したらデータを先頭に移動
            const len = self.end - self.start;
            std.mem.copyForwards(u8, self.buf[0..len], self.buf[self.start..self.end]);
            self.start = 0;
            self.end = len;
        }

        const space = config.Input.RING_BUF_SIZE - self.end;
        if (space == 0) return 0;

        // シグナル割り込み(SIGWINCH等)時にリトライ
        while (true) {
            const n = self.stdin.read(self.buf[self.end .. self.end + space]) catch |err| {
                if (err == error.Interrupted) continue; // EINTR: リトライ
                return err;
            };
            self.end += n;
            return n;
        }
    }

    /// 1バイト読み取り（バッファから、なければstdinから）
    pub fn readByte(self: *InputReader) !?u8 {
        // まずpushed_back_byteをチェック（UTF-8エラー時に戻されたバイト）
        if (self.pushed_back_byte) |byte| {
            self.pushed_back_byte = null;
            return byte;
        }
        if (self.available() == 0) {
            const n = try self.fill();
            if (n == 0) return null;
        }
        const byte = self.buf[self.start];
        self.start += 1;
        return byte;
    }

    /// 複数バイト読み取り（戻り値は読み取ったバイト数）
    pub fn readBytes(self: *InputReader, out: []u8) !usize {
        var total: usize = 0;

        // まず pushed_back_byte を処理（unreadByteで戻されたバイト）
        if (self.pushed_back_byte) |byte| {
            if (out.len > 0) {
                out[0] = byte;
                self.pushed_back_byte = null;
                total = 1;
            }
        }

        while (total < out.len) {
            if (self.available() == 0) {
                const n = try self.fill();
                if (n == 0) break;
            }
            const avail = @min(self.available(), out.len - total);
            @memcpy(out[total .. total + avail], self.buf[self.start .. self.start + avail]);
            self.start += avail;
            total += avail;
        }
        return total;
    }
};

/// 解釈されたキー入力（エスケープシーケンスをデコード済み）
///
/// 【種類】
/// - char: 印刷可能ASCII文字（0x20-0x7E）
/// - codepoint: 非ASCII UTF-8文字（日本語、絵文字等）
/// - ctrl: Ctrl+文字（C-a = 1, C-b = 2, ...）
/// - alt: Alt+文字（M-f, M-bなど）
/// - 特殊キー: arrow_*, page_*, home, end_key, delete等
///
/// 【エスケープシーケンス例】
/// ESC [ A → arrow_up
/// ESC [ 1 ; 2 A → shift_arrow_up
/// ESC [ 1 ; 3 A → alt_arrow_up
/// ESC f → alt + 'f'
pub const Key = union(enum) {
    char: u8,
    codepoint: u21, // UTF-8文字
    ctrl: u8,
    alt: u8,
    ctrl_alt: u8, // Ctrl+Alt+文字（C-M-s等）
    alt_delete,
    alt_arrow_up,
    alt_arrow_down,
    alt_arrow_left,
    alt_arrow_right,
    shift_alt_arrow_up,
    shift_alt_arrow_down,
    shift_alt_arrow_left,
    shift_alt_arrow_right,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    shift_arrow_up,
    shift_arrow_down,
    shift_arrow_left,
    shift_arrow_right,
    page_up,
    page_down,
    shift_page_up,
    shift_page_down,
    scroll_up,
    scroll_down,
    home,
    end_key,
    insert,
    delete,
    backspace,
    enter,
    escape,
    tab,
    shift_tab,
    ctrl_tab,
    ctrl_shift_tab,
    paste_start, // ブラケットペーストモード開始 (ESC[200~)
    paste_end, // ブラケットペーストモード終了 (ESC[201~)
};

/// InputReaderを使ってキーを読み取る
pub fn readKeyFromReader(reader: *InputReader) !?Key {
    var buf: [config.Input.BUF_SIZE]u8 = undefined;

    const ch = try reader.readByte() orelse return null;

    // 特殊キーを先にチェック（Ctrlキーと重複するため）
    switch (ch) {
        '\r', '\n' => return Key.enter,
        8, config.ASCII.DEL => return Key.backspace,
        '\t' => return Key.tab,
        else => {},
    }

    // Ctrl+Space (C-@) = ASCII 0 (NUL)
    if (ch == 0) {
        return Key{ .ctrl = 0 };
    }

    // Ctrl キー (0x01-0x1A)
    if (ch >= 1 and ch <= 26) {
        return Key{ .ctrl = ch + 'a' - 1 };
    }

    // Ctrl+/ (C-_) = ASCII 31 (0x1F)
    if (ch == 31) {
        return Key{ .ctrl = 31 };
    }

    // ESC シーケンス
    if (ch == config.ASCII.ESC) {
        // まず1バイトだけ読む
        const first_byte = try reader.readByte() orelse return Key.escape;
        buf[1] = first_byte;

        // Ctrl+Alt+文字（ESC + Ctrl文字）: C-M-s = ESC + 0x13
        // C-M-@ (ESC + 0x00)
        if (first_byte == 0) {
            return Key{ .ctrl_alt = '@' };
        }
        // C-M-a から C-M-z (ESC + 0x01-0x1A)
        if (first_byte >= 1 and first_byte <= 26) {
            // Ctrl+文字を元の文字に復元してctrl_altとして返す
            // 例: 0x13 (C-s) -> 's' (0x73)
            return Key{ .ctrl_alt = first_byte + 'a' - 1 };
        }
        // C-M-/ (ESC + 0x1F = 31) - Ctrl+/ は 31 になる
        if (first_byte == 31) {
            return Key{ .ctrl_alt = '/' };
        }

        // Alt+印刷可能ASCII文字（ESC + 文字）
        if (first_byte >= 0x20 and first_byte < 0x7F and first_byte != '[') {
            return Key{ .alt = first_byte };
        }

        // CSIシーケンス（ESC [）の場合、2バイト目を読む
        if (first_byte == '[') {
            const second_byte = try reader.readByte() orelse return Key.escape;
            buf[2] = second_byte;
            switch (buf[2]) {
                'A' => return Key.arrow_up,
                'B' => return Key.arrow_down,
                'C' => return Key.arrow_right,
                'D' => return Key.arrow_left,
                'H' => return Key.home,
                'F' => return Key.end_key,
                'Z' => return Key.shift_tab,
                'M' => {
                    // マウスイベント（X10形式）: ESC [ M <button> <x> <y>
                    // button byte = 32 + button_code
                    // scroll up: 32 + 64 = 96, scroll down: 32 + 65 = 97
                    const n = try reader.readBytes(buf[3..6]);
                    if (n >= 1) {
                        const button = buf[3];
                        if (button == 96) return Key.scroll_up;
                        if (button == 97) return Key.scroll_down;
                    }
                    return null; // その他のマウスイベントは無視
                },
                '<' => {
                    // SGR拡張マウスイベント: ESC [ < ... m/M
                    // 'm'または'M'が来るまで読み捨てる（上限32バイト）
                    var sgr_count: usize = 0;
                    while (sgr_count < 32) : (sgr_count += 1) {
                        const b = try reader.readByte() orelse break;
                        if (b == 'm' or b == 'M') break;
                    }
                    return null; // 無視して次のキーを待つ
                },
                '1'...'9' => {
                    const n3 = try reader.readBytes(buf[3..4]);
                    if (n3 > 0) {
                        if (buf[3] == '~') {
                            switch (buf[2]) {
                                '1', '7' => return Key.home,
                                '2' => return Key.insert,
                                '3' => return Key.delete,
                                '4', '8' => return Key.end_key,
                                '5' => return Key.page_up,
                                '6' => return Key.page_down,
                                else => {},
                            }
                        } else if (buf[2] == '1' and buf[3] == ';') {
                            // ESC [ 1 ; <modifier> <key>
                            // modifier: 2=Shift, 3=Alt, 5=Ctrl, 6=Ctrl+Shift
                            const n4 = try reader.readBytes(buf[4..6]);
                            if (n4 >= 2) {
                                if (buf[4] == '2') {
                                    // Shift+矢印キー (modifier 2)
                                    switch (buf[5]) {
                                        'A' => return Key.shift_arrow_up,
                                        'B' => return Key.shift_arrow_down,
                                        'C' => return Key.shift_arrow_right,
                                        'D' => return Key.shift_arrow_left,
                                        else => {},
                                    }
                                } else if (buf[4] == '3') {
                                    // Alt+矢印キー (modifier 3)
                                    switch (buf[5]) {
                                        'A' => return Key.alt_arrow_up,
                                        'B' => return Key.alt_arrow_down,
                                        'C' => return Key.alt_arrow_right,
                                        'D' => return Key.alt_arrow_left,
                                        else => {},
                                    }
                                } else if (buf[4] == '4') {
                                    // Shift+Alt+矢印キー (modifier 4)
                                    switch (buf[5]) {
                                        'A' => return Key.shift_alt_arrow_up,
                                        'B' => return Key.shift_alt_arrow_down,
                                        'C' => return Key.shift_alt_arrow_right,
                                        'D' => return Key.shift_alt_arrow_left,
                                        else => {},
                                    }
                                }
                            }
                        } else if (buf[2] == '5' and buf[3] == ';') {
                            // ESC [ 5 ; 2 ~ = Shift+PageUp
                            const n4 = try reader.readBytes(buf[4..6]);
                            if (n4 >= 2 and buf[4] == '2' and buf[5] == '~') {
                                return Key.shift_page_up;
                            }
                        } else if (buf[2] == '6' and buf[3] == ';') {
                            // ESC [ 6 ; 2 ~ = Shift+PageDown
                            const n4 = try reader.readBytes(buf[4..6]);
                            if (n4 >= 2 and buf[4] == '2' and buf[5] == '~') {
                                return Key.shift_page_down;
                            }
                        } else if (buf[2] == '3' and buf[3] == ';') {
                            const n4 = try reader.readBytes(buf[4..6]);
                            if (n4 >= 2 and buf[4] == '3' and buf[5] == '~') {
                                return Key.alt_delete;
                            }
                        } else if (buf[2] == '2' and buf[3] == '7') {
                            const n4 = try reader.readBytes(buf[4..9]);
                            if (n4 >= 5 and buf[4] == ';' and buf[6] == ';' and buf[7] == '9' and buf[8] == '~') {
                                if (buf[5] == '5') {
                                    return Key.ctrl_tab;
                                } else if (buf[5] == '6') {
                                    return Key.ctrl_shift_tab;
                                }
                            }
                        } else if (buf[2] == '2' and buf[3] == '0') {
                            // ブラケットペーストモード: ESC [ 2 0 0 ~ (開始) / ESC [ 2 0 1 ~ (終了)
                            const n4 = try reader.readBytes(buf[4..6]);
                            if (n4 >= 2 and buf[5] == '~') {
                                if (buf[4] == '0') {
                                    return Key.paste_start;
                                } else if (buf[4] == '1') {
                                    return Key.paste_end;
                                }
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
            // 無効なUTF-8先頭バイト（0x80-0xBFなどのcontinuation byte）
            // そのまま無視して次のバイトを待つ
            return null;
        };

        if (len > 1) {
            buf[0] = ch;
            var bytes_read: usize = 1;

            // continuation bytesを1バイトずつ読み取り、検証する
            while (bytes_read < len) {
                const byte = try reader.readByte() orelse {
                    // タイムアウト：不完全なシーケンス、置換文字を返す
                    return Key{ .codepoint = 0xFFFD };
                };

                // continuation byteかチェック
                if (!unicode.isUtf8Continuation(byte)) {
                    // continuation byteでない → 無効なシーケンス
                    // このバイトは次のキー入力の開始かもしれないので、
                    // バッファに戻して次回の読み取りで処理する
                    reader.unreadByte(byte);
                    return Key{ .codepoint = 0xFFFD };
                }

                buf[bytes_read] = byte;
                bytes_read += 1;
            }

            const codepoint = std.unicode.utf8Decode(buf[0..len]) catch {
                // デコード失敗：オーバーロング等の無効なシーケンス
                return Key{ .codepoint = 0xFFFD };
            };
            return Key{ .codepoint = codepoint };
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
        .ctrl_alt => |c| try std.fmt.bufPrint(buf, "C-M-{c}", .{c}),
        .alt_delete => "M-Del",
        .alt_arrow_up => "M-↑",
        .alt_arrow_down => "M-↓",
        .alt_arrow_left => "M-←",
        .alt_arrow_right => "M-→",
        .arrow_up => "↑",
        .arrow_down => "↓",
        .arrow_left => "←",
        .arrow_right => "→",
        .shift_arrow_up => "S-↑",
        .shift_arrow_down => "S-↓",
        .shift_arrow_left => "S-←",
        .shift_arrow_right => "S-→",
        .shift_alt_arrow_up => "S-M-↑",
        .shift_alt_arrow_down => "S-M-↓",
        .shift_alt_arrow_left => "S-M-←",
        .shift_alt_arrow_right => "S-M-→",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .shift_page_up => "S-PgUp",
        .shift_page_down => "S-PgDn",
        .scroll_up => "ScrollUp",
        .scroll_down => "ScrollDn",
        .home => "Home",
        .end_key => "End",
        .insert => "Ins",
        .delete => "Del",
        .backspace => "BS",
        .enter => "Enter",
        .escape => "Esc",
        .tab => "Tab",
        .shift_tab => "S-Tab",
        .ctrl_tab => "C-Tab",
        .ctrl_shift_tab => "C-S-Tab",
        .paste_start => "PasteStart",
        .paste_end => "PasteEnd",
        .codepoint => "UTF8",
    };
}
