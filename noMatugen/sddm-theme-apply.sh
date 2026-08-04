#!/bin/bash

set -euo pipefail

# This script is installed ROOT-OWNED, outside the user's home, because a
# sudoers rule names it NOPASSWD and sudo matches by PATH, not by owner: a rule
# pointing at a user-writable file is functionally NOPASSWD: ALL. So the script's
# own location is deliberately NOT where its data lives - every input below is
# read from $SRC (the user's config dir) rather than from alongside the script.
# Do not reintroduce a SCRIPT_DIR-relative read here.

# === The invoking user, not root ===
# Run through sudo, so $USER is root and $HOME is /root; SUDO_USER is the human.
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~$REAL_USER")"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    echo "❌ Error: invalid user home directory for '$REAL_USER'" >&2
    exit 1
fi

# === SDDM install destination ===
# Must match THEME_NAME in setup.sh. Left at the pre-fork name through the
# becaa77 rename, this wrote into the legacy directory that the same install run
# then deleted, so the background never reached the installed theme.
THEME_NAME="${THEME_NAME:-imi-sddm-theme}"
SRC="$USER_HOME/.config/$THEME_NAME"
DEST="/usr/share/sddm/themes/$THEME_NAME"

if [ ! -d "$SRC" ]; then
    echo "❌ Error: source directory not found: $SRC" >&2
    exit 1
fi

# === Validate function ===
validate_path() {
    local path="$1"
    local type_name="$2"
    
    if [ ! -e "$path" ]; then
        echo "❌ Error: $type_name not found: $path" >&2
        return 1
    fi
    if [ -L "$path" ]; then
        echo "❌ Error: $type_name is a symbolic link (not allowed): $path" >&2
        return 1
    fi
    echo "$path"
    return 0
}

echo "🔍 Searching for background file in $SRC ..."

# === Locate wallpaper in the user's config directory ===
shopt -s nullglob
wallpapers=( "$SRC"/background.* )
shopt -u nullglob

if [ ${#wallpapers[@]} -eq 0 ]; then
    echo "❌ No 'background.*' file found in $SRC."
    echo "➡️ Please place an image or video named **background** in that directory."
    echo "   Example: background.png, background.jpg, background.mp4"
    exit 3
fi

WALLPAPER_PATH="${wallpapers[0]}"
WALLPAPER_PATH=$(validate_path "$WALLPAPER_PATH" "Wallpaper") || exit 5

echo "✅ Found wallpaper: $WALLPAPER_PATH"

# === Determine extension ===
WALLPAPER_EXT="${WALLPAPER_PATH##*.}"
WALLPAPER_EXT_LOWER=$(echo "$WALLPAPER_EXT" | tr '[:upper:]' '[:lower:]')

IMAGE_EXTS=("png" "jpg" "jpeg" "webp" "gif")
VIDEO_EXTS=("mp4" "mov" "mkv" "webm" "m4v")

IS_IMAGE=false
IS_VIDEO=false

for ext in "${IMAGE_EXTS[@]}"; do [[ "$WALLPAPER_EXT_LOWER" == "$ext" ]] && IS_IMAGE=true; done
for ext in "${VIDEO_EXTS[@]}"; do [[ "$WALLPAPER_EXT_LOWER" == "$ext" ]] && IS_VIDEO=true; done

if ! $IS_IMAGE && ! $IS_VIDEO; then
    echo "❌ Unsupported wallpaper format: .$WALLPAPER_EXT_LOWER"
    exit 6
fi

BACKGROUND_FILENAME="background.${WALLPAPER_EXT_LOWER}"
BACKGROUND_SOURCE="$WALLPAPER_PATH"

# === Validate config file ===
CONF_FILE="$SRC/ii-sddm.conf"
CONF_FILE=$(validate_path "$CONF_FILE" "Configuration file") || exit 9

# === Modify config depending on image or video ===
if $IS_IMAGE; then
    echo "🖼️ Detected wallpaper type: image"
    sed -i -E \
        -e "s|^BackgroundPlaceholder=\"[^\"]*\"|BackgroundPlaceholder=\"\"|" \
        -e "s|^Background=\"Backgrounds/[^\"]+\"|Background=\"Backgrounds/${BACKGROUND_FILENAME}\"|" \
        "$CONF_FILE"
else
    echo "🎥 Detected wallpaper type: video (thumbnail will be generated)"
    PLACEHOLDER="$SRC/placeholder.png"

    if ! command -v ffmpeg &> /dev/null; then
        echo "❌ ffmpeg not installed. Please install ffmpeg to use video wallpapers."
        exit 13
    fi

    ffmpeg -y -i "$WALLPAPER_PATH" -ss 00:00:01 -vframes 1 "$PLACEHOLDER" >/dev/null 2>&1

    sed -i -E \
        -e "s|^BackgroundPlaceholder=\"[^\"]*\"|BackgroundPlaceholder=\"Backgrounds/placeholder.png\"|" \
        -e "s|^Background=\"Backgrounds/[^\"]+\"|Background=\"Backgrounds/${BACKGROUND_FILENAME}\"|" \
        "$CONF_FILE"
fi

echo "📦 Installing theme files to SDDM..."

# Create destination directories
sudo mkdir -p "$DEST/Components" "$DEST/Backgrounds" "$DEST/Themes"

# Copy components and config
sudo cp "$SRC/Colors.qml" "$DEST/Components/"
sudo cp "$SRC/Settings.qml" "$DEST/Components/"
sudo cp "$BACKGROUND_SOURCE" "$DEST/Backgrounds/$BACKGROUND_FILENAME"
sudo cp "$CONF_FILE" "$DEST/Themes/ii-sddm.conf"

# Copy placeholder if video wallpaper
if $IS_VIDEO; then
    sudo cp "$PLACEHOLDER" "$DEST/Backgrounds/placeholder.png"
fi

# Permissions
sudo chmod 644 "$DEST/Components/"*.qml "$DEST/Backgrounds/"* "$DEST/Themes/ii-sddm.conf"

echo "✅ SDDM theme applied successfully!"
echo "📁 Destination: $DEST"
echo "🖼️ Background: $BACKGROUND_FILENAME"
$IS_VIDEO && echo "🖼️ Video thumbnail: placeholder.png"
echo "🎉 Done!"
