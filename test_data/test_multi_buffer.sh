#!/bin/bash
# 複数バッファ/ウィンドウ環境での基本動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ビルド
echo "ビルド中..."
zig build -Doptimize=ReleaseSafe 2>&1 | grep -v "warning" || true

# テストファイルのクリーンアップ
rm -f /tmp/ze_buffer_test1.txt /tmp/ze_buffer_test2.txt /tmp/ze_buffer_test3.txt

echo ""
echo "========================================="
echo "複数バッファ環境での基本動作テスト"
echo "========================================="
echo ""

# テストカウンター
TOTAL=0
PASSED=0
FAILED=0

# テスト関数
run_test() {
    local test_name="$1"
    shift
    echo -n "テスト: $test_name ... "
    TOTAL=$((TOTAL + 1))

    if "$@" > /tmp/test_output.txt 2>&1; then
        echo "✓ PASS"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo "✗ FAIL"
        FAILED=$((FAILED + 1))
        cat /tmp/test_output.txt
        return 1
    fi
}

# ========================================
# テスト1: 基本的なバッファ切り替え
# ========================================
echo "カテゴリ 1: 基本的なバッファ切り替え"
echo "-----------------------------------"

# 1-1: ファイル1を開いて編集、保存
run_test "1-1: ファイル1作成と編集" bash -c '
    zig run test_harness_generic.zig -lc -- \
        "C-x" "C-f" "/tmp/ze_buffer_test1.txt" "Enter" \
        "First buffer content" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "First buffer content" /tmp/ze_buffer_test1.txt
'

# 1-2: ファイル2を開いて編集、保存
run_test "1-2: ファイル2作成と編集" bash -c '
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "Second buffer content" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "Second buffer content" /tmp/ze_buffer_test2.txt
'

# 1-3: バッファ1に切り替えて内容を確認（追加編集）
run_test "1-3: バッファ1に切り替えて追加編集" bash -c '
    # まず、ファイル1とファイル2を準備
    echo "First buffer content" > /tmp/ze_buffer_test1.txt
    echo "Second buffer content" > /tmp/ze_buffer_test2.txt

    # ファイル1を開く → ファイル2を開く → ファイル1に戻って追加編集
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "C-x" "b" "/tmp/ze_buffer_test1.txt" "Enter" \
        "C-e" " - modified" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "First buffer content - modified" /tmp/ze_buffer_test1.txt
'

# 1-4: バッファ2に切り替えて内容を確認（追加編集）
run_test "1-4: バッファ2に切り替えて追加編集" bash -c '
    # ファイルを準備
    echo "First buffer content - modified" > /tmp/ze_buffer_test1.txt
    echo "Second buffer content" > /tmp/ze_buffer_test2.txt

    # ファイル1を開く → ファイル2を開く → ファイル2で追加編集
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "C-e" " - also modified" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "Second buffer content - also modified" /tmp/ze_buffer_test2.txt
'

echo ""

# ========================================
# テスト2: バッファ切り替え後の基本編集操作
# ========================================
echo "カテゴリ 2: バッファ切り替え後の基本編集操作"
echo "-----------------------------------"

# 2-1: カーソル移動（C-n, C-p, C-f, C-b）
run_test "2-1: バッファ切り替え後のカーソル移動" bash -c '
    cat > /tmp/ze_buffer_test1.txt << "EOF"
Line 1
Line 2
Line 3
EOF

    # ファイル1を開く → 新規バッファを開く → ファイル1に戻ってカーソル移動
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "dummy" \
        "C-x" "b" "/tmp/ze_buffer_test1.txt" "Enter" \
        "C-n" "C-n" "C-a" "Modified " \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "Modified Line 3" /tmp/ze_buffer_test1.txt
'

# 2-2: 文字挿入
run_test "2-2: バッファ切り替え後の文字挿入" bash -c '
    echo "Original" > /tmp/ze_buffer_test1.txt
    echo "Dummy" > /tmp/ze_buffer_test2.txt

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "C-x" "b" "/tmp/ze_buffer_test1.txt" "Enter" \
        "C-e" " Text Added" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "Original Text Added" /tmp/ze_buffer_test1.txt
'

# 2-3: 削除操作（C-d, C-k）
run_test "2-3: バッファ切り替え後の削除操作" bash -c '
    echo "Delete This Part" > /tmp/ze_buffer_test1.txt
    echo "Dummy" > /tmp/ze_buffer_test2.txt

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "C-x" "b" "/tmp/ze_buffer_test1.txt" "Enter" \
        "C-a" "C-d" "C-d" "C-d" "C-d" "C-d" "C-d" "C-d" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "This Part" /tmp/ze_buffer_test1.txt &&
    ! grep -q "Delete" /tmp/ze_buffer_test1.txt
'

echo ""

# ========================================
# テスト3: バッファごとの独立したUndo/Redo
# ========================================
echo "カテゴリ 3: バッファごとの独立したUndo/Redo"
echo "-----------------------------------"

# 3-1: バッファ1でUndo
run_test "3-1: バッファ1でUndoが動作" bash -c '
    echo "Original" > /tmp/ze_buffer_test1.txt

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-e" " Modified" \
        "C-u" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "^Original$" /tmp/ze_buffer_test1.txt &&
    ! grep -q "Modified" /tmp/ze_buffer_test1.txt
'

# 3-2: バッファ切り替え後のUndoが独立
run_test "3-2: 複数バッファでUndoが独立して動作" bash -c '
    echo "Buffer1" > /tmp/ze_buffer_test1.txt
    echo "Buffer2" > /tmp/ze_buffer_test2.txt

    # バッファ1で編集 → バッファ2で編集 → バッファ1に戻ってUndo
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-e" " Edit1" \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "C-e" " Edit2" \
        "C-x" "b" "/tmp/ze_buffer_test1.txt" "Enter" \
        "C-u" \
        "C-x" "C-s" \
        "C-x" "b" "/tmp/ze_buffer_test2.txt" "Enter" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "^Buffer1$" /tmp/ze_buffer_test1.txt &&
    grep -q "Buffer2 Edit2" /tmp/ze_buffer_test2.txt
'

# 3-3: Redo動作の確認
run_test "3-3: バッファ切り替え後のRedoが動作" bash -c '
    echo "Original" > /tmp/ze_buffer_test1.txt

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-e" " Modified" \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "dummy" \
        "C-x" "b" "/tmp/ze_buffer_test1.txt" "Enter" \
        "C-u" \
        "C-/" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "Original Modified" /tmp/ze_buffer_test1.txt
'

echo ""

# ========================================
# テスト4: 複雑なシナリオ
# ========================================
echo "カテゴリ 4: 複雑なシナリオ"
echo "-----------------------------------"

# 4-1: 3つのバッファを順番に切り替え
run_test "4-1: 3つのバッファを切り替えて編集" bash -c '
    # 3つのファイルを作成
    echo "File1" > /tmp/ze_buffer_test1.txt
    echo "File2" > /tmp/ze_buffer_test2.txt
    echo "File3" > /tmp/ze_buffer_test3.txt

    # ファイル1 → ファイル2 → ファイル3 → ファイル1に戻る
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-e" " A" \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "C-e" " B" \
        "C-x" "C-f" "/tmp/ze_buffer_test3.txt" "Enter" \
        "C-e" " C" \
        "C-x" "b" "/tmp/ze_buffer_test1.txt" "Enter" \
        "C-e" "A" \
        "C-x" "C-s" \
        "C-x" "b" "/tmp/ze_buffer_test2.txt" "Enter" \
        "C-x" "C-s" \
        "C-x" "b" "/tmp/ze_buffer_test3.txt" "Enter" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "File1 AA" /tmp/ze_buffer_test1.txt &&
    grep -q "File2 B" /tmp/ze_buffer_test2.txt &&
    grep -q "File3 C" /tmp/ze_buffer_test3.txt
'

# 4-2: バッファを閉じてから再度開く
run_test "4-2: バッファを閉じてから再度開いて編集" bash -c '
    echo "Original Content" > /tmp/ze_buffer_test1.txt

    # ファイルを開く → 閉じる → 再度開く → 編集
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_buffer_test1.txt \
        "C-x" "C-f" "/tmp/ze_buffer_test2.txt" "Enter" \
        "dummy" \
        "C-x" "b" "/tmp/ze_buffer_test1.txt" "Enter" \
        "C-e" " Modified" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "Original Content Modified" /tmp/ze_buffer_test1.txt
'

echo ""
echo "========================================="
echo "テスト結果サマリー"
echo "========================================="
echo "合計:   $TOTAL"
echo "成功:   $PASSED"
echo "失敗:   $FAILED"
echo ""

# クリーンアップ
rm -f /tmp/ze_buffer_test1.txt /tmp/ze_buffer_test2.txt /tmp/ze_buffer_test3.txt /tmp/test_output.txt

if [ $FAILED -eq 0 ]; then
    echo "✓ 全テスト成功！"
    exit 0
else
    echo "✗ 一部のテストが失敗しました"
    exit 1
fi
