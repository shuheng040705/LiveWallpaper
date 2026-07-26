import os
import sys
import unittest

TOOLS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

import wp_audit


class WallpaperAuditClassificationTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "workshop/1/covered": {
                "variants": [
                    {"combos": {"MODE": "0"}, "passes": []},
                    {"combos": {"MODE": "1"}, "passes": []},
                ]
            }
        }
        self.basename_index = {"covered": "workshop/1/covered"}

    def test_video_script_is_a_known_gap_not_a_success(self):
        obj = {
            "visible": {
                "value": True,
                "script": "export function update(){ video.pause(); return video.isPlaying; }",
            }
        }

        _, rows = wp_audit.audit_object(obj, {}, self.manifest, self.basename_index)

        self.assertTrue(any(level == "GAP" and param == "script API" for level, param, _ in rows))
        self.assertFalse(any(level == "OK" and param.startswith("visible") for level, param, _ in rows))

    def test_parent_query_is_no_longer_classified_as_a_known_stub(self):
        rows = wp_audit.audit_scripts({
            "scale": {
                "script": "export function init(){ return thisLayer.getParent(); }"
            }
        })

        self.assertFalse(any(level == "GAP" for level, _, _ in rows))
        self.assertTrue(any(level == "VERIFY" for level, _, _ in rows))

    def test_playback_event_is_no_longer_classified_as_unimplemented(self):
        rows = wp_audit.audit_scripts({
            "visible": {
                "script": "export function mediaPlaybackChanged(event){ thisLayer.visible = event.state !== 0; }"
            }
        })

        self.assertFalse(any(level == "GAP" for level, _, _ in rows))
        self.assertTrue(any(level == "VERIFY" for level, _, _ in rows))

    def test_thumbnail_event_on_property_is_dispatched_but_requires_palette_verification(self):
        rows = wp_audit.audit_scripts({
            "color": {
                "script": "export function mediaThumbnailChanged(event){ return event.primaryColor; }"
            }
        })

        self.assertFalse(any(level == "GAP" for level, _, _ in rows))
        self.assertTrue(any(param == "script media thumbnail" for _, param, _ in rows))

    def test_thumbnail_event_inside_effect_remains_a_known_gap(self):
        rows = wp_audit.audit_scripts({
            "effects": [{
                "passes": [{
                    "constantshadervalues": {
                        "color": {
                            "script": "export function mediaThumbnailChanged(event){ return event.primaryColor; }"
                        }
                    }
                }]
            }]
        })

        self.assertTrue(any(level == "GAP" for level, _, _ in rows))

    def test_same_field_keyframe_animation_controller_is_not_a_known_stub(self):
        rows = wp_audit.audit_scripts({
            "origin": {
                "animation": {"options": {"fps": 30, "length": 300}},
                "script": "export function init(){ thisLayer.getAnimation().rate = 2; }",
            }
        })

        self.assertFalse(any(level == "GAP" for level, _, _ in rows))
        self.assertTrue(any(param == "script animation" for _, param, _ in rows))

    def test_named_animation_query_remains_a_known_gap(self):
        rows = wp_audit.audit_scripts({
            "origin": {
                "animation": {"options": {"fps": 30, "length": 300}},
                "script": 'export function init(){ thisLayer.getAnimation("blink").play(); }',
            }
        })

        self.assertTrue(any(level == "GAP" for level, _, _ in rows))

    def test_scale_keyframe_animation_controller_is_supported(self):
        rows = wp_audit.audit_scripts({
            "scale": {
                "animation": {"options": {"fps": 30, "length": 300}},
                "script": "export function init(){ thisLayer.getAnimation().rate = 2; }",
            }
        })

        self.assertFalse(any(level == "GAP" for level, _, _ in rows))
        self.assertTrue(any(param == "script animation" for _, param, _ in rows))

    def test_missing_workshop_effect_is_a_hard_error(self):
        effect = {"file": "effects/workshop/9/missing/effect.json", "passes": [{}]}

        level, _, note = wp_audit.audit_effect(effect, self.manifest, self.basename_index)

        self.assertEqual(level, "ERR")
        self.assertIn("T1", note)

    def test_missing_combo_variant_is_a_gap(self):
        effect = {
            "file": "effects/workshop/1/covered/effect.json",
            "passes": [{"combos": {"MODE": 2}}],
        }

        level, _, note = wp_audit.audit_effect(effect, self.manifest, self.basename_index)

        self.assertEqual(level, "GAP")
        self.assertIn("MODE=2", note)

    def test_covered_shader_still_requires_visual_verification(self):
        effect = {
            "file": "effects/workshop/1/covered/effect.json",
            "passes": [{"combos": {"MODE": 1}}],
        }

        level, _, note = wp_audit.audit_effect(effect, self.manifest, self.basename_index)

        self.assertEqual(level, "VERIFY")
        self.assertIn("需抓帧", note)

    def test_hidden_layer_does_not_report_its_missing_effect(self):
        obj = {
            "visible": False,
            "effects": [{"file": "effects/workshop/9/missing/effect.json", "passes": [{}]}],
        }

        _, rows = wp_audit.audit_object(obj, {}, self.manifest, self.basename_index)

        self.assertTrue(any(level == "SKIP" and param == "visible=false" for level, param, _ in rows))
        self.assertFalse(any(level == "ERR" for level, _, _ in rows))

    def test_album_cover_usertexture_is_reported_as_a_gap(self):
        obj = {
            "image": "cover.json",
            "instance": {"usertextures": [{"name": "$mediaThumbnail"}]},
        }

        _, rows = wp_audit.audit_object(obj, {}, self.manifest, self.basename_index)

        self.assertTrue(any(level == "GAP" and param == "album-cover texture"
                            for level, param, _ in rows))

    def test_zero_parallax_depth_is_classified_as_a_real_disable(self):
        obj = {"image": "layer.json", "parallaxDepth": "0.00000 0.00000"}

        _, rows = wp_audit.audit_object(obj, {}, self.manifest, self.basename_index)

        self.assertTrue(any(level == "OK" and param == "parallaxDepth"
                            and "完全关闭" in note for level, param, note in rows))

    def test_nonzero_parallax_requires_visual_verification(self):
        obj = {"image": "layer.json", "parallaxDepth": "-1.56 -0.79"}

        _, rows = wp_audit.audit_object(obj, {}, self.manifest, self.basename_index)

        self.assertTrue(any(level == "VERIFY" and param == "parallaxDepth"
                            and "delay=dt/duration" in note for level, param, note in rows))


if __name__ == "__main__":
    unittest.main()
