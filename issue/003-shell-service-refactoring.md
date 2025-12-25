# shell_service.zig リファクタリング提案

## 概要
ShellService (662行) の責務分離

## 1. 責務の分離

### 現状
1つのサービスが複数の責務を担当:
1. コマンド解析: `parseCommand()`, `isPositionInsideQuotes()`
2. シェル実行: `start()`, `poll()`, `cancel()`
3. bash環境検出: `findBashPath()`, `findShPath()`
4. 履歴管理: `addToHistory()`, `historyPrev()` など

### 提案
```
ShellParser    <- parseCommand, isPositionInsideQuotes
ShellExecutor  <- start, poll, cancel, cleanupState
ShellDetector  <- findBashPath, findShPath
ShellService   <- ShellExecutor, ShellParser, 履歴
```

## 2. findBashPath/findShPath のスタックバッファ使用

### 問題
PATH環境変数をループしながら複数回アロケーション/dealloc

### 提案
```zig
var path_buf: [256]u8 = undefined;
const path = try std.fmt.bufPrint(&path_buf, "{s}/bash", .{dir});
// 確認後、必要な場合のみアロケーション
```

## 3. 履歴サービスの共通化

### 問題
shell_service.zig と search_service.zig で同じ履歴管理パターン

### 提案
共通の HistoryService インターフェースを作成

## 影響範囲
- シェル統合機能全体
- 大規模なリファクタリング
