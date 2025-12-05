#!/bin/bash

# 包括的テストスイート for ze エディタ
# 全ての基本機能を徹底的にテスト

set -e

HARNESS="zig run test_harness_generic.zig -lc --"
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

# テスト結果を記録
test_result() {
    local test_name="$1"
    local result="$2"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [ "$result" = "PASS" ]; then
        echo "✓ $test_name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "✗ $test_name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# テスト実行ヘルパー
run_test() {
    local test_name="$1"
    shift
    if $HARNESS "$@" 2>&1 | grep -q "Child exited with status: 0"; then
        test_result "$test_name" "PASS"
    else
        test_result "$test_name" "FAIL"
    fi
}

echo "========================================="
echo "ze エディタ 包括的テストスイート"
echo "========================================="
echo

zig build

echo "=== カテゴリ 1: 基本的な編集操作 ==="
run_test "1.1 シンプルな文字入力" --file=/tmp/test_nums.txt "hello" "C-x" "C-c" "n"
run_test "1.2 複数行の入力" --file=/tmp/test_nums.txt "line1" "Enter" "line2" "C-x" "C-c" "n"
run_test "1.3 Backspaceで削除" --file=/tmp/test_nums.txt "hello" "Backspace" "Backspace" "C-x" "C-c" "n"
run_test "1.4 Enterで改行" --file=/tmp/test_nums.txt "test" "Enter" "Enter" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 2: カーソル移動 ==="
run_test "2.1 右移動" --file=/tmp/test_cursor_input.txt "Right" "Right" "X" "C-x" "C-c" "n"
run_test "2.2 左移動" --file=/tmp/test_cursor_input.txt "End" "Left" "Left" "X" "C-x" "C-c" "n"
run_test "2.3 上移動" --file=/tmp/test_cursor_input.txt "Down" "Down" "Up" "X" "C-x" "C-c" "n"
run_test "2.4 下移動" --file=/tmp/test_cursor_input.txt "Down" "X" "C-x" "C-c" "n"
run_test "2.5 Home移動" --file=/tmp/test_cursor_input.txt "End" "Home" "X" "C-x" "C-c" "n"
run_test "2.6 End移動" --file=/tmp/test_cursor_input.txt "End" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 3: ファイル操作 ==="
run_test "3.1 保存 (C-x C-s)" --file=/tmp/test_nums.txt "test" "C-x" "C-s" "C-x" "C-c"
run_test "3.2 保存せず終了 (n)" --file=/tmp/test_nums.txt "test" "C-x" "C-c" "n"
run_test "3.3 保存して終了 (y)" --file=/tmp/test_nums.txt "test" "C-x" "C-c" "y"

echo
echo "=== カテゴリ 4: 検索機能 ==="
run_test "4.1 英語で検索" --file=/tmp/test_search_pages.txt "C-s" "T" "a" "r" "g" "e" "t" "Enter" "C-x" "C-c"
run_test "4.2 次を検索 (C-s C-s)" --file=/tmp/test_search_pages.txt "C-s" "T" "a" "r" "Enter" "C-s" "C-x" "C-c"
run_test "4.3 検索キャンセル (C-g)" --file=/tmp/test_search_pages.txt "C-s" "test" "C-g" "C-x" "C-c"

echo
echo "=== カテゴリ 5: 日本語対応 ==="
run_test "5.1 日本語入力" --file=/tmp/test_japanese.txt "テスト" "C-x" "C-c" "n"
run_test "5.2 日本語で検索" --file=/tmp/test_japanese.txt "C-s" "日本語" "Enter" "C-x" "C-c"
run_test "5.3 日本語カーソル移動" --file=/tmp/test_japanese.txt "Down" "Right" "Right" "X" "C-x" "C-c" "n"
run_test "5.4 漢字ひらがな混在" --file=/tmp/test_japanese.txt "漢字test" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 6: 絵文字対応 ==="
run_test "6.1 絵文字表示" --file=/tmp/test_emoji.txt "C-x" "C-c"
run_test "6.2 絵文字入力" --file=/tmp/test_emoji.txt "😀" "C-x" "C-c" "n"
run_test "6.3 絵文字カーソル移動" --file=/tmp/test_emoji.txt "Down" "Right" "Right" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 7: 長い行の処理 ==="
run_test "7.1 長い行の表示" --file=/tmp/test_long_line.txt "C-x" "C-c"
run_test "7.2 長い行の編集" --file=/tmp/test_long_line.txt "End" "X" "C-x" "C-c" "n"
run_test "7.3 長い行でのカーソル移動" --file=/tmp/test_long_line.txt "Right" "Right" "Right" "Right" "Right" "C-x" "C-c"

echo
echo "=== カテゴリ 8: 大量行の処理 ==="
run_test "8.1 999行ファイル表示" --file=/tmp/test_999_lines.txt "C-x" "C-c"
run_test "8.2 999行ファイル編集" --file=/tmp/test_999_lines.txt "Down" "test" "C-x" "C-c" "n"
run_test "8.3 行番号幅変更 (998→999)" --file=/tmp/test_998_real.txt "End" "Enter" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 9: ページスクロール ==="
run_test "9.1 Page Down動作" --file=/tmp/test_page_scroll.txt "PageDown" "C-x" "C-c"
run_test "9.2 Page Up動作" --file=/tmp/test_page_scroll.txt "PageDown" "PageUp" "C-x" "C-c"
run_test "9.3 ページまたぎ検索" --file=/tmp/test_page_scroll.txt "C-s" "line" "Space" "3" "0" "Enter" "C-x" "C-c"

echo
echo "=== カテゴリ 10: エッジケース ==="
run_test "10.1 空ファイル" --file=/tmp/test_empty.txt "test" "C-x" "C-c" "n"
run_test "10.2 最終行での Enter" --file=/tmp/test_cursor_input.txt "Down" "Down" "Down" "Enter" "C-x" "C-c" "n"
run_test "10.3 先頭での Backspace" --file=/tmp/test_cursor_input.txt "Backspace" "C-x" "C-c"
run_test "10.4 長いファイルの末尾" --file=/tmp/test_999_lines.txt "C-e" "X" "C-x" "C-c" "n"

echo
echo "========================================="
echo "テスト完了"
echo "========================================="
echo "合計: $TOTAL_COUNT"
echo "成功: $PASS_COUNT"
echo "失敗: $FAIL_COUNT"
echo "成功率: $(( PASS_COUNT * 100 / TOTAL_COUNT ))%"
echo "========================================="

if [ $FAIL_COUNT -eq 0 ]; then
    echo "✓ 全てのテストが成功しました！"
    exit 0
else
    echo "✗ $FAIL_COUNT 個のテストが失敗しました"
    exit 1
fi
