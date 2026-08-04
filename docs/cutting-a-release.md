# Cutting an imi-sddm-theme release

This repo has no build and no CI. A "release" here is a **tag**, and the tag
exists for one reason: so the hub can pin something whose staleness is visible.

## Why tags at all

The hub pins this repo by ref in two places, and fetches `setup.sh` from that
ref over `raw.githubusercontent.com`:

- `sdata/subcmd-install/5.sddm-theme.sh` — `SDDM_REF`
- `sdata/subcmd-uninstall/0.run.sh` — the same value, duplicated

A bare SHA works there, and that is what was used until 0.1.0. It is also how
three shipped defects went unnoticed for as long as they did: a SHA gives a
reader no way to tell whether the pin is current or a year old, and `repo-status`
can only say "N commits behind", never "you are two releases behind".

A `vX.Y.Z` pin makes that legible at a glance.

## Steps

1. Make sure `main` is what you want to ship. There is no CI here, so this is
   the only gate — read the diff since the last tag:

   ```bash
   git log --oneline $(git describe --tags --abbrev=0)..main
   ```

2. **Static review only.** Do not run `setup.sh`, `uninstall.sh` or `check.sh`
   to "verify" a release: they modify the real system as root, and `check.sh`
   still reports FAIL on a correct install (#4). See AGENTS.md.

3. Roll `CHANGELOG.md` — move the `[Unreleased]` items under the new version
   with today's date — and bump `VERSION`.

4. Tag and push:

   ```bash
   git tag vX.Y.Z && git push origin main && git push origin vX.Y.Z
   ```

5. **Move the hub's pin, in both places.** Until you do, the release reaches
   nobody. Pin the **full SHA the tag points at**, not the tag name:

   ```bash
   git rev-parse vX.Y.Z^{commit}
   ```

   - `sdata/subcmd-install/5.sddm-theme.sh` → `SDDM_REF="${SDDM_REF:-<sha>}"`
   - `sdata/subcmd-uninstall/0.run.sh` → the same value

   The hub enforces this (`test_the_pin_is_a_full_commit_sha`), and the reason is
   worth keeping: a tag can be force-moved, so pinning one lets the theme change
   under a release that already shipped. A SHA cannot. This differs from
   `WE_REF`, which pins a *tag* on purpose — there the tag selects a published
   release artifact, and the installer's prebuilt fast path only triggers for a
   `v*` ref.

   Staleness is still visible: `repo-status` asks GitHub whether the pin is the
   tip of the satellite's default branch, so a SHA pin no longer goes stale
   silently the way it did before that check existed.

   The hub has a test pinning that those two agree
   (`dots/.config/quickshell/imi/tests/test_sddm_theme_source.py`). It checks
   they *match*, not that they are current.

## What a release does not do

There are no assets, no packages, and nothing to download. The installer clones
the repo at the pinned ref, so the tag is the entire artifact.

Note that `setup.sh` clones `THEME_REPO` **unpinned** (#5), so a downstream
`SDDM_REF` pin does not fully pin what lands on disk — the fetched `setup.sh`
comes from the pinned ref, but the theme content it then clones comes from
whatever `main` is at that moment. Until that is fixed, a tag is a pin on the
installer, not on the theme.
