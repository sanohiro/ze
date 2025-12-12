// キーマップ（固定長配列ベース）
// Ctrl/Altは256要素の配列、Specialはenum直接インデックス
// ホットパスでO(1)ルックアップを実現
//
// 使い方:
// 1. Editor.initでKeymap.initを呼ぶ
// 2. loadDefaults()でデフォルトキーバインドを登録
// 3. handleNormalKeyでfindCtrl/findAlt/findSpecialを使う
// 4. ユーザー設定ファイル対応時はbindCtrl等で上書き

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
    scroll_up,
    scroll_down,
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
/// 1. Editor.initでKeymap.initを呼ぶ
/// 2. loadDefaults()でEmacsキーバインドを登録
/// 3. handleNormalKeyでfindCtrl/findAlt/findSpecialを呼ぶ
pub const Keymap = struct {
    // 固定長配列: O(1)ルックアップ
    ctrl_table: [256]?CommandFn,
    alt_table: [256]?CommandFn,
    special_table: [SPECIAL_KEY_COUNT]?CommandFn,

    pub fn init(_: std.mem.Allocator) !Keymap {
        return .{
            .ctrl_table = [_]?CommandFn{null} ** 256,
            .alt_table = [_]?CommandFn{null} ** 256,
            .special_table = [_]?CommandFn{null} ** SPECIAL_KEY_COUNT,
        };
    }

    pub fn deinit(_: *Keymap) void {
        // 固定長配列なので解放不要
    }

    // キーバインド登録
    pub fn bindCtrl(self: *Keymap, key: u8, handler: CommandFn) !void {
        self.ctrl_table[key] = handler;
    }

    pub fn bindAlt(self: *Keymap, key: u8, handler: CommandFn) !void {
        self.alt_table[key] = handler;
    }

    pub fn bindSpecial(self: *Keymap, key: SpecialKey, handler: CommandFn) !void {
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
            .scroll_up => .scroll_up,
            .scroll_down => .scroll_down,
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

    // デフォルトキーバインドを登録
    pub fn loadDefaults(self: *Keymap) !void {
        // ========================================
        // Ctrl キーバインド
        // ========================================

        // マーク設定 (C-@ / C-Space)
        try self.bindCtrl(CtrlCode.SPACE, edit.setMark);
        try self.bindCtrl('@', edit.setMark);

        // カーソル移動
        try self.bindCtrl('f', movement.cursorRight);
        try self.bindCtrl('b', movement.cursorLeft);
        try self.bindCtrl('n', movement.cursorDown);
        try self.bindCtrl('p', movement.cursorUp);
        try self.bindCtrl('a', movement.lineStart);
        try self.bindCtrl('e', movement.lineEnd);

        // 編集
        try self.bindCtrl('d', edit.deleteChar);
        try self.bindCtrl('k', edit.killLine);
        try self.bindCtrl('w', edit.killRegion);
        try self.bindCtrl('y', edit.yank);

        // その他
        try self.bindCtrl('g', edit.keyboardQuit);
        try self.bindCtrl('u', edit.undo);
        try self.bindCtrl(CtrlCode.SLASH, edit.redo); // C-/
        try self.bindCtrl('/', edit.redo);

        // ページスクロール
        try self.bindCtrl('v', movement.pageDown);

        // 画面中央化
        try self.bindCtrl('l', movement.recenter);

        // ========================================
        // Alt キーバインド
        // ========================================

        // 単語移動
        try self.bindAlt('f', movement.forwardWord);
        try self.bindAlt('b', movement.backwardWord);
        try self.bindAlt('d', edit.deleteWord);

        // 選択しながら単語移動 (Alt+Shift+f/b = M-F/B)
        try self.bindAlt('F', movement.selectForwardWord);
        try self.bindAlt('B', movement.selectBackwardWord);

        // コピー
        try self.bindAlt('w', edit.copyRegion);

        // バッファ移動
        try self.bindAlt('<', movement.bufferStart);
        try self.bindAlt('>', movement.bufferEnd);

        // 段落移動
        try self.bindAlt('{', movement.backwardParagraph);
        try self.bindAlt('}', movement.forwardParagraph);

        // 行操作
        try self.bindAlt('^', edit.joinLine);
        try self.bindAlt(';', edit.toggleComment);

        // ウィンドウ切り替え（C-x oの短縮版）
        try self.bindAlt('o', movement.nextWindow);

        // ページスクロール（上）
        try self.bindAlt('v', movement.pageUp);

        // 選択しながらページスクロール（上）(Alt+Shift+v = M-V)
        try self.bindAlt('V', movement.selectPageUpAlt);

        // ========================================
        // 特殊キー
        // ========================================

        // 矢印キー
        try self.bindSpecial(.arrow_up, movement.cursorUp);
        try self.bindSpecial(.arrow_down, movement.cursorDown);
        try self.bindSpecial(.arrow_left, movement.cursorLeft);
        try self.bindSpecial(.arrow_right, movement.cursorRight);

        // Shift+矢印（選択移動）
        try self.bindSpecial(.shift_arrow_up, movement.selectUp);
        try self.bindSpecial(.shift_arrow_down, movement.selectDown);
        try self.bindSpecial(.shift_arrow_left, movement.selectLeft);
        try self.bindSpecial(.shift_arrow_right, movement.selectRight);

        // Alt+矢印
        try self.bindSpecial(.alt_arrow_up, edit.moveLineUp);
        try self.bindSpecial(.alt_arrow_down, edit.moveLineDown);
        try self.bindSpecial(.alt_arrow_left, movement.backwardWord);
        try self.bindSpecial(.alt_arrow_right, movement.forwardWord);
        try self.bindSpecial(.alt_delete, edit.deleteWord);

        // Shift+Alt+矢印（選択しながら単語/行移動）
        try self.bindSpecial(.shift_alt_arrow_up, movement.selectUp);
        try self.bindSpecial(.shift_alt_arrow_down, movement.selectDown);
        try self.bindSpecial(.shift_alt_arrow_left, movement.selectBackwardWord);
        try self.bindSpecial(.shift_alt_arrow_right, movement.selectForwardWord);

        // ページ
        try self.bindSpecial(.page_down, movement.pageDown);
        try self.bindSpecial(.page_up, movement.pageUp);

        // Shift+ページ（選択移動）
        try self.bindSpecial(.shift_page_up, movement.selectPageUp);
        try self.bindSpecial(.shift_page_down, movement.selectPageDown);

        // スクロールジェスチャー（トラックパッド）
        try self.bindSpecial(.scroll_up, movement.scrollUp);
        try self.bindSpecial(.scroll_down, movement.scrollDown);

        // ホーム/エンド
        try self.bindSpecial(.home, movement.lineStart);
        try self.bindSpecial(.end_key, movement.lineEnd);

        // 編集
        try self.bindSpecial(.delete, edit.deleteChar);
        try self.bindSpecial(.backspace, edit.backspace);

        // ウィンドウ切り替え
        try self.bindSpecial(.ctrl_tab, movement.nextWindow);
        try self.bindSpecial(.ctrl_shift_tab, movement.prevWindow);
    }
};
