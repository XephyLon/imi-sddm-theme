#!/usr/bin/env bash
set -euo pipefail

# === CONFIGURATION ===

readonly THEME_NAME="imi-sddm-theme"
# The name this theme installed under before the fork. Everything it left
# behind is migrated and removed by migrate_legacy_theme_name below.
readonly LEGACY_THEME_NAME="ii-sddm-theme"
# This fork, not 3d3f/ii-sddm-theme. The installer clones the theme content
# rather than copying the checkout it is running from, so pointing only the
# *installer* at this fork changed nothing on disk: every fork edit to the
# theme itself - the immaterial-impulse config path in
# iiMatugen/generate_settings.py, the Wallpaper Engine resolution in
# iiMatugen/sddm-theme-apply.sh - was cloned straight back over from upstream
# on each install. THEME_REPO is what decides which theme actually lands in
# /usr/share/sddm/themes.
readonly THEME_REPO="https://github.com/XephyLon/imi-sddm-theme"
# Which revision of THEME_REPO to install. A downstream pins this repo by
# fetching *this file* at a ref, which pinned the installer but not the theme it
# then cloned - so a hub pinned to a months-old SDDM_REF still laid down
# whatever main happened to be at that moment, and the pin only looked like one
# (#5). Passing the same ref through closes that: the installer and the content
# it installs come from one revision.
#
# Empty means "the default branch", which is what someone running setup.sh from
# a local checkout wants, and what every caller got before this existed.
readonly THEME_REF="${IMI_SDDM_THEME_REF:-}"

readonly SDDM_THEMES_DIR="${SDDM_THEMES_DIR:-/usr/share/sddm/themes}"
readonly SDDM_THEME_DEST="${SDDM_THEMES_DIR}/${THEME_NAME}"
readonly SDDM_CONF_DIR="${SDDM_CONF_DIR:-/etc/sddm.conf.d}"
# Per man 5 sddm.conf, configuration is loaded /usr/lib/sddm/sddm.conf.d, then
# /etc/sddm.conf.d, then /etc/sddm.conf, "with the latter having highest
# precedence" - so this file outranks every drop-in, including ours. Overridable
# purely so the legacy-name migration can be exercised against a sandbox instead
# of the real /etc.
readonly SDDM_MAIN_CONF="${SDDM_MAIN_CONF:-/etc/sddm.conf}"
readonly LEGACY_SDDM_THEME_CONF="${SDDM_CONF_DIR}/${LEGACY_THEME_NAME}.conf"
# Within /etc/sddm.conf.d later filenames win, so the drop-in has to sort after
# anything that might set its own [Theme] Current= - in practice
# kde_settings.conf, written by the KDE "Login Screen (SDDM)" module. Both
# "ii-sddm-theme.conf" and "imi-sddm-theme.conf" sort *before* it and lost
# silently: the install reported success and the greeter kept the old theme.
readonly SDDM_THEME_CONF="${SDDM_CONF_DIR}/zz-${THEME_NAME}.conf"
# The unprefixed name this fork used before the zz- prefix. Left in place it
# would be a second file setting Current=, so the install cleans it up.
readonly PREV_SDDM_THEME_CONF="${SDDM_CONF_DIR}/${THEME_NAME}.conf"

readonly HYPR_SCRIPTS_BASE="${HOME}/.config"
readonly HYPR_THEME_SCRIPTS_DEST="${HYPR_SCRIPTS_BASE}/${THEME_NAME}"

readonly DATE=$(date +%s)
readonly CLONE_DIR="/tmp/${THEME_NAME}-repo-${DATE}"

readonly USERNAME="${USER}"
# Root-owned, outside $HOME, because a NOPASSWD sudoers rule names it. sudo
# matches by path, so a rule pointing anywhere the user can write is equivalent
# to NOPASSWD: ALL. The script's inputs still live in HYPR_THEME_SCRIPTS_DEST.
readonly PRIV_SCRIPT_DIR="/usr/local/lib/${THEME_NAME}"
readonly APPLY_SCRIPT="${PRIV_SCRIPT_DIR}/sddm-theme-apply.sh"
# Where earlier versions put it - user-writable, and still named by any sudoers
# rule those versions installed. Removed on install and on uninstall.
readonly LEGACY_APPLY_SCRIPT="${HYPR_THEME_SCRIPTS_DEST}/sddm-theme-apply.sh"
readonly SUDOERS_FILE="/etc/sudoers.d/sddm-theme-${USERNAME}"

readonly MATUGEN_QML_INPUT_TEMPLATE="${HYPR_THEME_SCRIPTS_DEST}/SddmColors.qml"
readonly MATUGEN_GENERATE_SETTINGS_SCRIPT="${HYPR_THEME_SCRIPTS_DEST}/generate_settings.py"
readonly MATUGEN_CONF="${HOME}/.config/matugen/config.toml"

# The shell renamed itself illogical-impulse -> immaterial-impulse. Prefer the
# current directory and fall back to the old one, so this keeps working for
# installs on either side of that rename. A leftover illogical-impulse dir is a
# stale copy on a migrated install, so it must never win when both exist.
readonly II_CONFIG_JSON="$(
    for _d in immaterial-impulse illogical-impulse; do
        if [[ -f "${HOME}/.config/${_d}/config.json" ]]; then
            printf '%s' "${HOME}/.config/${_d}/config.json"; exit
        fi
    done
    printf '%s' "${HOME}/.config/immaterial-impulse/config.json"
)"

# === COLORS ===

STY_CYAN='\e[36m'
STY_GREEN='\e[32m'
STY_YELLOW='\e[33m'
STY_RED='\e[31m'
STY_RST='\e[0m'

# === NON-INTERACTIVE DRIVING ===
#
# This installer is invoked by other installers (Immaterial Impulse hands off to
# it from sdata/subcmd-install/5.sddm-theme.sh). Previously every confirmation
# was an unconditional `read`, so a caller whose stdin was not a terminal got
# EOF on the first prompt, fell through to the default case and exited 0 -
# installing nothing, silently. Two env vars make the whole run driveable:
#
#   IMI_SDDM_ASSUME_YES=1                  answer every confirmation with yes
#   IMI_SDDM_MODE=ii-matugen|matugen-only|no-matugen
#                                          preselect the installation type
#
# Unset, behaviour is exactly as before.
confirm() {
    local prompt="$1" reply
    if [[ "${IMI_SDDM_ASSUME_YES:-0}" == "1" ]]; then
        printf "===> %s [y/n]: y (IMI_SDDM_ASSUME_YES)\n" "$prompt"
        return 0
    fi
    read -r -p "===> ${prompt} [y/n]: " reply
    [[ "$reply" == [yY] ]]
}

# === LOGGING ===

log_info()  { printf "  [INFO] %s\n" "$*"; }
log_ok()    { printf "  ${STY_GREEN}[OK]   %s${STY_RST}\n" "$*"; }
log_warn()  { printf "  ${STY_YELLOW}[WARN] %s${STY_RST}\n" "$*" >&2; }
log_error() { printf "  ${STY_RED}[ERR]  %s${STY_RST}\n" "$*" >&2; }
log_step()  { printf "\n-- %s\n" "$*"; }

# Global flags

II_CONFIG_FOUND=false
MATUGEN_CONFIG_FOUND=false
INSTALLATION_TYPE="no-matugen"

# === BANNER ===

show_banner() {
    local title=" SETUP ${THEME_NAME} "
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
    show_banner
    printf "This script will install %s.\n" "${THEME_NAME}"
    printf "\n"
    printf "  ${STY_YELLOW}Note:${STY_RST} Please check what the script will do before running it.\n"
    printf "\n"
    if ! confirm "Continue?"; then
        log_error "Installation aborted by user."
        exit 0
    fi
}

# === GUARDS ===

check_requirements() {
    log_step "Preliminary checks"
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root. It will use sudo when needed."
        exit 1
    fi
    if ! sudo -v; then
        log_error "sudo authentication failed."
        exit 1
    fi
    log_ok "Environment check passed"
}

# === AUR HELPER DETECTION ===

get_aur_helper() {
    log_step "Checking for AUR helper"
    if command -v yay &>/dev/null; then
        log_ok "AUR helper 'yay' found."
    elif command -v paru &>/dev/null; then
        log_ok "AUR helper 'paru' found."
    else
        log_error "No AUR helper (yay or paru) found. Please install one to proceed."
        exit 1
    fi
}

# === GIT CHECK ===

check_git() {
    log_step "Checking for git"
    if ! command -v git &>/dev/null; then
        log_warn "git is not installed."
        if confirm "git is required to clone the theme. Install it now?"; then
            sudo pacman -S --needed git
            log_ok "git installed successfully."
        else
            log_error "git is required. Installation aborted."
            exit 1
        fi
    else
        log_ok "git is already installed."
    fi
}

# === SDDM CHECK ===

check_sddm_installation() {
    log_step "Checking SDDM installation"
    if ! command -v sddm &>/dev/null; then
        log_warn "SDDM is not currently installed on your system."
        log_warn "The script will proceed to install and configure SDDM along with the theme."
        if ! confirm "Continue with SDDM installation and theme setup?"; then
            log_error "Installation aborted by user. SDDM is required for this theme."
            exit 0
        fi
    else
        log_ok "SDDM is already installed."
    fi
}

# === FONT INSTALLATION ===

install_fonts() {
    log_step "Installing fonts"

    local repo_fonts="${CLONE_DIR}/fonts/ii-sddm-theme-fonts"

    if [[ -d "${repo_fonts}" ]]; then
        log_info "Copying fonts from ${repo_fonts} to /usr/share/fonts/..."
        sudo rm -rf /usr/share/fonts/ii-sddm-theme-fonts
        sudo cp -r "${repo_fonts}" /usr/share/fonts/
        log_info "Setting permissions..."
        sudo chown -R root:root /usr/share/fonts/ii-sddm-theme-fonts
        sudo find /usr/share/fonts/ii-sddm-theme-fonts -type d -exec chmod 755 {} \;
        sudo find /usr/share/fonts/ii-sddm-theme-fonts -type f -exec chmod 644 {} \;
        log_info "Updating font cache..."
        sudo fc-cache -f > /dev/null
        log_ok "Fonts installed."
    else
        log_warn "Fonts folder not found in the repository. Skipping font installation."
    fi
}

# === INSTALLATION TYPE SELECTION ===

detect_configs_and_select_installation_type() {
    log_step "Detecting existing configurations for optional features"

    if [[ -f "${II_CONFIG_JSON}" ]]; then
        II_CONFIG_FOUND=true
        log_ok "ii config file found: ${II_CONFIG_JSON}"
    else
        log_info "ii config file not found."
    fi

    if [[ -f "${MATUGEN_CONF}" ]]; then
        MATUGEN_CONFIG_FOUND=true
        log_ok "Matugen config file found: ${MATUGEN_CONF}"
    else
        log_info "Matugen config file not found."
    fi

    printf "\n"
    printf -- "-- Installation type\n"
    printf "\n"
    printf "Please select your preferred installation mode:\n"
    printf "\n"

    local option_num=1
    declare -A option_map

    if "${II_CONFIG_FOUND}" && "${MATUGEN_CONFIG_FOUND}"; then
        printf "  ${STY_GREEN}[%s]${STY_RST} ii + Matugen Integration\n" "${option_num}"
        printf "      └─ Sync ii settings, wallpaper and colors automatically\n"
        option_map[$option_num]="ii-matugen"
        ((option_num++))
        printf "\n"

        printf "  ${STY_GREEN}[%s]${STY_RST} Matugen Integration Only\n" "${option_num}"
        printf "      └─ Wallpaper and colors generated through matugen, manual settings configuration\n"
        option_map[$option_num]="matugen-only"
        ((option_num++))
        printf "\n"

        printf "  ${STY_GREEN}[%s]${STY_RST} Manual Configuration\n" "${option_num}"
        printf "      └─ Manual background, colors and settings configuration\n"
        option_map[$option_num]="no-matugen"
        ((option_num++))

    elif "${MATUGEN_CONFIG_FOUND}"; then
        printf "  ${STY_GREEN}[%s]${STY_RST} Matugen Integration\n" "${option_num}"
        printf "      └─ Wallpaper and colors generated through matugen, manual settings configuration\n"
        option_map[$option_num]="matugen-only"
        ((option_num++))
        printf "\n"

        printf "  ${STY_GREEN}[%s]${STY_RST} Manual Configuration\n" "${option_num}"
        printf "      └─ Full manual control: background, colors and settings\n"
        option_map[$option_num]="no-matugen"
        ((option_num++))

    else
        printf "  ${STY_GREEN}[%s]${STY_RST} Manual Configuration\n" "${option_num}"
        printf "      └─ Manual background, colors and settings configuration\n"
        option_map[$option_num]="no-matugen"
        ((option_num++))
    fi

    printf "\n"

    local selected_option
    local max_option=$((option_num - 1))
    local range_str
    range_str=$(seq -s "-" 1 $((option_num - 1)))

    # Preselected by a driving installer. Validated against the options this run
    # actually offers, so an unavailable mode (e.g. ii-matugen with no shell
    # config present) falls through to the prompt rather than being forced.
    if [[ -n "${IMI_SDDM_MODE:-}" ]]; then
        local _n
        for _n in "${!option_map[@]}"; do
            if [[ "${option_map[$_n]}" == "${IMI_SDDM_MODE}" ]]; then
                INSTALLATION_TYPE="${IMI_SDDM_MODE}"
                printf "\n"
                log_ok "Selected installation type: ${INSTALLATION_TYPE} (IMI_SDDM_MODE)"
                return
            fi
        done
        log_warn "IMI_SDDM_MODE='${IMI_SDDM_MODE}' is not available in this run; asking instead."
    fi

    while true; do
        read -r -p "===> [${range_str}]: " selected_option
        if [[ "${selected_option}" =~ ^[0-9]+$ ]] && [[ -n "${option_map[$selected_option]:-}" ]]; then
            INSTALLATION_TYPE="${option_map[$selected_option]}"
            printf "\n"
            log_ok "Selected installation type: ${INSTALLATION_TYPE}"
            break
        else
            log_error "Invalid choice. Please enter a number between 1 and ${max_option}."
        fi
    done

    printf "\n"
}

# === DEPENDENCIES INSTALLATION ===

install_deps() {
    log_step "Installing dependencies"
    log_info "Installing official Arch repositories packages..."
    sudo pacman -S --needed sddm qt6-svg qt6-virtualkeyboard qt6-multimedia-ffmpeg

    install_fonts

    log_ok "Dependencies installed successfully"
}

# === REPO CLONING ===

clone_repo_to_temp() {
    log_step "Cloning repository to temporary directory"

    log_info "Cloning ${THEME_REPO} into temporary directory ${CLONE_DIR}..."
    if ! git clone --depth 1 "${THEME_REPO}" "${CLONE_DIR}"; then
        log_error "Failed to clone theme repository. Please check your internet connection and the repository URL."
        exit 1
    fi

    if [[ -n "${THEME_REF}" ]]; then
        # Fetched separately rather than via `clone --branch`, which takes a
        # branch or tag name and rejects a raw SHA - and a SHA is exactly what a
        # downstream should be pinning, since a tag can be force-moved out from
        # under a release that already shipped.
        log_info "Checking out pinned revision ${THEME_REF:0:12}..."
        if ! git -C "${CLONE_DIR}" fetch --depth 1 origin "${THEME_REF}"; then
            log_error "Could not fetch ${THEME_REF} from ${THEME_REPO}."
            log_error "Refusing to fall back to the default branch: that would install a revision nobody asked for, which is the bug this pin exists to prevent."
            exit 1
        fi
        if ! git -C "${CLONE_DIR}" checkout -q FETCH_HEAD; then
            log_error "Fetched ${THEME_REF} but could not check it out."
            exit 1
        fi
        log_ok "Theme repository pinned at ${THEME_REF:0:12}."
    fi

    log_ok "Theme repository cloned successfully to ${CLONE_DIR}."
}

# === COPY SPECIFIC FILES TO HYPR SCRIPTS ===

copy_specific_files_to_hypr() {
    log_step "Copying specific files to Hyprland custom scripts (${HYPR_THEME_SCRIPTS_DEST})"

    if [[ -d "${HYPR_THEME_SCRIPTS_DEST}" ]]; then
        log_warn "Existing theme scripts directory found at ${HYPR_THEME_SCRIPTS_DEST}. Removing it before copying new files."
        rm -rf "${HYPR_THEME_SCRIPTS_DEST}"
        log_ok "Old theme scripts directory removed."
    fi

    mkdir -p "${HYPR_THEME_SCRIPTS_DEST}"

    local source_dir=""
    case "${INSTALLATION_TYPE}" in
        "ii-matugen")
            source_dir="${CLONE_DIR}/iiMatugen"
            log_info "Copying files for 'ii + Matugen Integration' from ${source_dir}..."
            ;;
        "matugen-only")
            source_dir="${CLONE_DIR}/Matugen"
            log_info "Copying files for 'Matugen Integration Only' from ${source_dir}..."
            ;;
        "no-matugen")
            source_dir="${CLONE_DIR}/noMatugen"
            log_info "Copying files for 'No Matugen Integration' from ${source_dir}..."
            ;;
        *)
            log_error "Unknown installation type: ${INSTALLATION_TYPE}. No files copied to Hyprland scripts."
            return 1
            ;;
    esac

    if [[ -d "${source_dir}" ]]; then
        cp -r "${source_dir}"/* "${HYPR_THEME_SCRIPTS_DEST}/"
        log_ok "All files from '${source_dir}' copied to '${HYPR_THEME_SCRIPTS_DEST}'."
    else
        log_error "Source directory '${source_dir}' not found. Cannot copy files for '${INSTALLATION_TYPE}'."
        return 1
    fi

    # The apply script is the one thing here that runs as ROOT without a
    # password, so it must not live where the user can rewrite it. sudo matches a
    # sudoers rule by PATH, not by owner or content: a NOPASSWD rule naming a
    # file under $HOME is functionally NOPASSWD: ALL, because anything running as
    # the user can replace that file and then ask sudo to execute it.
    #
    # So it is installed root-owned outside the home directory, and the copy that
    # landed in the user's config dir is removed - leaving it would be a
    # user-writable file with the same name one directory away from a rule that
    # used to point at it. Its DATA still lives in the config dir; only the
    # executable moves (see the header of sddm-theme-apply.sh).
    local staged_apply="${HYPR_THEME_SCRIPTS_DEST}/sddm-theme-apply.sh"
    if [[ -f "${staged_apply}" ]]; then
        sudo install -d -o root -g root -m 755 "${PRIV_SCRIPT_DIR}"
        sudo install -o root -g root -m 755 "${staged_apply}" "${APPLY_SCRIPT}"
        rm -f "${staged_apply}"
        log_ok "Installed the apply script root-owned at ${APPLY_SCRIPT}."
    else
        log_error "No sddm-theme-apply.sh in ${source_dir}; the theme cannot be applied."
        return 1
    fi

    if [[ "${INSTALLATION_TYPE}" == "ii-matugen" ]] && [[ -f "${MATUGEN_GENERATE_SETTINGS_SCRIPT}" ]]; then
        chmod +x "${MATUGEN_GENERATE_SETTINGS_SCRIPT}"
        log_ok "Made ${MATUGEN_GENERATE_SETTINGS_SCRIPT} executable."
    fi

    log_ok "Specific files copied and permissions set in ${HYPR_THEME_SCRIPTS_DEST}."
}

# === SDDM THEME INSTALLATION ===

install_theme() {
    log_step "Installing SDDM theme files to SDDM directory"

    if [[ -d "${SDDM_THEME_DEST}" ]]; then
        log_warn "Existing SDDM theme '${THEME_NAME}' detected in ${SDDM_THEMES_DIR}. Overwriting it."
        sudo rm -rf "${SDDM_THEME_DEST}"
    fi

    sudo mkdir -p "${SDDM_THEME_DEST}"
    sudo cp -r "${CLONE_DIR}"/* "${SDDM_THEME_DEST}/"

    log_ok "SDDM theme '${THEME_NAME}' installed to ${SDDM_THEME_DEST}."
}

# === SDDM CONFIGURATION ===

configure_sddm() {
    log_step "Configuring SDDM"

    log_info "Creating SDDM configuration drop-in file..."

    sudo mkdir -p "${SDDM_CONF_DIR}"

    sudo tee "${SDDM_THEME_CONF}" >/dev/null <<EOF
[General]
InputMethod=qtvirtualkeyboard
GreeterEnvironment=QML2_IMPORT_PATH=${SDDM_THEME_DEST}/Components/,QT_IM_MODULE=qtvirtualkeyboard

[Theme]
Current=${THEME_NAME}
EOF

    log_ok "SDDM configuration written to ${SDDM_THEME_CONF}"

    # An earlier install of this fork wrote the unprefixed name, which sorts
    # before kde_settings.conf. Two of our own files setting Current= would be
    # decided by filename order, so drop the one that loses.
    if [[ -f "${PREV_SDDM_THEME_CONF}" ]]; then
        sudo rm -f "${PREV_SDDM_THEME_CONF}" \
            && log_ok "Removed superseded ${PREV_SDDM_THEME_CONF}"
    fi

    # /etc/sddm.conf outranks every drop-in, so a Current= there beats anything
    # we just wrote. Several third-party theme installers write it directly.
    # Nothing here edits that file - it is not ours - but reporting success
    # while the greeter is about to show something else is worse than a warning.
    if [[ -f "${SDDM_MAIN_CONF}" ]] \
        && grep -qE "^[[:space:]]*Current[[:space:]]*=" "${SDDM_MAIN_CONF}" \
        && ! grep -qE "^[[:space:]]*Current[[:space:]]*=[[:space:]]*${THEME_NAME}[[:space:]]*$" "${SDDM_MAIN_CONF}"; then
        log_warn "${SDDM_MAIN_CONF} sets its own theme and outranks every drop-in:"
        grep -nE "^[[:space:]]*Current[[:space:]]*=" "${SDDM_MAIN_CONF}" | sed "s|^|    ${SDDM_MAIN_CONF}:|" >&2
        log_warn "The greeter will keep using that theme. Set it to ${THEME_NAME} there, or remove the line."
    fi
}

# === LEGACY NAME MIGRATION ===
#
# This theme installed as "ii-sddm-theme" before the fork. Renaming it is not
# just a directory move, because the theme name is a *value* SDDM resolves:
# [Theme] Current= names a directory under /usr/share/sddm/themes, and SDDM
# loads /usr/lib/sddm/sddm.conf.d, then /etc/sddm.conf.d/*.conf in lexical
# order, then /etc/sddm.conf - "the latter having highest precedence"
# (man 5 sddm.conf). So our drop-in is not authoritative: any drop-in sorting
# after it (kde_settings.conf is the common one, written by the KDE settings
# module, not by us) and /etc/sddm.conf unconditionally can carry their own
# Current=ii-sddm-theme.
#
# So removing the old directory while some later file still points at it leaves
# SDDM with a theme name that resolves to nothing, which is a broken greeter on
# the next boot - the one failure here that is genuinely painful to recover
# from. Every Current= naming the old theme has to be rewritten first,
# wherever it lives.
#
# Ordering is chosen so that any failure leaves the *old* install intact and
# still referenced, rather than half-removed:
#   1. the new theme is already installed and its drop-in written (callers run
#      this after install_theme and configure_sddm);
#   2. repoint every Current= that still names the old theme;
#   3. only then remove the old directory, drop-in and scripts.
# Re-running is harmless: with nothing left under the old name it does nothing.
migrate_legacy_theme_name() {
    log_step "Migrating from ${LEGACY_THEME_NAME}"

    # Refuse to touch anything unless the replacement is actually in place.
    if [[ ! -d "${SDDM_THEME_DEST}" ]]; then
        log_warn "${SDDM_THEME_DEST} is missing; leaving ${LEGACY_THEME_NAME} alone."
        return 0
    fi

    local repointed=0 conf
    for conf in "${SDDM_MAIN_CONF}" "${SDDM_CONF_DIR}"/*.conf; do
        [[ -f "${conf}" ]] || continue
        [[ "${conf}" == "${SDDM_THEME_CONF}" ]] && continue
        if grep -qE "^[[:space:]]*Current[[:space:]]*=[[:space:]]*${LEGACY_THEME_NAME}[[:space:]]*$" "${conf}"; then
            if sudo sed -i -E "s|^([[:space:]]*Current[[:space:]]*=[[:space:]]*)${LEGACY_THEME_NAME}[[:space:]]*$|\1${THEME_NAME}|" "${conf}"; then
                log_ok "Repointed ${conf} at ${THEME_NAME}"
                repointed=$((repointed + 1))
            else
                log_error "Could not rewrite ${conf}; keeping ${LEGACY_THEME_NAME} so the greeter keeps working."
                return 0
            fi
        fi
        # The greeter's QML import path names the theme directory too.
        if grep -q "themes/${LEGACY_THEME_NAME}/" "${conf}"; then
            sudo sed -i "s|themes/${LEGACY_THEME_NAME}/|themes/${THEME_NAME}/|g" "${conf}" \
                && log_ok "Repointed the greeter import path in ${conf}"
        fi
    done
    [[ ${repointed} -eq 0 ]] || log_info "Repointed ${repointed} config file(s)."

    # Our own old drop-in is superseded by SDDM_THEME_CONF; leaving it would
    # mean two files setting Current=, decided by filename order.
    if [[ -f "${LEGACY_SDDM_THEME_CONF}" ]]; then
        sudo rm -f "${LEGACY_SDDM_THEME_CONF}" && log_ok "Removed ${LEGACY_SDDM_THEME_CONF}"
    fi

    if [[ -d "${SDDM_THEMES_DIR}/${LEGACY_THEME_NAME}" ]]; then
        sudo rm -rf "${SDDM_THEMES_DIR}/${LEGACY_THEME_NAME}" \
            && log_ok "Removed ${SDDM_THEMES_DIR}/${LEGACY_THEME_NAME}"
    fi

    # The matugen post_hook is rewritten from THEME_NAME on every run, so it
    # already points at the new scripts directory by the time this runs.
    if [[ -d "${HYPR_SCRIPTS_BASE}/${LEGACY_THEME_NAME}" ]]; then
        if [[ -d "${HYPR_THEME_SCRIPTS_DEST}" ]]; then
            rm -rf "${HYPR_SCRIPTS_BASE}/${LEGACY_THEME_NAME}" \
                && log_ok "Removed ${HYPR_SCRIPTS_BASE}/${LEGACY_THEME_NAME}"
        else
            log_warn "${HYPR_THEME_SCRIPTS_DEST} is missing; keeping ${HYPR_SCRIPTS_BASE}/${LEGACY_THEME_NAME} so the matugen hook still resolves."
        fi
    fi

    log_ok "Migration from ${LEGACY_THEME_NAME} complete."
}

# === ENABLE SDDM ===

enable_sddm() {
    log_step "Enabling SDDM"
    sudo systemctl disable display-manager.service 2>/dev/null || true
    sudo systemctl enable sddm.service
    log_ok "SDDM enabled. It will start on next boot."
}

# === MATUGEN CONFIGURATION ===

configure_matugen() {
    log_step "Matugen integration"

    if [[ ! -f "${MATUGEN_QML_INPUT_TEMPLATE}" ]]; then
        log_error "Matugen input template file not found in ${HYPR_THEME_SCRIPTS_DEST}: ${MATUGEN_QML_INPUT_TEMPLATE}."
        log_error "This indicates an issue with copying selected Matugen files or an unexpected installation type."
        return 1
    fi

    mkdir -p "$(dirname "${MATUGEN_CONF}")"
    touch "${MATUGEN_CONF}"

    local input_path_tilde="~/.config/${THEME_NAME}/SddmColors.qml"
    local output_path_tilde="~/.config/${THEME_NAME}/Colors.qml"
    local post_hook_command=""

    if [[ "${INSTALLATION_TYPE}" == "ii-matugen" ]]; then
        if [[ ! -f "${MATUGEN_GENERATE_SETTINGS_SCRIPT}" ]]; then
            log_error "Python script ${MATUGEN_GENERATE_SETTINGS_SCRIPT} not found for ii-matugen integration. Skipping Matugen post-hook configuration."
            return 1
        fi
        if [[ ! -f "${APPLY_SCRIPT}" ]]; then
            log_error "Apply script ${APPLY_SCRIPT} not found for ii-matugen integration. Skipping Matugen post-hook configuration."
            return 1
        fi
        post_hook_command="python3 ~/.config/${THEME_NAME}/generate_settings.py && sudo ${APPLY_SCRIPT} &"
    elif [[ "${INSTALLATION_TYPE}" == "matugen-only" ]]; then
        if [[ ! -f "${APPLY_SCRIPT}" ]]; then
            log_error "Apply script ${APPLY_SCRIPT} not found for Matugen-only integration. Skipping Matugen post-hook configuration."
            return 1
        fi
        post_hook_command="sudo ${APPLY_SCRIPT} &"
    fi

    # Remove existing [templates.iisddmtheme] block
    if grep -q "^\[templates\.iisddmtheme\]" "${MATUGEN_CONF}"; then
        log_info "Found existing [templates.iisddmtheme] block. Removing it..."

        local temp_file
        temp_file=$(mktemp)
        awk '
            /^\[templates\.iisddmtheme\]/ { skip=1; next }
            /^\[/ { skip=0 }
            !skip { print }
        ' "${MATUGEN_CONF}" >"${temp_file}"
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "${temp_file}"
        mv "${temp_file}" "${MATUGEN_CONF}"
        log_ok "Previous [templates.iisddmtheme] block removed."
    fi

    cat >>"${MATUGEN_CONF}" <<EOF

[templates.iisddmtheme]
input_path = '${input_path_tilde}'
output_path = '${output_path_tilde}'
post_hook = '${post_hook_command}'
EOF
    log_ok "New SDDM template block added to Matugen config: ${MATUGEN_CONF}"

    if command -v matugen &>/dev/null; then
        if [[ "${INSTALLATION_TYPE}" == "ii-matugen" ]]; then
            local current_wallpaper
            current_wallpaper=$(cat "${HOME}/.local/state/quickshell/user/generated/wallpaper/path.txt" 2>/dev/null || echo "")
            if [[ -f "${current_wallpaper}" ]]; then
                log_info "Running matugen with current wallpaper to initialize SDDM theme: ${current_wallpaper}"
                matugen image "${current_wallpaper}" --source-color-index 0
            else
                log_warn "Could not detect current wallpaper. You may need to change your wallpaper once to trigger Matugen for SDDM theme synchronization."
            fi
        elif [[ "${INSTALLATION_TYPE}" == "matugen-only" ]]; then
            log_info "Run 'matugen image <your-wallpaper-path>' once to initialize the SDDM theme."
        fi
    fi

    return 0
}

# === SUDOERS CONFIGURATION ===

setup_sudoers() {
    log_step "Configuring sudoers for passwordless execution"
    if [[ ! -f "${APPLY_SCRIPT}" ]]; then
        log_warn "Apply script not found at expected path (${APPLY_SCRIPT}). Sudoers configuration cannot proceed."
        return 0
    fi

    # The check visudo cannot do. `visudo -c` validates SYNTAX only - it has no
    # idea whether the path it just accepted is a file the invoking user can
    # rewrite, which is the difference between "run this one script as root" and
    # NOPASSWD: ALL. Refuse rather than install a rule that grants standing root.
    #
    # Every component of the path matters, not just the file: a writable parent
    # lets the user replace the file by renaming it. Root-owned and not
    # group/other-writable is the property being asserted.
    local p="${APPLY_SCRIPT}"
    while :; do
        if [[ -e "${p}" ]]; then
            local owner perms
            owner="$(stat -c '%U' "${p}")"
            perms="$(stat -c '%a' "${p}")"
            if [[ "${owner}" != "root" ]]; then
                log_error "Refusing to grant NOPASSWD on ${APPLY_SCRIPT}: ${p} is owned by '${owner}', not root."
                log_error "A sudoers rule naming a user-writable path is equivalent to NOPASSWD: ALL."
                return 1
            fi
            if [[ "${perms: -1}" =~ [2367] || "${perms: -2:1}" =~ [2367] ]]; then
                log_error "Refusing to grant NOPASSWD on ${APPLY_SCRIPT}: ${p} is group- or world-writable (${perms})."
                return 1
            fi
        fi
        [[ "${p}" == "/" ]] && break
        p="$(dirname "${p}")"
    done

    local sudoers_rule="${USERNAME} ALL=(ALL) NOPASSWD: ${APPLY_SCRIPT}"
    local temp_file
    temp_file=$(mktemp)

    printf '%s\n' "${sudoers_rule}" >"${temp_file}"

    if ! visudo -c -f "${temp_file}" >/dev/null 2>&1; then
        log_error "Invalid sudoers rule generated. Aborting sudoers configuration."
        rm -f "${temp_file}"
        return 1
    fi

    sudo cp "${temp_file}" "${SUDOERS_FILE}"
    sudo chmod 0440 "${SUDOERS_FILE}"
    rm -f "${temp_file}"

    log_ok "Sudoers configured: ${USERNAME} can run ${APPLY_SCRIPT} without password."
}

# === MAIN ===

main() {
    introduction
    check_requirements
    get_aur_helper
    check_git
    check_sddm_installation

    clone_repo_to_temp

    detect_configs_and_select_installation_type

    install_deps
    install_theme

    configure_sddm
    enable_sddm

    copy_specific_files_to_hypr

    if [[ "${INSTALLATION_TYPE}" == "ii-matugen" || "${INSTALLATION_TYPE}" == "matugen-only" ]]; then
        configure_matugen
        setup_sudoers

        log_step "Applying SDDM theme"
        if [[ -f "${APPLY_SCRIPT}" ]]; then
            if [[ "${INSTALLATION_TYPE}" == "ii-matugen" ]]; then
                if ! python3 "${MATUGEN_GENERATE_SETTINGS_SCRIPT}" > /dev/null 2>&1; then
                    log_warn "generate_settings.py failed. Theme application might be incomplete."
                fi
            fi

            # `|| true` made this condition unconditionally true, so the else
            # branch was dead code and the installer printed "Theme applied."
            # no matter what the script did - which is how a permanently failing
            # apply survived the becaa77 rename unnoticed. Still non-fatal, but
            # now reported honestly, and with the output that was being thrown
            # away.
            local apply_rc=0 apply_log
            apply_log="$(mktemp)"
            sudo bash "${APPLY_SCRIPT}" >"${apply_log}" 2>&1 || apply_rc=$?
            if (( apply_rc == 0 )); then
                log_ok "Theme applied."
            else
                log_warn "Failed to apply theme automatically (exit ${apply_rc}). Run manually: sudo ${APPLY_SCRIPT}"
                sed 's/^/    /' "${apply_log}" >&2
            fi
            rm -f "${apply_log}"
        else
            log_warn "Apply script not found at ${APPLY_SCRIPT}. Theme will be applied on next Matugen run."
        fi

    elif [[ "${INSTALLATION_TYPE}" == "no-matugen" ]]; then
        log_step "Applying SDDM theme"
        if [[ -f "${APPLY_SCRIPT}" ]]; then
            # `|| true` made this condition unconditionally true, so the else
            # branch was dead code and the installer printed "Theme applied."
            # no matter what the script did - which is how a permanently failing
            # apply survived the becaa77 rename unnoticed. Still non-fatal, but
            # now reported honestly, and with the output that was being thrown
            # away.
            local apply_rc=0 apply_log
            apply_log="$(mktemp)"
            sudo bash "${APPLY_SCRIPT}" >"${apply_log}" 2>&1 || apply_rc=$?
            if (( apply_rc == 0 )); then
                log_ok "Theme applied."
            else
                log_warn "Failed to apply theme automatically (exit ${apply_rc}). Run manually: sudo ${APPLY_SCRIPT}"
                sed 's/^/    /' "${apply_log}" >&2
            fi
            rm -f "${apply_log}"
        else
            log_warn "Apply script not found at ${APPLY_SCRIPT}. Theme application skipped."
        fi
    fi

    # Last, so everything replacing the old install - the theme directory, the
    # drop-in, the scripts directory and the rewritten matugen post_hook - is
    # already on disk before anything is removed.
    migrate_legacy_theme_name

    local msg=" Installation completed successfully "
    local width=${#msg}
    local border
    border=$(printf '─%.0s' $(seq 1 $width))
    printf "\n"
    printf "  ${STY_GREEN}┌%s┐${STY_RST}\n" "${border}"
    printf "  ${STY_GREEN}│%s│${STY_RST}\n" "${msg}"
    printf "  ${STY_GREEN}└%s┘${STY_RST}\n" "${border}"
    printf "\n"

    printf -- "-- Optional: Test the theme with the following command:\n"
    printf "   ${STY_YELLOW}sddm-greeter-qt6 --test-mode --theme %s${STY_RST}\n" "${SDDM_THEME_DEST}"
    log_info "Test mode will open fullscreen. Appearance may have minor differences from the actual login screen."
    printf "\n"

    printf -- "-- Reboot your system\n"
    log_warn "Please REBOOT your system to apply the new SDDM theme and configurations."

    if [[ -d "${CLONE_DIR}" ]]; then
        rm -rf "${CLONE_DIR}"
    fi
}

# Only run when executed, not when sourced, so individual functions can be
# exercised against a temporary tree without installing anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
