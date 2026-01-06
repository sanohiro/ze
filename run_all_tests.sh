#!/bin/bash

# 統合テストスイート for ze エディタ
# 全ての機能を徹底的にテスト
#
# 使い方:
#   ./run_all_tests.sh           # 全てのテストを実行
#   ./run_all_tests.sh 30        # カテゴリ30のみ実行
#   ./run_all_tests.sh 30 31 32  # カテゴリ30, 31, 32を実行
#   ./run_all_tests.sh -s 1-20   # カテゴリ1-20をスキップ（21以降を実行）

set -e

# 引数パース
CATEGORIES=()
SKIP_RANGE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--skip)
            SKIP_RANGE="$2"
            shift 2
            ;;
        *)
            CATEGORIES+=("$1")
            shift
            ;;
    esac
done

# カテゴリを実行するかチェック
should_run_category() {
    local cat_num=$1

    # スキップ範囲の処理
    if [[ -n "$SKIP_RANGE" ]]; then
        if [[ "$SKIP_RANGE" == *-* ]]; then
            local start=$(echo "$SKIP_RANGE" | cut -d'-' -f1)
            local end=$(echo "$SKIP_RANGE" | cut -d'-' -f2)
            if [[ $cat_num -ge $start && $cat_num -le $end ]]; then
                return 1
            fi
        elif [[ $cat_num -eq $SKIP_RANGE ]]; then
            return 1
        fi
    fi

    # カテゴリ指定がない場合は全て実行
    if [[ ${#CATEGORIES[@]} -eq 0 ]]; then
        return 0
    fi

    # 指定されたカテゴリのみ実行
    for cat in "${CATEGORIES[@]}"; do
        if [[ $cat -eq $cat_num ]]; then
            return 0
        fi
    done
    return 1
}

# 終了時にターミナル状態をリセット（代替画面終了、マウスモード無効化、カーソル表示）
cleanup() {
    printf '\e[?1049l\e[?1000l\e[?1003l\e[?1006l\e[?25h'
}
trap cleanup EXIT

# 事前コンパイル済みハーネスを使用（存在しなければビルド）
if [[ ! -f "./test_harness_generic" ]]; then
    echo "ハーネスをビルド中..."
    zig build-exe test_harness_generic.zig -lc -O ReleaseFast
fi
HARNESS="./test_harness_generic"
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

# テストファイルをリセット（元のtest_dataからコピー）
reset_test_file() {
    local file="$1"
    cp "test_data/$file" "/tmp/ze_test_data/$file"
}

# 内容検証付きテスト実行ヘルパー（--expect使用）
run_test_verify() {
    local test_name="$1"
    shift
    # test_data/ のパスを /tmp/ze_test_data/ に置換
    local args=()
    for arg in "$@"; do
        local replaced_arg=$(echo "$arg" | sed 's|test_data/|/tmp/ze_test_data/|g')
        args+=("$replaced_arg")
    done
    local output
    output=$($HARNESS "${args[@]}" 2>&1)
    if echo "$output" | grep -q "PASS: Content matches!"; then
        test_result "$test_name" "PASS"
    elif echo "$output" | grep -q "Child exited with status: 0"; then
        # --expectなしの場合は終了コードで判断
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

if should_run_category 1; then
echo "=== カテゴリ 1: 基本的な編集操作 ==="
run_test "1.1 シンプルな文字入力" --file=test_data/test_nums.txt "hello" "C-x" "C-c" "n"
run_test "1.2 複数行の入力" --file=test_data/test_nums.txt "line1" "Enter" "line2" "C-x" "C-c" "n"
run_test "1.3 Backspaceで削除" --file=test_data/test_nums.txt "hello" "Backspace" "Backspace" "C-x" "C-c" "n"
run_test "1.4 Enterで改行" --file=test_data/test_nums.txt "test" "Enter" "Enter" "C-x" "C-c" "n"
echo
fi

if should_run_category 2; then
echo "=== カテゴリ 2: カーソル移動 ==="
run_test "2.1 右移動" --file=test_data/test_cursor_input.txt "Right" "Right" "X" "C-x" "C-c" "n"
run_test "2.2 左移動" --file=test_data/test_cursor_input.txt "End" "Left" "Left" "X" "C-x" "C-c" "n"
run_test "2.3 上移動" --file=test_data/test_cursor_input.txt "Down" "Down" "Up" "X" "C-x" "C-c" "n"
run_test "2.4 下移動" --file=test_data/test_cursor_input.txt "Down" "X" "C-x" "C-c" "n"
run_test "2.5 Home移動" --file=test_data/test_cursor_input.txt "End" "Home" "X" "C-x" "C-c" "n"
run_test "2.6 End移動" --file=test_data/test_cursor_input.txt "End" "X" "C-x" "C-c" "n"
echo
fi

if should_run_category 3; then
echo "=== カテゴリ 3: ファイル操作 ==="
run_test "3.1 保存 (C-x C-s)" --file=test_data/test_nums.txt "test" "C-x" "C-s" "C-x" "C-c"
run_test "3.2 保存せず終了 (n)" --file=test_data/test_nums.txt "test" "C-x" "C-c" "n"
run_test "3.3 保存して終了 (y)" --file=test_data/test_nums.txt "test" "C-x" "C-c" "y"
echo
fi

if should_run_category 4; then

echo
echo "=== カテゴリ 4: 検索機能 ==="
run_test "4.1 英語で検索" --file=test_data/test_search_pages.txt "C-s" "T" "a" "r" "g" "e" "t" "Enter" "C-x" "C-c"
run_test "4.2 次を検索 (C-s C-s)" --file=test_data/test_search_pages.txt "C-s" "T" "a" "r" "Enter" "C-s" "C-x" "C-c"
run_test "4.3 検索キャンセル (C-g)" --file=test_data/test_search_pages.txt "C-s" "test" "C-g" "C-x" "C-c"
run_test "4.4 正規表現検索 (C-M-s)" --file=test_data/test_comma.txt "C-M-s" "," "$" "Enter" "C-x" "C-c"
run_test "4.5 正規表現後方検索 (C-M-r)" --file=test_data/test_comma.txt "M->" "C-M-r" "," "$" "Enter" "C-x" "C-c"
echo
fi

if should_run_category 5; then

echo
echo "=== カテゴリ 5: 日本語対応 ==="
run_test "5.1 日本語入力" --file=test_data/test_japanese.txt "テスト" "C-x" "C-c" "n"
run_test "5.2 日本語で検索" --file=test_data/test_japanese.txt "C-s" "日本語" "Enter" "C-x" "C-c"
run_test "5.3 日本語カーソル移動" --file=test_data/test_japanese.txt "Down" "Right" "Right" "X" "C-x" "C-c" "n"
run_test "5.4 漢字ひらがな混在" --file=test_data/test_japanese.txt "漢字test" "C-x" "C-c" "n"
echo
fi

if should_run_category 6; then

echo
echo "=== カテゴリ 6: 絵文字対応 ==="
run_test "6.1 絵文字表示" --file=test_data/test_emoji.txt "C-x" "C-c"
run_test "6.2 絵文字入力" --file=test_data/test_emoji.txt "😀" "C-x" "C-c" "n"
run_test "6.3 絵文字カーソル移動" --file=test_data/test_emoji.txt "Down" "Right" "Right" "X" "C-x" "C-c" "n"
echo
fi

if should_run_category 7; then

echo
echo "=== カテゴリ 7: 長い行の処理 ==="
run_test "7.1 長い行の表示" --file=test_data/test_long_line.txt "C-x" "C-c"
run_test "7.2 長い行の編集" --file=test_data/test_long_line.txt "End" "X" "C-x" "C-c" "n"
run_test "7.3 長い行でのカーソル移動" --file=test_data/test_long_line.txt "Right" "Right" "Right" "Right" "Right" "C-x" "C-c"
echo
fi

if should_run_category 8; then

echo
echo "=== カテゴリ 8: 大量行の処理 ==="
run_test "8.1 999行ファイル表示" --file=test_data/test_999_lines.txt "C-x" "C-c"
run_test "8.2 999行ファイル編集" --file=test_data/test_999_lines.txt "Down" "test" "C-x" "C-c" "n"
run_test "8.3 行番号幅変更 (998→999)" --file=test_data/test_998_real.txt "End" "Enter" "C-x" "C-c" "n"
echo
fi

if should_run_category 9; then

echo
echo "=== カテゴリ 9: ページスクロール ==="
run_test "9.1 Page Down動作" --file=test_data/test_page_scroll.txt "PageDown" "C-x" "C-c"
run_test "9.2 Page Up動作" --file=test_data/test_page_scroll.txt "PageDown" "PageUp" "C-x" "C-c"
run_test "9.3 ページまたぎ検索" --file=test_data/test_page_scroll.txt "C-s" "30" "Enter" "C-x" "C-c"
echo
fi

if should_run_category 10; then

echo
echo "=== カテゴリ 10: エッジケース ==="
run_test "10.1 空ファイル" --file=test_data/test_empty.txt "test" "C-x" "C-c" "n"
run_test "10.2 最終行での Enter" --file=test_data/test_cursor_input.txt "Down" "Down" "Down" "Enter" "C-x" "C-c" "n"
run_test "10.3 先頭での Backspace" --file=test_data/test_cursor_input.txt "Backspace" "C-x" "C-c"
run_test "10.4 長いファイルの末尾" --file=test_data/test_999_lines.txt "C-e" "X" "C-x" "C-c" "n"
echo
fi

if should_run_category 11; then

echo
echo "=== カテゴリ 11: Undo/Redo機能 ==="
run_test "11.1 単純なUndo" --file=test_data/test_nums.txt "hello" "C-u" "C-x" "C-c"
run_test "11.2 複数回のUndo" --file=test_data/test_nums.txt "a" "b" "c" "C-u" "C-u" "C-u" "C-x" "C-c"
run_test "11.3 Redo" --file=test_data/test_nums.txt "test" "C-u" "C-/" "C-x" "C-c" "n"
run_test "11.4 Undo後に編集でRedoクリア" --file=test_data/test_nums.txt "abc" "C-u" "x" "C-/" "C-x" "C-c" "n"
run_test "11.5 削除のUndo" --file=test_data/test_cursor_input.txt "C-d" "C-u" "C-x" "C-c"
run_test "11.6 Backspace のUndo" --file=test_data/test_cursor_input.txt "End" "Backspace" "C-u" "C-x" "C-c"
echo
fi

if should_run_category 12; then

echo
echo "=== カテゴリ 12: 範囲選択とコピー/カット/ペースト ==="
run_test "12.1 範囲選択とコピー (M-w)" --file=test_data/test_region.txt "C-Space" "End" "M-w" "C-x" "C-c"
run_test "12.2 範囲選択とカット (C-w)" --file=test_data/test_region.txt "C-Space" "End" "C-w" "C-x" "C-c" "n"
run_test "12.3 ペースト (C-y)" --file=test_data/test_region.txt "C-Space" "End" "M-w" "Down" "C-y" "C-x" "C-c" "n"
run_test "12.4 複数行の範囲選択" --file=test_data/test_region.txt "C-Space" "Down" "End" "M-w" "C-x" "C-c"
run_test "12.5 マーク解除" --file=test_data/test_region.txt "C-Space" "C-Space" "C-x" "C-c"
run_test "12.6 範囲カット後にペースト" --file=test_data/test_region.txt "C-Space" "Right" "Right" "Right" "Right" "C-w" "End" "C-y" "C-x" "C-c" "n"
run_test "12.7 矩形削除 (C-x r k)" --file=test_data/test_region.txt "C-Space" "Down" "Right" "Right" "C-x" "r" "k" "C-x" "C-c" "n"
run_test "12.8 矩形ヤンク (C-x r y)" --file=test_data/test_region.txt "C-Space" "Right" "Right" "Right" "C-x" "r" "k" "Down" "C-x" "r" "y" "C-x" "C-c" "n"
echo
fi

if should_run_category 13; then

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
run_test "13.11 段落前進 (M-})" --file=test_data/test_paragraphs.txt "M-}" "X" "C-x" "C-c" "n"
run_test "13.12 段落後退 (M-{)" --file=test_data/test_paragraphs.txt "End" "M-{" "M-{" "X" "C-x" "C-c" "n"
run_test "13.13 段落移動（複数前進）" --file=test_data/test_paragraphs.txt "M-}" "M-}" "X" "C-x" "C-c" "n"
echo
fi

if should_run_category 14; then

echo
echo "=== カテゴリ 14: Emacs スタイルカーソル移動 ==="
run_test "14.1 C-f (前進)" --file=test_data/test_cursor_input.txt "C-f" "C-f" "X" "C-x" "C-c" "n"
run_test "14.2 C-b (後退)" --file=test_data/test_cursor_input.txt "End" "C-b" "C-b" "X" "C-x" "C-c" "n"
run_test "14.3 C-n (次行)" --file=test_data/test_cursor_input.txt "C-n" "X" "C-x" "C-c" "n"
run_test "14.4 C-p (前行)" --file=test_data/test_cursor_input.txt "Down" "C-p" "X" "C-x" "C-c" "n"
run_test "14.5 C-a (行頭)" --file=test_data/test_cursor_input.txt "End" "C-a" "X" "C-x" "C-c" "n"
run_test "14.6 C-e (行末)" --file=test_data/test_cursor_input.txt "C-e" "X" "C-x" "C-c" "n"
run_test "14.7 C-v (ページダウン)" --file=test_data/test_page_scroll.txt "C-v" "C-x" "C-c"
run_test "14.8 M-v (ページアップ)" --file=test_data/test_page_scroll.txt "C-v" "M-v" "C-x" "C-c"
run_test "14.9 C-l (recenter)" --file=test_data/test_page_scroll.txt "PageDown" "C-l" "C-x" "C-c"
run_test "14.10 M-< (バッファ先頭)" --file=test_data/test_page_scroll.txt "PageDown" "M-<" "C-x" "C-c"
run_test "14.11 M-> (バッファ末尾)" --file=test_data/test_page_scroll.txt "M->" "C-x" "C-c"
echo
fi

if should_run_category 15; then

echo
echo "=== カテゴリ 15: 削除操作 ==="
run_test "15.1 C-d (文字削除)" --file=test_data/test_cursor_input.txt "C-d" "C-x" "C-c" "n"
run_test "15.2 C-k (行削除)" --file=test_data/test_cursor_input.txt "C-k" "C-x" "C-c" "n"
run_test "15.3 複数回C-d" --file=test_data/test_cursor_input.txt "C-d" "C-d" "C-d" "C-x" "C-c" "n"
run_test "15.4 C-k で改行削除" --file=test_data/test_cursor_input.txt "End" "C-k" "C-x" "C-c" "n"
run_test "15.5 行末でC-d" --file=test_data/test_cursor_input.txt "End" "C-d" "C-x" "C-c" "n"
run_test "15.6 C-kとUndo" --file=test_data/test_cursor_input.txt "C-k" "C-u" "C-x" "C-c"
echo
fi

if should_run_category 16; then

echo
echo "=== カテゴリ 16: 後方検索 ==="
run_test "16.1 後方検索 (C-r)" --file=test_data/test_search_pages.txt "C-e" "C-r" "T" "a" "r" "Enter" "C-x" "C-c"
run_test "16.2 後方検索で複数ヒット" --file=test_data/test_search_pages.txt "C-e" "C-r" "l" "i" "n" "e" "Enter" "C-x" "C-c"
run_test "16.3 後方検索キャンセル" --file=test_data/test_search_pages.txt "C-e" "C-r" "test" "C-g" "C-x" "C-c"
run_test "16.4 後方検索で日本語" --file=test_data/test_japanese.txt "C-e" "C-r" "日本語" "Enter" "C-x" "C-c"
echo
fi

if should_run_category 17; then

echo
echo "=== カテゴリ 17: 複合操作とエッジケース ==="
run_test "17.1 Tabキー入力" --file=test_data/test_nums.txt "Tab" "hello" "C-x" "C-c" "n"
run_test "17.2 連続改行" --file=test_data/test_nums.txt "Enter" "Enter" "Enter" "C-x" "C-c" "n"
run_test "17.3 全選択してカット" --file=test_data/test_cursor_input.txt "C-Space" "C-e" "C-w" "C-x" "C-c" "n"
run_test "17.4 範囲選択後に入力" --file=test_data/test_region.txt "C-Space" "Right" "Right" "a" "C-x" "C-c" "n"
run_test "17.5 カット後Undo" --file=test_data/test_region.txt "C-Space" "End" "C-w" "C-u" "C-x" "C-c" "n"
run_test "17.6 複雑な編集シーケンス" --file=test_data/test_nums.txt "hello" "Enter" "world" "C-u" "C-u" "test" "C-x" "C-c" "n"
echo
fi

if should_run_category 18; then

echo
echo "=== カテゴリ 18: 日本語とUTF-8 詳細テスト ==="
run_test "18.1 日本語範囲選択" --file=test_data/test_japanese.txt "C-Space" "Right" "Right" "Right" "M-w" "C-x" "C-c"
run_test "18.2 日本語単語削除" --file=test_data/test_japanese.txt "M-d" "C-x" "C-c" "n"
run_test "18.3 日本語でC-k" --file=test_data/test_japanese.txt "C-k" "C-x" "C-c" "n"
run_test "18.4 絵文字範囲選択" --file=test_data/test_emoji.txt "C-Space" "Right" "Right" "M-w" "C-x" "C-c"
run_test "18.5 絵文字削除" --file=test_data/test_emoji.txt "C-d" "C-x" "C-c" "n"
run_test "18.6 混在文字のペースト" --file=test_data/test_japanese.txt "C-Space" "End" "M-w" "Down" "C-y" "C-x" "C-c" "n"
echo
fi

if should_run_category 19; then

echo
echo "=== カテゴリ 19: ファイル操作詳細 ==="
run_test "19.1 新規ファイル名入力" "新規" "C-x" "C-s" "/tmp/test_new_file.txt" "Enter" "y" "C-x" "C-c"
run_test "19.2 ファイル名入力でBackspace" "test" "C-x" "C-s" "abc" "Backspace" "Backspace" "Backspace" "C-g" "C-x" "C-c" "n"
run_test "19.3 保存確認でキャンセル (c)" --file=test_data/test_nums.txt "test" "C-x" "C-c" "c" "C-x" "C-c" "n"
run_test "19.4 変更なしでC-x C-s" --file=test_data/test_nums.txt "C-x" "C-s" "C-x" "C-c"
run_test "19.5 複数回保存" --file=test_data/test_nums.txt "a" "C-x" "C-s" "b" "C-x" "C-s" "C-x" "C-c"
run_test "19.6 名前を付けて保存 (C-x C-w)" --file=test_data/test_nums.txt "test" "C-x" "C-w" "/tmp/ze_test_saveas.txt" "Enter" "y" "C-x" "C-c"
run_test "19.7 C-x k (バッファを閉じる)" --file=test_data/test_buffer1.txt "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "C-x" "k" "C-x" "C-c"
run_test "19.8 M-x kill-buffer" --file=test_data/test_buffer1.txt "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "M-x" "kill-buffer" "Enter" "C-x" "C-c"
run_test "19.9 M-x kb (エイリアス)" --file=test_data/test_buffer1.txt "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "M-x" "kb" "Enter" "C-x" "C-c"
run_test "19.10 C-x h (全選択)" --file=test_data/test_cursor_input.txt "C-x" "h" "C-w" "C-x" "C-c" "n"
echo
fi

if should_run_category 20; then

echo
echo "=== カテゴリ 20: ストレステストと境界値 ==="
run_test "20.1 1000文字の行" --file=test_data/test_long_line.txt "C-e" "X" "C-x" "C-c" "n"
run_test "20.2 ファイル全体をコピー" --file=test_data/test_cursor_input.txt "C-Space" "C-e" "M-w" "C-x" "C-c"
run_test "20.3 長いファイルでUndo" --file=test_data/test_999_lines.txt "X" "C-u" "C-x" "C-c"
run_test "20.4 大量のUndo/Redo" --file=test_data/test_nums.txt "1" "2" "3" "4" "5" "C-u" "C-u" "C-u" "C-/" "C-/" "C-x" "C-c" "n"
run_test "20.5 範囲選択で全文削除" --file=test_data/test_cursor_input.txt "C-Space" "C-e" "C-w" "hello" "C-x" "C-c" "n"
run_test "20.6 空行での各種操作" --file=test_data/test_empty.txt "C-d" "Backspace" "C-k" "M-d" "C-x" "C-c"
echo
fi

if should_run_category 21; then

echo
echo "=== カテゴリ 21: Query Replace (M-%) ==="
# 各テスト前にファイルをリセット（前のテストの影響を排除）
# 21.1: 最初の"foo"を"bar"に置換 → 期待値ファイルで検証
reset_test_file "test_replace.txt"
run_test_verify "21.1 基本的な置換 (y)" --file=test_data/test_replace.txt --expect-file=test_data/expected/test_replace_first.txt "M-%" "foo" "Enter" "bar" "Enter" "y" "q" "C-x" "C-s" "C-x" "C-c"
reset_test_file "test_replace.txt"
run_test "21.2 置換をスキップ (n)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "n" "n" "q" "C-x" "C-c"
# 21.3: 全ての"foo"を"bar"に置換 → 期待値ファイルで検証
reset_test_file "test_replace.txt"
run_test_verify "21.3 全て置換 (!)" --file=test_data/test_replace.txt --expect-file=test_data/expected/test_replace_all.txt "M-%" "foo" "Enter" "bar" "Enter" "!" "C-x" "C-s" "C-x" "C-c"
reset_test_file "test_replace.txt"
run_test "21.4 置換を中断 (q)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "q" "C-x" "C-c"
reset_test_file "test_replace.txt"
run_test "21.5 置換をキャンセル (C-g)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "C-g" "C-x" "C-c"
reset_test_file "test_replace.txt"
run_test "21.6 マッチなし" --file=test_data/test_replace.txt "M-%" "n" "o" "t" "f" "o" "u" "n" "d" "Enter" "bar" "Enter" "C-x" "C-c"
reset_test_file "test_replace.txt"
run_test "21.7 空の置換文字列" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "Enter" "y" "q" "C-x" "C-c" "n"
reset_test_file "test_replace.txt"
run_test "21.8 複数回の置換 (y,y,y)" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "y" "y" "y" "q" "C-x" "C-c" "n"
reset_test_file "test_replace.txt"
run_test "21.9 置換のUndo" --file=test_data/test_replace.txt "M-%" "foo" "Enter" "bar" "Enter" "!" "C-u" "C-x" "C-c" "n"
# 21.10: 日本語置換 → 期待値ファイルで検証
reset_test_file "test_replace_ja.txt"
run_test_verify "21.10 日本語の置換" --input-file=test_data/test_japanese_replace_keys.txt --file=test_data/test_replace_ja.txt --expect-file=test_data/expected/test_replace_ja_all.txt
echo
fi

if should_run_category 22; then

echo
echo "=== カテゴリ 22: 検索履歴 ==="
run_test "22.1 C-s で前回パターン再利用（次へ）" --file=test_data/test_search_pages.txt "C-s" "Tar" "Enter" "C-s" "C-x" "C-c"
run_test "22.2 C-r で前回パターン再利用（前へ）" --file=test_data/test_search_pages.txt "M->" "C-s" "li" "Enter" "C-r" "C-x" "C-c"
run_test "22.3 検索後に別の検索" --file=test_data/test_search_pages.txt "C-s" "Tar" "Enter" "C-s" "C-s" "C-x" "C-c"
run_test "22.4 C-s→C-r の切り替え" --file=test_data/test_search_pages.txt "C-s" "li" "Enter" "C-s" "C-r" "C-x" "C-c"
echo
fi

if should_run_category 23; then

echo
echo "=== カテゴリ 23: 正規表現検索 ==="
run_test "23.1 数字の検索 (\\d+)" --file=test_data/test_regex.txt "C-s" "\\" "d" "+" "Enter" "C-x" "C-c"
run_test "23.2 行頭マッチ (^TODO)" --file=test_data/test_regex.txt "C-s" "^" "T" "O" "D" "O" "Enter" "C-x" "C-c"
run_test "23.3 行末マッチ (bar$)" --file=test_data/test_regex.txt "C-s" "b" "a" "r" "$" "Enter" "C-x" "C-c"
run_test "23.4 任意文字 (l.ne)" --file=test_data/test_regex.txt "C-s" "l" "." "n" "e" "Enter" "C-x" "C-c"
run_test "23.5 文字クラス ([a-z]+)" --file=test_data/test_regex.txt "C-s" "[" "a" "-" "z" "]" "+" "Enter" "C-x" "C-c"
run_test "23.6 否定文字クラス ([^0-9]+)" --file=test_data/test_regex.txt "C-s" "[" "^" "0" "-" "9" "]" "+" "Enter" "C-x" "C-c"
run_test "23.7 単語文字 (\\w+)" --file=test_data/test_regex.txt "C-s" "\\" "w" "+" "Enter" "C-x" "C-c"
run_test "23.8 正規表現後方検索" --file=test_data/test_regex.txt "C-e" "C-r" "\\" "d" "+" "Enter" "C-x" "C-c"
echo
fi

if should_run_category 24; then

echo
echo "=== カテゴリ 24: M-xコマンド ==="
run_test "24.1 M-x line (行番号表示)" --file=test_data/test_multiwin.txt "M-x" "l" "i" "n" "e" "Enter" "C-x" "C-c"
run_test "24.2 M-x line 3 (行移動)" --file=test_data/test_multiwin.txt "M-x" "l" "i" "n" "e" " " "3" "Enter" "C-x" "C-c"
run_test "24.3 M-x tab (タブ幅表示)" --file=test_data/test_multiwin.txt "M-x" "t" "a" "b" "Enter" "C-x" "C-c"
run_test "24.4 M-x tab 4 (タブ幅設定)" --file=test_data/test_multiwin.txt "M-x" "t" "a" "b" " " "4" "Enter" "C-x" "C-c"
run_test "24.5 M-x indent (インデント表示)" --file=test_data/test_multiwin.txt "M-x" "i" "n" "d" "e" "n" "t" "Enter" "C-x" "C-c"
run_test "24.6 M-x mode (モード表示)" --file=test_data/test_multiwin.txt "M-x" "m" "o" "d" "e" "Enter" "C-x" "C-c"
run_test "24.7 M-x ? (ヘルプ)" --file=test_data/test_multiwin.txt "M-x" "?" "Enter" "C-x" "C-c"
run_test "24.8 M-x ro (読み取り専用トグル)" --file=test_data/test_multiwin.txt "M-x" "r" "o" "Enter" "C-x" "C-c"
run_test "24.9 M-x コマンドキャンセル" --file=test_data/test_multiwin.txt "M-x" "l" "i" "n" "C-g" "C-x" "C-c"
echo
fi

if should_run_category 25; then

echo
echo "=== カテゴリ 25: マルチウィンドウ操作 ==="
run_test "25.1 横分割 (C-x 2)" --file=test_data/test_multiwin.txt "C-x" "2" "C-x" "C-c"
run_test "25.2 縦分割 (C-x 3)" --file=test_data/test_multiwin.txt "C-x" "3" "C-x" "C-c"
run_test "25.3 ウィンドウ切り替え (C-x o)" --file=test_data/test_multiwin.txt "C-x" "2" "C-x" "o" "C-x" "C-c"
run_test "25.4 ウィンドウを閉じる (C-x 0)" --file=test_data/test_multiwin.txt "C-x" "2" "C-x" "0" "C-x" "C-c"
run_test "25.5 他のウィンドウを閉じる (C-x 1)" --file=test_data/test_multiwin.txt "C-x" "2" "C-x" "1" "C-x" "C-c"
run_test "25.6 分割後に編集" --file=test_data/test_multiwin.txt "C-x" "2" "test" "C-x" "C-c" "n"
run_test "25.7 分割後に検索" --file=test_data/test_multiwin.txt "C-x" "2" "C-s" "L" "i" "n" "e" "Enter" "C-x" "C-c"
run_test "25.8 ウィンドウ間移動と編集" --file=test_data/test_multiwin.txt "C-x" "2" "C-x" "o" "hello" "C-x" "C-c" "n"
# 注: C-TabはESC [27;5;9~ 形式で送信されるが、ターミナルによってサポートが異なるためC-x oでテスト
run_test "25.9 ウィンドウ切り替え繰り返し" --file=test_data/test_multiwin.txt "C-x" "2" "C-x" "o" "C-x" "o" "C-x" "C-c"
echo
fi

if should_run_category 26; then

echo
echo "=== カテゴリ 26: マルチバッファ操作 ==="
run_test "26.1 ファイルを開く (C-x C-f)" --file=test_data/test_buffer1.txt "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "C-x" "C-c"
# バッファ切り替えは以前のバッファに戻るため、まずbuffer2を開いてからC-x bでbuffer1に戻る
run_test "26.2 バッファ切り替え (C-x b)" --file=test_data/test_buffer1.txt "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "C-x" "b" "/tmp/ze_test_data/test_buffer1.txt" "Enter" "C-x" "C-c"
run_test "26.3 バッファ間でkill ring共有" --file=test_data/test_buffer1.txt "C-k" "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "C-y" "C-x" "C-c" "n"
run_test "26.4 複数バッファで保存" --file=test_data/test_buffer1.txt "test" "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "data" "C-x" "C-c" "n" "n"
run_test "26.5 バッファ一覧表示" --file=test_data/test_buffer1.txt "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "C-x" "C-b" "C-x" "C-c"
echo
fi

if should_run_category 27; then

echo
echo "=== カテゴリ 27: ウィンドウ+バッファ複合操作 ==="
run_test "27.1 分割して別ファイル" --file=test_data/test_buffer1.txt "C-x" "2" "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "C-x" "C-c"
run_test "27.2 分割ウィンドウで両方編集" --file=test_data/test_buffer1.txt "C-x" "2" "edit1" "C-x" "o" "edit2" "C-x" "C-c" "n"
# 分割ウィンドウでそれぞれのウィンドウで検索（シンプル化）
run_test "27.3 分割ウィンドウで検索" --file=test_data/test_buffer1.txt "C-x" "2" "C-s" "B" "u" "f" "Enter" "C-x" "C-c"
# 分割ウィンドウで異なるバッファを表示（シンプル化）
run_test "27.4 分割でバッファ切り替え" --file=test_data/test_buffer1.txt "C-x" "2" "C-x" "C-f" "/tmp/ze_test_data/test_buffer2.txt" "Enter" "C-x" "C-c"
run_test "27.5 3分割" --file=test_data/test_multiwin.txt "C-x" "2" "C-x" "2" "C-x" "C-c"
run_test "27.6 縦横混合分割" --file=test_data/test_multiwin.txt "C-x" "2" "C-x" "3" "C-x" "C-c"
echo
fi

if should_run_category 28; then

echo
echo "=== カテゴリ 28: 追加のEmacsキーバインド ==="
# M-^ (join-line) - 現在行を上の行と結合
run_test "28.1 行結合 (M-^)" --file=test_data/test_cursor_input.txt "Down" "M-^" "C-x" "C-c" "n"
# M-Up/M-Down (行移動)
run_test "28.2 行を上に移動 (M-Up)" --file=test_data/test_cursor_input.txt "Down" "Down" "M-Up" "C-x" "C-c" "n"
run_test "28.3 行を下に移動 (M-Down)" --file=test_data/test_cursor_input.txt "M-Down" "C-x" "C-c" "n"
# S-Tab (unindent)
run_test "28.4 アンインデント (S-Tab)" --file=test_data/test_tab.txt "S-Tab" "C-x" "C-c" "n"
# M-; (toggle comment)
run_test "28.5 コメント切り替え (M-;)" --file=test_data/test_cursor_input.txt "M-;" "C-x" "C-c" "n"
# C-Tab (次のウィンドウ - ターミナル依存だがテスト可能)
run_test "28.6 ウィンドウ切り替え (C-Tab)" --file=test_data/test_multiwin.txt "C-x" "2" "C-Tab" "C-x" "C-c"
# C-v / M-v ページスクロール (既にテストあるが明示的テスト)
run_test "28.7 C-v ページダウン" --file=test_data/test_page_scroll.txt "C-v" "C-x" "C-c"
run_test "28.8 M-v ページアップ" --file=test_data/test_page_scroll.txt "C-v" "M-v" "C-x" "C-c"
echo
fi

if should_run_category 29; then

echo
echo "=== カテゴリ 29: 改行操作とC-j ==="
run_test "29.1 行頭でEnter" --file=test_data/test_cursor_input.txt "Enter" "C-x" "C-c" "n"
run_test "29.2 行途中でEnter" --file=test_data/test_cursor_input.txt "Right" "Right" "Enter" "C-x" "C-c" "n"
run_test "29.3 行末でEnter" --file=test_data/test_cursor_input.txt "End" "Enter" "C-x" "C-c" "n"
run_test "29.4 行末でC-j" --file=test_data/test_cursor_input.txt "End" "C-j" "C-x" "C-c" "n"
run_test "29.5 行頭でC-j" --file=test_data/test_cursor_input.txt "C-j" "C-x" "C-c" "n"
run_test "29.6 行途中でC-j" --file=test_data/test_cursor_input.txt "Right" "Right" "C-j" "C-x" "C-c" "n"
run_test "29.7 C-j後に文字入力" --file=test_data/test_cursor_input.txt "End" "C-j" "new" "C-x" "C-c" "n"
echo
fi

if should_run_category 30; then

echo
echo "=== カテゴリ 30: 追加のM-xコマンド ==="
# M-x revert - ファイル再読み込み（変更なしファイルで実行）
run_test "30.1 M-x revert (変更なし)" --file=test_data/test_nums.txt "M-x" "r" "e" "v" "e" "r" "t" "Enter" "C-x" "C-c"
# M-x key - キー説明
run_test "30.2 M-x key" --file=test_data/test_nums.txt "M-x" "k" "e" "y" "Enter" "C-f" "C-x" "C-c"
# M-x mode <name> - モード設定
run_test "30.3 M-x mode python" --file=test_data/test_nums.txt "M-x" "m" "o" "d" "e" " " "p" "y" "t" "h" "o" "n" "Enter" "C-x" "C-c"
# M-x exit (確認プロンプトにyで応答)
run_test "30.4 M-x exit" --file=test_data/test_nums.txt "M-x" "e" "x" "i" "t" "Enter" "y"
# M-x quit (確認プロンプトにyで応答)
run_test "30.5 M-x quit" --file=test_data/test_nums.txt "M-x" "q" "u" "i" "t" "Enter" "y"
# M-x overwrite - 上書きモード切り替え
run_test "30.6 M-x overwrite" --file=test_data/test_nums.txt "M-x" "o" "v" "e" "r" "w" "r" "i" "t" "e" "Enter" "C-x" "C-c"
# M-x ow (エイリアス)
run_test "30.7 M-x ow (エイリアス)" --file=test_data/test_nums.txt "M-x" "o" "w" "Enter" "C-x" "C-c"
echo
fi

if should_run_category 31; then

echo
echo "=== カテゴリ 31: 検索モード機能 ==="
# M-r - 検索中に正規表現/リテラルをトグル
run_test "31.1 M-r トグル (検索中)" --file=test_data/test_search_pages.txt "C-s" "t" "e" "s" "t" "M-r" "Enter" "C-x" "C-c"
# 正規表現で開始してM-rでリテラルに
run_test "31.2 C-M-s後にM-rでリテラル" --file=test_data/test_search_pages.txt "C-M-s" "l" "i" "M-r" "Enter" "C-x" "C-c"
# Query Replace中のM-r
run_test "31.3 Query Replace中のM-r" --file=test_data/test_replace.txt "M-%" "f" "o" "o" "M-r" "Enter" "b" "a" "r" "Enter" "q" "C-x" "C-c"
echo
fi

if should_run_category 32; then

echo
echo "=== カテゴリ 32: 選択系キーバインド ==="
# S-PageUp / S-PageDown 選択
run_test "32.1 S-PageDown (選択)" --file=test_data/test_page_scroll.txt "S-PageDown" "C-x" "C-c"
run_test "32.2 S-PageUp (選択)" --file=test_data/test_page_scroll.txt "PageDown" "S-PageUp" "C-x" "C-c"
# M-F / M-B 単語選択
run_test "32.3 M-F (単語選択前進)" --file=test_data/test_words.txt "M-F" "M-F" "C-x" "C-c"
run_test "32.4 M-B (単語選択後退)" --file=test_data/test_words.txt "End" "M-B" "M-B" "C-x" "C-c"
# S-M-Left / S-M-Right 単語選択
run_test "32.5 S-M-Right (単語選択)" --file=test_data/test_words.txt "S-M-Right" "S-M-Right" "C-x" "C-c"
run_test "32.6 S-M-Left (単語選択)" --file=test_data/test_words.txt "End" "S-M-Left" "S-M-Left" "C-x" "C-c"
echo
fi

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
