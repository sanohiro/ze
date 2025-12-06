#!/bin/bash

# 統合テストスイート for ze エディタ
# 全ての機能を徹底的にテスト

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
    # test_data/ のパスを /tmp/ze_test_data/ に置換
    local args=()
    for arg in "$@"; do
        # sedを使ってパスを置換（バックスラッシュエスケープの問題を回避）
        local replaced_arg=$(echo "$arg" | sed 's|test_data/|/tmp/ze_test_data/|g')
        args+=("$replaced_arg")
    done
    if $HARNESS "${args[@]}" 2>&1 | grep -q "Child exited with status: 0"; then
        test_result "$test_name" "PASS"
    else
        test_result "$test_name" "FAIL"
    fi
}

echo "========================================="
echo "ze エディタ 統合テストスイート"
echo "========================================="
echo

zig build

# テストデータを /tmp にコピー（元のファイルを保護）
echo "テストデータを /tmp にコピー中..."
rm -rf /tmp/ze_test_data
cp -r test_data /tmp/ze_test_data
echo

echo "=== カテゴリ 1: 基本的な編集操作 ==="
run_test "1.1 シンプルな文字入力" --file=test_data/test_nums.txt "hello" "C-x" "C-c" "n"
run_test "1.2 複数行の入力" --file=test_data/test_nums.txt "line1" "Enter" "line2" "C-x" "C-c" "n"
run_test "1.3 Backspaceで削除" --file=test_data/test_nums.txt "hello" "Backspace" "Backspace" "C-x" "C-c" "n"
run_test "1.4 Enterで改行" --file=test_data/test_nums.txt "test" "Enter" "Enter" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 2: カーソル移動 ==="
run_test "2.1 右移動" --file=test_data/test_cursor_input.txt "Right" "Right" "X" "C-x" "C-c" "n"
run_test "2.2 左移動" --file=test_data/test_cursor_input.txt "End" "Left" "Left" "X" "C-x" "C-c" "n"
run_test "2.3 上移動" --file=test_data/test_cursor_input.txt "Down" "Down" "Up" "X" "C-x" "C-c" "n"
run_test "2.4 下移動" --file=test_data/test_cursor_input.txt "Down" "X" "C-x" "C-c" "n"
run_test "2.5 Home移動" --file=test_data/test_cursor_input.txt "End" "Home" "X" "C-x" "C-c" "n"
run_test "2.6 End移動" --file=test_data/test_cursor_input.txt "End" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 3: ファイル操作 ==="
run_test "3.1 保存 (C-x C-s)" --file=test_data/test_nums.txt "test" "C-x" "C-s" "C-x" "C-c"
run_test "3.2 保存せず終了 (n)" --file=test_data/test_nums.txt "test" "C-x" "C-c" "n"
run_test "3.3 保存して終了 (y)" --file=test_data/test_nums.txt "test" "C-x" "C-c" "y"

echo
echo "=== カテゴリ 4: 検索機能 ==="
run_test "4.1 英語で検索" --file=test_data/test_search_pages.txt "C-s" "T" "a" "r" "g" "e" "t" "Enter" "C-x" "C-c"
run_test "4.2 次を検索 (C-s C-s)" --file=test_data/test_search_pages.txt "C-s" "T" "a" "r" "Enter" "C-s" "C-x" "C-c"
run_test "4.3 検索キャンセル (C-g)" --file=test_data/test_search_pages.txt "C-s" "test" "C-g" "C-x" "C-c"

echo
echo "=== カテゴリ 5: 日本語対応 ==="
run_test "5.1 日本語入力" --file=test_data/test_japanese.txt "テスト" "C-x" "C-c" "n"
run_test "5.2 日本語で検索" --file=test_data/test_japanese.txt "C-s" "日本語" "Enter" "C-x" "C-c"
run_test "5.3 日本語カーソル移動" --file=test_data/test_japanese.txt "Down" "Right" "Right" "X" "C-x" "C-c" "n"
run_test "5.4 漢字ひらがな混在" --file=test_data/test_japanese.txt "漢字test" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 6: 絵文字対応 ==="
run_test "6.1 絵文字表示" --file=test_data/test_emoji.txt "C-x" "C-c"
run_test "6.2 絵文字入力" --file=test_data/test_emoji.txt "😀" "C-x" "C-c" "n"
run_test "6.3 絵文字カーソル移動" --file=test_data/test_emoji.txt "Down" "Right" "Right" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 7: 長い行の処理 ==="
run_test "7.1 長い行の表示" --file=test_data/test_long_line.txt "C-x" "C-c"
run_test "7.2 長い行の編集" --file=test_data/test_long_line.txt "End" "X" "C-x" "C-c" "n"
run_test "7.3 長い行でのカーソル移動" --file=test_data/test_long_line.txt "Right" "Right" "Right" "Right" "Right" "C-x" "C-c"

echo
echo "=== カテゴリ 8: 大量行の処理 ==="
run_test "8.1 999行ファイル表示" --file=test_data/test_999_lines.txt "C-x" "C-c"
run_test "8.2 999行ファイル編集" --file=test_data/test_999_lines.txt "Down" "test" "C-x" "C-c" "n"
run_test "8.3 行番号幅変更 (998→999)" --file=test_data/test_998_real.txt "End" "Enter" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 9: ページスクロール ==="
run_test "9.1 Page Down動作" --file=test_data/test_page_scroll.txt "PageDown" "C-x" "C-c"
run_test "9.2 Page Up動作" --file=test_data/test_page_scroll.txt "PageDown" "PageUp" "C-x" "C-c"
run_test "9.3 ページまたぎ検索" --file=test_data/test_page_scroll.txt "C-s" "line" "Space" "3" "0" "Enter" "C-x" "C-c"

echo
echo "=== カテゴリ 10: エッジケース ==="
run_test "10.1 空ファイル" --file=test_data/test_empty.txt "test" "C-x" "C-c" "n"
run_test "10.2 最終行での Enter" --file=test_data/test_cursor_input.txt "Down" "Down" "Down" "Enter" "C-x" "C-c" "n"
run_test "10.3 先頭での Backspace" --file=test_data/test_cursor_input.txt "Backspace" "C-x" "C-c"
run_test "10.4 長いファイルの末尾" --file=test_data/test_999_lines.txt "C-e" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 11: Undo/Redo機能 ==="
run_test "11.1 単純なUndo" --file=test_data/test_nums.txt "hello" "C-u" "C-x" "C-c"
run_test "11.2 複数回のUndo" --file=test_data/test_nums.txt "a" "b" "c" "C-u" "C-u" "C-u" "C-x" "C-c"
run_test "11.3 Redo" --file=test_data/test_nums.txt "test" "C-u" "C-/" "C-x" "C-c" "n"
run_test "11.4 Undo後に編集でRedoクリア" --file=test_data/test_nums.txt "abc" "C-u" "x" "C-/" "C-x" "C-c" "n"
run_test "11.5 削除のUndo" --file=test_data/test_cursor_input.txt "C-d" "C-u" "C-x" "C-c"
run_test "11.6 Backspace のUndo" --file=test_data/test_cursor_input.txt "End" "Backspace" "C-u" "C-x" "C-c"

echo
echo "=== カテゴリ 12: 範囲選択とコピー/カット/ペースト ==="
run_test "12.1 範囲選択とコピー (M-w)" --file=test_data/test_region.txt "C-Space" "End" "M-w" "C-x" "C-c"
run_test "12.2 範囲選択とカット (C-w)" --file=test_data/test_region.txt "C-Space" "End" "C-w" "C-x" "C-c" "n"
run_test "12.3 ペースト (C-y)" --file=test_data/test_region.txt "C-Space" "End" "M-w" "Down" "C-y" "C-x" "C-c" "n"
run_test "12.4 複数行の範囲選択" --file=test_data/test_region.txt "C-Space" "Down" "End" "M-w" "C-x" "C-c"
run_test "12.5 マーク解除" --file=test_data/test_region.txt "C-Space" "C-Space" "C-x" "C-c"
run_test "12.6 範囲カット後にペースト" --file=test_data/test_region.txt "C-Space" "Right" "Right" "Right" "Right" "C-w" "End" "C-y" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 13: 単語移動と削除 ==="
run_test "13.1 単語前進 (M-f)" --file=test_data/test_words.txt "M-f" "X" "C-x" "C-c" "n"
run_test "13.2 単語後退 (M-b)" --file=test_data/test_words.txt "End" "M-b" "X" "C-x" "C-c" "n"
run_test "13.3 単語削除 (M-d)" --file=test_data/test_words.txt "M-d" "C-x" "C-c" "n"
run_test "13.4 後方単語削除 (M-delete)" --file=test_data/test_words.txt "M-f" "M-delete" "C-x" "C-c" "n"
run_test "13.5 複数単語前進" --file=test_data/test_words.txt "M-f" "M-f" "M-f" "X" "C-x" "C-c" "n"
run_test "13.6 行末から単語後退" --file=test_data/test_words.txt "End" "M-b" "M-b" "X" "C-x" "C-c" "n"
run_test "13.7 日本語単語前進 (M-f)" --file=test_data/test_words_ja.txt "M-f" "X" "C-x" "C-c" "n"
run_test "13.8 日本語単語後退 (M-b)" --file=test_data/test_words_ja.txt "End" "M-b" "X" "C-x" "C-c" "n"
run_test "13.9 日本語単語削除 (M-d)" --file=test_data/test_words_ja.txt "M-d" "C-x" "C-c" "n"
run_test "13.10 混在文字の単語移動" --file=test_data/test_words_ja.txt "M-f" "M-f" "M-f" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 14: Emacs スタイルカーソル移動 ==="
run_test "14.1 C-f (前進)" --file=test_data/test_cursor_input.txt "C-f" "C-f" "X" "C-x" "C-c" "n"
run_test "14.2 C-b (後退)" --file=test_data/test_cursor_input.txt "End" "C-b" "C-b" "X" "C-x" "C-c" "n"
run_test "14.3 C-n (次行)" --file=test_data/test_cursor_input.txt "C-n" "X" "C-x" "C-c" "n"
run_test "14.4 C-p (前行)" --file=test_data/test_cursor_input.txt "Down" "C-p" "X" "C-x" "C-c" "n"
run_test "14.5 C-a (行頭)" --file=test_data/test_cursor_input.txt "End" "C-a" "X" "C-x" "C-c" "n"
run_test "14.6 C-e (行末)" --file=test_data/test_cursor_input.txt "C-e" "X" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 15: 削除操作 ==="
run_test "15.1 C-d (文字削除)" --file=test_data/test_cursor_input.txt "C-d" "C-x" "C-c" "n"
run_test "15.2 C-k (行削除)" --file=test_data/test_cursor_input.txt "C-k" "C-x" "C-c" "n"
run_test "15.3 複数回C-d" --file=test_data/test_cursor_input.txt "C-d" "C-d" "C-d" "C-x" "C-c" "n"
run_test "15.4 C-k で改行削除" --file=test_data/test_cursor_input.txt "End" "C-k" "C-x" "C-c" "n"
run_test "15.5 行末でC-d" --file=test_data/test_cursor_input.txt "End" "C-d" "C-x" "C-c" "n"
run_test "15.6 C-kとUndo" --file=test_data/test_cursor_input.txt "C-k" "C-u" "C-x" "C-c"

echo
echo "=== カテゴリ 16: 後方検索 ==="
run_test "16.1 後方検索 (C-r)" --file=test_data/test_search_pages.txt "C-e" "C-r" "T" "a" "r" "Enter" "C-x" "C-c"
run_test "16.2 後方検索で複数ヒット" --file=test_data/test_search_pages.txt "C-e" "C-r" "l" "i" "n" "e" "Enter" "C-x" "C-c"
run_test "16.3 後方検索キャンセル" --file=test_data/test_search_pages.txt "C-e" "C-r" "test" "C-g" "C-x" "C-c"
run_test "16.4 後方検索で日本語" --file=test_data/test_japanese.txt "C-e" "C-r" "日本語" "Enter" "C-x" "C-c"

echo
echo "=== カテゴリ 17: 複合操作とエッジケース ==="
run_test "17.1 Tabキー入力" --file=test_data/test_nums.txt "Tab" "hello" "C-x" "C-c" "n"
run_test "17.2 連続改行" --file=test_data/test_nums.txt "Enter" "Enter" "Enter" "C-x" "C-c" "n"
run_test "17.3 全選択してカット" --file=test_data/test_cursor_input.txt "C-Space" "C-e" "C-w" "C-x" "C-c" "n"
run_test "17.4 範囲選択後に入力" --file=test_data/test_region.txt "C-Space" "Right" "Right" "a" "C-x" "C-c" "n"
run_test "17.5 カット後Undo" --file=test_data/test_region.txt "C-Space" "End" "C-w" "C-u" "C-x" "C-c" "n"
run_test "17.6 複雑な編集シーケンス" --file=test_data/test_nums.txt "hello" "Enter" "world" "C-u" "C-u" "test" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 18: 日本語とUTF-8 詳細テスト ==="
run_test "18.1 日本語範囲選択" --file=test_data/test_japanese.txt "C-Space" "Right" "Right" "Right" "M-w" "C-x" "C-c"
run_test "18.2 日本語単語削除" --file=test_data/test_japanese.txt "M-d" "C-x" "C-c" "n"
run_test "18.3 日本語でC-k" --file=test_data/test_japanese.txt "C-k" "C-x" "C-c" "n"
run_test "18.4 絵文字範囲選択" --file=test_data/test_emoji.txt "C-Space" "Right" "Right" "M-w" "C-x" "C-c"
run_test "18.5 絵文字削除" --file=test_data/test_emoji.txt "C-d" "C-x" "C-c" "n"
run_test "18.6 混在文字のペースト" --file=test_data/test_japanese.txt "C-Space" "End" "M-w" "Down" "C-y" "C-x" "C-c" "n"

echo
echo "=== カテゴリ 19: ファイル操作詳細 ==="
run_test "19.1 新規ファイル名入力" "新規" "C-x" "C-s" "/tmp/test_new_file.txt" "Enter" "C-x" "C-c"
run_test "19.2 ファイル名入力でBackspace" "test" "C-x" "C-s" "abc" "Backspace" "Backspace" "Backspace" "C-g" "C-x" "C-c" "n"
run_test "19.3 保存確認でキャンセル (c)" --file=test_data/test_nums.txt "test" "C-x" "C-c" "c" "C-x" "C-c" "n"
run_test "19.4 変更なしでC-x C-s" --file=test_data/test_nums.txt "C-x" "C-s" "C-x" "C-c"
run_test "19.5 複数回保存" --file=test_data/test_nums.txt "a" "C-x" "C-s" "b" "C-x" "C-s" "C-x" "C-c"

echo
echo "=== カテゴリ 20: ストレステストと境界値 ==="
run_test "20.1 1000文字の行" --file=test_data/test_long_line.txt "C-e" "X" "C-x" "C-c" "n"
run_test "20.2 ファイル全体をコピー" --file=test_data/test_cursor_input.txt "C-Space" "C-e" "M-w" "C-x" "C-c"
run_test "20.3 長いファイルでUndo" --file=test_data/test_999_lines.txt "X" "C-u" "C-x" "C-c"
run_test "20.4 大量のUndo/Redo" --file=test_data/test_nums.txt "1" "2" "3" "4" "5" "C-u" "C-u" "C-u" "C-/" "C-/" "C-x" "C-c" "n"
run_test "20.5 範囲選択で全文削除" --file=test_data/test_cursor_input.txt "C-Space" "C-e" "C-w" "hello" "C-x" "C-c" "n"
run_test "20.6 空行での各種操作" --file=test_data/test_empty.txt "C-d" "Backspace" "C-k" "M-d" "C-x" "C-c"

echo
echo "=== カテゴリ 21: Query Replace (M-%) ==="
run_test "21.1 基本的な置換 (y)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "y" "q" "C-x" "C-c" "n"
run_test "21.2 置換をスキップ (n)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "n" "n" "q" "C-x" "C-c"
run_test "21.3 全て置換 (!)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "!" "C-x" "C-c" "n"
run_test "21.4 置換を中断 (q)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "q" "C-x" "C-c"
run_test "21.5 置換をキャンセル (C-g)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "C-g" "C-x" "C-c"
run_test "21.6 マッチなし" --file=test_data/test_replace.txt "M-%" "notfound" "Enter" "bar" "Enter" "C-x" "C-c"
run_test "21.7 空の置換文字列" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "Enter" "y" "q" "C-x" "C-c" "n"
run_test "21.8 複数回の置換 (y,y,y)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "y" "y" "y" "q" "C-x" "C-c" "n"
run_test "21.9 置換のUndo" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "!" "C-u" "C-x" "C-c" "n"
run_test "21.10 日本語の置換" --input-file=test_data/test_japanese_replace_keys.txt --file=test_data/test_replace_ja.txt

echo
echo "========================================="
echo "統合テスト完了"
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
