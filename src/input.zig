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
    pub inline fn available(self: *const InputReader) usize {
        return self.end - self.start;
    }

    /// バッファにデータがあるかチェック
    pub inline fn hasData(self: *const InputReader) bool {
        return self.available() > 0;
    }

    /// stdinから利用可能なデータをバッファに読み込む
    /// シグナル割り込み(error.Interrupted)は自動的にリトライする
    fn fill(self: *InputReader) !usize {
        if (self.start > 0 and self.end == self.start) {
            // バッファが空なら先頭にリセット
            self.start = 0;
            self.end = 0;
        } else if (self.start > config.Input.RING_BUF_SIZE * 3 / 4) {
            // 3/4以上消費したらデータを先頭に移動（compaction頻度削減）
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
    // ファンクションキー
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// 修飾キー付き矢印キーをパース
fn parseModifiedArrowKey(buf: []u8, reader: *InputReader) !?Key {
    const n4 = try reader.readBytes(buf[4..6]);
    if (n4 < 2) return null;

    const modifier = buf[4];
    const key = buf[5];
    return switch (modifier) {
        '2' => switch (key) {
            'A' => Key.shift_arrow_up,
            'B' => Key.shift_arrow_down,
            'C' => Key.shift_arrow_right,
            'D' => Key.shift_arrow_left,
            else => null,
        },
        '3' => switch (key) {
            'A' => Key.alt_arrow_up,
            'B' => Key.alt_arrow_down,
            'C' => Key.alt_arrow_right,
            'D' => Key.alt_arrow_left,
            else => null,
        },
        '4' => switch (key) {
            'A' => Key.shift_alt_arrow_up,
            'B' => Key.shift_alt_arrow_down,
            'C' => Key.shift_alt_arrow_right,
            'D' => Key.shift_alt_arrow_left,
            else => null,
        },
        else => null,
    };
}

/// CSIシーケンスをパース（ESC [ ... の部分）
fn parseCSISequence(reader: *InputReader, buf: []u8) !?Key {
    const second_byte = try reader.readByte() orelse return Key.escape;
    buf[2] = second_byte;

    // シンプルなシーケンス（ESC [ X）
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
            _ = reader.readBytes(buf[3..6]) catch {};
            return null;
        },
        '<' => {
            // SGR拡張マウスイベント: ESC [ < ... m/M
            var sgr_count: usize = 0;
            while (sgr_count < 32) : (sgr_count += 1) {
                const b = try reader.readByte() orelse break;
                if (b == 'm' or b == 'M') break;
            }
            return null;
        },
        '1'...'9' => {
            // 多桁数値を読み取る（F5=15~, F6=17~等に対応）
            var num: u32 = buf[2] - '0';
            var idx: usize = 3;
            while (idx < buf.len) : (idx += 1) {
                const b = try reader.readByte() orelse break;
                buf[idx] = b;
                if (b >= '0' and b <= '9') {
                    num = num * 10 + (b - '0');
                } else {
                    break; // '~' または ';' または他の終端文字
                }
            }

            // チルダ終端（ESC [ N ~）
            // バッファ境界チェック: ループ終了後にidx == buf.lenの可能性がある
            if (idx < buf.len and buf[idx] == '~') {
                return switch (num) {
                    1, 7 => Key.home,
                    2 => Key.insert,
                    3 => Key.delete,
                    4, 8 => Key.end_key,
                    5 => Key.page_up,
                    6 => Key.page_down,
                    // ファンクションキー
                    15 => Key.f5,
                    17 => Key.f6,
                    18 => Key.f7,
                    19 => Key.f8,
                    20 => Key.f9,
                    21 => Key.f10,
                    23 => Key.f11,
                    24 => Key.f12,
                    // ブラケットペースト
                    200 => Key.paste_start,
                    201 => Key.paste_end,
                    else => null,
                };
            }

            // セミコロン区切りのパラメータ
            if (buf[idx] == ';') {
                // ESC [ 1 ; <modifier> <key>
                if (num == 1) {
                    return try parseModifiedArrowKey(buf, reader);
                }
                // ESC [ 5 ; 2 ~ (Shift+PageUp) - バッファ境界チェック
                if (num == 5 and idx + 3 <= buf.len) {
                    const n4 = try reader.readBytes(buf[idx + 1 ..][0..2]);
                    if (n4 >= 2 and buf[idx + 1] == '2' and buf[idx + 2] == '~') {
                        return Key.shift_page_up;
                    }
                }
                // ESC [ 6 ; 2 ~ (Shift+PageDown) - バッファ境界チェック
                if (num == 6 and idx + 3 <= buf.len) {
                    const n4 = try reader.readBytes(buf[idx + 1 ..][0..2]);
                    if (n4 >= 2 and buf[idx + 1] == '2' and buf[idx + 2] == '~') {
                        return Key.shift_page_down;
                    }
                }
                // ESC [ 3 ; 3 ~ (Alt+Delete) - バッファ境界チェック
                if (num == 3 and idx + 3 <= buf.len) {
                    const n4 = try reader.readBytes(buf[idx + 1 ..][0..2]);
                    if (n4 >= 2 and buf[idx + 1] == '3' and buf[idx + 2] == '~') {
                        return Key.alt_delete;
                    }
                }
                // ESC [ 27 ; ... (Ctrl+Tab系) - バッファ境界チェック
                if (num == 27 and idx + 6 <= buf.len) {
                    const n4 = try reader.readBytes(buf[idx + 1 ..][0..5]);
                    if (n4 >= 5 and buf[idx + 2] == ';' and buf[idx + 3] == '9' and buf[idx + 4] == '~') {
                        if (buf[idx + 1] == '5') return Key.ctrl_tab;
                        if (buf[idx + 1] == '6') return Key.ctrl_shift_tab;
                    }
                }
            }
        },
        else => {},
    }

    return null;
}

/// InputReaderを使ってキーを読み取る
pub fn readKeyFromReader(reader: *InputReader) !?Key {
    var buf: [config.Input.BUF_SIZE]u8 = undefined;

    const ch = try reader.readByte() orelse return null;

    // 特殊キーを先にチェック（Ctrlキーと重複するため）
    switch (ch) {
        '\r', '\n' => return Key.enter,
        config.ASCII.BACKSPACE, config.ASCII.DEL => return Key.backspace,
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

        // SS3シーケンス（ESC O）- 一部ターミナルの矢印キー・ファンクションキー
        // 注: application cursor keys mode 等で使用される
        if (first_byte == 'O') {
            const third_byte = try reader.readByte() orelse return Key{ .alt = 'O' };
            return switch (third_byte) {
                'A' => Key.arrow_up,
                'B' => Key.arrow_down,
                'C' => Key.arrow_right,
                'D' => Key.arrow_left,
                'H' => Key.home,
                'F' => Key.end_key,
                'P', 'Q', 'R', 'S' => null, // F1-F4（未サポート、無視）
                else => Key{ .alt = 'O' }, // 不明なシーケンスはAlt+Oとして扱う
            };
        }

        // Alt+印刷可能ASCII文字（ESC + 文字）
        if (first_byte >= 0x20 and first_byte < 0x7F and first_byte != '[') {
            return Key{ .alt = first_byte };
        }

        // CSIシーケンス（ESC [）の場合、パーサーに委譲
        if (first_byte == '[') {
            return try parseCSISequence(reader, &buf);
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
