#!/usr/bin/env python3
"""The sync wrapper's diff gate: generous triggers, root only on real change.

sddm-theme-sync.sh is the single entry point every trigger calls - matugen's
post_hook and the hub's GreeterSync observer. It generates Settings.qml,
fingerprints what the greeter consumes (the generated QML plus the derived
still's identity), and escalates to the privileged apply only when the
fingerprint changed. These run the REAL wrapper against a sandbox: env
overrides point it at a scratch dir, and `sudo` is a stub that records
instead of acting, so the tests hold in CI where there is no sudoers rule.
"""
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WRAPPER = REPO / "iiMatugen/sddm-theme-sync.sh"

FAKE_GENERATOR = """\
import os, pathlib
src = pathlib.Path(__file__).parent
src.joinpath("Settings.qml").write_text(
    'property string wallpaperSelector_wallpaperEngine_activeProject: "%s"\\n'
    'property string wallpaperSelector_wallpaperEngine_scaling: "%s"\\n'
    % (os.environ.get("FAKE_PROJ", "111"), os.environ.get("FAKE_SCALING", "fill")))
src.joinpath("Colors.qml").write_text("// colors\\n")
"""

SUDO_STUB = """\
#!/usr/bin/env bash
echo "APPLY: $*" >> "$SUDO_LOG"
[ -f "$SUDO_FAIL" ] && exit 1 || exit 0
"""


class SyncGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "src").mkdir()
        (self.tmp / "bin").mkdir()
        (self.tmp / "stills").mkdir()
        (self.tmp / "src/generate_settings.py").write_text(FAKE_GENERATOR)
        sudo = self.tmp / "bin/sudo"
        sudo.write_text(SUDO_STUB)
        sudo.chmod(0o755)
        self.log = self.tmp / "sudo.log"

    def run_wrapper(self, proj="111", scaling="fill", fail_apply=False):
        fail = self.tmp / "fail"
        if fail_apply:
            fail.touch()
        else:
            fail.unlink(missing_ok=True)
        env = {**os.environ,
               "PATH": f"{self.tmp / 'bin'}:{os.environ['PATH']}",
               "IMI_SDDM_SRC": str(self.tmp / "src"),
               "IMI_SDDM_APPLY": "/nonexistent/apply",
               "IMI_SDDM_STILLS": str(self.tmp / "stills"),
               "SUDO_LOG": str(self.log), "SUDO_FAIL": str(fail),
               "FAKE_PROJ": proj, "FAKE_SCALING": scaling}
        return subprocess.run(["bash", str(WRAPPER)], env=env,
                              capture_output=True, text=True)

    def applies(self):
        return self.log.read_text().count("APPLY") if self.log.exists() else 0

    def test_first_run_applies_and_identical_rerun_skips(self):
        # The whole point: a spurious trigger costs a hash, not a root copy.
        self.assertEqual(self.run_wrapper().returncode, 0)
        self.assertEqual(self.applies(), 1)
        self.assertEqual(self.run_wrapper().returncode, 0)
        self.assertEqual(self.applies(), 1, "identical inputs re-ran the root apply")

    def test_a_settings_change_applies(self):
        # Scaling is the leaf whose staleness started all of this.
        self.run_wrapper(scaling="fill")
        self.run_wrapper(scaling="fit")
        self.assertEqual(self.applies(), 2)

    def test_the_still_landing_applies(self):
        # The still arrives AFTER the config changes that announced it - its
        # identity is part of the fingerprint precisely so its arrival is a
        # change. This is the copy-before-still race being closed.
        self.run_wrapper()
        (self.tmp / "stills/111.png").write_bytes(b"png")
        self.run_wrapper()
        self.assertEqual(self.applies(), 2)

    def test_a_regrabbed_still_applies(self):
        # Same path, new content (monitor change, settled frame): mtime+size
        # identity must catch it.
        (self.tmp / "stills/111.png").write_bytes(b"png")
        self.run_wrapper()
        time.sleep(1.1)
        os.utime(self.tmp / "stills/111.png")
        self.run_wrapper()
        self.assertEqual(self.applies(), 2)

    def test_a_failed_apply_is_retried_not_stamped(self):
        # The stamp records "the greeter HAS this", not "we tried": a failed
        # apply must leave the fingerprint unstamped so the next trigger
        # retries instead of skipping forever.
        proc = self.run_wrapper(fail_apply=True)
        self.assertNotEqual(proc.returncode, 0)
        self.run_wrapper()
        self.assertEqual(self.applies(), 2)

    def test_the_wrapper_never_calls_the_apply_directly(self):
        # The privilege boundary: root is reached through sudo and the
        # path-matched rule, nothing else.
        code = "\n".join(l for l in WRAPPER.read_text().splitlines()
                         if not l.lstrip().startswith("#"))
        self.assertIn('sudo "$APPLY"', code)
        self.assertNotIn("pkexec", code)


if __name__ == "__main__":
    unittest.main()
