# editor.zig リファクタリング提案

## 概要
editor.zig (4157行) の大規模リファクタリング提案

## 1. 確認ハンドラーの統合

### 問題
4つの確認ハンドラーが同じパターンを繰り返している:
- `handleKillBufferConfirmChar` (行 561-574)
- `handleQuitConfirmChar` (行 591-616)
- `handleExitConfirmChar` (行 619-626)
- `handleOverwriteConfirmChar` (行 629-677)

### 提案
```zig
const ConfirmMode = enum { kill_buffer, quit, exit, overwrite };

fn handleConfirmChar(self: *Editor, cp: u21, mode: ConfirmMode) !void {
    const c = unicode.toAsciiChar(cp);
    switch (mode) {
        .kill_buffer => { /* 処理 */ },
        .quit => { /* 処理 */ },
        // ...
    }
}
```

### 効果
- 約150行の重複コード削減
- 保守性向上

## 2. run() と runWithoutPoller() の統合

### 問題
行 1883-1995 の約110行が重複

### 提案
ポーリングの有無をnull許容で表現し、1つの関数に統合

### 効果
- 約40行削減

## 3. ミニバッファラッパーの簡素化

### 問題
行 825-888 で15個の1行パススルーラッパーが定義されている

### 提案
単純なパススルーは直接 `self.minibuffer.xxx()` を呼び出す

## 影響範囲
- 大規模な変更が必要
- 広範なテストが必要
