#!/usr/bin/env bash
set -e

SRC_DIR="$HOME/install-yolo/whls"
DST_DIR="$(pwd)/whls"

echo "📦 Copying whls from:"
echo "   $SRC_DIR"
echo "➡️  To:"
echo "   $DST_DIR"
echo

# Check if source directory exists
if [ ! -d "$SRC_DIR" ]; then
    echo "❌ Source directory not found: $SRC_DIR"
    exit 1
fi

# If destination already exists, ask for confirmation
if [ -d "$DST_DIR" ]; then
    echo "⚠️  The whls directory already exists in the current directory."
    read -p "👉 Overwrite it? (y/N): " ans
    if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
        echo "❌ Aborted."
        exit 0
    fi
    rm -rf "$DST_DIR"
fi

# Copy directory
cp -r "$SRC_DIR" "$DST_DIR"

echo "✅ Copy completed!"
ls -lh "$DST_DIR"
