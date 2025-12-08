# ze

**Zero-latency Editor**

[English](README.md)

SSH先でサクッと使える、設定不要の軽量で高速なモダンエディタ。

## Why ze?

- **軽量** — 300KB以下、依存なし
- **ゼロコンフィグ** — dotfileなし、コピーして即使用
- **Emacsスタイル編集** — キーバインドだけでなく、マルチバッファ・ウィンドウ分割など編集モデル全体
- **シェル統合** — sort, jq, awkに直接パイプ
- **UTF-8完全対応** — 日本語、絵文字、grapheme cluster

## 動作環境

- Linux (x86_64, aarch64)
- macOS (Intel, Apple Silicon)
- WSL2

## Install

[Releases](https://github.com/sanohiro/ze/releases) からビルド済みバイナリをダウンロード、またはソースからビルド：

```bash
# ビルド (Zig 0.15以上が必要)
zig build -Doptimize=ReleaseFast

# パスを通す（任意）
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
| `>` | 入力元を置換 |
| `+>` | カーソル位置に挿入 |
| `n>` | 新規バッファ |

### 例

```bash
| date +>              # 日付をカーソル位置に挿入
| sort >               # 選択範囲をソートして置換
% | jq . >             # JSON全体を整形
. | sh >               # 現在行をシェル実行
% | grep TODO n>       # TODO行を新規バッファに抽出
```

**C-g** でいつでもキャンセル可能。LLM呼び出しなど長時間処理もOK。

---

## Keybindings

zeはEmacsスタイルのキーバインドを採用しています。`C-` は Ctrl、`M-` は Alt/Option。

| キー | 動作 |
|------|------|
| `C-f` / `C-b` / `C-n` / `C-p` | カーソル移動 |
| `C-s` / `C-r` | 前方/後方検索 |
| `M-%` | 対話的置換 |
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
| `revert` | ファイル再読み込み |
| `ro` | 読み取り専用切り替え |
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

### 予定

- [ ] アプリ内ヘルプ (`C-h ?`)
- [ ] キーボードマクロ (`C-x (` / `)` / `e`)

---

## Philosophy

1. **Speed** — 8ms以下の応答性。ゲームレベル。
2. **Minimal** — 一つのことを上手く行う。
3. **Unix** — テキストはストリーム。パイプはファーストクラス。
4. **Zero-config** — コピーして即使える。

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
