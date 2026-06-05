#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_TsOfHiding;
    float u_DynamicHiding;
    float u_BarCount;
    float2 u_CircleAngles;
    float u_VolumeFactor;
    char _m5_pad[4];
    packed_float3 u_BarColor;
    float u_BarOpacity;
    float u_BarSpacing;
    float2 u_AASmoothness;
    float2 u_rAASmoothness;
    float u_Radius;
    float u_RadiusForH;
    float u_minHeight;
    float u_minHeightForC;
    float u_BorderWidth;
    float u_SegmentSpacing;
    float u_SegmentCount;
    float u_SegmentThreshold;
    float2 u_BarBounds;
    float u_CurveResolution;
    float4 g_Texture0Resolution;
    float4 g_AudioSpectrum32Left[32];
    float4 g_AudioSpectrum32Right[32];
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 p_TexCoord [[user(locn1)]];
    float2 _we_ro_v_TexCoord [[user(locn2)]];
};

static inline __attribute__((always_inline))
float mod2(thread const float& x, thread const float& y)
{
    return x - (y * floor(x / y));
}

static inline __attribute__((always_inline))
float remapVolume(thread const float& volume)
{
    return volume;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _35;
    if (A.x < 0.5)
    {
        _35 = (2.0 * A.x) * B.x;
    }
    else
    {
        _35 = 1.0 - ((2.0 * (1.0 - A.x)) * (1.0 - B.x));
    }
    float _61;
    if (A.y < 0.5)
    {
        _61 = (2.0 * A.y) * B.y;
    }
    else
    {
        _61 = 1.0 - ((2.0 * (1.0 - A.y)) * (1.0 - B.y));
    }
    float _85;
    if (A.z < 0.5)
    {
        _85 = (2.0 * A.z) * B.z;
    }
    else
    {
        _85 = 1.0 - ((2.0 * (1.0 - A.z)) * (1.0 - B.z));
    }
    return mix(A, float3(_35, _61, _85), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _163 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 v_TexCoord = in._we_ro_v_TexCoord;
    float audioResolution = 32.0;
    float frequency = v_TexCoord.x * audioResolution;
    float param = frequency;
    float param_1 = audioResolution;
    float barFreq1 = mod2(param, param_1);
    float param_2 = barFreq1 + 1.0;
    float param_3 = audioResolution;
    float barFreq2 = mod2(param_2, param_3);
    float u_BarBoundsX = _163.u_BarBounds.x;
    float u_BarBoundsY = _163.u_BarBounds.y;
    float tsOfHiding = _163.u_TsOfHiding;
    float DynamicHiding = _163.u_DynamicHiding;
    float barVolume1 = (_163.g_AudioSpectrum32Left[int(barFreq1)].x + _163.g_AudioSpectrum32Right[int(barFreq1)].x) * 0.5;
    float barVolume2 = (_163.g_AudioSpectrum32Left[int(barFreq2)].x + _163.g_AudioSpectrum32Right[int(barFreq2)].x) * 0.5;
    float param_4 = mix(barVolume1, barVolume2, smoothstep(0.0, 1.0, fract(frequency)));
    float barVolume = remapVolume(param_4) * _163.u_VolumeFactor;
    float barHeight = mix(u_BarBoundsX, u_BarBoundsY, barVolume);
    float verticalSmoothing = _163.u_AASmoothness.y * 0.0500000007450580596923828125;
    verticalSmoothing *= fast::clamp(mix(0.0, 1.0, barVolume * 100.0), 0.0, 1.0);
    float bar = smoothstep((1.0 - v_TexCoord.y) - verticalSmoothing, (1.0 - v_TexCoord.y) + verticalSmoothing, barHeight);
    float3 finalColor = float3(_163.u_BarColor);
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.p_TexCoord);
    float3 param_5 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_6 = finalColor;
    float param_7 = bar * _163.u_BarOpacity;
    finalColor = ApplyBlending(11, param_5, param_6, param_7);
    float alpha = bar * _163.u_BarOpacity;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

