#!/usr/bin/env bash
set -euo pipefail

# === CONFIGURATION ===

readonly THEME_NAME="imi-sddm-theme"
# The pre-fork name. An install that predates the rename, or one whose
# migration did not finish, still has everything under this name - so the
# uninstaller has to clean up both or it silently leaves a whole theme,
# a drop-in setting Current=, and the scripts the matugen hook calls.
readonly LEGACY_THEME_NAME="ii-sddm-theme"

readonly SDDM_THEMES_DIR="${SDDM_THEMES_DIR:-/usr/share/sddm/themes}"
readonly SDDM_THEME_DEST="${SDDM_THEMES_DIR}/${THEME_NAME}"
# Overridable so the config-reverting logic below can be exercised against a
# temporary tree instead of the real /etc. Nothing in normal use sets these.
readonly SDDM_CONF_DIR="${SDDM_CONF_DIR:-/etc/sddm.conf.d}"
# setup.sh's migration rewrites Current= and the greeter import path in every
# config that names the old theme - including files we do not own, like the KDE
# settings module's kde_settings.conf and /etc/sddm.conf itself. Uninstall has
# to read the same set to put them back.
readonly SDDM_MAIN_CONF="${SDDM_MAIN_CONF:-/etc/sddm.conf}"
readonly SDDM_THEME_CONF="${SDDM_CONF_DIR}/${THEME_NAME}.conf"
readonly LEGACY_SDDM_THEME_DEST="/usr/share/sddm/themes/${LEGACY_THEME_NAME}"
readonly LEGACY_SDDM_THEME_CONF="${SDDM_CONF_DIR}/${LEGACY_THEME_NAME}.conf"
readonly LEGACY_HYPR_THEME_SCRIPTS_DEST="${HOME}/.config/${LEGACY_THEME_NAME}"

readonly HYPR_THEME_SCRIPTS_DEST="${HOME}/.config/${THEME_NAME}"

readonly MATUGEN_CONF="${HOME}/.config/matugen/config.toml"

readonly USERNAME="${USER}"
readonly SUDOERS_FILE="/etc/sudoers.d/sddm-theme-${USERNAME}"

readonly FONTS_DIR="/usr/share/fonts/ii-sddm-theme-fonts"

# === COLORS ===

STY_CYAN='\e[36m'
STY_GREEN='\e[32m'
STY_YELLOW='\e[33m'
STY_RED='\e[31m'
STY_RST='\e[0m'

# === LOGGING ===

log_info()  { printf "  [INFO] %s\n" "$*"; }
log_ok()    { printf "  ${STY_GREEN}[OK]   %s${STY_RST}\n" "$*"; }
log_warn()  { printf "  ${STY_YELLOW}[WARN] %s${STY_RST}\n" "$*" >&2; }
log_error() { printf "  ${STY_RED}[ERR]  %s${STY_RST}\n" "$*" >&2; }
log_step()  { printf "\n-- %s\n" "$*"; }

# === GUARDS ===

if [[ $EUID -eq 0 ]]; then
    log_error "Do not run this script as root. It will use sudo when needed."
    exit 1
fi

if ! sudo -v; then
    log_error "sudo authentication failed."
    exit 1
fi

# === BANNER ===

show_banner() {
    local title=" UNINSTALL ${THEME_NAME} "
    local width=${#title}
    local border
    border=$(printf '─%.0s' $(seq 1 $width))
    printf "\n"
    printf "${STY_CYAN}┌%s┐${STY_RST}\n" "${border}"
    printf "${STY_CYAN}│%s│${STY_RST}\n" "${title}"
    printf "${STY_CYAN}└%s┘${STY_RST}\n" "${border}"
    printf "\n"
}

# === INTRODUCTION ===

introduction() {
    clear
    show_banner
    printf "This script will remove %s and all its components.\n" "${THEME_NAME}"
    printf "\n"
    printf "  ${STY_YELLOW}Note:${STY_RST} This will remove the theme, SDDM configuration, scripts,\n"
    printf "        fonts, matugen block, and sudoers rule.\n"
    printf "\n"
    read -r -p "===> Continue? [y/n]: " p
    case $p in
        y|Y) ;;
        *)
            log_error "Uninstallation aborted by user."
            exit 0
            ;;
    esac
}

# === REVERT SDDM REFERENCES TO THIS THEME ===

# The mirror of setup.sh's migrate_legacy_theme_name, and it exists for the same
# reason that function does: [Theme] Current= is a *name* SDDM resolves against
# /usr/share/sddm/themes, so deleting the directory while some config still
# names it leaves SDDM pointing at nothing - a broken greeter on the next boot,
# the one failure here that is genuinely painful to recover from.
#
# The install is what put those references in other people's files: the
# migration rewrites Current= and the greeter import path wherever they live,
# and /etc/sddm.conf outranks every drop-in while kde_settings.conf sorts after
# ours. Removing only our own drop-in therefore leaves the authoritative copies
# behind, still naming a directory we are about to delete.
#
# Ordering mirrors the install: revert the references FIRST, remove the
# directory second, so an interruption leaves a working greeter either way.

# A theme we hand back has to actually exist, or we have recreated the same
# dangling-name failure under a different name.
pick_fallback_theme() {
    local candidate
    for candidate in breeze elarun maldives maya; do
        if [[ -d "${SDDM_THEMES_DIR}/${candidate}" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done
    return 1
}

sddm_configs() {
    local conf
    for conf in "${SDDM_MAIN_CONF}" "${SDDM_CONF_DIR}"/*.conf; do
        [[ -f "${conf}" ]] || continue
        # Our own drop-ins are deleted wholesale by remove_sddm_conf.
        [[ "${conf}" == "${SDDM_THEME_CONF}" ]] && continue
        [[ "${conf}" == "${LEGACY_SDDM_THEME_CONF}" ]] && continue
        printf '%s\n' "${conf}"
    done
}

# Any surviving reference to either of our names, in a file we are not deleting.
sddm_still_references_our_theme() {
    local conf name
    while IFS= read -r conf; do
        for name in "${THEME_NAME}" "${LEGACY_THEME_NAME}"; do
            grep -qE "^[[:space:]]*Current[[:space:]]*=[[:space:]]*${name}[[:space:]]*$" "${conf}" && return 0
            grep -q "themes/${name}/" "${conf}" && return 0
        done
    done < <(sddm_configs)
    return 1
}

revert_sddm_references() {
    log_step "Reverting SDDM configuration that points at this theme"

    local fallback conf name reverted=0
    fallback="$(pick_fallback_theme || true)"

    while IFS= read -r conf; do
        for name in "${THEME_NAME}" "${LEGACY_THEME_NAME}"; do
            if grep -qE "^[[:space:]]*Current[[:space:]]*=[[:space:]]*${name}[[:space:]]*$" "${conf}"; then
                if [[ -n "${fallback}" ]]; then
                    if sudo sed -i -E "s|^([[:space:]]*Current[[:space:]]*=[[:space:]]*)${name}[[:space:]]*$|\1${fallback}|" "${conf}"; then
                        log_ok "Repointed Current= in ${conf} at ${fallback}"
                        reverted=$((reverted + 1))
                    else
                        log_error "Could not rewrite ${conf}."
                    fi
                else
                    # No known-good theme on disk: drop the line so SDDM falls
                    # back to its own default rather than to a missing name.
                    if sudo sed -i -E "/^[[:space:]]*Current[[:space:]]*=[[:space:]]*${name}[[:space:]]*$/d" "${conf}"; then
                        log_ok "Removed Current=${name} from ${conf} (no fallback theme installed)"
                        reverted=$((reverted + 1))
                    else
                        log_error "Could not rewrite ${conf}."
                    fi
                fi
            fi

            # setup.sh's configure_sddm writes GreeterEnvironment= with a
            # QML2_IMPORT_PATH into our Components/ directory. Once the theme is
            # gone that path is dangling, so drop the line we added - that is
            # the pre-install state.
            if grep -qE "^[[:space:]]*GreeterEnvironment[[:space:]]*=.*themes/${name}/" "${conf}"; then
                if sudo sed -i -E "\|^[[:space:]]*GreeterEnvironment[[:space:]]*=.*themes/${name}/|d" "${conf}"; then
                    log_ok "Removed the greeter import path naming ${name} from ${conf}"
                    reverted=$((reverted + 1))
                else
                    log_error "Could not rewrite ${conf}."
                fi
            fi
        done
    done < <(sddm_configs)

    if (( reverted == 0 )); then
        log_info "No other SDDM config referenced this theme."
    else
        log_info "Reverted ${reverted} reference(s)."
    fi
}

# === REMOVE SDDM THEME ===

remove_theme() {
    log_step "Removing SDDM theme"

    # Refuse rather than create the dangling-name failure described above. The
    # theme staying installed is a cosmetic problem; a greeter that cannot
    # resolve its theme is not.
    if sddm_still_references_our_theme; then
        log_error "SDDM config still names this theme after the revert pass; keeping the theme directory."
        log_warn  "Fix the Current= / import path below by hand, then re-run this uninstaller:"
        local conf name
        while IFS= read -r conf; do
            for name in "${THEME_NAME}" "${LEGACY_THEME_NAME}"; do
                grep -nE "^[[:space:]]*Current[[:space:]]*=[[:space:]]*${name}[[:space:]]*$|themes/${name}/" "${conf}" \
                    | sed "s|^|    ${conf}:|"
            done
        done < <(sddm_configs)
        return 0
    fi

    if [[ -d "${SDDM_THEME_DEST}" ]]; then
        sudo rm -rf "${SDDM_THEME_DEST}"
        log_ok "Removed ${SDDM_THEME_DEST}"
    else
        log_warn "${SDDM_THEME_DEST} not found, skipping"
    fi

    if [[ -d "${LEGACY_SDDM_THEME_DEST}" ]]; then
        sudo rm -rf "${LEGACY_SDDM_THEME_DEST}"
        log_ok "Removed ${LEGACY_SDDM_THEME_DEST} (pre-rename install)"
    fi
}

# === REMOVE SDDM CONFIGURATION ===

remove_sddm_conf() {
    log_step "Removing SDDM configuration"

    if [[ -f "${LEGACY_SDDM_THEME_CONF}" ]]; then
        sudo rm -f "${LEGACY_SDDM_THEME_CONF}"
        log_ok "Removed ${LEGACY_SDDM_THEME_CONF} (pre-rename install)"
    fi

    if [[ -f "${SDDM_THEME_CONF}" ]]; then
        sudo rm -f "${SDDM_THEME_CONF}"
        log_ok "Removed ${SDDM_THEME_CONF}"

        # /etc/sddm.conf.d is owned by the sddm package, not created by us, and
        # other software drops configs into it. Leaving an empty directory
        # behind is correct; removing it is deleting someone else's property.
    else
        log_warn "${SDDM_THEME_CONF} not found, skipping"
    fi
}

# === REMOVE HYPR SCRIPTS ===

remove_hypr_scripts() {
    log_step "Removing theme scripts"

    if [[ -d "${HYPR_THEME_SCRIPTS_DEST}" ]]; then
        rm -rf "${HYPR_THEME_SCRIPTS_DEST}"
        log_ok "Removed ${HYPR_THEME_SCRIPTS_DEST}"
    else
        log_warn "${HYPR_THEME_SCRIPTS_DEST} not found, skipping"
    fi

    if [[ -d "${LEGACY_HYPR_THEME_SCRIPTS_DEST}" ]]; then
        rm -rf "${LEGACY_HYPR_THEME_SCRIPTS_DEST}"
        log_ok "Removed ${LEGACY_HYPR_THEME_SCRIPTS_DEST} (pre-rename install)"
    fi
}

# === REMOVE FONTS ===

remove_fonts() {
    log_step "Removing fonts"

    if [[ -d "${FONTS_DIR}" ]]; then
        sudo rm -rf "${FONTS_DIR}"
        log_ok "Fonts removed."
        sudo fc-cache -fv > /dev/null 2>&1
    else
        log_warn "${FONTS_DIR} not found, skipping"
    fi
}

# === REMOVE MATUGEN BLOCK ===

remove_matugen_conf() {
    log_step "Removing matugen configuration block"

    if [[ ! -f "${MATUGEN_CONF}" ]]; then
        log_warn "${MATUGEN_CONF} not found, skipping"
        return
    fi

    if grep -q "^\[templates\.iisddmtheme\]" "${MATUGEN_CONF}"; then
        log_info "Found [templates.iisddmtheme] block. Removing it..."

        local temp_file
        temp_file=$(mktemp)
        awk '
            /^\[templates\.iisddmtheme\]/ { skip=1; next }
            /^\[/ { skip=0 }
            !skip { print }
        ' "${MATUGEN_CONF}" >"${temp_file}"
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "${temp_file}"
        mv "${temp_file}" "${MATUGEN_CONF}"
        log_ok "[templates.iisddmtheme] block removed from ${MATUGEN_CONF}"
    else
        log_warn "No [templates.iisddmtheme] block found in ${MATUGEN_CONF}, skipping"
    fi
}

# === REMOVE SUDOERS ===

remove_sudoers() {
    log_step "Removing sudoers rule"

    if sudo test -f "${SUDOERS_FILE}"; then
        sudo rm -f "${SUDOERS_FILE}"
        log_ok "Removed ${SUDOERS_FILE}"
    else
        log_warn "${SUDOERS_FILE} not found, skipping"
    fi
}

# === MAIN ===

main() {
    introduction

    # Before remove_theme: a config still naming this theme once the directory
    # is gone is a greeter that cannot start.
    revert_sddm_references
    remove_theme
    remove_sddm_conf
    remove_hypr_scripts
    remove_fonts
    remove_matugen_conf
    remove_sudoers

    local msg=" Uninstallation completed successfully "
    local width=${#msg}
    local border
    border=$(printf '─%.0s' $(seq 1 $width))
    printf "\n"
    printf "  ${STY_GREEN}┌%s┐${STY_RST}\n" "${border}"
    printf "  ${STY_GREEN}│%s│${STY_RST}\n" "${msg}"
    printf "  ${STY_GREEN}└%s┘${STY_RST}\n" "${border}"
    printf "\n"
    
    printf -- "-- Reboot your system\n"
    log_warn "Please REBOOT now your system to fully apply the changes, if fonts looks broken rebooting will fix it."
}

# Only run when executed, not when sourced, so the functions above can be
# tested individually without uninstalling anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
