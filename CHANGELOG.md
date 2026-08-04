# Changelog

imi-sddm-theme follows [Semantic Versioning](https://semver.org/) (currently
pre-1.0: `0.x` may change without notice). The current version is in `VERSION`.

This is a **satellite** of [`XephyLon/immaterial-impulse`](https://github.com/XephyLon/immaterial-impulse),
which pins the revision it installs as `SDDM_REF` (in both
`sdata/subcmd-install/5.sddm-theme.sh` and `sdata/subcmd-uninstall/0.run.sh`).
Nothing here reaches a user until that pin moves.

Until this file existed the repo had **no tags at all**, so it could only be
pinned by SHA — the mode that goes stale invisibly, and did: three separate
defects below shipped behind a pin nobody noticed was old.

## [0.1.1] — 2026-08-04

### Fixed
- **The greeter showed a wallpaper from months ago.** It read the shell's
  `activeStill`, and nothing has written that field since the shell's
  selector-only refactor removed the code that generated those stills
  ([immaterial-impulse#103](https://github.com/XephyLon/immaterial-impulse/issues/103)).
  It sat frozen at whatever project was active that day, and applying a preset
  restored the stale value rather than correcting it. It now reads
  `activePreview`, which the shell writes on every wallpaper switch and which
  always names the active project.

  The trade-off: `preview.jpg` is preview-sized, so the greeter background is
  lower resolution than a full still. A *scene* wallpaper has no full-resolution
  still at all — the shell used to render one, and that renderer is gone — so
  this is the best available source until still generation is revived.

## [0.1.0] — 2026-08-04

First tagged release. Everything below was already on `main`; this is the point
at which it became referable by a name instead of a hash.

### Security
- **The sudoers rule no longer grants standing root.** The matugen integration
  installs a `NOPASSWD` rule for the apply script, and that script lived inside
  the user's own home directory. `sudo` matches a rule by *path*, not by owner
  or content, so anything running as that user could rewrite the script and run
  it as root without a password — functionally `NOPASSWD: ALL`, and it outlived
  uninstalling everything except the sudoers file. The script is now installed
  root-owned at `/usr/local/lib/imi-sddm-theme/`, and the installer refuses to
  write the rule at all unless the target and every parent directory is
  root-owned and not group- or world-writable — the check `visudo -c` cannot
  perform, since it validates syntax only.

  **Existing installs stay exposed until the installer is re-run**, because the
  old rule and the old script are already on disk. Re-running replaces both.

### Fixed
- **The theme actually applies.** All three `sddm-theme-apply.sh` variants still
  used the pre-fork theme name, so since the rename no install had copied the
  user's wallpaper or colours into the installed theme — the greeter kept the
  stock background, and the matugen hook failed on every wallpaper change, while
  the installer reported success.
- **Uninstalling no longer breaks login.** It removed the theme directory but
  left `Current=` and the greeter's QML import path naming it, so SDDM came up
  pointing at a theme that no longer existed: a login loop after a *correct*
  password. Uninstall now reverts those references first, and refuses to remove
  the directory if any config still names it.
- **The config drop-in wins.** It sorted before KDE's `kde_settings.conf` and
  lost, so on any system where the KDE Login Screen module had been used the
  install silently changed nothing. It is now `zz-`-prefixed. A numeric prefix
  would not have worked — digits sort before letters.
- The installer no longer reports `Theme applied.` unconditionally. `|| true`
  made that branch unreachable and discarded the apply script's stderr, which is
  how a permanently failing apply survived the rename unnoticed.
