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
    float i_DCorrectingFactor [[user(locn0)]];
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
float roundedHollowBoxSDF(thread float2& CurPosition, thread float3& Size, thread const float& DCorrectingFactor, constant _Globals& _164)
{
    Size *= 0.5;
    Size.x *= DCorrectingFactor;
    CurPosition.y -= (Size.y + Size.z);
    Size.y -= Size.z;
    float BorderWidth = _164.u_BorderWidth * 0.00999999977648258209228515625;
    float r = (_164.u_RadiusForH * fast::min(Size.x, Size.y)) - BorderWidth;
    float2 delta = (abs(CurPosition) - (Size.xy - float2(BorderWidth))) + float2(r);
    CurPosition.x *= DCorrectingFactor;
    return length(fast::max(delta, float2(0.0))) - r;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _43;
    if (A.x < 0.5)
    {
        _43 = (2.0 * A.x) * B.x;
    }
    else
    {
        _43 = 1.0 - ((2.0 * (1.0 - A.x)) * (1.0 - B.x));
    }
    float _69;
    if (A.y < 0.5)
    {
        _69 = (2.0 * A.y) * B.y;
    }
    else
    {
        _69 = 1.0 - ((2.0 * (1.0 - A.y)) * (1.0 - B.y));
    }
    float _93;
    if (A.z < 0.5)
    {
        _93 = (2.0 * A.z) * B.z;
    }
    else
    {
        _93 = 1.0 - ((2.0 * (1.0 - A.z)) * (1.0 - B.z));
    }
    return mix(A, float3(_43, _69, _93), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _164 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 v_TexCoord = in._we_ro_v_TexCoord;
    float audioResolution = 32.0;
    float barDist = abs((fract(v_TexCoord.x * _164.u_BarCount) * 2.0) - 1.0);
    float frequency = (floor(v_TexCoord.x * _164.u_BarCount) / _164.u_BarCount) * audioResolution;
    float param = frequency;
    float param_1 = audioResolution;
    float barFreq1 = mod2(param, param_1);
    float param_2 = barFreq1 + 1.0;
    float param_3 = audioResolution;
    float barFreq2 = mod2(param_2, param_3);
    float rW = (1.0 - _164.u_BarSpacing) / _164.u_BarCount;
    float minBarHeight = _164.u_minHeight * rW;
    float BorderWidth = _164.u_BorderWidth * 0.00999999977648258209228515625;
    minBarHeight *= in.i_DCorrectingFactor;
    float rAntiAliasFactor = 15.0 / fast::min(_164.g_Texture0Resolution.x, _164.g_Texture0Resolution.y);
    float rAASmoothnessX = (-_164.u_rAASmoothness.x) * rAntiAliasFactor;
    float rAASmoothnessY = _164.u_rAASmoothness.y * rAntiAliasFactor;
    float u_BarBoundsX = _164.u_BarBounds.x;
    float u_BarBoundsY = _164.u_BarBounds.y;
    float tsOfHiding = _164.u_TsOfHiding;
    float DynamicHiding = _164.u_DynamicHiding;
    float barVolume1 = (_164.g_AudioSpectrum32Left[int(barFreq1)].x + _164.g_AudioSpectrum32Right[int(barFreq1)].x) * 0.5;
    float barVolume2 = (_164.g_AudioSpectrum32Left[int(barFreq2)].x + _164.g_AudioSpectrum32Right[int(barFreq2)].x) * 0.5;
    float param_4 = mix(barVolume1, barVolume2, smoothstep(0.0, 1.0, fract(frequency)));
    float barVolume = remapVolume(param_4) * _164.u_VolumeFactor;
    float barHeight = mix(fast::max(u_BarBoundsX, minBarHeight), u_BarBoundsY, barVolume);
    float rBoxUpperBound = barHeight;
    float rBoxLowerBound = 0.0;
    rBoxLowerBound = fast::max(0.0, fast::min(rBoxLowerBound, rBoxUpperBound - minBarHeight));
    float2 rCenter = float2((barDist / _164.u_BarCount) * 0.5, 1.0 - v_TexCoord.y);
    float3 barSize = float3(rW, rBoxUpperBound, rBoxLowerBound);
    float2 param_5 = rCenter;
    float3 param_6 = barSize;
    float param_7 = in.i_DCorrectingFactor;
    float _388 = roundedHollowBoxSDF(param_5, param_6, param_7, _164);
    float d = _388;
    float bar = 1.0 - smoothstep(rAASmoothnessX, rAASmoothnessY, abs(d) - BorderWidth);
    float3 finalColor = float3(_164.u_BarColor);
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.p_TexCoord);
    float3 param_8 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_9 = finalColor;
    float param_10 = bar * _164.u_BarOpacity;
    finalColor = ApplyBlending(11, param_8, param_9, param_10);
    float alpha = bar * _164.u_BarOpacity;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

