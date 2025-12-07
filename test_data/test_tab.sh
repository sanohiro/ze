#!/bin/bash
# タブ文字の基本動作テスト

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ビルド
echo "ビルド中..."
zig build -Doptimize=ReleaseSafe 2>&1 | grep -v "warning" || true

# テストファイルのクリーンアップ
rm -f /tmp/ze_tab_test.txt

echo ""
echo "========================================="
echo "タブ文字の基本動作テスト"
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
# テスト1: タブ文字の基本入力と保存
# ========================================
echo "カテゴリ 1: タブ文字の基本入力と保存"
echo "-----------------------------------"

# 1-1: タブ文字を入力して保存
run_test "1-1: タブ文字の入力と保存" bash -c '
    zig run test_harness_generic.zig -lc -- \
        "a" "Tab" "b" "Tab" "c" \
        "C-x" "C-s" "/tmp/ze_tab_test.txt" "Enter" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "a	b	c" /tmp/ze_tab_test.txt
'

# 1-2: 複数行にタブ文字
run_test "1-2: 複数行のタブ文字" bash -c '
    zig run test_harness_generic.zig -lc -- \
        "a" "Tab" "b" "Enter" \
        "1" "Tab" "2" \
        "C-x" "C-s" "/tmp/ze_tab_test.txt" "Enter" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "a	b" /tmp/ze_tab_test.txt &&
    grep -q "1	2" /tmp/ze_tab_test.txt
'

echo ""

# ========================================
# テスト2: タブ文字上のカーソル移動
# ========================================
echo "カテゴリ 2: タブ文字上のカーソル移動"
echo "-----------------------------------"

# 2-1: タブ文字を含む行でC-f（右移動）
run_test "2-1: タブ文字上でC-f（右移動）" bash -c '
    cat > /tmp/ze_tab_test.txt << "EOF"
a	b	c
EOF

    # ファイルを開く → C-f で移動 → タブを飛び越えて"b"の位置へ → "X"を挿入
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_tab_test.txt \
        "C-f" "C-f" "X" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "a	Xb	c" /tmp/ze_tab_test.txt
'

# 2-2: タブ文字を含む行でC-b（左移動）
run_test "2-2: タブ文字上でC-b（左移動）" bash -c '
    cat > /tmp/ze_tab_test.txt << "EOF"
a	b	c
EOF

    # ファイルを開く → 行末へ → C-b で移動 → タブを飛び越える
    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_tab_test.txt \
        "C-e" "C-b" "C-b" "C-b" "X" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "a	Xb	c" /tmp/ze_tab_test.txt
'

# 2-3: タブ文字を含む行でC-a, C-e（行頭・行末移動）
run_test "2-3: タブ文字を含む行でC-a, C-e" bash -c '
    cat > /tmp/ze_tab_test.txt << "EOF"
a	b	c
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_tab_test.txt \
        "C-e" "X" "C-a" "Y" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "Ya	b	cX" /tmp/ze_tab_test.txt
'

echo ""

# ========================================
# テスト3: タブ文字の削除
# ========================================
echo "カテゴリ 3: タブ文字の削除"
echo "-----------------------------------"

# 3-1: C-dでタブ文字を削除
run_test "3-1: C-dでタブ文字を削除" bash -c '
    cat > /tmp/ze_tab_test.txt << "EOF"
a	b
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_tab_test.txt \
        "C-a" "C-f" "C-d" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "^ab$" /tmp/ze_tab_test.txt
'

# 3-2: Backspaceでタブ文字を削除
run_test "3-2: Backspaceでタブ文字を削除" bash -c '
    cat > /tmp/ze_tab_test.txt << "EOF"
a	b
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_tab_test.txt \
        "C-a" "C-f" "C-f" "Backspace" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "^ab$" /tmp/ze_tab_test.txt
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
rm -f /tmp/ze_tab_test.txt /tmp/test_output.txt

if [ $FAILED -eq 0 ]; then
    echo "✓ 全テスト成功！"
    exit 0
else
    echo "✗ 一部のテストが失敗しました"
    exit 1
fi
