#!/bin/bash
# build_release.sh - 複数アーキテクチャ向けリリースビルド

set -e

VERSION="${1:-1.0.2}"
TARGETS=(
    "aarch64-macos"      # darwin-arm64
    "x86_64-macos"       # darwin-amd64
    "aarch64-linux"      # linux-arm64
    "x86_64-linux"       # linux-amd64
)

echo "Building ze v$VERSION for multiple platforms..."

rm -rf dist
mkdir -p dist

for target in "${TARGETS[@]}"; do
    echo ""
    echo "=== Building for $target ==="
    zig build -Doptimize=ReleaseFast -Dtarget=$target

    # ターゲット名を変換
    case $target in
        aarch64-macos) name="ze-darwin-arm64" ;;
        x86_64-macos)  name="ze-darwin-amd64" ;;
        aarch64-linux) name="ze-linux-arm64" ;;
        x86_64-linux)  name="ze-linux-amd64" ;;
    esac

    # tarballに固めてzeという名前でアーカイブ
    mkdir -p "dist/tmp"
    cp zig-out/bin/ze "dist/tmp/ze"
    tar -czvf "dist/$name.tar.gz" -C dist/tmp ze
    rm -rf "dist/tmp"

    echo "Created: dist/$name.tar.gz"
done

# SHA256を計算
echo ""
echo "=== Checksums ==="
cd dist
shasum -a 256 *.tar.gz | tee checksums.txt

echo ""
echo "Done! Upload these files to GitHub Release:"
ls -la
