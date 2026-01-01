# ze — Zero-latency Editor

小さくて、設定不要で、Emacsライクなターミナルエディタ。特にSSH越しの高速編集に。

> Vimは重く感じる、でもnanoでは物足りない。
> zeはその中間。

[English](README.md)

![ze demo](demo/ze_demo.gif)

---

## なぜ ze？

**ze** は「今すぐテキストを編集したい」状況のために作られました。

- SSH先のリモートサーバー
- dotfilesのないミニマル環境
- 起動時間が重要なちょっとした編集
- Emacsスタイルが好きだが、Emacs自体は使いたくない人

セットアップなし。プラグインなし。バックグラウンドジョブなし。
すぐに入力を始められます。

---

## 主な特徴

- **ゼロコンフィグ**
  設定ファイル不要。箱から出してすぐ動く。

- **瞬時の起動とレスポンシブな入力**
  入力中に待たされることがないよう設計。

- **Emacsライクなキーバインド**
  馴染みのあるカーソル移動と編集コマンド。

- **Unixフレンドリー**
  バッファや選択範囲を外部コマンドにパイプで渡して戻せる。

- **小さなシングルバイナリ**
  500KB以下、依存なし。どこにでも簡単にデプロイ。

---

## 非目標

zeは意図的に以下を**目指しません**：

- IDE
- Vimの代替
- 高度にカスタマイズ可能なエディタ
- プラグインやLSP駆動

それらが必要なら、すでに優れたツールがあります。
zeは一つのことに集中します：**ターミナルでの高速で信頼性の高いテキスト編集**。

---

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

### Debian/Ubuntu

#### Option 1: .deb直接インストール（推奨）

リポジトリ追加なし、自動更新なし。必要な時に手動で更新。

```bash
# x86_64の場合
wget https://github.com/sanohiro/ze/releases/latest/download/ze_amd64.deb
sudo apt install ./ze_amd64.deb

# ARM64の場合
wget https://github.com/sanohiro/ze/releases/latest/download/ze_arm64.deb
sudo apt install ./ze_arm64.deb
```

#### Option 2: aptリポジトリ

aptで更新管理したい場合。

```bash
curl -fsSL https://sanohiro.github.io/ze/install.sh | sudo sh
sudo apt install ze
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
ze -R file.txt       # ファイルを閲覧（読み取り専用）
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
| `ln` | 行番号表示切り替え |
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
