#!/bin/bash
set -e

TMPDIR="$(mktemp -d /tmp/ffmpegconvert-resolve.XXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "[Remote Installer] Creating temp workspace..."
cd "$TMPDIR"

echo "[Remote Installer] Downloading repo..."
curl -fsSL \
  -o repo.zip \
  https://github.com/MetalMan1245/DaVinci-Resolve-Video-Converter-for-Dolphin-File-Manager/archive/refs/heads/main.zip

echo "[Remote Installer] Extracting..."
unzip -q repo.zip
cd DaVinci-Resolve-Video-Converter-for-Dolphin-File-Manager-main

echo "[Remote Installer] Running installer..."
chmod +x install_uninstall-resolve.sh
./install_uninstall-resolve.sh

echo "[Remote Installer] Done."
