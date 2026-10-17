#!/bin/bash
set -e

########################################
# CONFIG
########################################

CONFIG_DIR="$HOME/.config/ffmpegconvert"
CONFIG_FILE="$CONFIG_DIR/install-resolve.conf"
MANIFEST_FILE="$CONFIG_DIR/manifest-resolve.txt"

mkdir -p "$CONFIG_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SOURCE="$SCRIPT_DIR/release/ffmpegconvert-resolve.sh"

shopt -s nullglob
DESKTOP_FILES=("$SCRIPT_DIR"/release/servicemenus/ffmpegconvert-resolve.desktop)

DEFAULT_SCRIPT_DIR="$HOME/.local/bin"
DEFAULT_SCRIPT_PATH="$HOME/.local/bin/ffmpegconvert-resolve.sh"

USER_DIR="$HOME/.local/share/kio/servicemenus"
SYSTEM_DIR="/usr/share/kio/servicemenus"

########################################
# SAFETY CHECK
########################################

if [ ! -f "$SCRIPT_SOURCE" ]; then
    echo "ERROR: ffmpegconvert-resolve.sh must be next to installer"
    exit 1
fi

########################################
# MODE
########################################

MODE="$1"

if [ "$MODE" == "--install" ]; then
    UNINSTALL=0
elif [ "$MODE" == "--uninstall" ]; then
    UNINSTALL=1
else
    [ -f "$CONFIG_FILE" ] && UNINSTALL=1 || UNINSTALL=0
fi

########################################
# HELPERS
########################################

ask() { read -rp "$1 " r; echo "$r"; }
confirm() { read -rp "$1 [y/N]: " r; [[ "$r" =~ ^[Yy]$ ]]; }

run_rm() {
    if [ "$USE_SUDO" -eq 1 ]; then
        sudo rm -f -- "$1"
    else
        rm -f -- "$1"
    fi
}

refresh_kde() {
    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    elif command -v kbuildsycoca5 >/dev/null 2>&1; then
        kbuildsycoca5 --noincremental >/dev/null 2>&1 || true
    fi

    # extra safety: restart cache daemon (important on Plasma 5/6 edge cases)
    kquitapp6 kded6 >/dev/null 2>&1 || true
    kquitapp5 kded5 >/dev/null 2>&1 || true
}

########################################
# DEPENDENCIES
########################################

command -v ffmpeg >/dev/null 2>&1 || missing_ffmpeg=1
command -v ffprobe >/dev/null 2>&1 || missing_ffmpeg=1
command -v zenity >/dev/null 2>&1 || missing_zenity=1

########################################
# LOAD CONFIG (uninstall)
########################################

if [ "$UNINSTALL" -eq 1 ] && [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

########################################
# UNINSTALL
########################################

if [ "$UNINSTALL" -eq 1 ]; then

    echo "========================================"
    echo "FFMPEG CONVERT UNINSTALL"
    echo "========================================"
    echo

    echo "Script:"
    echo "  $SCRIPT_PATH"
    echo
    echo "Target directory:"
    echo "  $TARGET_DIR"
    echo

    confirm "Continue uninstall?" || exit 0

    echo
    echo "Removing script..."
    run_rm "$SCRIPT_PATH"

    echo
    echo "Removing service menus..."

    REMOVED=0
    FAILED=0

    ########################################
    # PRIMARY: manifest-based removal
    ########################################

    if [ -f "$MANIFEST_FILE" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            echo "Deleting: $f"
            run_rm "$f"

            if [ -e "$f" ]; then
                echo "❌ FAILED: $f"
                FAILED=1
            else
                REMOVED=1
            fi
        done < "$MANIFEST_FILE"
    fi

    ########################################
    # FALLBACK: directory scan (IMPORTANT FIX)
    ########################################

    echo
    echo "Fallback scan of servicemenus..."

    for f in "$TARGET_DIR"/ffmpegconvert-resolve.desktop; do
        [ -e "$f" ] || continue
        echo "Deleting (scan): $f"
        run_rm "$f"

        if [ -e "$f" ]; then
            echo "❌ FAILED: $f"
            FAILED=1
        fi
    done

    ########################################
    # KDE REFRESH (CRITICAL)
    ########################################

    echo
    echo "Refreshing KDE cache..."
    refresh_kde

    ########################################
    # VERIFY REAL STATE (NOT CONFIG)
    ########################################

    echo
    echo "Verifying..."

    STILL_EXISTS=0

    for f in "$TARGET_DIR"/ffmpegconvert-resolve.desktop; do
        if [ -e "$f" ]; then
            echo "❌ STILL EXISTS: $f"
            STILL_EXISTS=1
        fi
    done

    echo
    if [ "$STILL_EXISTS" -eq 0 ]; then
        echo "✔ All servicemenus removed from filesystem"
    else
        echo "⚠ Some files still remain (permissions or KDE lock issue)"
        echo "Try: logout/login or reboot"
    fi

    ########################################
    # CLEANUP
    ########################################

    rm -f "$CONFIG_FILE" "$MANIFEST_FILE"

    echo
    echo "✔ Uninstall complete"
    exit 0
fi

########################################
# INSTALL
########################################

echo "Install scope:"
echo "1) User"
echo "2) System"

choice=$(ask "Select [1-2]:")

if [ "$choice" == "2" ]; then
    TARGET_DIR="$SYSTEM_DIR"
    USE_SUDO=1
else
    TARGET_DIR="$USER_DIR"
    USE_SUDO=0
fi

# IMPORTANT FIX
mkdir -p "$TARGET_DIR"
mkdir -p "$USER_DIR"

########################################
# SCRIPT INSTALL
########################################

echo "Script location (default: $DEFAULT_SCRIPT_DIR)"
custom=$(ask "Custom path (Enter = default):")

if [ -z "$custom" ]; then
    SCRIPT_DEST="$DEFAULT_SCRIPT_PATH"
else
    SCRIPT_DEST="$custom/ffmpegconvert-resolve.sh"
    mkdir -p "$custom"
fi

mkdir -p "$(dirname "$SCRIPT_DEST")"

cp "$SCRIPT_SOURCE" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"

########################################
# INSTALL DESKTOP FILES
########################################

echo "Installing service menus → $TARGET_DIR"

> "$MANIFEST_FILE"

for file in "${DESKTOP_FILES[@]}"; do
    name=$(basename "$file")
    tmp="/tmp/$name"

    cp "$file" "$tmp"
    sed -i "s|Exec=.*ffmpegconvert-resolve.sh|Exec=$SCRIPT_DEST|g" "$tmp"

    dest="$TARGET_DIR/$name"

    if [ "$USE_SUDO" -eq 1 ]; then
        sudo cp "$tmp" "$dest"
        sudo chmod +x "$dest"
    else
        cp "$tmp" "$dest"
        chmod +x "$dest"
    fi

    echo "$dest" >> "$MANIFEST_FILE"
    rm -f "$tmp"
done

########################################
# KDE REFRESH
########################################

refresh_kde

########################################
# SAVE CONFIG
########################################

cat > "$CONFIG_FILE" <<EOF
SCRIPT_PATH="$SCRIPT_DEST"
TARGET_DIR="$TARGET_DIR"
USE_SUDO="$USE_SUDO"
EOF

echo
echo "✔ Installation complete"
