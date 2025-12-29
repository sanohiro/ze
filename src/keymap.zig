// キーマップ（固定長配列ベース）
// Ctrl/Altは256要素の配列、Specialはenum直接インデックス
// ホットパスでO(1)ルックアップを実現
//
// 使い方:
// 1. Editor.initでKeymap.initを呼ぶ（デフォルトキーバインドはcomptime適用済み）
// 2. handleNormalKeyでfindCtrl/findAlt/findSpecialを使う
// 3. ユーザー設定ファイル対応時はbindCtrl等で上書き
//
// ========================================
// 検索・置換キーバインド（editor.zigで直接処理）
// ========================================
//
// 【インクリメンタルサーチ】
// C-s         : 前方検索（リテラル）
// C-r         : 後方検索（リテラル）
// C-M-s       : 前方検索（正規表現）
// C-M-r       : 後方検索（正規表現）
//
// 【検索モード中】
// C-s / C-M-s : 次のマッチへ移動
// C-r / C-M-r : 前のマッチへ移動
// M-r         : 正規表現/リテラルモードをトグル
// C-g         : 検索をキャンセル（元の位置に戻る）
// Enter       : 検索を確定（現在位置で終了）
//
// 【Query Replace（対話的置換）】
// M-%         : 置換開始（リテラル）
// M-% → M-r   : 正規表現モードに切り替え
//
// 【置換入力中】
// M-r         : 正規表現/リテラルモードをトグル
//
// 【置換確認中】
// y           : 置換して次へ
// n           : スキップして次へ
// !           : 残り全てを置換
// q / C-g     : 置換を終了

const std = @import("std");

/// Ctrl+キーの制御文字コード
/// 印字できない制御文字に対する定数（可読性のため）
const CtrlCode = struct {
    /// Ctrl+@ または Ctrl+Space (NUL)
    const SPACE: u8 = 0;
    /// Ctrl+/ (Unit Separator)
    const SLASH: u8 = 31;
};
const Editor = @import("editor").Editor;
const input = @import("input");

// コマンドモジュール
const edit = @import("commands_edit");
const movement = @import("commands_movement");

pub const CommandFn = *const fn (*Editor) anyerror!void;

/// 特殊キーの識別子
pub const SpecialKey = enum(u8) {
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
    delete,
    backspace,
    enter,
    tab,
    shift_tab,
    ctrl_tab,
    ctrl_shift_tab,
    alt_delete,
    alt_arrow_up,
    alt_arrow_down,
    alt_arrow_left,
    alt_arrow_right,
    shift_alt_arrow_up,
    shift_alt_arrow_down,
    shift_alt_arrow_left,
    shift_alt_arrow_right,
};

const SPECIAL_KEY_COUNT = @typeInfo(SpecialKey).@"enum".fields.len;

/// キーマップ: キーバインディングの管理
///
/// 【設計】
/// 固定長配列ベースでO(1)ルックアップを実現。
/// HashMapを使わないことでキー入力のホットパスを最速に保つ。
///
/// 【構成】
/// - ctrl_table[256]: Ctrl+キー（C-a〜C-zなど）
/// - alt_table[256]: Alt+キー（M-f、M-bなど）
/// - special_table[N]: 矢印、Page Up/Down、Home/Endなど
///
/// 【使い方】
/// 1. Editor.initでKeymap.initを呼ぶ（デフォルトキーバインドはcomptime適用済み）
/// 2. handleNormalKeyでfindCtrl/findAlt/findSpecialを呼ぶ
/// Ctrlキーバインドのエントリ
const CtrlBinding = struct { key: u8, handler: CommandFn };

/// Altキーバインドのエントリ
const AltBinding = struct { key: u8, handler: CommandFn };

/// 特殊キーバインドのエントリ
const SpecialBinding = struct { key: SpecialKey, handler: CommandFn };

/// デフォルトCtrlキーバインド（comptime配列）
const default_ctrl_bindings = [_]CtrlBinding{
    // マーク設定 (C-@ / C-Space)
    .{ .key = CtrlCode.SPACE, .handler = edit.setMark },
    .{ .key = '@', .handler = edit.setMark },
    // カーソル移動
    .{ .key = 'f', .handler = movement.cursorRight },
    .{ .key = 'b', .handler = movement.cursorLeft },
    .{ .key = 'n', .handler = movement.cursorDown },
    .{ .key = 'p', .handler = movement.cursorUp },
    .{ .key = 'a', .handler = movement.lineStart },
    .{ .key = 'e', .handler = movement.lineEnd },
    // 編集
    .{ .key = 'd', .handler = edit.deleteChar },
    .{ .key = 'k', .handler = edit.killLine },
    .{ .key = 'w', .handler = edit.killRegion },
    .{ .key = 'y', .handler = edit.yank },
    // その他
    .{ .key = 'g', .handler = edit.keyboardQuit },
    .{ .key = 'u', .handler = edit.undo },
    .{ .key = CtrlCode.SLASH, .handler = edit.redo }, // C-/ (31 = 0x1F)
    // ページスクロール
    .{ .key = 'v', .handler = movement.pageDown },
    // 画面中央化
    .{ .key = 'l', .handler = movement.recenter },
};

/// デフォルトAltキーバインド（comptime配列）
const default_alt_bindings = [_]AltBinding{
    // 単語移動
    .{ .key = 'f', .handler = movement.forwardWord },
    .{ .key = 'b', .handler = movement.backwardWord },
    .{ .key = 'd', .handler = edit.deleteWord },
    // 選択しながら単語移動 (Alt+Shift+f/b = M-F/B)
    .{ .key = 'F', .handler = movement.selectForwardWord },
    .{ .key = 'B', .handler = movement.selectBackwardWord },
    // コピー
    .{ .key = 'w', .handler = edit.copyRegion },
    // バッファ移動
    .{ .key = '<', .handler = movement.bufferStart },
    .{ .key = '>', .handler = movement.bufferEnd },
    // 段落移動
    .{ .key = '{', .handler = movement.backwardParagraph },
    .{ .key = '}', .handler = movement.forwardParagraph },
    // 行操作
    .{ .key = '^', .handler = edit.joinLine },
    .{ .key = ';', .handler = edit.toggleComment },
    // ウィンドウ切り替え（C-x oの短縮版）
    .{ .key = 'o', .handler = movement.nextWindow },
    // ページスクロール（上）
    .{ .key = 'v', .handler = movement.pageUp },
    // 選択しながらページスクロール（上）(Alt+Shift+v = M-V)
    .{ .key = 'V', .handler = movement.selectPageUpAlt },
};

/// デフォルト特殊キーバインド（comptime配列）
const default_special_bindings = [_]SpecialBinding{
    // 矢印キー
    .{ .key = .arrow_up, .handler = movement.cursorUp },
    .{ .key = .arrow_down, .handler = movement.cursorDown },
    .{ .key = .arrow_left, .handler = movement.cursorLeft },
    .{ .key = .arrow_right, .handler = movement.cursorRight },
    // Shift+矢印（選択移動）
    .{ .key = .shift_arrow_up, .handler = movement.selectUp },
    .{ .key = .shift_arrow_down, .handler = movement.selectDown },
    .{ .key = .shift_arrow_left, .handler = movement.selectLeft },
    .{ .key = .shift_arrow_right, .handler = movement.selectRight },
    // Alt+矢印
    .{ .key = .alt_arrow_up, .handler = edit.moveLineUp },
    .{ .key = .alt_arrow_down, .handler = edit.moveLineDown },
    .{ .key = .alt_arrow_left, .handler = movement.backwardWord },
    .{ .key = .alt_arrow_right, .handler = movement.forwardWord },
    .{ .key = .alt_delete, .handler = edit.deleteWord },
    // Shift+Alt+矢印（選択しながら単語/行移動）
    .{ .key = .shift_alt_arrow_up, .handler = movement.selectUp },
    .{ .key = .shift_alt_arrow_down, .handler = movement.selectDown },
    .{ .key = .shift_alt_arrow_left, .handler = movement.selectBackwardWord },
    .{ .key = .shift_alt_arrow_right, .handler = movement.selectForwardWord },
    // ページ
    .{ .key = .page_down, .handler = movement.pageDown },
    .{ .key = .page_up, .handler = movement.pageUp },
    // Shift+ページ（選択移動）
    .{ .key = .shift_page_up, .handler = movement.selectPageUp },
    .{ .key = .shift_page_down, .handler = movement.selectPageDown },
    // ホーム/エンド
    .{ .key = .home, .handler = movement.lineStart },
    .{ .key = .end_key, .handler = movement.lineEnd },
    // 編集
    .{ .key = .delete, .handler = edit.deleteChar },
    .{ .key = .backspace, .handler = edit.backspace },
    // ウィンドウ切り替え
    .{ .key = .ctrl_tab, .handler = movement.nextWindow },
    .{ .key = .ctrl_shift_tab, .handler = movement.prevWindow },
};

/// comptimeでデフォルトテーブルを生成（ジェネリック版）
fn makeDefaultTable(comptime size: usize, comptime bindings: anytype) [size]?CommandFn {
    var table = [_]?CommandFn{null} ** size;
    for (bindings) |binding| {
        const index = switch (@TypeOf(binding.key)) {
            u8 => binding.key,
            SpecialKey => @intFromEnum(binding.key),
            else => @compileError("Unsupported key type"),
        };
        table[index] = binding.handler;
    }
    return table;
}

/// comptime生成されたデフォルトテーブル
const DEFAULT_CTRL_TABLE: [256]?CommandFn = makeDefaultTable(256, default_ctrl_bindings);
const DEFAULT_ALT_TABLE: [256]?CommandFn = makeDefaultTable(256, default_alt_bindings);
const DEFAULT_SPECIAL_TABLE: [SPECIAL_KEY_COUNT]?CommandFn = makeDefaultTable(SPECIAL_KEY_COUNT, default_special_bindings);

pub const Keymap = struct {
    // 固定長配列: O(1)ルックアップ
    ctrl_table: [256]?CommandFn,
    alt_table: [256]?CommandFn,
    special_table: [SPECIAL_KEY_COUNT]?CommandFn,

    /// 初期化（デフォルトキーバインド適用済み）
    /// comptimeテーブルからの単純コピーなので高速
    pub fn init(_: std.mem.Allocator) !Keymap {
        return .{
            .ctrl_table = DEFAULT_CTRL_TABLE,
            .alt_table = DEFAULT_ALT_TABLE,
            .special_table = DEFAULT_SPECIAL_TABLE,
        };
    }

    pub fn deinit(_: *Keymap) void {
        // 固定長配列なので解放不要
    }

    // キーバインド登録（ユーザー設定で上書き用）
    pub fn bindCtrl(self: *Keymap, key: u8, handler: CommandFn) void {
        self.ctrl_table[key] = handler;
    }

    pub fn bindAlt(self: *Keymap, key: u8, handler: CommandFn) void {
        self.alt_table[key] = handler;
    }

    pub fn bindSpecial(self: *Keymap, key: SpecialKey, handler: CommandFn) void {
        self.special_table[@intFromEnum(key)] = handler;
    }

    // キーバインド検索: 配列の直接インデックスでO(1)
    pub fn findCtrl(self: *const Keymap, key: u8) ?CommandFn {
        return self.ctrl_table[key];
    }

    pub fn findAlt(self: *const Keymap, key: u8) ?CommandFn {
        return self.alt_table[key];
    }

    pub fn findSpecial(self: *const Keymap, key: SpecialKey) ?CommandFn {
        return self.special_table[@intFromEnum(key)];
    }

    /// input.Key を SpecialKey に変換
    pub fn toSpecialKey(key: input.Key) ?SpecialKey {
        return switch (key) {
            .arrow_up => .arrow_up,
            .arrow_down => .arrow_down,
            .arrow_left => .arrow_left,
            .arrow_right => .arrow_right,
            .shift_arrow_up => .shift_arrow_up,
            .shift_arrow_down => .shift_arrow_down,
            .shift_arrow_left => .shift_arrow_left,
            .shift_arrow_right => .shift_arrow_right,
            .page_up => .page_up,
            .page_down => .page_down,
            .shift_page_up => .shift_page_up,
            .shift_page_down => .shift_page_down,
            .home => .home,
            .end_key => .end_key,
            .delete => .delete,
            .backspace => .backspace,
            .enter => .enter,
            .tab => .tab,
            .shift_tab => .shift_tab,
            .ctrl_tab => .ctrl_tab,
            .ctrl_shift_tab => .ctrl_shift_tab,
            .alt_delete => .alt_delete,
            .alt_arrow_up => .alt_arrow_up,
            .alt_arrow_down => .alt_arrow_down,
            .alt_arrow_left => .alt_arrow_left,
            .alt_arrow_right => .alt_arrow_right,
            .shift_alt_arrow_up => .shift_alt_arrow_up,
            .shift_alt_arrow_down => .shift_alt_arrow_down,
            .shift_alt_arrow_left => .shift_alt_arrow_left,
            .shift_alt_arrow_right => .shift_alt_arrow_right,
            else => null,
        };
    }

};
