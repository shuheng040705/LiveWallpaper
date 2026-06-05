#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    packed_float3 u_curveColor;
    float u_curveOpacity;
    float u_amplitude;
    float u_maxFreqBand;
    float u_envelopeSteepness;
    float u_curveThickness;
    float u_smoothness;
    float u_verticalOffset;
    float4 g_Texture0Resolution;
    float4 g_AudioSpectrum64Left[64];
    float4 g_AudioSpectrum64Right[64];
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float getMirroredAudioValue(thread int& index, thread const int& maxBand, constant _Globals& _48)
{
    index = abs(index);
    if (index > maxBand)
    {
        index = maxBand - (index - maxBand);
    }
    index = clamp(index, 0, 63);
    return (_48.g_AudioSpectrum64Left[index].x + _48.g_AudioSpectrum64Right[index].x) * 0.5;
}

static inline __attribute__((always_inline))
float cubicSpline(thread const float& p0, thread const float& p1, thread const float& p2, thread const float& p3, thread const float& t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5 * ((((2.0 * p1) + (((-p0) + p2) * t)) + (((((2.0 * p0) - (5.0 * p1)) + (4.0 * p2)) - p3) * t2)) + (((((-p0) + (3.0 * p1)) - (3.0 * p2)) + p3) * t3));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _48 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 uv = in.v_TexCoord - float2(0.5);
    uv.x *= (_48.g_Texture0Resolution.x / _48.g_Texture0Resolution.y);
    float x_norm = abs(uv.x) / ((0.5 * _48.g_Texture0Resolution.x) / _48.g_Texture0Resolution.y);
    float freq_norm = 1.0 - x_norm;
    float audioIndexFloat = freq_norm * _48.u_maxFreqBand;
    int index1 = int(floor(audioIndexFloat));
    float t = fract(audioIndexFloat);
    int maxBandInt = int(_48.u_maxFreqBand);
    int param = index1 - 1;
    int param_1 = maxBandInt;
    float _172 = getMirroredAudioValue(param, param_1, _48);
    float p0 = _172;
    int param_2 = index1;
    int param_3 = maxBandInt;
    float _178 = getMirroredAudioValue(param_2, param_3, _48);
    float p1 = _178;
    int param_4 = index1 + 1;
    int param_5 = maxBandInt;
    float _185 = getMirroredAudioValue(param_4, param_5, _48);
    float p2 = _185;
    int param_6 = index1 + 2;
    int param_7 = maxBandInt;
    float _193 = getMirroredAudioValue(param_6, param_7, _48);
    float p3 = _193;
    float param_8 = p0;
    float param_9 = p1;
    float param_10 = p2;
    float param_11 = p3;
    float param_12 = t;
    float rawAudioValue = cubicSpline(param_8, param_9, param_10, param_11, param_12);
    rawAudioValue = fast::max(0.0, rawAudioValue);
    float envelope = powr(fast::max(0.0, 1.0 - x_norm), _48.u_envelopeSteepness);
    float finalAudioValue = (rawAudioValue * envelope) * _48.u_amplitude;
    float curve_y = _48.u_verticalOffset - finalAudioValue;
    float dist = abs(uv.y - curve_y);
    float halfThickness = _48.u_curveThickness / 2.0;
    float lineIntensity = 1.0 - smoothstep(halfThickness, halfThickness + _48.u_smoothness, dist);
    float4 originalColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float effectiveCurveAlpha = lineIntensity * _48.u_curveOpacity;
    float3 finalColor = mix(originalColor.xyz, float3(_48.u_curveColor), float3(effectiveCurveAlpha));
    float finalAlpha = fast::max(originalColor.w, effectiveCurveAlpha);
    out._fragColor = float4(finalColor, finalAlpha);
    return out;
}

