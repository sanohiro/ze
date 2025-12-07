#!/bin/bash
# 複数バッファ/ウィンドウの包括的テストスイート

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# ビルド
echo "ビルド中..."
zig build -Doptimize=ReleaseSafe 2>&1 | grep -v "warning" || true

# テストファイルのクリーンアップ
cleanup() {
    rm -f /tmp/ze_multi_test*.txt /tmp/test_output.txt
}
cleanup

echo ""
echo "========================================="
echo "複数バッファ/ウィンドウの包括的テスト"
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
# カテゴリ 1: 複数バッファの基本操作
# ========================================
echo "カテゴリ 1: 複数バッファの基本操作"
echo "-----------------------------------"

# 1-1: 新規ファイルを作成してバッファ切り替え
run_test "1-1: 新規ファイル作成とバッファ切り替え" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
file1 content
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-e" " edited" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "file1 content edited" /tmp/ze_multi_test1.txt
'

# 1-2: C-x C-f で別ファイルを開く
run_test "1-2: C-x C-f で別ファイルを開く" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
buffer1
EOF
    cat > /tmp/ze_multi_test2.txt << "EOF"
buffer2
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "C-f" "/tmp/ze_multi_test2.txt" "Enter" \
        "C-e" " from2" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "buffer2 from2" /tmp/ze_multi_test2.txt
'

# 1-3: C-x C-b でバッファ一覧表示
run_test "1-3: C-x C-b でバッファ一覧表示" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
test
EOF

    zig run test_harness_generic.zig -lc -- \
        --show-output \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "C-b" \
        "C-x" "C-c" "n" 2>&1 | grep -q "Buffer"
'

echo ""

# ========================================
# カテゴリ 2: ウィンドウ分割の基本操作
# ========================================
echo "カテゴリ 2: ウィンドウ分割の基本操作"
echo "-----------------------------------"

# 2-1: C-x 2 で水平分割
run_test "2-1: C-x 2 で水平分割" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
horizontal split test
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-e" " done" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "horizontal split test done" /tmp/ze_multi_test1.txt
'

# 2-2: C-x 3 で垂直分割
run_test "2-2: C-x 3 で垂直分割" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
vertical split test
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "3" \
        "C-e" " done" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "vertical split test done" /tmp/ze_multi_test1.txt
'

# 2-3: C-x o でウィンドウ切り替え
run_test "2-3: C-x o でウィンドウ切り替え" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
window switch test
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-x" "o" \
        "C-e" " switched" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "window switch test switched" /tmp/ze_multi_test1.txt
'

# 2-4: C-x 0 でウィンドウを閉じる
run_test "2-4: C-x 0 でウィンドウを閉じる" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
close window test
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-x" "0" \
        "C-e" " closed" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "close window test closed" /tmp/ze_multi_test1.txt
'

echo ""

# ========================================
# カテゴリ 3: 同じバッファを複数ウィンドウで編集
# ========================================
echo "カテゴリ 3: 同じバッファを複数ウィンドウで編集"
echo "-----------------------------------"

# 3-1: 分割後、両ウィンドウで同じバッファを編集
run_test "3-1: 両ウィンドウで同じバッファを編集" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
shared buffer
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-a" "TOP " \
        "C-x" "o" \
        "C-e" " BOTTOM" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "TOP shared buffer BOTTOM" /tmp/ze_multi_test1.txt
'

# 3-2: 分割後、一方で編集し他方で確認
run_test "3-2: 一方で編集、他方で確認" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
line1
line2
line3
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-x" "o" \
        "C-n" "C-n" \
        "C-a" "EDITED " \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "EDITED line3" /tmp/ze_multi_test1.txt
'

echo ""

# ========================================
# カテゴリ 4: 異なるバッファを複数ウィンドウで編集
# ========================================
echo "カテゴリ 4: 異なるバッファを複数ウィンドウで編集"
echo "-----------------------------------"

# 4-1: 分割後、別のファイルを開いて編集
run_test "4-1: 分割後、別ファイルを開いて編集" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
file1
EOF
    cat > /tmp/ze_multi_test2.txt << "EOF"
file2
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-x" "o" \
        "C-x" "C-f" "/tmp/ze_multi_test2.txt" "Enter" \
        "C-e" " edited2" \
        "C-x" "C-s" \
        "C-x" "o" \
        "C-e" " edited1" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "file1 edited1" /tmp/ze_multi_test1.txt &&
    grep -q "file2 edited2" /tmp/ze_multi_test2.txt
'

# 4-2: 垂直分割で2つのファイルを同時編集
run_test "4-2: 垂直分割で2ファイル同時編集" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
left
EOF
    cat > /tmp/ze_multi_test2.txt << "EOF"
right
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "3" \
        "C-x" "o" \
        "C-x" "C-f" "/tmp/ze_multi_test2.txt" "Enter" \
        "C-e" " pane" \
        "C-x" "C-s" \
        "C-x" "o" \
        "C-e" " pane" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "left pane" /tmp/ze_multi_test1.txt &&
    grep -q "right pane" /tmp/ze_multi_test2.txt
'

echo ""

# ========================================
# カテゴリ 5: 基本編集操作（複数ウィンドウ環境）
# ========================================
echo "カテゴリ 5: 基本編集操作（複数ウィンドウ環境）"
echo "-----------------------------------"

# 5-1: 分割環境でのカーソル移動
run_test "5-1: 分割環境でカーソル移動" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
line1
line2
line3
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-n" "C-e" "X" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "line2X" /tmp/ze_multi_test1.txt
'

# 5-2: 分割環境での削除操作（C-d）
run_test "5-2: 分割環境で削除操作" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
delete this
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-a" "C-d" "C-d" "C-d" "C-d" "C-d" "C-d" "C-d" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "this" /tmp/ze_multi_test1.txt &&
    ! grep -q "delete" /tmp/ze_multi_test1.txt
'

# 5-3: 分割環境での複数行入力
run_test "5-3: 分割環境で複数行入力" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
original
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-e" "Enter" "new line" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "original" /tmp/ze_multi_test1.txt &&
    grep -q "new line" /tmp/ze_multi_test1.txt
'

# 5-4: 分割環境での検索
run_test "5-4: 分割環境で検索" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
find this word here
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-s" "word" "Enter" \
        "FOUND" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "FOUNDword" /tmp/ze_multi_test1.txt
'

echo ""

# ========================================
# カテゴリ 6: エッジケースと複合操作
# ========================================
echo "カテゴリ 6: エッジケースと複合操作"
echo "-----------------------------------"

# 6-1: 複数回分割
run_test "6-1: 複数回分割" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
multi split
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-x" "2" \
        "C-a" "1" \
        "C-x" "o" \
        "C-a" "2" \
        "C-x" "o" \
        "C-a" "3" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "321multi split" /tmp/ze_multi_test1.txt
'

# 6-2: 分割後にすべてのウィンドウを閉じる
run_test "6-2: 分割後に全ウィンドウを閉じる" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
close all
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-x" "0" \
        "C-e" " done" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "close all done" /tmp/ze_multi_test1.txt
'

# 6-3: 日本語を含むファイルの複数ウィンドウ編集
run_test "6-3: 日本語ファイルの複数ウィンドウ編集" bash -c '
    cat > /tmp/ze_multi_test1.txt << "EOF"
日本語テスト
EOF

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-e" "OK" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    grep -q "日本語テストOK" /tmp/ze_multi_test1.txt
'

# 6-4: タブ文字を含むファイルの複数ウィンドウ編集
run_test "6-4: タブ文字の複数ウィンドウ編集" bash -c '
    printf "a\tb\tc\n" > /tmp/ze_multi_test1.txt

    zig run test_harness_generic.zig -lc -- \
        --file=/tmp/ze_multi_test1.txt \
        "C-x" "2" \
        "C-e" "Tab" "d" \
        "C-x" "C-s" \
        "C-x" "C-c" 2>&1 > /dev/null &&
    xxd /tmp/ze_multi_test1.txt | grep -q "6109 6209 6309 640a"
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
cleanup

if [ $FAILED -eq 0 ]; then
    echo "✓ 全テスト成功！"
    exit 0
else
    echo "✗ 一部のテストが失敗しました"
    exit 1
fi
