#!/bin/bash

# 拡張テストスイート for ze エディタ
# 実装済み機能の完全網羅テスト

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
echo "ze エディタ 拡張テストスイート"
echo "========================================="
echo

zig build

echo "=== カテゴリ 11: Undo/Redo機能 ==="
run_test "11.1 単純なUndo" --file=/tmp/test_nums.txt "hello" "C-u" "C-x" "C-c"
run_test "11.2 複数回のUndo" --file=/tmp/test_nums.txt "a" "b" "c" "C-u" "C-u" "C-u" "C-x" "C-c"
run_test "11.3 Redo" --file=/tmp/test_nums.txt "test" "C-u" "C-/" "C-x" "C-c" "n"
run_test "11.4 Undo後に編集でRedoクリア" --file=/tmp/test_nums.txt "abc" "C-u" "x" "C-/" "C-x" "C-c" "n"
run_test "11.5 削除のUndo" --file=/tmp/test_cursor_input.txt "C-d" "C-u" "C-x" "C-c"
run_test "11.6 Backspace のUndo" --file=/tmp/test_cursor_input.txt "End" "Backspace" "C-u" "C-x" "C-c"

echo
echo "=== カテゴリ 12: 範囲選択とコピー/カット/ペースト ==="
run_test "12.1 範囲選択とコピー (M-w)" --file=/tmp/test_region.txt "C-Space" "End" "M-w" "C-x" "C-c"
run_test "12.2 範囲選択とカット (C-w)" --file=/tmp/test_region.txt "C-Space" "End" "C-w" "C-x" "C-c" "n"
run_test "12.3 ペースト (C-y)" --file=/tmp/test_region.txt "C-Space" "End" "M-w" "Down" "C-y" "C-x" "C-c" "n"
run_test "12.4 複数行の範囲選択" --file=/tmp/test_region.txt "C-Space" "Down" "End" "M-w" "C-x" "C-c"
run_test "12.5 マーク解除" --file=/tmp/test_region.txt "C-Space" "C-Space" "C-x" "C-c"
run_test "12.6 範囲カット後にペースト" --file=/tmp/test_region.txt "C-Space" "Right" "Right" "Right" "Right" "C-w" "End" "C-y" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 13: 単語移動と削除 ==="
run_test "13.1 単語前進 (M-f)" --file=/tmp/test_words.txt "M-f" "X" "C-x" "C-c" "n"
run_test "13.2 単語後退 (M-b)" --file=/tmp/test_words.txt "End" "M-b" "X" "C-x" "C-c" "n"
run_test "13.3 単語削除 (M-d)" --file=/tmp/test_words.txt "M-d" "C-x" "C-c" "n"
run_test "13.4 後方単語削除 (M-delete)" --file=/tmp/test_words.txt "M-f" "M-delete" "C-x" "C-c" "n"
run_test "13.5 複数単語前進" --file=/tmp/test_words.txt "M-f" "M-f" "M-f" "X" "C-x" "C-c" "n"
run_test "13.6 行末から単語後退" --file=/tmp/test_words.txt "End" "M-b" "M-b" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 14: Emacs スタイルカーソル移動 ==="
run_test "14.1 C-f (前進)" --file=/tmp/test_cursor_input.txt "C-f" "C-f" "X" "C-x" "C-c" "n"
run_test "14.2 C-b (後退)" --file=/tmp/test_cursor_input.txt "End" "C-b" "C-b" "X" "C-x" "C-c" "n"
run_test "14.3 C-n (次行)" --file=/tmp/test_cursor_input.txt "C-n" "X" "C-x" "C-c" "n"
run_test "14.4 C-p (前行)" --file=/tmp/test_cursor_input.txt "Down" "C-p" "X" "C-x" "C-c" "n"
run_test "14.5 C-a (行頭)" --file=/tmp/test_cursor_input.txt "End" "C-a" "X" "C-x" "C-c" "n"
run_test "14.6 C-e (行末)" --file=/tmp/test_cursor_input.txt "C-e" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 15: 削除操作 ==="
run_test "15.1 C-d (文字削除)" --file=/tmp/test_cursor_input.txt "C-d" "C-x" "C-c" "n"
run_test "15.2 C-k (行削除)" --file=/tmp/test_cursor_input.txt "C-k" "C-x" "C-c" "n"
run_test "15.3 複数回C-d" --file=/tmp/test_cursor_input.txt "C-d" "C-d" "C-d" "C-x" "C-c" "n"
run_test "15.4 C-k で改行削除" --file=/tmp/test_cursor_input.txt "End" "C-k" "C-x" "C-c" "n"
run_test "15.5 行末でC-d" --file=/tmp/test_cursor_input.txt "End" "C-d" "C-x" "C-c" "n"
run_test "15.6 C-kとUndo" --file=/tmp/test_cursor_input.txt "C-k" "C-u" "C-x" "C-c"

echo
echo "=== カテゴリ 16: 後方検索 ==="
run_test "16.1 後方検索 (C-r)" --file=/tmp/test_search_pages.txt "C-e" "C-r" "T" "a" "r" "Enter" "C-x" "C-c"
run_test "16.2 後方検索で複数ヒット" --file=/tmp/test_search_pages.txt "C-e" "C-r" "l" "i" "n" "e" "Enter" "C-x" "C-c"
run_test "16.3 後方検索キャンセル" --file=/tmp/test_search_pages.txt "C-e" "C-r" "test" "C-g" "C-x" "C-c"
run_test "16.4 後方検索で日本語" --file=/tmp/test_japanese.txt "C-e" "C-r" "日本語" "Enter" "C-x" "C-c"

echo
echo "=== カテゴリ 17: 複合操作とエッジケース ==="
run_test "17.1 Tabキー入力" --file=/tmp/test_nums.txt "Tab" "hello" "C-x" "C-c" "n"
run_test "17.2 連続改行" --file=/tmp/test_nums.txt "Enter" "Enter" "Enter" "C-x" "C-c" "n"
run_test "17.3 全選択してカット" --file=/tmp/test_cursor_input.txt "C-Space" "C-e" "C-w" "C-x" "C-c" "n"
run_test "17.4 範囲選択後に入力" --file=/tmp/test_region.txt "C-Space" "Right" "Right" "a" "C-x" "C-c" "n"
run_test "17.5 カット後Undo" --file=/tmp/test_region.txt "C-Space" "End" "C-w" "C-u" "C-x" "C-c" "n"
run_test "17.6 複雑な編集シーケンス" --file=/tmp/test_nums.txt "hello" "Enter" "world" "C-u" "C-u" "test" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 18: 日本語とUTF-8 詳細テスト ==="
run_test "18.1 日本語範囲選択" --file=/tmp/test_japanese.txt "C-Space" "Right" "Right" "Right" "M-w" "C-x" "C-c"
run_test "18.2 日本語単語削除" --file=/tmp/test_japanese.txt "M-d" "C-x" "C-c" "n"
run_test "18.3 日本語でC-k" --file=/tmp/test_japanese.txt "C-k" "C-x" "C-c" "n"
run_test "18.4 絵文字範囲選択" --file=/tmp/test_emoji.txt "C-Space" "Right" "Right" "M-w" "C-x" "C-c"
run_test "18.5 絵文字削除" --file=/tmp/test_emoji.txt "C-d" "C-x" "C-c" "n"
run_test "18.6 混在文字のペースト" --file=/tmp/test_japanese.txt "C-Space" "End" "M-w" "Down" "C-y" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 19: ファイル操作詳細 ==="
run_test "19.1 新規ファイル名入力" "新規" "C-x" "C-s" "/tmp/test_new_file.txt" "Enter" "C-x" "C-c"
run_test "19.2 ファイル名入力でBackspace" "test" "C-x" "C-s" "abc" "Backspace" "Backspace" "Backspace" "C-g" "C-x" "C-c" "n"
run_test "19.3 保存確認でキャンセル (c)" --file=/tmp/test_nums.txt "test" "C-x" "C-c" "c" "C-x" "C-c" "n"
run_test "19.4 変更なしでC-x C-s" --file=/tmp/test_nums.txt "C-x" "C-s" "C-x" "C-c"
run_test "19.5 複数回保存" --file=/tmp/test_nums.txt "a" "C-x" "C-s" "b" "C-x" "C-s" "C-x" "C-c"

echo
echo "=== カテゴリ 20: ストレステストと境界値 ==="
run_test "20.1 1000文字の行" --file=/tmp/test_long_line.txt "C-e" "X" "C-x" "C-c" "n"
run_test "20.2 ファイル全体をコピー" --file=/tmp/test_cursor_input.txt "C-Space" "C-e" "M-w" "C-x" "C-c"
run_test "20.3 長いファイルでUndo" --file=/tmp/test_999_lines.txt "X" "C-u" "C-x" "C-c"
run_test "20.4 大量のUndo/Redo" --file=/tmp/test_nums.txt "1" "2" "3" "4" "5" "C-u" "C-u" "C-u" "C-/" "C-/" "C-x" "C-c" "n"
run_test "20.5 範囲選択で全文削除" --file=/tmp/test_cursor_input.txt "C-Space" "C-e" "C-w" "hello" "C-x" "C-c" "n"
run_test "20.6 空行での各種操作" --file=/tmp/test_empty.txt "C-d" "Backspace" "C-k" "M-d" "C-x" "C-c"

echo
echo "========================================="
echo "拡張テスト完了"
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
