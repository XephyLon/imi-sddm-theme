#!/usr/bin/env bash

set -euo pipefail

# --- Security: Validate and sanitize paths ---
validate_path() {
    local path="$1"
    local description="$2"

    # Check if path exists
    if [ ! -e "$path" ]; then
        echo "Error: $description not found: $path" >&2
        return 1
    fi

    # Check if it's a symbolic link (security risk)
    if [ -L "$path" ]; then
        echo "Error: $description is a symbolic link (not allowed): $path" >&2
        return 1
    fi

    # Resolve to absolute path
    realpath "$path"
}

# --- Local user name ---
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~$REAL_USER")"

# Validate USER_HOME
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    echo "Error: invalid user home directory" >&2
    exit 1
fi

# --- Directories ---
# This script is installed ROOT-OWNED, outside the user's home, because a
# sudoers rule names it NOPASSWD and sudo matches by PATH, not by owner: a rule
# pointing at a user-writable file is functionally NOPASSWD: ALL. So the script's
# own location is deliberately NOT where its data lives - every input below is
# read from $SRC (the user's config dir) rather than from alongside the script.
# Do not reintroduce a SCRIPT_DIR-relative read here.
# Must match THEME_NAME in setup.sh. This script is what actually copies the
# user's wallpaper, Colors.qml and Settings.qml into the installed theme, so a
# stale name here means a successful-looking install that never applies anything
# (it was left at the pre-fork name through the becaa77 rename).
THEME_NAME="${THEME_NAME:-imi-sddm-theme}"
SRC="$USER_HOME/.config/$THEME_NAME"
DEST="/usr/share/sddm/themes/$THEME_NAME"

# --- QML Sources ---
COLORS_QML_SOURCE="$SRC/Colors.qml"
SETTINGS_QML_SOURCE="$SRC/Settings.qml"

# Validate source directory
if [ ! -d "$SRC" ]; then
    echo "Error: source directory not found: $SRC" >&2
    exit 1
fi

# Validate destination parent directory
if [ ! -d "$(dirname "$(dirname "$DEST")")" ]; then
    echo "Error: invalid destination directory: $DEST" >&2
    exit 2
fi

# --- Extract wallpaper path ---
WALLPAPER_PATH=""

# Wallpaper Engine is resolved FIRST, not as a fallback.
#
# The earlier version of this only looked at Wallpaper Engine when
# background.wallpaperPath was empty, on the assumption that the shell clears
# that key while a WE wallpaper is active. It does not: WallpaperEngine.qml's
# apply() records the project and leaves background.wallpaperPath exactly as it
# was, so on any install that used a static wallpaper before switching to WE,
# both are set and the stale static path won. The greeter then showed whatever
# picture the user had chosen before, which reads as "the login screen ignores
# my wallpaper".
#
# The shell's own precedence is in modules/imi/background/Background.qml:
#   weActive: activePath !== "" && activeType.toLowerCase() !== "web"
# i.e. Wallpaper Engine wins whenever a project is set and it is not a "web"
# one, regardless of background.wallpaperPath. Mirror that here so the greeter
# and the desktop agree on which wallpaper is current.
#
# A "video" project is a plain video file, which this script already handles -
# it copies it in and has ffmpeg cut a poster frame for BackgroundPlaceholder.
# "scene" needs the Wallpaper Engine runtime, which the greeter does not have,
# so it gets the still the shell already renders. "web" needs CEF/Chromium and
# the shell itself falls back to the static wallpaper for it, so this does too.
if [ -f "$SETTINGS_QML_SOURCE" ]; then
    we_field() {
        grep -m1 "wallpaperSelector_wallpaperEngine_$1:" "$SETTINGS_QML_SOURCE" \
            | cut -d '"' -f 2 || true
    }
    we_type="$(we_field activeType | tr '[:upper:]' '[:lower:]')"
    we_dir="$(we_field activePath)"
    # The fallback. activePreview is written by WallpaperEngine.apply() on every
    # switch and always names the active project, at the cost of being a
    # preview-sized thumbnail rather than a full-resolution image.
    we_still="$(we_field activePreview)"
    # The shell caches a full-resolution still of the active project - it grabs
    # it off the live Wallpaper Engine surface, which it can do because the
    # renderer is embedded in the shell process; this script runs as root
    # through sudo and has neither a GPU session nor the shell to ask.
    #
    # DERIVED from activeProject, deliberately not read from a field. A stored
    # path is what immaterial-impulse#103 was about: nothing rewrote it, so it
    # froze at whatever project was active that day and the greeter served that
    # wallpaper for months. The stale values are still sitting in every saved
    # preset. A path computed from the project the config *currently* names
    # cannot disagree with that project - there is nothing to go stale.
    #
    # Absent is normal, not an error: no still exists until the wallpaper has
    # been applied at least once since the shell gained this, a stock Quickshell
    # build has no Wallpaper Engine module and never grabs one, and the greeter
    # falls back to the preview below in both cases.
    #
    # $HOME/.cache is assumed rather than XDG_CACHE_HOME resolved: sudo's
    # env_reset means the user's environment is not visible here, so a custom
    # XDG_CACHE_HOME simply misses and falls back to the preview.
    we_project="$(we_field activeProject)"
    we_native=""
    if [ -n "$we_project" ]; then
        we_native="$USER_HOME/.cache/quickshell/wallpaperengine-stills/$we_project.png"
    fi
    we_dir="${we_dir/#\~/$USER_HOME}"
    we_still="${we_still/#\~/$USER_HOME}"

    # No project, or a "web" one: leave WALLPAPER_PATH empty so the static
    # wallpaper below is used, exactly as the shell does.
    if [ -z "$we_dir" ] || [ "$we_type" = "web" ]; then
        we_type=""
        we_still=""
    fi

    if [ "$we_type" = "video" ] && [ -f "$we_dir/project.json" ]; then
        # WE names the asset in project.json rather than by a fixed filename.
        we_file="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("file") or "")
except Exception:
    pass' "$we_dir/project.json" 2>/dev/null || true)"
        if [ -n "$we_file" ] && [ -f "$we_dir/$we_file" ]; then
            # This is copied onto the root filesystem under /usr/share, so cap it.
            # A multi-hundred-megabyte login background is a bad trade when a
            # still of the same wallpaper costs a few hundred kilobytes.
            we_size="$(stat -c%s "$we_dir/$we_file" 2>/dev/null || echo 0)"
            if [ "$we_size" -le "${IMI_SDDM_MAX_VIDEO_BYTES:-104857600}" ]; then
                WALLPAPER_PATH="$we_dir/$we_file"
                echo "Using Wallpaper Engine video: $WALLPAPER_PATH" >&2
            else
                echo "Wallpaper Engine video is $((we_size / 1048576)) MiB, over the $((${IMI_SDDM_MAX_VIDEO_BYTES:-104857600} / 1048576)) MiB cap." >&2
                # Cut the still out of the video rather than falling back to
                # activePreview. The preview is a Workshop thumbnail - often
                # square and around 1024px - so on a wide display it was cropped
                # to a narrow band and upscaled several times over
                # (immaterial-impulse#113). The video is the wallpaper at its
                # real resolution, so a frame from it matches the display
                # exactly, for the same few hundred kilobytes on disk.
                #
                # No -vf scale: whatever the video's resolution is, that is the
                # wallpaper's own resolution, and the greeter scales to fit.
                # JPEG, not PNG: at 5120x1440 a lossless frame is ~6.4 MiB
                # against ~1 MiB at -q:v 2, and the source is a photographic
                # render where the difference is not visible. It also keeps the
                # background comparable in size to the preview it replaces.
                WE_FRAME_TEMP="/tmp/sddm_we_frame_$$.jpg"
                if ffmpeg -y -i "$we_dir/$we_file" -ss 00:00:01.000 -vframes 1 \
                        -q:v 2 "$WE_FRAME_TEMP" >/dev/null 2>&1 && [ -s "$WE_FRAME_TEMP" ]; then
                    WALLPAPER_PATH="$WE_FRAME_TEMP"
                    echo "Using a native-resolution frame cut from the video." >&2
                else
                    # Not fatal: the preview below is still better than nothing,
                    # and a login screen must not fail to apply over a thumbnail.
                    echo "Could not cut a frame from the video; falling back to the preview." >&2
                    rm -f "$WE_FRAME_TEMP"
                    WE_FRAME_TEMP=""
                fi
            fi
        fi
    fi

    # A scene cannot be played or sampled here - the greeter has no Wallpaper
    # Engine runtime - so the shell's render is the only full-resolution source
    # there is. Preferred over the preview for every project type.
    if [ -z "$WALLPAPER_PATH" ] && [ -n "$we_native" ] && [ -f "$we_native" ]; then
        WALLPAPER_PATH="$we_native"
        echo "Using the shell's full-resolution Wallpaper Engine still: $WALLPAPER_PATH" >&2
    fi

    if [ -z "$WALLPAPER_PATH" ] && [ -n "$we_still" ] && [ -f "$we_still" ]; then
        WALLPAPER_PATH="$we_still"
        echo "Using Wallpaper Engine preview: $WALLPAPER_PATH" >&2
    fi
fi

# The static wallpaper: used when no Wallpaper Engine project is active, when
# it is a "web" one, or when its asset could not be resolved (missing still,
# oversized video).
if [ -z "$WALLPAPER_PATH" ] && [ -f "$SETTINGS_QML_SOURCE" ]; then
    WALLPAPER_PATH=$(grep "background_wallpaperPath:" "$SETTINGS_QML_SOURCE" | cut -d '"' -f 2 || true)
fi

# Fallback from Colors.qml
if [ -z "$WALLPAPER_PATH" ]; then
    if [ -f "$COLORS_QML_SOURCE" ]; then
        echo "Warning: wallpaper path not found in Settings.qml, using fallback from Colors.qml" >&2
        WALLPAPER_PATH=$(sed -n '5p' "$COLORS_QML_SOURCE" | sed 's/^\/\/\s*//' | xargs || true)
    fi
fi

# Final check
if [ -z "$WALLPAPER_PATH" ]; then
    echo "Error: Could not extract wallpaper path from Settings.qml or Colors.qml." >&2
    exit 4
fi

# Expand ~ to home dir
WALLPAPER_PATH="${WALLPAPER_PATH/#\~/$USER_HOME}"

# Convert relative to absolute if needed
if [[ "$WALLPAPER_PATH" != /* ]]; then
    WALLPAPER_PATH="$SRC/$WALLPAPER_PATH"
fi

# Validate wallpaper file
if ! WALLPAPER_PATH=$(validate_path "$WALLPAPER_PATH" "wallpaper"); then
    exit 5
fi

if [ ! -f "$WALLPAPER_PATH" ]; then
    echo "Error: wallpaper is not a regular file: $WALLPAPER_PATH" >&2
    exit 5
fi

# --- Determine type and extension ---
WALLPAPER_BASENAME="$(basename "$WALLPAPER_PATH")"
WALLPAPER_EXT="${WALLPAPER_BASENAME##*.}"
WALLPAPER_EXT_LOWER=$(echo "$WALLPAPER_EXT" | tr '[:upper:]' '[:lower:]')
BACKGROUND_FILENAME="background.${WALLPAPER_EXT_LOWER}"

IMAGE_EXTS=("png" "jpg" "jpeg" "webp" "gif")
VIDEO_EXTS=("avi" "mp4" "mov" "mkv" "m4v" "webm")

IS_IMAGE=false
IS_VIDEO=false
for ext in "${IMAGE_EXTS[@]}"; do
    [[ "$WALLPAPER_EXT_LOWER" == "$ext" ]] && IS_IMAGE=true
done
for ext in "${VIDEO_EXTS[@]}"; do
    [[ "$WALLPAPER_EXT_LOWER" == "$ext" ]] && IS_VIDEO=true
done

if [ "$IS_IMAGE" = false ] && [ "$IS_VIDEO" = false ]; then
    echo "Error: unsupported wallpaper type: .$WALLPAPER_EXT_LOWER" >&2
    exit 6
fi

# --- Modify ii-sddm.conf dynamically ---
CONF_FILE="$SRC/ii-sddm.conf"
if [ ! -f "$CONF_FILE" ]; then
    echo "Error: ii-sddm.conf not found in $SRC" >&2
    exit 9
fi

if [ "$IS_IMAGE" = true ]; then
    sed -i -E \
        -e "s|^BackgroundPlaceholder=\"[^\"]*\"|BackgroundPlaceholder=\"\"|" \
        -e "s|^Background=\"Backgrounds/background\.[^\"]+\"|Background=\"Backgrounds/${BACKGROUND_FILENAME}\"|" \
        "$CONF_FILE"
else
    # Se è un video, generiamo una miniatura temporanea come placeholder
    PLACEHOLDER_FILENAME="placeholder.png"
    PLACEHOLDER_TEMP="/tmp/sddm_placeholder_$$.png"
    ffmpeg -y -i "$WALLPAPER_PATH" -ss 00:00:01.000 -vframes 1 "$PLACEHOLDER_TEMP" >/dev/null 2>&1 || {
        echo "Error: failed to generate thumbnail with ffmpeg" >&2
        exit 10
    }
    sed -i -E \
        -e "s|^BackgroundPlaceholder=\"[^\"]*\"|BackgroundPlaceholder=\"Backgrounds/${PLACEHOLDER_FILENAME}\"|" \
        -e "s|^Background=\"Backgrounds/background\.[^\"]+\"|Background=\"Backgrounds/${BACKGROUND_FILENAME}\"|" \
        "$CONF_FILE"
fi

# --- Validate required files ---
REQUIRED_FILES=(
    "$COLORS_QML_SOURCE"
    "$SETTINGS_QML_SOURCE"
    "$CONF_FILE"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "Error: required file not found: $file" >&2
        exit 7
    fi
    if [ -L "$file" ]; then
        echo "Error: required file is a symbolic link (not allowed): $file" >&2
        exit 8
    fi
done

# --- Copy to destination ---

sudo mkdir -p -m 755 "$DEST/Components"
sudo mkdir -p -m 755 "$DEST/Backgrounds"
sudo mkdir -p -m 755 "$DEST/Themes"

sudo cp --no-dereference --preserve=mode,timestamps "$COLORS_QML_SOURCE" "$DEST/Components/Colors.qml"
sudo cp --no-dereference --preserve=mode,timestamps "$SETTINGS_QML_SOURCE" "$DEST/Components/Settings.qml"
sudo cp --no-dereference --preserve=mode,timestamps "$WALLPAPER_PATH" "$DEST/Backgrounds/$BACKGROUND_FILENAME"
sudo cp --no-dereference --preserve=mode,timestamps "$CONF_FILE" "$DEST/Themes/ii-sddm.conf"

if [ "$IS_VIDEO" = true ]; then
    sudo cp --no-dereference --preserve=mode,timestamps "$PLACEHOLDER_TEMP" "$DEST/Backgrounds/$PLACEHOLDER_FILENAME"
    rm -f "$PLACEHOLDER_TEMP"
fi

# The frame cut from an oversized Wallpaper Engine video, once copied in.
[ -n "${WE_FRAME_TEMP:-}" ] && rm -f "$WE_FRAME_TEMP"

sudo chmod 644 "$DEST/Components/Colors.qml" "$DEST/Components/Settings.qml" "$DEST/Backgrounds/$BACKGROUND_FILENAME" "$DEST/Themes/ii-sddm.conf"
[ "$IS_VIDEO" = true ] && sudo chmod 644 "$DEST/Backgrounds/$PLACEHOLDER_FILENAME"