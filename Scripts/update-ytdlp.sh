#!/bin/bash
# Downloads the latest standalone yt-dlp macOS universal binary.
# Saves it to Resources/yt-dlp so the build phase can bundle it.
# Run:  bash Scripts/update-ytdlp.sh

set -euo pipefail

REPO="yt-dlp/yt-dlp"
DEST="Resources/yt-dlp"

# yt-dlp_macos is a universal (Intel + Apple Silicon) executable
LATEST_URL="https://github.com/$REPO/releases/latest/download/yt-dlp_macos"

echo "==> Downloading latest yt-dlp (macOS universal) from $REPO ..."
curl -fL "$LATEST_URL" -o "$DEST.tmp"

chmod +x "$DEST.tmp"
mv "$DEST.tmp" "$DEST"

echo "==> Downloaded to $DEST"
"$DEST" --version
