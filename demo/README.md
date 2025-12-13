# Demo GIFs

vhsを使ってデモGIFを生成するためのスクリプト。

## 必要なもの

```bash
brew install vhs figlet jq gifsicle
```

## 生成方法

```bash
# 全部生成
for f in demo/*.tape; do vhs "$f"; done

# 個別に生成
vhs demo/01_basic_editing.tape
```

## デモ一覧

| ファイル | 内容 |
|----------|------|
| 01_basic_editing | 基本編集、日本語、絵文字 |
| 02_multi_window | ウィンドウ分割、バッファ切り替え |
| 03_shell_jq | シェル統合: jqでJSON整形 |
| 04_shell_figlet | シェル統合: figletでASCIIアート |
| 05_shell_pipeline | シェル統合: grep + パイプライン |

## GIF結合

```bash
# 全デモを1つのGIFに結合（最適化あり）
gifsicle -O3 --colors 256 demo/01_basic_editing.gif demo/02_multi_window.gif demo/03_shell_jq.gif demo/04_shell_figlet.gif demo/05_shell_pipeline.gif -o demo/ze_demo.gif
```

## カスタマイズ

各.tapeファイルの先頭で設定を変更できる:

```tape
Set FontSize 18          # フォントサイズ
Set Width 900            # 幅
Set Height 500           # 高さ
Set Theme "Catppuccin Mocha"  # テーマ
Set TypingSpeed 50ms     # タイピング速度
```
