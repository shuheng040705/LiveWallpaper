import os
import sys
import unittest

TOOLS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

import we_transpile


class HLSLCompatibilityTests(unittest.TestCase):
    def test_legacy_packed_audio_register_access_is_flattened(self):
        source = """
uniform float g_AudioSpectrum64Left[64];
float volume(float barID) {
    return g_AudioSpectrum64Left[barID / 4][barID % 4];
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn("g_AudioSpectrum64Left[int(barID)]", converted)
        self.assertNotIn("[barID / 4][barID % 4]", converted)

    def test_mismatched_packed_audio_register_indices_are_not_rewritten(self):
        source = "return g_AudioSpectrum64Left[a / 4][b % 4];"

        converted = we_transpile.rename_reserved(source)

        self.assertEqual(source, converted)

    def test_scalar_literals_in_multi_vector_declaration_are_broadcast(self):
        source = """
void compute() {
    vec2 radial = 0.0, tangential = .0, center = (one - position) * scale;
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn(
            "vec2 radial = vec2(0.0), tangential = vec2(.0), center = (one - position) * scale;",
            converted,
        )

    def test_main_local_shadowing_varying_is_renamed_from_declaration_forward(self):
        source = """
varying vec4 timer;
void main() {
    consume(timer);
    float timer = sin(g_Time);
    consume(timer);
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn("varying vec4 timer;", converted)
        self.assertIn("consume(timer);", converted)
        self.assertIn("float _we_local_timer_0 = sin(g_Time);", converted)
        self.assertIn("consume(_we_local_timer_0);", converted)

    def test_scalar_roundtrip_local_is_narrowed_for_sine_wave_shape(self):
        source = """
vec3 ApplyBlending(int mode, vec3 a, vec3 b, float opacity);
void main() {
    vec2 waveCoord = v_TexCoord;
#if AUDIOPROCESSING
    waveCoord = pow(saturate(audioValue), exponent);
#else
    waveCoord = pow(saturate(baseValue), exponent);
#endif
    color = ApplyBlending(BLENDMODE, scene, wave, opacity * waveCoord);
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn("float waveCoord = v_TexCoord.x;", converted)
        self.assertNotIn("vec2 waveCoord = v_TexCoord;", converted)

    def test_real_vec2_local_is_not_narrowed_without_two_scalar_branches(self):
        source = """
void main() {
    vec2 waveCoord = v_TexCoord;
    waveCoord += offset;
    color = ApplyBlending(BLENDMODE, scene, wave, opacity * waveCoord.x);
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn("vec2 waveCoord = v_TexCoord;", converted)

    def test_float_assignment_truncates_full_vec2_swizzle(self):
        source = """
uniform vec2 g_PointerPosition;
uniform float u_pointerSpeed;
void main() {
    float pointer = g_PointerPosition.xy * u_pointerSpeed;
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn(
            "float pointer = (g_PointerPosition.xy * u_pointerSpeed).x;",
            converted,
        )

    def test_mix_broadcasts_known_float_to_known_vector_width(self):
        source = """
vec3 vibrance(vec3 color, float luma) {
    return mix(luma, color, weight);
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn("return mix(vec3(luma), color, weight);", converted)

    def test_mix_truncates_vec4_to_vec3_operand_width(self):
        source = """
uniform vec3 tint;
vec3 render() {
    vec4 color = vec4(0.0);
    color = vec4(mix(tint, color, weight), 1.0);
    return color;
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn("mix(tint, color.rgb, weight)", converted)
        self.assertIn("return color.rgb;", converted)

    def test_float_truncation_does_not_rewrite_same_named_vec2_declaration(self):
        source = """
float roundedBox(vec2 p) {
    vec2 d = abs(p) - vec2(0.5);
    return length(d);
}
void main() {
    float d = roundedBox(uv);
    alpha = d;
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn("vec2 d = abs(p) - vec2(0.5);", converted)
        self.assertNotIn("vec2 d = (abs(p) - vec2(0.5)).x;", converted)

    def test_float_returning_function_with_vec2_argument_is_not_swizzled(self):
        source = """
float sdRect(vec2 p, vec2 offset) { return length(p - offset); }
void main() {
    float distance = sdRect(uv, vec2(0.5));
}
"""

        converted = we_transpile.rename_reserved(source)

        self.assertIn("float distance = sdRect(uv, vec2(0.5));", converted)
        self.assertNotIn("sdRect(uv, vec2(0.5))).x", converted)


if __name__ == "__main__":
    unittest.main()
