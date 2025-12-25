# regex.zig 最適化提案

## 概要
正規表現エンジンの性能最適化

## 1. matchRepeat関数群の共通化

### 問題
3つの関数が同じバッファ管理ロジックを繰り返している:
- `matchRepeatLiteral` (行 604-653)
- `matchRepeat` (行 683-732)
- `matchRepeatClass` (行 734-783)

### 提案
```zig
fn appendPosition(
    self: *const Regex,
    stack_buf: *[256]usize,
    heap_buf: *?std.ArrayList(usize),
    positions: *[]usize,
    positions_len: *usize,
    value: usize,
) !void {
    // 共通バッファ管理ロジック
}
```

### 効果
- 約150行削減（regex.zig全体の約19%）

## 2. CharClass.matches() の O(1) 化

### 問題
現在は線形検索 O(n)

### 提案
256要素のルックアップテーブルを使用
```zig
pub const CharClassLUT = struct {
    table: [256]bool,
    negated: bool,

    pub fn matches(self: CharClassLUT, c: u8) bool {
        return if (self.negated) !self.table[c] else self.table[c];
    }
};
```

### 効果
- 複雑なパターン `[a-z0-9_-]` でも単一配列アクセス

## 影響範囲
- 正規表現エンジン全体に影響
- 広範なテストが必要
