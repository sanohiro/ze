#!/bin/bash
# テストファイルのセットアップスクリプト

# テストデータディレクトリ
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"

# 基本的なテストファイル
cat > "$TEST_DIR/test_nums.txt" << 'EOF'
1
2
3
4
5
EOF

cat > "$TEST_DIR/test_cursor_input.txt" << 'EOF'
First line for testing
Second line here
Third line content
EOF

cat > "$TEST_DIR/test_region.txt" << 'EOF'
Region test line one
Region test line two
Region test line three
EOF

cat > "$TEST_DIR/test_words.txt" << 'EOF'
hello world this is a test
EOF

cat > "$TEST_DIR/test_japanese.txt" << 'EOF'
日本語のテストです
これは二行目
三行目の内容
EOF

cat > "$TEST_DIR/test_emoji.txt" << 'EOF'
😀😁😂🤣
絵文字と日本語
EOF

cat > "$TEST_DIR/test_empty.txt" << 'EOF'
EOF

# 検索用のテストファイル
cat > "$TEST_DIR/test_search_pages.txt" << 'EOF'
Target line with search term
Another line here
More content
Target line again
Final line
EOF

# 長い行のテストファイル
python3 << 'PYEOF' > "$TEST_DIR/test_long_line.txt"
print('a' * 1000)
PYEOF

# 大量行のテストファイル
python3 << 'PYEOF' > "$TEST_DIR/test_999_lines.txt"
for i in range(1, 1000):
    print(f'Line {i}')
PYEOF

# 置換用のテストファイル
cat > "$TEST_DIR/test_replace.txt" << 'EOF'
foo is a test word.
This foo should be replaced.
Multiple foo foo foo here.
No match on this line.
Last foo here.
EOF

cat > "$TEST_DIR/test_replace_ja.txt" << 'EOF'
こんにちは、世界！
こんにちは、みなさん。
今日はこんにちは言う日です。
こんにちは、また会いましょう。
EOF

echo "テストファイルのセットアップが完了しました: $TEST_DIR"
