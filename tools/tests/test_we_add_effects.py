import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

TOOLS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

import we_add_effects
import we_build_effects as builder


class IncrementalVariantMergeTests(unittest.TestCase):
    def test_pending_variants_preserves_existing_and_normalizes_values(self):
        existing = [
            {"combos": {}},
            {"combos": {"TYPE": "1", "MASK": "0"}},
        ]
        requested = [
            {},
            {"TYPE": 1, "MASK": 0},
            {"TYPE": 2},
        ]

        pending = we_add_effects.pending_variants(existing, requested)

        self.assertEqual(pending, [{"TYPE": "2"}])

    def test_pending_variants_deduplicates_requested_combos(self):
        pending = we_add_effects.pending_variants(
            [],
            [{"MODE": 3}, {"MODE": "3"}],
        )

        self.assertEqual(pending, [{"MODE": "3"}])


class SceneTextureVariantTests(unittest.TestCase):
    def test_shared_shader_uses_overrides_from_each_scene_by_variant_and_pass(self):
        for key, scan in [("workshop/100/tone", builder.scan_post_workshop_effects),
                          ("local_tone", builder.scan_pkg_local_effects)]:
            with self.subTest(key=key):
                path = f"effects/{key}/effect.json"

                def package(*instances):
                    effects = [{"file": path, "passes": passes} for passes in instances]
                    return {"scene.json": json.dumps({"objects": [{"effects": effects}]}).encode(),
                            path: b"{}"}

                packages = {
                    "a.pkg": package([{"combos": {"BLENDMODE": 7}}]),
                    "b.pkg": package([{"combos": {"BLENDMODE": 7}, "textures": [None, "grain"]}],
                                     [{"combos": {"TOOLS": 1}},
                                      {"combos": {"LEVEL": 2}, "textures": [None, None, "masks/area"]}]),
                }
                bindings = {}
                with patch.object(builder.glob, "glob", return_value=list(packages)), \
                     patch.object(builder, "pkg_files", side_effect=packages.__getitem__):
                    source, combos = scan(bindings)[key]
                self.assertEqual(source, "a.pkg")
                blend = (("BLENDMODE", "7"),)
                masked = (("LEVEL", "2"), ("MASK", "1"), ("TOOLS", "1"))
                self.assertIn(masked, combos)
                self.assertEqual(bindings[key], {blend: {0: {1}}, masked: {1: {2}}})

    def test_two_passes_with_the_same_shader_keep_distinct_sampler_permutations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tone.frag").write_text('uniform sampler2D g_Texture1; // {"combo":"MASK"}\n')
            effect = {"passes": [{"shader": "tone"}, {"shader": "tone"}]}

            def compile_stage(directory, shader, stage, combos, locations, *, bound_slots, **options):
                if stage == "frag":
                    return ("masked" if 1 in bound_slots else "unmasked", [], [], 0)
                return None

            with patch.object(builder, "MSL_DIR", directory), \
                 patch.object(builder, "transpile_stage", side_effect=compile_stage):
                result, error, _ = builder.build_effect_passes(
                    effect, {}, "base", directory, lambda path: None, slots_by_pass={1: {1}})
            self.assertIsNone(error)
            shaders = [root / p["frag"]["metal"] for p in result["passes"]]
            self.assertEqual([p.read_text() for p in shaders], ["unmasked", "masked"])


if __name__ == "__main__":
    unittest.main()
