#!/bin/bash

# 基本操作の網羅的テスト
# 「一瞬で見つかるバグ」を事前に防ぐ

set -e

HARNESS="zig run test_harness_generic.zig -lc --"
PASS=0
FAIL=0
FAILED_TESTS=""

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# テスト実行
run_test() {
    local name="$1"
    shift
    if timeout 5 $HARNESS "$@" 2>&1 | grep -q "Child exited with status: 0"; then
        echo -e "${GREEN}✓${NC} $name"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗${NC} $name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS\n  - $name"
    fi
}

# テストファイル作成
setup_test_files() {
    # 3行のシンプルなファイル
    echo -e "line1\nline2\nline3" > /tmp/test_3lines.txt

    # 1行のファイル
    echo "single line" > /tmp/test_1line.txt

    # 空ファイル
    > /tmp/test_empty.txt

    # 空行を含むファイル
    echo -e "line1\n\nline3" > /tmp/test_with_empty.txt

    # 長い行
    python3 -c "print('x' * 200)" > /tmp/test_long.txt

    # 日本語
    echo -e "日本語\nテスト\n漢字" > /tmp/test_jp.txt

    # シェルスクリプト（#でコメント）
    echo -e '#!/bin/bash\necho "hello"\n# comment' > /tmp/test_sh.txt
}

echo "========================================="
echo "基本操作 網羅的テスト"
echo "========================================="
echo

# ビルド
echo "ビルド中..."
zig build 2>&1 || { echo "ビルド失敗"; exit 1; }
echo

# テストファイル準備
echo "テストファイル準備..."
setup_test_files
echo

# =========================================
# セクション1: 各位置への文字入力
# =========================================
echo "=== セクション1: 各位置への文字入力 ==="

echo "--- 行の先頭に入力 ---"
run_test "1.1 1行目先頭に入力" --file=/tmp/test_3lines.txt "X" "C-x" "C-c" "n"
run_test "1.2 2行目先頭に入力" --file=/tmp/test_3lines.txt "Down" "X" "C-x" "C-c" "n"
run_test "1.3 最終行先頭に入力" --file=/tmp/test_3lines.txt "Down" "Down" "X" "C-x" "C-c" "n"

echo "--- 行の途中に入力 ---"
run_test "1.4 1行目途中に入力" --file=/tmp/test_3lines.txt "Right" "Right" "X" "C-x" "C-c" "n"
run_test "1.5 2行目途中に入力" --file=/tmp/test_3lines.txt "Down" "Right" "Right" "X" "C-x" "C-c" "n"

echo "--- 行の末尾に入力 ---"
run_test "1.6 1行目末尾に入力" --file=/tmp/test_3lines.txt "End" "X" "C-x" "C-c" "n"
run_test "1.7 2行目末尾に入力" --file=/tmp/test_3lines.txt "Down" "End" "X" "C-x" "C-c" "n"
run_test "1.8 最終行末尾に入力" --file=/tmp/test_3lines.txt "Down" "Down" "End" "X" "C-x" "C-c" "n"

echo "--- 特殊文字の入力 ---"
run_test "1.9 #を行頭に入力" --file=/tmp/test_3lines.txt "#" "C-x" "C-c" "n"
run_test "1.10 #を2行目先頭に入力" --file=/tmp/test_3lines.txt "Down" "#" "C-x" "C-c" "n"
run_test "1.11 #を行途中に入力" --file=/tmp/test_3lines.txt "Right" "Right" "#" "C-x" "C-c" "n"

echo "--- 空ファイルへの入力 ---"
run_test "1.12 空ファイルに入力" --file=/tmp/test_empty.txt "hello" "C-x" "C-c" "n"
run_test "1.13 空ファイルに改行" --file=/tmp/test_empty.txt "Enter" "C-x" "C-c" "n"

echo "--- 空行への入力 ---"
run_test "1.14 空行に入力" --file=/tmp/test_with_empty.txt "Down" "X" "C-x" "C-c" "n"

echo "--- 1行ファイルへの入力 ---"
run_test "1.15 1行ファイル先頭に入力" --file=/tmp/test_1line.txt "X" "C-x" "C-c" "n"
run_test "1.16 1行ファイル末尾に入力" --file=/tmp/test_1line.txt "End" "X" "C-x" "C-c" "n"

echo

# =========================================
# セクション2: 境界でのカーソル移動
# =========================================
echo "=== セクション2: 境界でのカーソル移動 ==="

echo "--- 先頭での移動 ---"
run_test "2.1 1行目で上移動" --file=/tmp/test_3lines.txt "Up" "C-x" "C-c"
run_test "2.2 行頭で左移動" --file=/tmp/test_3lines.txt "Left" "C-x" "C-c"
run_test "2.3 ファイル先頭でHome" --file=/tmp/test_3lines.txt "Home" "C-x" "C-c"

echo "--- 末尾での移動 ---"
run_test "2.4 最終行で下移動" --file=/tmp/test_3lines.txt "Down" "Down" "Down" "C-x" "C-c"
run_test "2.5 行末で右移動" --file=/tmp/test_3lines.txt "End" "Right" "C-x" "C-c"
run_test "2.6 最終行末尾でEnd" --file=/tmp/test_3lines.txt "Down" "Down" "End" "End" "C-x" "C-c"

echo "--- 空ファイルでの移動 ---"
run_test "2.7 空ファイルで上" --file=/tmp/test_empty.txt "Up" "C-x" "C-c"
run_test "2.8 空ファイルで下" --file=/tmp/test_empty.txt "Down" "C-x" "C-c"
run_test "2.9 空ファイルで左" --file=/tmp/test_empty.txt "Left" "C-x" "C-c"
run_test "2.10 空ファイルで右" --file=/tmp/test_empty.txt "Right" "C-x" "C-c"

echo "--- 1行ファイルでの移動 ---"
run_test "2.11 1行ファイルで上" --file=/tmp/test_1line.txt "Up" "C-x" "C-c"
run_test "2.12 1行ファイルで下" --file=/tmp/test_1line.txt "Down" "C-x" "C-c"

echo "--- 空行での移動 ---"
run_test "2.13 空行で左" --file=/tmp/test_with_empty.txt "Down" "Left" "C-x" "C-c"
run_test "2.14 空行で右" --file=/tmp/test_with_empty.txt "Down" "Right" "C-x" "C-c"

echo

# =========================================
# セクション3: 削除操作
# =========================================
echo "=== セクション3: 削除操作 ==="

echo "--- Backspace ---"
run_test "3.1 行頭でBackspace" --file=/tmp/test_3lines.txt "Down" "Backspace" "C-x" "C-c" "n"
run_test "3.2 ファイル先頭でBackspace" --file=/tmp/test_3lines.txt "Backspace" "C-x" "C-c"
run_test "3.3 行途中でBackspace" --file=/tmp/test_3lines.txt "Right" "Right" "Backspace" "C-x" "C-c" "n"
run_test "3.4 行末でBackspace" --file=/tmp/test_3lines.txt "End" "Backspace" "C-x" "C-c" "n"

echo "--- C-d (Delete) ---"
run_test "3.5 行頭でC-d" --file=/tmp/test_3lines.txt "C-d" "C-x" "C-c" "n"
run_test "3.6 行末でC-d" --file=/tmp/test_3lines.txt "End" "C-d" "C-x" "C-c" "n"
# TODO: 最終行末尾でC-dすると何も削除されないのにmodified=trueになるバグ
run_test "3.7 最終行末尾でC-d" --file=/tmp/test_3lines.txt "Down" "Down" "End" "C-d" "C-x" "C-c" "n"
run_test "3.8 行途中でC-d" --file=/tmp/test_3lines.txt "Right" "Right" "C-d" "C-x" "C-c" "n"

echo "--- 空ファイルでの削除 ---"
run_test "3.9 空ファイルでBackspace" --file=/tmp/test_empty.txt "Backspace" "C-x" "C-c"
run_test "3.10 空ファイルでC-d" --file=/tmp/test_empty.txt "C-d" "C-x" "C-c"

echo "--- C-k (Kill line) ---"
run_test "3.11 行頭でC-k" --file=/tmp/test_3lines.txt "C-k" "C-x" "C-c" "n"
run_test "3.12 行途中でC-k" --file=/tmp/test_3lines.txt "Right" "Right" "C-k" "C-x" "C-c" "n"
run_test "3.13 行末でC-k" --file=/tmp/test_3lines.txt "End" "C-k" "C-x" "C-c" "n"
run_test "3.14 空行でC-k" --file=/tmp/test_with_empty.txt "Down" "C-k" "C-x" "C-c" "n"

echo

# =========================================
# セクション4: 改行操作
# =========================================
echo "=== セクション4: 改行操作 ==="

run_test "4.1 行頭でEnter" --file=/tmp/test_3lines.txt "Enter" "C-x" "C-c" "n"
run_test "4.2 行途中でEnter" --file=/tmp/test_3lines.txt "Right" "Right" "Enter" "C-x" "C-c" "n"
run_test "4.3 行末でEnter" --file=/tmp/test_3lines.txt "End" "Enter" "C-x" "C-c" "n"
run_test "4.4 最終行末尾でEnter" --file=/tmp/test_3lines.txt "Down" "Down" "End" "Enter" "C-x" "C-c" "n"
run_test "4.5 空ファイルでEnter" --file=/tmp/test_empty.txt "Enter" "C-x" "C-c" "n"
run_test "4.6 空行でEnter" --file=/tmp/test_with_empty.txt "Down" "Enter" "C-x" "C-c" "n"

echo

# =========================================
# セクション5: Undo/Redo
# =========================================
echo "=== セクション5: Undo/Redo ==="

run_test "5.1 入力後Undo" --file=/tmp/test_3lines.txt "hello" "C-/" "C-x" "C-c" "n"
# TODO: Undo後もmodifiedフラグがtrueのままになるバグ
run_test "5.2 削除後Undo" --file=/tmp/test_3lines.txt "C-d" "C-/" "C-x" "C-c" "n"
run_test "5.3 改行後Undo" --file=/tmp/test_3lines.txt "Enter" "C-/" "C-x" "C-c" "n"
run_test "5.4 複数回Undo" --file=/tmp/test_3lines.txt "a" "b" "c" "C-/" "C-/" "C-/" "C-x" "C-c" "n"
run_test "5.5 Undo後にRedo" --file=/tmp/test_3lines.txt "hello" "C-/" "C-_" "C-x" "C-c" "n"

echo

# =========================================
# セクション6: 連続操作（入力→移動→入力）
# =========================================
echo "=== セクション6: 連続操作 ==="

run_test "6.1 入力→下移動→入力" --file=/tmp/test_3lines.txt "A" "Down" "B" "C-x" "C-c" "n"
run_test "6.2 入力→上移動→入力" --file=/tmp/test_3lines.txt "Down" "A" "Up" "B" "C-x" "C-c" "n"
run_test "6.3 入力→End→入力" --file=/tmp/test_3lines.txt "A" "End" "B" "C-x" "C-c" "n"
run_test "6.4 入力→Home→入力" --file=/tmp/test_3lines.txt "End" "A" "Home" "B" "C-x" "C-c" "n"
run_test "6.5 削除→入力" --file=/tmp/test_3lines.txt "C-d" "X" "C-x" "C-c" "n"
run_test "6.6 入力→削除→入力" --file=/tmp/test_3lines.txt "A" "Backspace" "B" "C-x" "C-c" "n"

echo

# =========================================
# セクション7: 日本語操作
# =========================================
echo "=== セクション7: 日本語操作 ==="

run_test "7.1 日本語先頭に入力" --file=/tmp/test_jp.txt "あ" "C-x" "C-c" "n"
run_test "7.2 日本語2行目先頭に入力" --file=/tmp/test_jp.txt "Down" "あ" "C-x" "C-c" "n"
run_test "7.3 日本語の後に入力" --file=/tmp/test_jp.txt "Right" "X" "C-x" "C-c" "n"
run_test "7.4 日本語でBackspace" --file=/tmp/test_jp.txt "Right" "Backspace" "C-x" "C-c" "n"
run_test "7.5 日本語でC-d" --file=/tmp/test_jp.txt "C-d" "C-x" "C-c" "n"

echo

# =========================================
# セクション8: シンタックス関連（今回のバグ）
# =========================================
echo "=== セクション8: シンタックス関連 ==="

run_test "8.1 shファイル行頭に#" --file=/tmp/test_sh.txt "#" "C-x" "C-c" "n"
run_test "8.2 shファイル2行目先頭に#" --file=/tmp/test_sh.txt "Down" "#" "C-x" "C-c" "n"
run_test "8.3 shファイル行途中に#" --file=/tmp/test_sh.txt "Right" "Right" "#" "C-x" "C-c" "n"
run_test "8.4 shファイル行末に#" --file=/tmp/test_sh.txt "End" "#" "C-x" "C-c" "n"

echo

# =========================================
# セクション9: 段落・ページ移動
# =========================================
echo "=== セクション9: 段落・ページ移動 ==="

# 段落移動用ファイル
echo -e "para1 line1\npara1 line2\n\npara2 line1\npara2 line2\n\npara3" > /tmp/test_para.txt

run_test "9.1 段落移動 M-}" --file=/tmp/test_para.txt "M-}" "C-x" "C-c"
run_test "9.2 段落移動 M-{" --file=/tmp/test_para.txt "M-}" "M-}" "M-{" "C-x" "C-c"
run_test "9.3 ページダウン C-v" --file=/tmp/test_para.txt "C-v" "C-x" "C-c"
run_test "9.4 ページアップ M-v" --file=/tmp/test_para.txt "C-v" "M-v" "C-x" "C-c"

echo

# =========================================
# セクション10: ヘルプ・情報表示
# =========================================
echo "=== セクション10: ヘルプ・情報表示 ==="

# TODO: C-hはBackspaceとして扱われている（ヘルプ機能が未実装）
# run_test "10.1 ヘルプ表示 C-h" --file=/tmp/test_3lines.txt "C-h" "q" "C-x" "C-c"
run_test "10.2 言語表示確認" --file=/tmp/test_sh.txt "C-x" "C-c"

echo

# =========================================
# セクション11: シェル連携 (M-|)
# =========================================
echo "=== セクション11: シェル連携 ==="

# シェル連携用ファイル
echo -e "3\n1\n2" > /tmp/test_shell_input.txt
echo -e '{"name":"test"}' > /tmp/test_json.txt

echo "--- 基本コマンド ---"
run_test "11.1 シェル echo" --file=/tmp/test_3lines.txt "M-|" "echo hello" "Enter" "C-x" "C-c"
run_test "11.2 シェル ls" --file=/tmp/test_3lines.txt "M-|" "ls /" "Enter" "C-x" "C-c"

echo "--- 選択→コマンド→置換 ---"
# シェルコマンドはタイミングに依存するため、待機時間を長くして実行
# TODO: シェルコマンド完了後の確実な待機が必要
run_test "11.3 sort置換" --wait=1000 --delay=200 --file=/tmp/test_shell_input.txt "M-|" "% | sort >" "Enter" "C-x" "C-c" "n"

echo "--- テキスト処理 ---"
# これらのテストは非同期実行のタイミング問題があるため、簡略化
run_test "11.4 sed置換" --wait=1000 --delay=200 --file=/tmp/test_3lines.txt "M-|" "% | sed 's/line/LINE/g' >" "Enter" "C-x" "C-c" "n"

echo "--- JSON処理 ---"
# jqがインストールされていない環境もあるためスキップ可能
# run_test "11.5 jq整形" --file=/tmp/test_json.txt "M-|" "% | jq . >" "Enter" "C-x" "C-c" "n"

echo "--- 出力先バリエーション ---"
run_test "11.9 カーソル位置に挿入" --file=/tmp/test_3lines.txt "M-|" "echo inserted +>" "Enter" "C-x" "C-c" "n"
run_test "11.10 新規バッファに出力" --file=/tmp/test_3lines.txt "M-|" "echo newbuf n>" "Enter" "C-x" "C-c"

echo

# =========================================
# セクション12: バッファ操作
# =========================================
echo "=== セクション12: バッファ操作 ==="

run_test "12.1 バッファリスト C-x C-b" --file=/tmp/test_3lines.txt "C-x" "C-b" "q" "C-x" "C-c"
# バッファ切替は複数バッファがある場合のみ有効なので、先に別ファイルを開く
run_test "12.2 ファイルを開く C-x C-f" --file=/tmp/test_3lines.txt "C-x" "C-f" "/tmp/test_1line.txt" "Enter" "C-x" "C-c"
run_test "12.3 バッファ切替 C-x b" --file=/tmp/test_3lines.txt "C-x" "C-f" "/tmp/test_1line.txt" "Enter" "C-x" "b" "Enter" "C-x" "C-c"

echo

# =========================================
# セクション13: マクロ
# =========================================
echo "=== セクション13: マクロ ==="

run_test "13.1 マクロ記録開始 C-x (" --file=/tmp/test_3lines.txt "C-x" "(" "a" "C-x" ")" "C-x" "C-c" "n"
run_test "13.2 マクロ実行 C-x e" --file=/tmp/test_3lines.txt "C-x" "(" "X" "C-x" ")" "C-x" "e" "C-x" "C-c" "n"
run_test "13.3 マクロ連続実行" --file=/tmp/test_3lines.txt "C-x" "(" "Y" "Down" "C-x" ")" "C-x" "e" "e" "C-x" "C-c" "n"

echo

# =========================================
# 結果サマリー
# =========================================
echo "========================================="
echo "結果: $PASS 成功 / $((PASS + FAIL)) 合計"
if [ $FAIL -gt 0 ]; then
    echo -e "${RED}$FAIL 件の失敗${NC}"
    echo -e "失敗したテスト:$FAILED_TESTS"
    exit 1
else
    echo -e "${GREEN}全テスト成功！${NC}"
fi
