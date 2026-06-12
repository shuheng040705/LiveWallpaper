#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    packed_float3 u_curveColor;
    float u_curveOpacity;
    float u_amplitude;
    float u_minFreq;
    float u_maxFreq;
    float u_smoothStrength;
    float u_curveThickness;
    float u_smoothness;
    float u_verticalOffset;
    float4 g_Texture0Resolution;
    float g_Time;
    float2 g_PointerPosition;
    float4 g_AudioSpectrum16Left[16];
    float4 g_AudioSpectrum16Right[16];
    float4 g_AudioSpectrum32Left[32];
    float4 g_AudioSpectrum32Right[32];
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
float getMaxBands()
{
    return 64.0;
}

static inline __attribute__((always_inline))
float getAudioValueByBand(thread int& index, constant _Globals& _56)
{
    if (index < 0)
    {
        index = 0;
    }
    if (index >= 64)
    {
        index = 63;
    }
    return (_56.g_AudioSpectrum64Left[index].x + _56.g_AudioSpectrum64Right[index].x) * 0.5;
}

static inline __attribute__((always_inline))
float catmullRom(thread const float& p0, thread const float& p1, thread const float& p2, thread const float& p3, thread const float& t)
{
    float t2 = t * t;
    float t3 = t2 * t;
    float v0 = (p2 - p0) * 0.5;
    float v1 = (p3 - p1) * 0.5;
    return ((p1 + (v0 * t)) + ((((3.0 * (p2 - p1)) - (2.0 * v0)) - v1) * t2)) + ((((2.0 * (p1 - p2)) + v0) + v1) * t3);
}

static inline __attribute__((always_inline))
float getInterpolatedAudio(thread float& position, constant _Globals& _56)
{
    float maxBands = getMaxBands();
    position = fast::clamp(position, 0.0, maxBands - 1.0);
    int index = int(floor(position));
    float fraction = fract(position);
    int param = index - 1;
    float _144 = getAudioValueByBand(param, _56);
    float p0 = _144;
    int param_1 = index;
    float _148 = getAudioValueByBand(param_1, _56);
    float p1 = _148;
    int param_2 = index + 1;
    float _153 = getAudioValueByBand(param_2, _56);
    float p2 = _153;
    int param_3 = index + 2;
    float _159 = getAudioValueByBand(param_3, _56);
    float p3 = _159;
    float param_4 = p0;
    float param_5 = p1;
    float param_6 = p2;
    float param_7 = p3;
    float param_8 = fraction;
    return catmullRom(param_4, param_5, param_6, param_7, param_8);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _56 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float maxBands = getMaxBands();
    float x_norm = in.v_TexCoord.x;
    float actualMinFreq = fast::clamp(_56.u_minFreq, 0.0, maxBands - 1.0);
    float actualMaxFreq = fast::clamp(_56.u_maxFreq, 0.0, maxBands - 1.0);
    if (actualMaxFreq <= actualMinFreq)
    {
        actualMaxFreq = actualMinFreq + 1.0;
        if (actualMaxFreq >= maxBands)
        {
            actualMaxFreq = maxBands - 1.0;
            actualMinFreq = actualMaxFreq - 1.0;
        }
    }
    float freq_range = actualMaxFreq - actualMinFreq;
    float audioPosition = actualMinFreq + (x_norm * freq_range);
    float param = audioPosition;
    float _225 = getInterpolatedAudio(param, _56);
    float audioValue = _225;
    if (_56.u_smoothStrength > 0.0)
    {
        float delta = freq_range * 0.00999999977648258209228515625;
        float param_1 = audioPosition - delta;
        float _241 = getInterpolatedAudio(param_1, _56);
        float leftValue = _241;
        float param_2 = audioPosition + delta;
        float _247 = getInterpolatedAudio(param_2, _56);
        float rightValue = _247;
        float smoothed = ((leftValue * 0.25) + (audioValue * 0.5)) + (rightValue * 0.25);
        audioValue = mix(audioValue, smoothed, _56.u_smoothStrength);
    }
    float finalAudioValue = audioValue * _56.u_amplitude;
    float curve_y = (0.5 + _56.u_verticalOffset) - finalAudioValue;
    float dist = abs(in.v_TexCoord.y - curve_y);
    float halfThickness = _56.u_curveThickness * 0.5;
    float edge0 = halfThickness - _56.u_smoothness;
    float edge1 = halfThickness + _56.u_smoothness;
    float lineIntensity = 1.0 - smoothstep(edge0, edge1, dist);
    float4 originalColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float effectiveCurveAlpha = lineIntensity * _56.u_curveOpacity;
    float3 finalColor = mix(originalColor.xyz, float3(_56.u_curveColor), float3(effectiveCurveAlpha));
    float finalAlpha = fast::max(originalColor.w, effectiveCurveAlpha);
    out._fragColor = float4(finalColor, finalAlpha);
    return out;
}

