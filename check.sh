#!/usr/bin/env bash

# Read-only diagnostic for an installed imi-sddm-theme. It never writes
# anything; every path below is derived from the same variables setup.sh and
# uninstall.sh use, because the whole point of this script is to tell the user
# whether what is on disk matches what the installer claims to have put there.

# === CONFIGURATION ===

readonly THEME_NAME="imi-sddm-theme"
# The pre-fork name. setup.sh migrates installs away from it; anything still
# under it means the migration has not run or did not finish.
readonly LEGACY_THEME_NAME="ii-sddm-theme"

# Overridable exactly as in setup.sh/uninstall.sh, so the check functions can be
# exercised against a temporary tree instead of the real /etc. Nothing in normal
# use sets these.
readonly SDDM_THEMES_DIR="${SDDM_THEMES_DIR:-/usr/share/sddm/themes}"
readonly SDDM_THEME_DEST="${SDDM_THEMES_DIR}/${THEME_NAME}"
readonly LEGACY_SDDM_THEME_DEST="${SDDM_THEMES_DIR}/${LEGACY_THEME_NAME}"
readonly SDDM_CONF_DIR="${SDDM_CONF_DIR:-/etc/sddm.conf.d}"
# Per man 5 sddm.conf: /usr/lib/sddm/sddm.conf.d, then /etc/sddm.conf.d/*.conf
# in lexical order, then /etc/sddm.conf, "with the latter having highest
# precedence". So this file, and any drop-in sorting after ours, can silently
# win - which is the failure this script exists to make visible.
readonly SDDM_MAIN_CONF="${SDDM_MAIN_CONF:-/etc/sddm.conf}"
# Must match setup.sh. The zz- prefix is what makes the drop-in sort after
# kde_settings.conf; a numeric prefix does not work, digits sort before letters.
readonly SDDM_THEME_CONF="${SDDM_CONF_DIR}/zz-${THEME_NAME}.conf"
# The unprefixed name this fork wrote before the zz- prefix, and the pre-fork
# name. Either one left behind is a second file setting Current=.
readonly PREV_SDDM_THEME_CONF="${SDDM_CONF_DIR}/${THEME_NAME}.conf"
readonly LEGACY_SDDM_THEME_CONF="${SDDM_CONF_DIR}/${LEGACY_THEME_NAME}.conf"

readonly HYPR_SCRIPTS_BASE="${HOME}/.config"
readonly HYPR_THEME_SCRIPTS_DEST="${HYPR_SCRIPTS_BASE}/${THEME_NAME}"
readonly LEGACY_HYPR_THEME_SCRIPTS_DEST="${HYPR_SCRIPTS_BASE}/${LEGACY_THEME_NAME}"

readonly MATUGEN_CONF="${HOME}/.config/matugen/config.toml"

readonly USERNAME="${USER:-$(id -un)}"
# Must match setup.sh: root-owned and outside $HOME, because the sudoers rule
# names it NOPASSWD and sudo matches by path. A user-writable target there is
# equivalent to NOPASSWD: ALL, so "is it root-owned" is a security check, not a
# tidiness one.
# Overridable for the same reason as the SDDM_* paths above - this script only
# ever reads, so pointing it at a temporary tree exercises the ownership check
# without needing a real install.
readonly PRIV_SCRIPT_DIR="${PRIV_SCRIPT_DIR:-/usr/local/lib/${THEME_NAME}}"
readonly APPLY_SCRIPT="${PRIV_SCRIPT_DIR}/sddm-theme-apply.sh"
readonly LEGACY_APPLY_SCRIPT="${HYPR_THEME_SCRIPTS_DEST}/sddm-theme-apply.sh"
readonly SUDOERS_FILE="/etc/sudoers.d/sddm-theme-${USERNAME}"

# Genuinely still the legacy name: setup.sh installs fonts from
# fonts/ii-sddm-theme-fonts to /usr/share/fonts under that name.
readonly FONTS_DIR="/usr/share/fonts/ii-sddm-theme-fonts"

# === COLORS ===

STY_CYAN='\e[36m'
STY_GREEN='\e[32m'
STY_YELLOW='\e[33m'
STY_RED='\e[31m'
STY_RST='\e[0m'

# === LOGGING ===

failures=0
warnings=0

log_ok()   { printf "  ${STY_GREEN}[OK]   %s${STY_RST}\n" "$*"; }
log_warn() { printf "  ${STY_YELLOW}[WARN] %s${STY_RST}\n" "$*"; warnings=$((warnings + 1)); }
log_fail() { printf "  ${STY_RED}[FAIL] %s${STY_RST}\n" "$*"; failures=$((failures + 1)); }
log_step() { printf "\n-- %s\n" "$*"; }

# === CHECKS ===

check_dependencies() {
    log_step "Dependencies"

    local pkgs=(sddm qt6-svg qt6-virtualkeyboard qt6-multimedia-ffmpeg)
    for pkg in "${pkgs[@]}"; do
        if pacman -Q "${pkg}" >/dev/null 2>&1; then
            log_ok "${pkg} installed"
        else
            log_fail "${pkg} missing"
        fi
    done

    if command -v matugen >/dev/null 2>&1; then
        log_ok "matugen found"
    else
        log_warn "matugen not found (only required for matugen integrations)"
    fi

    if command -v python3 >/dev/null 2>&1; then
        log_ok "python3 found"
    else
        log_warn "python3 not found (only required for the ii-matugen integration)"
    fi
}

check_sddm_theme() {
    log_step "SDDM theme"

    if [[ -d "${SDDM_THEME_DEST}" ]]; then
        log_ok "Theme directory exists: ${SDDM_THEME_DEST}"
    else
        log_fail "Theme directory missing: ${SDDM_THEME_DEST}"
        return
    fi

    for f in Main.qml metadata.desktop; do
        if [[ -f "${SDDM_THEME_DEST}/${f}" ]]; then
            log_ok "${f} present"
        else
            log_fail "${f} missing in ${SDDM_THEME_DEST}"
        fi
    done

    if find "${SDDM_THEME_DEST}/Backgrounds/" -maxdepth 1 -name 'background.*' 2>/dev/null | grep -q .; then
        log_ok "Background file present"
    else
        log_warn "No background file found in ${SDDM_THEME_DEST}/Backgrounds/"
    fi

    for f in Components/Colors.qml Components/Settings.qml; do
        if [[ -f "${SDDM_THEME_DEST}/${f}" ]]; then
            log_ok "${f} present"
        else
            log_warn "${f} missing (may not be generated yet — run matugen once)"
        fi
    done

    # The pre-rename install. setup.sh's migration removes it, so its presence
    # means either the migration has not run or it stopped before the delete -
    # and a leftover directory is what a stale Current= resolves against.
    if [[ -d "${LEGACY_SDDM_THEME_DEST}" ]]; then
        log_warn "Pre-rename install still present: ${LEGACY_SDDM_THEME_DEST} (re-run setup.sh to migrate it)"
    fi
}

# The check the old version could not do, and the reason a completely broken
# sync used to pass: everything above only proves files were *installed*. The
# generated colours and settings live in the user's config directory and the
# apply script copies them into the installed theme - so if the generated file
# exists and the installed one differs, the apply script has not run since it
# was generated, and the greeter is showing something older than the desktop.
# That is the exact signature of #1, where the apply script exited before
# copying anything and the installer still reported success.
check_theme_is_current() {
    log_step "Generated files reached the greeter"

    if [[ ! -d "${SDDM_THEME_DEST}" || ! -d "${HYPR_THEME_SCRIPTS_DEST}" ]]; then
        log_warn "Skipped: theme or scripts directory missing (see above)"
        return
    fi

    local generated installed pair
    local checked=0 stale=0
    for pair in "Colors.qml:Components/Colors.qml" "Settings.qml:Components/Settings.qml"; do
        generated="${HYPR_THEME_SCRIPTS_DEST}/${pair%%:*}"
        installed="${SDDM_THEME_DEST}/${pair##*:}"
        [[ -f "${generated}" ]] || continue
        checked=$((checked + 1))
        if [[ ! -f "${installed}" ]]; then
            log_fail "${pair%%:*} was generated but never installed to ${installed}"
            stale=1
        elif cmp -s "${generated}" "${installed}"; then
            log_ok "${pair%%:*} matches the installed theme"
        else
            log_fail "${installed} is stale: it differs from the generated ${generated}"
            stale=1
        fi
    done

    if [[ "${checked}" -eq 0 ]]; then
        log_warn "Nothing generated yet in ${HYPR_THEME_SCRIPTS_DEST} (only applies to matugen integrations)"
    elif [[ "${stale}" -eq 1 ]]; then
        log_warn "Run the apply script manually to see why: sudo ${APPLY_SCRIPT}"
    fi
}

check_sddm_conf() {
    log_step "SDDM configuration"

    if [[ -f "${SDDM_THEME_CONF}" ]]; then
        log_ok "Drop-in exists: ${SDDM_THEME_CONF}"
    else
        log_fail "Drop-in missing: ${SDDM_THEME_CONF}"
        if [[ -f "${PREV_SDDM_THEME_CONF}" ]]; then
            log_fail "Found ${PREV_SDDM_THEME_CONF} instead: it sorts before kde_settings.conf and loses (re-run setup.sh)"
        fi
        return
    fi

    if grep -qE "^[[:space:]]*Current[[:space:]]*=[[:space:]]*${THEME_NAME}[[:space:]]*$" "${SDDM_THEME_CONF}"; then
        log_ok "Current=${THEME_NAME} set"
    else
        log_fail "Current=${THEME_NAME} not set in ${SDDM_THEME_CONF}"
    fi

    if grep -q "QML2_IMPORT_PATH" "${SDDM_THEME_CONF}"; then
        log_ok "QML2_IMPORT_PATH set"
    else
        log_warn "QML2_IMPORT_PATH not found in ${SDDM_THEME_CONF}"
    fi

    # Two of our own files both setting Current= would be decided by filename
    # order, not by which one is current.
    local stale
    for stale in "${PREV_SDDM_THEME_CONF}" "${LEGACY_SDDM_THEME_CONF}"; do
        [[ -f "${stale}" ]] || continue
        log_warn "Superseded drop-in still present: ${stale} (re-run setup.sh to remove it)"
    done

    check_sddm_conf_precedence
}

# Which file actually decides the theme. This is the failure mode that reports
# success and shows the wrong greeter anyway, so it gets its own check: a
# drop-in sorting after ours, or /etc/sddm.conf at any position, outranks what
# we wrote.
check_sddm_conf_precedence() {
    local ours winner="" conf
    ours="$(basename "${SDDM_THEME_CONF}")"

    if [[ -d "${SDDM_CONF_DIR}" ]]; then
        for conf in "${SDDM_CONF_DIR}"/*.conf; do
            [[ -f "${conf}" ]] || continue
            [[ "$(basename "${conf}")" > "${ours}" ]] || continue
            grep -qE "^[[:space:]]*Current[[:space:]]*=" "${conf}" || continue
            grep -qE "^[[:space:]]*Current[[:space:]]*=[[:space:]]*${THEME_NAME}[[:space:]]*$" "${conf}" && continue
            winner="${conf}"
        done
    fi

    if [[ -f "${SDDM_MAIN_CONF}" ]] \
        && grep -qE "^[[:space:]]*Current[[:space:]]*=" "${SDDM_MAIN_CONF}" \
        && ! grep -qE "^[[:space:]]*Current[[:space:]]*=[[:space:]]*${THEME_NAME}[[:space:]]*$" "${SDDM_MAIN_CONF}"; then
        winner="${SDDM_MAIN_CONF}"
    fi

    if [[ -n "${winner}" ]]; then
        log_fail "${winner} sets its own theme and outranks ${SDDM_THEME_CONF}:"
        grep -nE "^[[:space:]]*Current[[:space:]]*=" "${winner}" | sed "s|^|         ${winner}:|"
        log_warn "The greeter will use that theme, not ${THEME_NAME}. setup.sh does not edit that file - change it by hand."
    else
        log_ok "No higher-precedence config overrides Current=${THEME_NAME}"
    fi
}

check_hypr_scripts() {
    log_step "Theme scripts"

    if [[ -d "${HYPR_THEME_SCRIPTS_DEST}" ]]; then
        log_ok "Scripts directory exists: ${HYPR_THEME_SCRIPTS_DEST}"
    else
        log_fail "Scripts directory missing: ${HYPR_THEME_SCRIPTS_DEST}"
        return
    fi

    if [[ -f "${HYPR_THEME_SCRIPTS_DEST}/SddmColors.qml" ]]; then
        log_ok "SddmColors.qml present"
    else
        log_warn "SddmColors.qml missing (only required for matugen integrations)"
    fi

    if [[ -f "${HYPR_THEME_SCRIPTS_DEST}/generate_settings.py" ]]; then
        log_ok "generate_settings.py present"
    else
        log_warn "generate_settings.py missing (only required for the ii-matugen integration)"
    fi

    if [[ -d "${LEGACY_HYPR_THEME_SCRIPTS_DEST}" ]]; then
        log_warn "Pre-rename scripts still present: ${LEGACY_HYPR_THEME_SCRIPTS_DEST} (re-run setup.sh to migrate them)"
    fi
}

# The apply script is the only thing here that runs as root without a password,
# so where it lives and who owns it is the security-relevant part of this whole
# install. Checking that it is merely *present* is not enough - it used to live
# in the user's own config directory, and a NOPASSWD rule naming a path the user
# can rewrite is equivalent to NOPASSWD: ALL.
check_apply_script() {
    log_step "Apply script"

    if [[ -f "${APPLY_SCRIPT}" ]]; then
        log_ok "sddm-theme-apply.sh present: ${APPLY_SCRIPT}"
    else
        log_fail "sddm-theme-apply.sh missing: ${APPLY_SCRIPT}"
        if [[ -f "${LEGACY_APPLY_SCRIPT}" ]]; then
            log_fail "Found the pre-move copy at ${LEGACY_APPLY_SCRIPT}; re-run setup.sh to install it root-owned"
        fi
        return
    fi

    if [[ -x "${APPLY_SCRIPT}" ]]; then
        log_ok "sddm-theme-apply.sh is executable"
    else
        log_fail "sddm-theme-apply.sh is not executable"
    fi

    # Every component of the path matters, not just the file: a writable parent
    # lets the user replace the file by renaming it.
    local p="${APPLY_SCRIPT}" owner perms insecure=0
    while :; do
        if [[ -e "${p}" ]]; then
            owner="$(stat -c '%U' "${p}")"
            perms="$(stat -c '%a' "${p}")"
            if [[ "${owner}" != "root" ]]; then
                log_fail "${p} is owned by '${owner}', not root - the sudoers rule naming it grants standing root"
                insecure=1
            elif [[ "${perms: -1}" =~ [2367] || "${perms: -2:1}" =~ [2367] ]]; then
                log_fail "${p} is group- or world-writable (${perms}) - the sudoers rule naming it grants standing root"
                insecure=1
            fi
        fi
        [[ "${p}" == "/" ]] && break
        p="$(dirname "${p}")"
    done
    [[ "${insecure}" -eq 0 ]] && log_ok "${APPLY_SCRIPT} is root-owned along its whole path"

    # Left behind, this is a user-writable file with the same name one directory
    # away from a rule that used to point at it.
    if [[ -f "${LEGACY_APPLY_SCRIPT}" ]]; then
        log_fail "Pre-move copy still present: ${LEGACY_APPLY_SCRIPT} (re-run setup.sh, or delete it)"
    fi
}

check_fonts() {
    log_step "Fonts"

    # Still the legacy name on purpose: setup.sh installs fonts/ii-sddm-theme-fonts
    # under that name, so renaming this without renaming that would be the same
    # class of mismatch this script exists to catch.
    if [[ -d "${FONTS_DIR}" ]]; then
        log_ok "Font directory exists: ${FONTS_DIR}"
    else
        log_warn "Font directory missing: ${FONTS_DIR}"
    fi
}

check_matugen_conf() {
    log_step "Matugen configuration"

    if [[ ! -f "${MATUGEN_CONF}" ]]; then
        log_warn "${MATUGEN_CONF} not found (only required for matugen integrations)"
        return
    fi

    log_ok "${MATUGEN_CONF} present"

    # Deliberately still keyed "iisddmtheme": it is a matugen template id, not a
    # path, and renaming it would orphan the block on every existing install.
    if ! grep -q "^\[templates\.iisddmtheme\]" "${MATUGEN_CONF}"; then
        log_warn "[templates.iisddmtheme] block missing (only required for matugen integrations)"
        check_matugen_stray_hook
        return
    fi
    log_ok "[templates.iisddmtheme] block found"

    # The block is what regenerates the greeter's colours; a post_hook without
    # it fires forever and regenerates nothing. The hub's dots sync used to
    # delete the whole block and restore only the hook, which produced exactly
    # that state and reported success (immaterial-impulse#101).
    local block key
    block="$(awk '
        /^\[templates\.iisddmtheme\]/ { skip=1; next }
        /^\[/ { skip=0 }
        skip { print }
    ' "${MATUGEN_CONF}")"

    for key in input_path output_path; do
        if grep -qE "^[[:space:]]*${key}[[:space:]]*=" <<<"${block}"; then
            log_ok "${key} set in [templates.iisddmtheme]"
        else
            log_fail "${key} missing from [templates.iisddmtheme] - colours will never be regenerated"
        fi
    done

    if ! grep -qE "^[[:space:]]*post_hook[[:space:]]*=" <<<"${block}"; then
        log_warn "post_hook missing from [templates.iisddmtheme] (present only in matugen integrations)"
    elif grep -q "${APPLY_SCRIPT}" <<<"${block}"; then
        log_ok "post_hook calls ${APPLY_SCRIPT}"
    else
        log_fail "post_hook does not call ${APPLY_SCRIPT}:"
        grep -E "^[[:space:]]*post_hook[[:space:]]*=" <<<"${block}" | sed 's|^|         |'
        log_warn "sudo matches the sudoers rule by path, so a hook naming any other path prompts for a password and never completes."
    fi

    check_matugen_stray_hook
}

# A post_hook outside the template block runs after *every* matugen invocation,
# not just this template's. One ends up there when something restores the hook
# without the block it belongs to.
check_matugen_stray_hook() {
    local stray
    stray="$(awk '
        /^\[templates\.iisddmtheme\]/ { skip=1; next }
        /^\[/ { skip=0 }
        !skip && /^[[:space:]]*post_hook[[:space:]]*=/ { print }
    ' "${MATUGEN_CONF}")"
    [[ -n "${stray}" ]] || return 0
    grep -q "sddm-theme-apply" <<<"${stray}" || return 0

    log_fail "An SDDM post_hook sits outside [templates.iisddmtheme]:"
    sed 's|^|         |' <<<"${stray}"
    log_warn "It fires after every matugen run rather than this template's, and regenerates nothing on its own. Remove it and re-run setup.sh."
}

check_sudoers() {
    log_step "Sudoers"

    if sudo test -f "${SUDOERS_FILE}"; then
        log_ok "Sudoers rule exists: ${SUDOERS_FILE}"
    else
        log_warn "Sudoers rule missing: ${SUDOERS_FILE} (only required for matugen integrations)"
        return
    fi

    if sudo visudo -c -f "${SUDOERS_FILE}" >/dev/null 2>&1; then
        log_ok "Sudoers rule is valid"
    else
        log_fail "Sudoers rule failed validation"
    fi

    # A rule naming the old in-home path is the escalation the move fixed.
    if sudo grep -q "${APPLY_SCRIPT}" "${SUDOERS_FILE}" 2>/dev/null; then
        log_ok "Sudoers rule names ${APPLY_SCRIPT}"
    else
        log_fail "Sudoers rule does not name ${APPLY_SCRIPT} - re-run setup.sh"
        sudo grep -v '^[[:space:]]*#' "${SUDOERS_FILE}" 2>/dev/null | sed 's|^|         |'
    fi
}

check_sddm_service() {
    log_step "SDDM service"

    if systemctl is-enabled sddm.service >/dev/null 2>&1; then
        log_ok "sddm.service is enabled"
    else
        log_warn "sddm.service is not enabled"
    fi
}

# === MAIN ===

main() {
    clear
    printf "\n"
    printf "${STY_CYAN}CHECK ${THEME_NAME}${STY_RST}\n"
    printf "\n"

    check_dependencies
    check_sddm_theme
    check_sddm_conf
    check_hypr_scripts
    check_apply_script
    check_theme_is_current
    check_fonts
    check_matugen_conf
    check_sudoers
    check_sddm_service

    printf "\n-- Result\n"
    printf "  Failures : ${STY_RED}%d${STY_RST}\n" "${failures}"
    printf "  Warnings : ${STY_YELLOW}%d${STY_RST}\n" "${warnings}"

    if [[ "${failures}" -gt 0 ]]; then
        printf "\n  ${STY_RED}Some checks failed. Run setup.sh to repair the installation.${STY_RST}\n"
        exit 1
    elif [[ "${warnings}" -gt 0 ]]; then
        printf "\n  ${STY_YELLOW}Installation looks good, but review the warnings above.${STY_RST}\n"
    else
        printf "\n  ${STY_GREEN}All checks passed.${STY_RST}\n"
    fi
}

# Only run when executed, not when sourced, so the checks above can be exercised
# individually - against a temporary tree via the SDDM_* overrides - without
# running the whole diagnostic against the real system.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
