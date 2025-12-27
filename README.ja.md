# ze — Zero-latency Editor

SSH先で一瞬で起動。設定ファイルなし。すぐ使える。

[English](README.md)

![ze demo](demo/ze_demo.gif)

Emacsのキーバインドで、mgのように軽く動く。
vimを覚える気はないが、nanoでは物足りない人のために。

---

## zeが向いている人

- SSH先で設定なしに快適に編集したい
- Emacsキーバインドが指に馴染んでいる
- 編集はUnixツール（sort, jq, sed）と組み合わせたい
- dotfiles管理に疲れた

## zeが向いていない人

- IDEのような補完やLSPが欲しい
- すべてをカスタマイズしたい
- vimのモーダル編集が好き

---

## 特徴

- **500KB以下** — 依存なし、シングルバイナリ
- **ゼロコンフィグ** — dotfileなし、コピーして即使用
- **Emacsスタイル編集** — マルチバッファ、ウィンドウ分割、キルリング
- **シェル統合** — sort, jq, awkに直接パイプ
- **UTF-8完全対応** — 日本語、絵文字、grapheme cluster

## 動作環境

- Linux (x86_64, aarch64)
- macOS (Intel, Apple Silicon)
- WSL2

## Install

### Homebrew (macOS/Linux)

```bash
brew tap sanohiro/ze
brew install ze
```

### ビルド済みバイナリ

[Releases](https://github.com/sanohiro/ze/releases) からダウンロードしてパスを通す。

### ソースからビルド

```bash
# Zig 0.15以上が必要
zig build -Doptimize=ReleaseFast
cp ./zig-out/bin/ze ~/.local/bin/
```

## Quick Start

```bash
ze file.txt          # ファイルを開く
ze                    # 新規バッファで起動
```

保存して終了: `C-x C-s` → `C-x C-c`

---

## Shell Integration

zeは「テキストはストリーム」というUnix哲学に基づいています。

高度なテキスト処理は `sort`、`jq`、`awk`、`sed` など既に存在する優れたツールに任せ、zeはそれらとバッファを繋ぐパイプラインの役割に徹します。車輪の再発明はしません。

`M-|` でシェルコマンドを実行し、選択範囲やバッファ全体をパイプで渡せます。

### 構文

```
[入力元] | コマンド [出力先]
```

| 入力元 | 内容 |
|--------|------|
| (なし) | 選択範囲 |
| `%` | バッファ全体 |
| `.` | 現在行 |

| 出力先 | 内容 |
|--------|------|
| (なし) | コマンドバッファに表示 |
| `>` | 入力元を置換（選択なしならカーソル位置に挿入） |
| `+>` | カーソル位置に挿入 |
| `n>` | 新規バッファ |

### 例

```bash
| date +>              # 日付をカーソル位置に挿入
| sort >               # 選択範囲をソートして置換
% | jq . >             # JSON全体を整形
. | sh >               # 現在行をシェル実行
% | grep TODO n>       # TODO行を新規バッファに抽出
| upper >              # 選択範囲を大文字に変換（alias使用）
| lower >              # 選択範囲を小文字に変換（alias使用）
```

**C-g** でいつでもキャンセル可能。LLM呼び出しなど長時間処理もOK。

### 履歴と補完

**プレフィックス履歴マッチング**: 入力中に `↑`/`↓` を押すと、入力文字列で始まる履歴のみ表示されます。

```
| git       # ↑を押す
| git push origin main   # "git"で始まる履歴のみ表示
| git commit -m "fix"    # さらに↑
```

**Tab補完**: `Tab` でコマンドやファイルパスを補完します（bashの `compgen` を使用）。

```
| gi<Tab>        → git
| cat /tmp/<Tab> → /tmp/内のファイル一覧を表示
```

### Alias

`~/.ze/aliases` を作成すると、よく使う操作のショートカットを定義できます：

```bash
alias upper='tr a-z A-Z'
alias lower='tr A-Z a-z'
alias trim='sed "s/^[[:space:]]*//;s/[[:space:]]*$//"'
alias uniq='sort | uniq'
```

このファイルが存在し、bashが利用可能な場合、zeが自動的に読み込みます。

**Unixのテキスト処理ツールに詳しくない方へ:**
- [awesome-text-tools](https://github.com/sanohiro/awesome-text-tools) — テキスト処理ツールのキュレーションリスト
- [txtk](https://github.com/sanohiro/txtk) — 日本語処理も含む、便利なテキストツールキット

---

## Keybindings

zeはEmacsスタイルのキーバインドを採用しています。`C-` は Ctrl、`M-` は Alt/Option。

| キー | 動作 |
|------|------|
| `C-f` / `C-b` / `C-n` / `C-p` | カーソル移動 |
| `C-s` / `C-r` | 前方/後方検索 |
| `M-%` | 対話的置換 |
| `M-\|` | シェルコマンド |
| `C-Space` | 範囲選択開始 |
| `C-w` / `M-w` / `C-y` | カット/コピー/ペースト |
| `C-x 2` / `C-x 3` | ウィンドウ分割（横/縦） |
| `C-x b` | バッファ切り替え |
| `C-x C-s` | 保存 |
| `C-x C-c` | 終了 |

**全キーバインド:** [KEYBINDINGS.ja.md](KEYBINDINGS.ja.md)

---

## Design Choices

### コメントのみ着色

zeはコメントのみをハイライトします。これは意図的な設計です：

- **可読性** — 設定ファイルでコメントが目立つ
- **IDEではない** — フルハイライトはzeのユースケースには不要な複雑さ
- **速度** — パース処理を最小限に

### zeがやらないこと

- **シンタックスハイライト** — zeは設定ファイルエディタ、コーディング用ではない
- **LSP** — 本格的な開発はVSCodeで
- **プラグイン** — 拡張性よりシンプルさ
- **マウス / GUI** — キーボードとターミナルのみ

### ターミナルでの使い方

- **テキスト選択**: `Option`キー（Mac）または`Alt`キー（Linux）を押しながらドラッグすると、ターミナル本来のテキスト選択が使えます。システムクリップボードにコピーされます。
- **スクロール**: `C-v` / `M-v` または `PageDown` / `PageUp` でスクロールします。

---

## Features

### エンコーディング

- **UTF-8 + LF** に最適化。UTF-8+LFファイルはゼロコピーmmap
- UTF-8 (BOM有無)、UTF-16 (BOM付き)、Shift_JIS、EUC-JPを自動検出・変換
- 改行コード (LF, CRLF, CR) を自動検出
- **元のエンコーディングで保存**（エンコーディング、BOM、改行コードを保持）

### M-x コマンド

| コマンド | 動作 |
|----------|------|
| `line N` | N行目へジャンプ |
| `tab` / `tab N` | タブ幅表示/設定 |
| `indent` | インデントスタイル表示/設定 |
| `mode` / `mode X` | 言語モード表示/設定 |
| `key` | キーバインド説明 |
| `revert` | ファイル再読み込み |
| `ro` | 読み取り専用切り替え |
| `exit` / `quit` | 確認付きで終了 |
| `?` | コマンド一覧 |

---

## Roadmap

### 実装済み

- Piece Tableバッファ、Undo/Redo
- Grapheme cluster対応（絵文字、CJK完全サポート）
- インクリメンタル検索、正規表現、Query Replace
- マルチバッファ、ウィンドウ分割
- シェル統合 (M-|)
- 48言語のコメント・インデント設定
- キーボードマクロ (`C-x (` / `)` / `e`)
- アプリ内ヘルプ (`M-?`)

---

## Philosophy

1. **Speed** — 応答性を最優先に。
2. **Minimal** — 一つのことを上手く行う。
3. **Unix** — テキストはストリーム。パイプはファーストクラス。
4. **Zero-config** — コピーして即使える。（履歴は `~/.ze/` に保存）

---

## Inspiration

- [mg](https://github.com/hboetes/mg) — ミニマルなEmacs
- [kilo](https://github.com/antirez/kilo) — 1000行エディタ
- [vis](https://github.com/martanne/vis) — 構造的正規表現

---

## License

MIT

---

*"一つのことを上手く行う。高速に。"*
