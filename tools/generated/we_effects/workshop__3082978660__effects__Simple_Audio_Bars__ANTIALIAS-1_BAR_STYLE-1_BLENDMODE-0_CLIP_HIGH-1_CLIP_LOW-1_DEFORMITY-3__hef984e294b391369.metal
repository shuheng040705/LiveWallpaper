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
    char _m4_pad[8];
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
float roundedBoxSDF(thread float2& CurPosition, thread float3& Size, thread const float& DCorrectingFactor, constant _Globals& _86)
{
    Size *= 0.5;
    Size.x *= DCorrectingFactor;
    CurPosition.y -= (Size.y + Size.z);
    Size.y -= Size.z;
    float r = _86.u_Radius * fast::min(Size.x, Size.y);
    CurPosition.x *= DCorrectingFactor;
    return length(fast::max((abs(CurPosition) - Size.xy) + float2(r), float2(0.0))) - r;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _86 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 v_TexCoord = in._we_ro_v_TexCoord;
    float barDist = abs((fract(v_TexCoord.x * _86.u_BarCount) * 2.0) - 1.0);
    float frequency = (floor(v_TexCoord.x * _86.u_BarCount) / _86.u_BarCount) * 32.0;
    float param = frequency;
    float param_1 = 32.0;
    float barFreq1 = mod2(param, param_1);
    float param_2 = barFreq1 + 1.0;
    float param_3 = 32.0;
    float barFreq2 = mod2(param_2, param_3);
    float rW = (1.0 - _86.u_BarSpacing) / _86.u_BarCount;
    float minBarHeight = _86.u_minHeight * rW;
    minBarHeight *= in.i_DCorrectingFactor;
    float rAntiAliasFactor = 15.0 / fast::min(_86.g_Texture0Resolution.x, _86.g_Texture0Resolution.y);
    float rAASmoothnessX = (-_86.u_rAASmoothness.x) * rAntiAliasFactor;
    float rAASmoothnessY = _86.u_rAASmoothness.y * rAntiAliasFactor;
    float u_BarBoundsX = _86.u_BarBounds.x;
    float u_BarBoundsY = _86.u_BarBounds.y;
    float tsOfHiding = _86.u_TsOfHiding;
    float DynamicHiding = _86.u_DynamicHiding;
    float barVolume1 = (_86.g_AudioSpectrum32Left[int(barFreq1)].x + _86.g_AudioSpectrum32Right[int(barFreq1)].x) * 0.5;
    float barVolume2 = (_86.g_AudioSpectrum32Left[int(barFreq2)].x + _86.g_AudioSpectrum32Right[int(barFreq2)].x) * 0.5;
    float param_4 = mix(barVolume1, barVolume2, smoothstep(0.0, 1.0, fract(frequency)));
    float barVolume = remapVolume(param_4);
    float barHeight = mix(fast::max(u_BarBoundsX, minBarHeight), u_BarBoundsY, barVolume);
    float rBoxUpperBound = barHeight;
    float rBoxLowerBound = 0.0;
    rBoxUpperBound = fast::min(rBoxUpperBound, u_BarBoundsY);
    rBoxLowerBound = fast::max(u_BarBoundsX, rBoxLowerBound);
    rBoxLowerBound = fast::max(0.0, fast::min(rBoxLowerBound, rBoxUpperBound - minBarHeight));
    float2 rCenter = float2((barDist / _86.u_BarCount) * 0.5, 1.0 - v_TexCoord.y);
    float3 barSize = float3(rW, rBoxUpperBound, rBoxLowerBound);
    float2 param_5 = rCenter;
    float3 param_6 = barSize;
    float param_7 = in.i_DCorrectingFactor;
    float _293 = roundedBoxSDF(param_5, param_6, param_7, _86);
    float d = _293;
    float bar = 1.0 - smoothstep(rAASmoothnessX, rAASmoothnessY, d);
    float3 finalColor = float3(_86.u_BarColor);
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.p_TexCoord);
    float3 param_8 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_9 = finalColor;
    float param_10 = bar * _86.u_BarOpacity;
    finalColor = ApplyBlending(0, param_8, param_9, param_10);
    float alpha = bar * _86.u_BarOpacity;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

