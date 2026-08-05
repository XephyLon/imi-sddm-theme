#!/usr/bin/env bash
# Sync the greeter with the desktop - generate, diff, and only then escalate.
#
# This is the single entry point every trigger calls: matugen's post_hook
# (colors changed) and the shell's GreeterSync service (a greeter-relevant
# config leaf changed, or the full-resolution still finished writing). It
# exists so that observation can be generous: a trigger that turns out to be
# spurious costs a hash comparison here, not a root copy onto /usr/share.
#
# Runs entirely as the user except the final sudo, which fires only when the
# fingerprint of what the greeter actually consumes has changed. The stamp is
# written only after a successful apply, so a failed apply is retried by the
# next trigger instead of being recorded as done.
set -euo pipefail

SRC="${IMI_SDDM_SRC:-$HOME/.config/imi-sddm-theme}"
APPLY="${IMI_SDDM_APPLY:-/usr/local/lib/imi-sddm-theme/sddm-theme-apply.sh}"
STILLS="${IMI_SDDM_STILLS:-$HOME/.cache/quickshell/wallpaperengine-stills}"
STAMP="$SRC/.last-applied"

# Two triggers can land together (matugen fires on a wallpaper switch and the
# shell's observer debounce follows it). Serialize rather than stack.
exec 9>"$SRC/.sync-lock"
flock 9

python3 "$SRC/generate_settings.py"

# Fingerprint of what the greeter consumes:
#  - the generated QML (Settings.qml carries every flattened config key, so
#    any greeter-relevant config change lands here; Colors.qml carries the
#    palette),
#  - the derived still's identity. Content changes without a Settings change
#    when the shell re-grabs at a new size (monitor change) or a settled
#    frame replaces a warmup one - identity by mtime+size, because hashing a
#    ~13 MiB PNG per trigger is the kind of cost this gate exists to avoid.
fingerprint() {
    sha256sum "$SRC/Settings.qml" "$SRC/Colors.qml" 2>/dev/null || true
    local proj still
    proj="$(grep -m1 'wallpaperSelector_wallpaperEngine_activeProject:' "$SRC/Settings.qml" 2>/dev/null | cut -d '"' -f 2 || true)"
    if [ -n "$proj" ]; then
        still="$STILLS/$proj.png"
        if [ -f "$still" ]; then
            stat -c '%n %Y %s' "$still"
        else
            echo "no-still:$proj"
        fi
    fi
}

new="$(fingerprint | sha256sum | cut -d ' ' -f 1)"
old="$(cat "$STAMP" 2>/dev/null || true)"
if [ "$new" = "$old" ]; then
    exit 0
fi

sudo "$APPLY"
printf '%s\n' "$new" > "$STAMP"
