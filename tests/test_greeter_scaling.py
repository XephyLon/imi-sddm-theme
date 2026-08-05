#!/usr/bin/env python3
"""The greeter respects the shell's Wallpaper Engine scaling choice.

The shell records fill / fit / stretch (and "default") in
`wallpaperSelector.wallpaperEngine.scaling`; the greeter used to hardcode crop,
so any wallpaper whose resolution differed from the screen looked different at
login than on the desktop. Scenes are immune (their still is grabbed at screen
size with the scaling baked in); the mapping matters for video wallpapers, the
frame cut from an oversized video, and the preview fallback.

Static pins, in the hub's lint style: they read the QML rather than run it,
because running a greeter needs a session. The visual halves were verified
live with `sddm-greeter-qt6 --test-mode --theme <scratch copy>` - fit
pillarboxes on black, fill crops.
"""
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MAIN = (REPO / "Main.qml").read_text()
DEFAULTS = [REPO / "Components/Settings.qml", REPO / "noMatugen/Settings.qml"]

WE_PROPS = [
    "wallpaperSelector_wallpaperEngine_activePath",
    "wallpaperSelector_wallpaperEngine_activeType",
    "wallpaperSelector_wallpaperEngine_scaling",
]


class ScalingMappingTests(unittest.TestCase):
    def test_image_maps_every_selectable_mode(self):
        # The image path covers the still, the cut frame and the preview.
        for token in ("Image.PreserveAspectFit", "Image.Stretch", "Image.Pad",
                      "Image.PreserveAspectCrop"):
            self.assertIn(token, MAIN, f"image mapping lost {token}")
        self.assertRegex(MAIN, r'weScaling === "fit" \? Image\.PreserveAspectFit')

    def test_video_maps_the_selectable_modes(self):
        # VideoOutput has no Pad; "default" is not selectable in the shell's
        # UI, so crop is the documented fallback there.
        self.assertRegex(MAIN, r'weScaling === "fit" \? VideoOutput\.PreserveAspectFit')
        self.assertRegex(MAIN, r'weScaling === "stretch" \? VideoOutput\.Stretch')

    def test_scaling_applies_only_to_we_backgrounds(self):
        # The static wallpaper never had a scaling choice; repainting every
        # non-WE login would be a silent behaviour change. Same weActive mirror
        # as the apply script: path non-empty, type not web.
        self.assertIn("weBackground", MAIN)
        self.assertRegex(MAIN, r'activeType[^\n]*toLowerCase\(\) !== "web"')

    def test_the_video_placeholder_scales_like_its_video(self):
        # The poster frame had NO fillMode, which in Qt means Stretch: on a
        # crop video the placeholder appeared distorted, then snapped when
        # playback started. It must follow the image mapping.
        placeholder = MAIN[MAIN.index("config.BackgroundPlaceholder || \"\""):]
        placeholder = placeholder[:placeholder.index("MediaPlayer {")]
        self.assertIn("fillMode: backgroundImage.fillMode", placeholder)

    def test_fit_letterbox_bars_are_drawn(self):
        # Wallpaper Engine clears the bars to black on the desktop; without a
        # backing rectangle the greeter shows whatever the Pane paints there.
        bars = MAIN[MAIN.index("DimBackgroundColor"):]
        bars = bars[:bars.index("}")]
        self.assertIn('weScaling === "fit"', bars)


class DefaultSettingsTests(unittest.TestCase):
    def test_both_default_settings_declare_the_we_properties(self):
        # Components/Settings.qml is the registered singleton a fresh install
        # reads until the first apply overwrites it; noMatugen/ is the
        # no-matugen variant. Miss either and Main.qml's reads come back
        # undefined on that install - silently, as undefined maps to crop.
        for path in DEFAULTS:
            text = path.read_text()
            for prop in WE_PROPS:
                self.assertRegex(text, rf"property string {prop}:",
                                 f"{path.name} lacks {prop}")

    def test_the_generated_settings_carries_what_main_reads(self):
        # Every Settings.* name Main.qml consumes must be a key the shell's
        # config flattener actually produces - the generated file overwrites
        # the defaults wholesale, so a typo here reads undefined forever.
        for prop in WE_PROPS:
            self.assertIn(f"Settings.{prop}", MAIN)


if __name__ == "__main__":
    unittest.main()
