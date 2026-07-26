import os
import sys
import unittest

TOOLS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

import we_add_effects


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


if __name__ == "__main__":
    unittest.main()
