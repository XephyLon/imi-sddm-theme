# AGENTS.md

Reference for coding agents (and humans) working in this repository.

> **Read this file sequentially, in full, top to bottom, before any work — and again after a
> context compaction.** Grep hits and section jumps are not reading: the rules that get broken are
> the ones adjacent to the section someone jumped to.

## Read this first

**This code runs as root and can lock the user out of their machine.** It installs an SDDM theme into
`/usr/share/sddm/themes`, writes `/etc/sddm.conf.d/`, edits `/etc/sddm.conf`, and installs a sudoers
rule. If SDDM cannot load its greeter, there is no graphical login — no desktop, no terminal emulator,
just a black screen and a TTY if the user knows to find one.

Weight everything accordingly. A wrong colour is cosmetic. Anything that can leave SDDM pointing at a
theme that does not exist, or a config it cannot parse, is critical.

**Do not run `setup.sh`, `uninstall.sh`, or `check.sh` while developing.** Not "carefully", not "with
a backup" — they modify the real system as root. Static review only, unless the user has explicitly
asked you to install.

## Doc discipline

**Every point added to this file must cite the commit that motivated it** — the change it
documents, or the mistake it guards against — kernel `Fixes:` style:

```
bf34d6c ("fix(apply): prefer the shell's full-resolution still over the preview")
```

A point with no commit behind it is unverifiable folklore; the citation is what lets the next agent
judge whether the reasoning still applies. `tests/lint_doc_citations.py` (run by
`.github/workflows/docs.yml` — this repo's first CI) fails on any citation that resolves to nothing
— by SHA **or** by exact subject line, the fallback existing because rebase merges rewrite SHAs and
the subject is the half that survives.

The worked motivation: bf34d6c ("fix(apply): prefer the shell's full-resolution still over the
preview") taught this theme to read a stored `activeStill` path — the very field
[immaterial-impulse#103](https://github.com/XephyLon/immaterial-impulse/issues/103) was filed
about, restored hub-side without that issue ever being read. A citation on the hub's doc entry
would have put the issue one click from the person about to repeat it.

**Every PR body must carry a `Docs:` receipt line**, enforced by
`.github/workflows/docs-receipt.yml`: either `Docs: updated AGENTS.md §<section>` or
`Docs: not needed — <reason>`. It converts "did you consider the docs" (unverifiable) into a line
a reviewer checks in seconds.

## What this is

An SDDM theme, forked from upstream and adapted for
[`XephyLon/immaterial-impulse`](https://github.com/XephyLon/immaterial-impulse) (the shell, "the hub").
It renders the login greeter with the user's own colours and wallpaper, so the login screen matches
the desktop.

It is a **satellite**: the hub fetches `setup.sh` from a pinned commit and executes it. The pin lives
in the hub at `sdata/subcmd-install/5.sddm-theme.sh` as `SDDM_REF`, and is duplicated in the hub's
`sdata/subcmd-uninstall/0.run.sh`. **Those two have silently disagreed before while a comment claimed
they matched** — if you change one, change both, and the hub has a test pinning them
(`dots/.config/quickshell/imi/tests/test_sddm_theme_source.py`).

This repo has **no tags**, so it can only be pinned by SHA — the mode that goes stale invisibly.

### Theme name

The installed theme is `imi-sddm-theme`. It used to be `ii-sddm-theme`, and `setup.sh` carries a
migration that renames an existing install and repoints every `Current=` at it. Anything that
hardcodes a theme name or a `~/.config/<name>` path must agree with that migration — several files
were missed by the original rename, so check rather than assume.

## The things that actually bite

### `/etc/sddm.conf.d` precedence

SDDM reads the system directory, then `/etc/sddm.conf.d/*.conf` in lexical order, then `/etc/sddm.conf`
— **`/etc/sddm.conf` has the highest precedence**, per `man 5 sddm.conf`. Within the drop-in directory,
later filenames win.

`kde_settings.conf` is written by KDE's settings module, is not ours, and sorts after most names. A
drop-in that sorts before it **loses silently** — the install reports success and the theme never
applies. If you are reasoning about which config wins, check the manual; comments in these scripts have
been wrong about this.

### Root file edits

Every `sed -i`, `mv`, `rm` and redirect that touches `/etc` or `/usr/share` needs:

- quoting that survives paths with spaces (the user's wallpaper path is
  `/mnt/p2/Program Files (x86)/Steam/...` — this is not theoretical);
- a check that it *worked*. A `sed` that fails on a read-only or immutable file, under a script that
  carries on, produces a "success" message and a broken login;
- an ordering where an interruption leaves a **working** install, not a half-migrated one. The rule the
  migration follows: put the replacement in place first, repoint config second, delete last.

### Sandboxing

`SDDM_MAIN_CONF`, `SDDM_CONF_DIR` and `SDDM_THEMES_DIR` are overridable in `setup.sh`,
`uninstall.sh` and `check.sh`; `check.sh` additionally takes `PRIV_SCRIPT_DIR`. Point them at a
tempdir, put a `sudo` stub that refuses everything on `PATH`, and the logic can be exercised without
reaching the real system. `uninstall.sh` and `check.sh` only run `main` when executed, not when
sourced, so individual functions can be driven directly.

That is a sandbox for *reading and reasoning*, not a licence to run the installers: a stub can only
block what the script routes through `sudo`, and one missed path is a root write to `/etc`. A
previous session's sandbox test leaked onto the real `/etc/sddm.conf` and was saved only by a
permissions error.

If you do any work near these paths, verify afterwards that `/etc/sddm.conf` and every file in
`/etc/sddm.conf.d/` is byte-identical to how you found it, and say so explicitly in your report.

### Wallpaper resolution

The greeter shows the active Wallpaper Engine wallpaper, falling back to the static one. That
precedence must mirror the shell's `weActive` — a WE project is used when its path is non-empty and its
type is not `web`. Keys come from the shell's `config.json`
(`wallpaperSelector.wallpaperEngine.{activePath,activeType,activeProject,activePreview}`).

**The full-resolution still's path is DERIVED, never read from a field.** It is
`~/.cache/quickshell/wallpaperengine-stills/<activeProject>.png`, computed from the project the config
currently names. Do not "simplify" this by reading a stored path back — that is
[immaterial-impulse#103](https://github.com/XephyLon/immaterial-impulse/issues/103) exactly: a stored
`activeStill` had no writer once the renderer moved in-process, so it froze at whatever project was
active that day and this script served that wallpaper for months. Those stale values are still sitting
in every saved preset. A path derived from `activeProject` cannot disagree with `activeProject`.

Absent is normal and must stay non-fatal: no still exists until a wallpaper has been applied since the
shell gained the grab, and a stock Quickshell build has no Wallpaper Engine module at all. Fall back to
`activePreview` — a login screen must not fail to apply over a missing thumbnail.

The greeter runs as the `sddm` user, not the human — a wallpaper on a path only the user can read is a
greeter that fails to draw its background. Treat that as a login-path failure, not a cosmetic one.

### Uninstall

`uninstall.sh` must remove installs under **both** the old and new theme names, must not delete a theme
it did not install, and must **revert every config change it made** — including `Current=` in
`kde_settings.conf` and any rewrite of `/etc/sddm.conf`. Removing the theme directory while leaving
config pointing at it is exactly the login-blocking failure this file opens with.

## Working on someone's live machine

- **Never `pkill -f <pattern>`** where the pattern could match your own command line — it kills the
  shell running it. This has happened.
- Do not restart the user's shell, and do not `git push` or open PRs unless asked.
- Inspecting the *installed* theme under `/usr/share/sddm/themes/` read-only is fine and often the
  fastest way to tell whether an install actually did what it claimed.
