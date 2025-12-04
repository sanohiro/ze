# ze: A Minimal, Fast, Emacs-like Editor

**ze** — "Zig Editor" または "Zero-latency Editor"

> mgとUnix哲学にインスパイアされた、高速で最小限のテキストエディタ。
> Zigで実装。Emacsキーバインディング。シェル統合。

---

## Vision

**zeは「SSH先で即使える、設定不要のモダンなエディタ」を目指しています。**

### コンセプト
- **ゼロコンフィグ**: dotfileなし、インストール後即使用可能
- **シングルバイナリ**: 依存なし、5MB以下、どこでもコピーして動く
- **SSH先での編集**: vimほど複雑でなく、nanoより高機能で綺麗
- **Emacsライク**: Ctrl-n/p/f/b等のキーバインドでBash/Readline使いにも自然
- **モダンで綺麗**: 24bit色、UTF-8完全対応、見た目も快適

### ポジショニング

| エディタ | サイズ | 起動 | 学習コスト | 設定 | 見た目 |
|---------|-------|------|-----------|------|--------|
| vim | 3MB | 速い | 高い | 必要 | 古い |
| nano | 200KB | 速い | 低い | 不要 | 古い |
| micro | 8MB | 普通 | 低い | 任意 | 普通 |
| helix | 15MB | 遅い | 中 | 任意 | モダン |
| **ze** | **5MB** | **爆速** | **低い** | **不要** | **モダン** |

### 使用場面
- サーバーのログファイル編集
- 設定ファイルのクイック修正
- ちょっとしたスクリプト編集
- Git commit message編集
- SSH先での日常的な編集作業

**目指すのは「IDEではなく、日常使いのエディタ」**

---

## Philosophy

1. **Speed** — 8ms以下の入力レイテンシ。ゲームレベルの応答性。
2. **Minimal** — 一つのことを上手く行う。余分な機能なし。
3. **Unix** — テキストはストリーム。パイプはファーストクラス。
4. **Short** — コマンドは簡潔。`shell-command-on-region`のような冗長さはなし。

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    Input Thread                     │
│              (epoll/kqueue, lock-free)              │
└────────────────────────┬────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────┐
│                 Command Dispatch                    │
│              (comptime keymap table)                │
└────────────────────────┬────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────┐
│                      Buffer                         │
│        (Piece Table + B-tree line index)            │
│          mmap original, arena additions             │
└────────────────────────┬────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────┐
│                       View                          │
│     (double-buffer cells, diff-only rendering)      │
└────────────────────────┬────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────┐
│                     Terminal                        │
│              (batched write, 1 syscall)             │
└─────────────────────────────────────────────────────┘
```

---

## Performance Targets

| 指標 | 目標値 |
|--------|--------|
| 起動時間 | < 10ms |
| キー入力から画面更新 | < 8ms (125fps) |
| ファイルオープン (1GB) | < 100ms |
| 検索速度 (1GB) | > 2GB/s |
| メモリオーバーヘッド | ファイルサイズの約10% |

---

## Data Structures

### Buffer: Piece Table + B-tree

```
Original File (mmap, read-only):
┌─────────────────────────────────────────────────┐
│ The quick brown fox jumps over the lazy dog.   │
└─────────────────────────────────────────────────┘

Add Buffer (arena, append-only):
┌─────────────────┐
│ FAST            │
└─────────────────┘

Piece Table:
┌──────────────────────────────────────────────────┐
│ (orig, 0, 10) → (add, 0, 4) → (orig, 16, 28)    │
│ "The quick " + "FAST" + " fox jumps..."          │
└──────────────────────────────────────────────────┘

B-tree Index:
  - 行番号 → pieceオフセット (遅延、オンデマンド)
  - 影響範囲のみ再構築
```

### Memory Strategy

| コンポーネント | アロケータ |
|-----------|-----------|
| 元ファイル | mmap (ゼロコピー) |
| 追加バッファ | Arena (フラグメンテーションなし) |
| Undoスタック | Piece参照 (コピーなし) |
| レンダーバッファ | 固定バッファ |
| 検索結果 | 一時Arena (クエリごと) |

---

## Input System

### Goals

- 専用入力スレッド
- メインループでブロッキングなし
- メインスレッドへのロックフリーキュー
- 自前のキーリピート管理（OS経由なし）

### Implementation

```zig
const InputEvent = struct {
    key: Key,
    timestamp: i128,  // レイテンシ追跡用
};

// 入力スレッド
fn inputLoop(queue: *LockFreeQueue(InputEvent)) void {
    while (running) {
        if (poll(stdin, 1_ms)) |raw| {
            queue.push(.{
                .key = parseKey(raw),
                .timestamp = nanotime(),
            });
        }
    }
}

// メインループ: 固定タイムステップ
const FRAME_NS = 8_000_000;  // 8ms

fn mainLoop() void {
    while (running) {
        while (input_queue.pop()) |ev| processInput(ev);
        if (dirty) render();
        sleepUntilNextFrame();
    }
}
```

### Speculative Rendering

文字入力時の処理:
1. カーソル位置に文字を即座に描画（バッファ更新前）
2. ターミナルをフラッシュ
3. バッファ構造を更新
4. 次フレームで完全レンダリング（整合性確認）

---

## Rendering

### Double Buffer Cells

```zig
const Cell = struct {
    char: u21,
    fg: Color,
    bg: Color,
    attr: Attr,
};

const Screen = struct {
    front: []Cell,  // 現在表示中
    back: []Cell,   // 構築中

    fn flip(self: *@This()) void {
        // 差分を検出して変更されたセルのみ出力
        for (self.back, 0..) |cell, i| {
            if (cell != self.front[i]) {
                emitCell(i, cell);
            }
        }
        std.mem.swap([]Cell, &self.front, &self.back);
    }
};
```

### Output Batching

- すべてのエスケープシーケンスをバッファに蓄積
- フレームあたり1回の`write()`システムコール
- 相対カーソル移動を使用（バイト数最小化）

---

## Search Engine

### Literal Search: SIMD

```zig
fn simdSearch(haystack: []const u8, needle: u8) ?usize {
    const V = @Vector(32, u8);
    const target: V = @splat(needle);

    var i: usize = 0;
    while (i + 32 <= haystack.len) : (i += 32) {
        const chunk: V = haystack[i..][0..32].*;
        const mask = @as(u32, @bitCast(chunk == target));
        if (mask != 0) return i + @ctz(mask);
    }
    return null;
}
```

### Parallel Search

- バッファを1MBチャンクに分割
- スレッドプールに分配
- パターン長でチャンクをオーバーラップ（境界処理）
- 結果をマージ

### Incremental Search

- パターン拡張時に前回の結果をフィルタ
- 未検索領域を非同期で継続検索
- 表示を段階的に更新

---

## Command System

### Design Principles

- 短いコマンド（典型的に1-3文字）
- Unix風のパイプ
- バッファをストリームとして扱う
- 外部コマンドの積極的利用

### Grammar

```
command     := source? pipe* sink?
source      := '.' | '%' | ',' | ';' | range
pipe        := '|' cmd
sink        := '>' dest | '>>' dest
dest        := '.' | ',' | '+' | '_' | '@' reg | 'new' | 'vs' | 'sp'
range       := num ',' num
cmd         := builtin | external | alias

# 例
, | sort > .              # 選択範囲 → ソート → バッファ置換
; | sh > +                # 現在行 → シェル実行 → 下に挿入
. | grep TODO             # バッファ → grep → 新規バッファ
, | jq . > ,              # 選択範囲 → jq → 選択範囲置換
```

### Source Specifiers

| 記号 | 意味 |
|--------|---------|
| `.` | バッファ全体 |
| `%` | バッファ全体（エイリアス） |
| `,` | 選択範囲 |
| `;` | 現在行 |
| `n,m` | 行範囲 |
| `@x` | レジスタx |

### Sink Specifiers

| 記号 | 意味 |
|--------|---------|
| `.` | バッファを置換 |
| `,` | 選択範囲を置換 |
| `+` | カーソル位置に挿入 |
| `_` | 破棄 |
| `@x` | レジスタxに保存 |
| `new` | 新規バッファ |
| `vs` | 新規縦分割 |
| `sp` | 新規横分割 |

### Variable Expansion

| 変数 | 展開内容 |
|-----|------------|
| `{f}` | 現在のファイル名 |
| `{d}` | 現在のディレクトリ |
| `{w}` | カーソル下の単語 |
| `{l}` | 現在の行番号 |
| `{sel}` | 選択範囲のテキスト |
| `{@x}` | レジスタxの内容 |

---

## Built-in Commands (Fast Path)

プロセス生成を回避する組み込みコマンド:

| コマンド | 説明 |
|---------|-------------|
| `sort` | 行をソート |
| `uniq` | 重複を削除 |
| `grep` | 行をフィルタ (SIMD) |
| `head` | 最初のn行 |
| `tail` | 最後のn行 |
| `wc` | 行/単語/文字をカウント |
| `tr` | 文字を変換 |
| `cut` | フィールドを抽出 |
| `rev` | 行を反転 |
| `tac` | 行順序を反転 |

解決順序:
1. 組み込み（最速）
2. エイリアス
3. エディタコマンド
4. 外部コマンド（$PATH）

---

## Editor Commands

### File Operations

| コマンド | 説明 |
|-----|-------------|
| `w` | 保存 |
| `w <name>` | 名前を付けて保存 |
| `e <name>` | ファイルを開く |
| `e!` | 元に戻す |
| `q` | 終了 |
| `q!` | 強制終了 |
| `wq` | 保存して終了 |

### Buffer Operations

| コマンド | 説明 |
|-----|-------------|
| `b` | バッファ一覧 |
| `b<n>` | バッファnに切り替え |
| `bn` | 次のバッファ |
| `bp` | 前のバッファ |
| `bd` | バッファを削除 |

### Window Operations

| コマンド | 説明 |
|-----|-------------|
| `sp` | 横分割 |
| `vs` | 縦分割 |
| `c` | ウィンドウを閉じる |
| `o` | 他のウィンドウを閉じる |

### Navigation

| コマンド | 説明 |
|-----|-------------|
| `g <n>` | n行目へ移動 |
| `g <mark>` | マークへ移動 |
| `m <name>` | マークを設定 |

### Search & Replace

| コマンド | 説明 |
|-----|-------------|
| `/ <pat>` | 前方検索 |
| `? <pat>` | 後方検索 |
| `s/a/b/` | 最初を置換 |
| `s/a/b/g` | すべて置換 |
| `, s/a/b/g` | 選択範囲内で置換 |

### Undo/Redo

| コマンド | 説明 |
|-----|-------------|
| `u` | 元に戻す |
| `r` | やり直す |

---

## Keybindings (Emacs-like)

### Movement

| キー | 動作 |
|-----|--------|
| `C-f` | 前進（文字） |
| `C-b` | 後退（文字） |
| `C-n` | 次の行 |
| `C-p` | 前の行 |
| `C-a` | 行頭へ |
| `C-e` | 行末へ |
| `M-f` | 前進（単語） |
| `M-b` | 後退（単語） |
| `C-v` | ページダウン |
| `M-v` | ページアップ |
| `M-<` | バッファの先頭へ |
| `M->` | バッファの末尾へ |
| `C-l` | カーソルを中央に |

### Editing

| キー | 動作 |
|-----|--------|
| `C-d` | 文字削除 |
| `M-d` | 単語削除 |
| `C-k` | 行末まで削除 |
| `C-w` | 領域を削除 |
| `M-w` | 領域をコピー |
| `C-y` | 貼り付け |
| `C-/` | 元に戻す |
| `C-g` | キャンセル |
| `C-@` | マーク設定 |
| `C-x C-x` | ポイントとマークを交換 |

### File

| キー | 動作 |
|-----|--------|
| `C-x C-f` | ファイルを開く |
| `C-x C-s` | 保存 |
| `C-x C-w` | 名前を付けて保存 |
| `C-x C-c` | 終了 |

### Buffer/Window

| キー | 動作 |
|-----|--------|
| `C-x b` | バッファ切り替え |
| `C-x k` | バッファを閉じる |
| `C-x 2` | 横分割 |
| `C-x 3` | 縦分割 |
| `C-x 0` | ウィンドウを閉じる |
| `C-x 1` | 他のウィンドウを閉じる |
| `C-x o` | 他のウィンドウへ |

### Search

| キー | 動作 |
|-----|--------|
| `C-s` | インクリメンタル前方検索 |
| `C-r` | インクリメンタル後方検索 |
| `M-%` | 置換問い合わせ |

### Command Line

| キー | 動作 |
|-----|--------|
| `M-x` | コマンドプロンプト |
| `M-!` | シェルコマンド |
| `M-|` | 領域をパイプ |

---

## Alias System

```zig
const aliases = .{
    // フォーマット
    .{ "jq",   ", | jq . > ," },
    .{ "fmt",  ". | zig fmt - > ." },
    .{ "py",   ", | python > +" },
    .{ "sh",   "; | sh > +" },
    .{ "bc",   "; | bc > +" },

    // ソート
    .{ "su",   ", | sort | uniq > ," },
    .{ "sr",   ", | sort -r > ," },
    .{ "sn",   ", | sort -n > ," },

    // Git
    .{ "ga",   "!git add {f}" },
    .{ "gc",   "!git commit" },
    .{ "gd",   "!git diff {f} | vs" },
    .{ "gb",   "!git blame {f} | vs" },
    .{ "gl",   "!git log --oneline | head -20" },

    // その他
    .{ "wc",   ". | wc" },
    .{ "rev",  ". | tac > ." },
    .{ "x",    "wq" },
};
```

---

## File Structure

```
ze/
├── src/
│   ├── main.zig           # エントリポイント
│   ├── editor.zig         # エディタコア状態
│   ├── buffer.zig         # Piece table実装
│   ├── view.zig           # レンダリング、画面管理
│   ├── input.zig          # 入力処理、キーパース
│   ├── command.zig        # コマンドパーサー、実行器
│   ├── search.zig         # 検索エンジン (SIMD)
│   ├── terminal.zig       # 端末制御
│   ├── window.zig         # ウィンドウ/分割管理
│   ├── keymap.zig         # キーバインディング定義
│   ├── builtin.zig        # 組み込みコマンド
│   ├── pipe.zig           # パイプライン実行
│   └── util/
│       ├── arena.zig      # Arenaアロケータ
│       ├── btree.zig      # 索引用B-tree
│       ├── queue.zig      # ロックフリーキュー
│       └── simd.zig       # SIMDユーティリティ
├── build.zig
├── README.md
└── config/
    └── default.zig        # デフォルト設定、エイリアス
```

---

## Configuration

Zigによるコンパイル時設定:

```zig
// config.zig
pub const config = .{
    .tab_width = 4,
    .scroll_margin = 5,
    .frame_rate = 120,

    .colors = .{
        .fg = 0xFFFFFF,
        .bg = 0x1E1E1E,
        .cursor = 0x00FF00,
        .selection = 0x264F78,
    },

    .aliases = .{
        .{ "fmt", ". | zig fmt - > ." },
        // ...
    },

    .keymap_overrides = .{
        .{ "C-t", "transpose-chars" },
        // ...
    },
};
```

---

## Non-Goals

- シンタックスハイライト（v2で検討）
- LSP統合（v2で検討）
- プラグインシステム
- マウスサポート
- GUI
- Emacs Lisp互換性
- Org-mode
- Email、IRC、テトリス

---

## Inspirations

- **mg** — ミニマルなEmacs、クリーンなコードベース
- **kilo** — 1000行のエディタ、教育的
- **vis** — 構造的正規表現、sam/acmeのアイデア
- **kakoune** — 選択ファーストの編集
- **ripgrep** — 高速検索実装
- **Alacritty** — GPUアクセラレーテッド端末

---

## Implementation Roadmap

### 現在の状態 (v0.1-alpha) - 2024-12-04

#### 実装完了機能
- [x] **Piece tableバッファ実装**
  - [x] 効率的な挿入/削除（O(1)）
  - [x] Undo/Redo対応（C-u/C-r）
  - [x] ファイルI/O（保存: C-s）
  - [x] Pieceマージ（隣接する同一ソースのPieceを自動結合）

- [x] **完全なUnicode/UTF-8対応** ✨
  - [x] Grapheme cluster境界認識（Unicode 15.0準拠）
  - [x] 絵文字完全サポート（ZWJ sequences、肌色修飾子、国旗）
  - [x] CJK文字対応（日中韓の全文字、幅2）
  - [x] 結合文字対応（Variation Selectors等）
  - [x] 10言語以上のスクリプト対応
  - [x] 62個の包括的テストで検証済み
  - [x] **差分描画時のUTF-8境界チェック**（文字化け防止）

- [x] **Emacsライクなキーバインド**
  - [x] 移動: C-n/p/f/b/a/e, M-f/b, 矢印キー
  - [x] 編集: C-d（文字削除）、M-d（単語削除）、C-k（行末まで削除）
  - [x] 特殊: Enter（改行挿入）、C-h/Backspace（削除）、Tab
  - [x] Undo/Redo: C-u/C-r
  - [x] **終了: C-q（未保存変更の警告付き）**
  - [x] Alt+大文字/数字/記号のサポート

- [x] **パフォーマンス最適化**
  - [x] O(1) バッファ長取得（total_len cache）
  - [x] **PieceIterator.seek()（O(pieces)直接ジャンプ）**
  - [x] LineIndex（O(log N)行アクセス）
  - [x] **deleteChar/backspace/backwardWordのO(n)問題修正**
  - [x] 差分描画（セルレベル、行ごと独立バッファ）
  - [x] 巨大行の最適化（画面幅で読み取り停止）
  - [x] インライン関数とコンパイル時最適化

- [x] **表示機能**
  - [x] **Tab文字の適切な処理**（タブ幅4で空白展開）
  - [x] **水平スクロール**（長い行の自動スクロール）
  - [x] ステータスバー（ファイル名、行番号、カラム、モード表示）

- [x] **入力処理**
  - [x] ESCシーケンス処理（100msタイムアウト）
  - [x] バイト分割到着対応

- [x] **テスト体制**
  - [x] 62個の包括的テスト（Unicode、カーソル移動、編集操作）
  - [x] すべてのテストが通過
  - [x] CI/CDレディ

### Phase 1: 実用最小限 (v0.2 - 優先度: 最高)
**目標: 実際にSSH先で使い始められるレベル**

- [x] **UTF-8完全対応** ✅ **完了**
  - [x] マルチバイト文字の正しい表示
  - [x] カーソル移動の文字境界認識
  - [x] 日本語・絵文字の編集
  - [x] 差分描画時の境界チェック
- [x] **Tab文字の適切な処理** ✅ **完了**
  - [x] タブ幅4で空白展開
  - [x] タブストップ位置の正確な計算
- [x] **水平スクロール** ✅ **完了**
  - [x] 長い行の自動スクロール
  - [x] カーソル移動時の自動調整
- [x] **保存確認機能** ✅ **完了**
  - [x] 未保存変更時のC-q警告
- [ ] **インクリメンタル検索** (C-s)
  - [ ] 前方検索、後方検索 (C-r)
  - [ ] マッチのハイライト表示
- [ ] **コピー/ペースト + killring**
  - [x] C-k (kill-line) - 実装済み
  - [ ] C-w (kill-region)
  - [ ] M-w (copy-region)
  - [ ] C-y (yank)
  - [ ] M-y (yank-pop)
- [ ] **行番号表示**
- [x] **主要なバグ修正** ✅ **完了**
  - [x] O(n)パフォーマンス問題の修正
  - [x] Buffer境界チェック
  - [x] UTF-8境界チェック

### Phase 2: 快適な編集 (v0.3)
**目標: 日常的に使えるレベル**

- [ ] **シンタックスハイライト** (シンプルな正規表現ベース)
  - [ ] 主要言語5-10個 (Zig, C, Go, Python, JS, Rust等)
  - [ ] ファイル拡張子による自動認識
- [ ] **置換機能** (M-%)
  - [ ] 検索・置換の問い合わせ
  - [ ] 一括置換
- [ ] **複数バッファ**
  - [ ] C-x C-f (find-file)
  - [ ] C-x b (switch-buffer)
  - [ ] C-x k (kill-buffer)
  - [ ] バッファリスト表示
- [ ] **自動インデント**
  - [ ] 基本的なインデント継承
  - [ ] Tab/Spaceの自動判定
- [ ] **.editorconfig対応**

### Phase 3: モダンな見た目 (v0.4)
**目標: 綺麗で快適なUI**

- [ ] **24bit色対応**
  - [ ] シンタックスハイライトでの利用
  - [ ] デフォルトテーマ (Dracula風、Nord風等)
- [ ] **改善されたステータスライン**
  - [ ] ファイル名、モード表示
  - [ ] エンコーディング、改行コード表示
  - [ ] Git branch表示 (オプション)
- [ ] **大きなファイルの最適化**
  - [ ] 遅延ロード
  - [ ] 1GB以上のファイル対応
- [ ] **マウスサポート (オプション)**
  - [ ] クリックでカーソル移動
  - [ ] ドラッグで選択

### Phase 4: Unix統合 (v0.5)
**目標: Unixツールとの連携**

- [ ] **コマンドライン (ミニバッファ)**
  - [ ] M-x コマンド入力
  - [ ] M-! シェルコマンド実行
  - [ ] M-| リージョンをパイプ
- [ ] **基本エディタコマンド**
  - [ ] :w, :q, :wq (vi風も受け入れる)
  - [ ] :e <file>, :b <buffer>
- [ ] **外部コマンド実行**
  - [ ] 選択範囲を外部コマンドに渡す
  - [ ] 結果をバッファに挿入

### Phase 5: 高度な機能 (v1.0)
**目標: パワーユーザー向け**

- [ ] **ウィンドウ分割**
  - [ ] C-x 2 (横分割)
  - [ ] C-x 3 (縦分割)
  - [ ] C-x o (ウィンドウ切り替え)
- [ ] **マーク・リージョン**
  - [ ] C-@ (set-mark)
  - [ ] C-x C-x (exchange-point-and-mark)
- [ ] **レジスタ**
  - [ ] テキストの保存・呼び出し
- [ ] **差分ログベースのUndo/Redo**
  - [ ] メモリ効率の改善
- [ ] **mmap ファイルロード**

### 長期目標 (v2.0+)
- [ ] LSP対応 (オプション、軽量に)
- [ ] 設定ファイルサポート (Zig製でコンパイル時評価)
- [ ] プラグインシステム (シンプルなもの)
- [ ] パイプ構文 (Unix統合の拡張)

---

## 現在の技術的負債

### 最優先で対処が必要
1. ~~**UTF-8非対応**~~ ✅ **完了**: Grapheme cluster境界認識、絵文字・CJK完全対応
2. ~~**カーソル位置の不正確さ**~~ ✅ **完了**: grapheme cluster単位の正確なカーソル移動実装
3. **エラーハンドリング**: `try`で即終了、ユーザーにメッセージなし（未対応）

### Phase 2で対処
4. ~~**Undo/Redoのメモリ効率**~~ ✅ **完了**: 連続insert結合 + 1000エントリ上限実装
5. **ファイルロード**: readToEndAllocではなくmmap（未対応）
6. ~~**完全な差分描画**~~ ✅ **完了**: LineIndex + dirty範囲トラッキング実装

### v0.1で完了した最適化 (2024-12-04)
- ✅ **LineIndex導入**: O(1)行アクセス（O(file_size)描画を解決）
- ✅ **PieceIterator.seek()**: O(pieces)直接ジャンプ
- ✅ **errdefer rollback**: 編集操作の原子性保証
- ✅ **メモリ最適化**: 再利用バッファで描画時のヒープ確保削減
- ✅ **dirty範囲の正確な管理**: ?usizeでEOF表現、maxInt wrap回避

---

## License

MIT または BSD-2-Clause（未定）

---

*"一つのことを上手く行う。高速に。"*
