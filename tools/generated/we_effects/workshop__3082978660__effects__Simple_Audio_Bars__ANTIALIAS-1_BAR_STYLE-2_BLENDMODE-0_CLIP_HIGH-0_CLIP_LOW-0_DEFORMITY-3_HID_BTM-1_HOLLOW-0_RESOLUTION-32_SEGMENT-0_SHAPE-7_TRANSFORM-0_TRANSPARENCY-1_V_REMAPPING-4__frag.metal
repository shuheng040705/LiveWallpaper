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
    float2 p_TexCoord [[user(locn1)]];
    float2 _we_ro_v_TexCoord [[user(locn2)]];
};

static inline __attribute__((always_inline))
float mod2(thread const float& x, thread const float& y)
{
    return x - (y * floor(x / y));
}

static inline __attribute__((always_inline))
float remapVolume(thread float& volume)
{
    volume = 1.0 - volume;
    return 1.0 - (volume * volume);
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _95 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 v_TexCoord = in._we_ro_v_TexCoord;
    v_TexCoord.y = fract(0.5 - v_TexCoord.y) + floor(v_TexCoord.y);
    float frequency = v_TexCoord.x * 32.0;
    float param = frequency;
    float param_1 = 32.0;
    float barFreq1 = mod2(param, param_1);
    float param_2 = barFreq1 + 1.0;
    float param_3 = 32.0;
    float barFreq2 = mod2(param_2, param_3);
    float u_BarBoundsX = _95.u_BarBounds.x;
    float u_BarBoundsY = _95.u_BarBounds.y;
    float tsOfHiding = _95.u_TsOfHiding;
    float DynamicHiding = _95.u_DynamicHiding;
    float barVolume1L = _95.g_AudioSpectrum32Left[int(barFreq1)].x;
    float barVolume2L = _95.g_AudioSpectrum32Left[int(barFreq2)].x;
    float barVolume1R = _95.g_AudioSpectrum32Right[int(barFreq1)].x;
    float barVolume2R = _95.g_AudioSpectrum32Right[int(barFreq2)].x;
    float param_4 = mix(barVolume1L, barVolume2L, smoothstep(0.0, 1.0, fract(frequency)));
    float _142 = remapVolume(param_4);
    float barVolumeLeft = _142;
    float param_5 = mix(barVolume1R, barVolume2R, smoothstep(0.0, 1.0, fract(frequency)));
    float _151 = remapVolume(param_5);
    float barVolumeRight = _151;
    float barHeightLeft = 0.5 * mix(u_BarBoundsX, u_BarBoundsY, barVolumeLeft);
    float barHeightRight = 0.5 * mix(u_BarBoundsX, u_BarBoundsY, barVolumeRight);
    float verticalSmoothingLeft = _95.u_AASmoothness.y * 0.0500000007450580596923828125;
    float verticalSmoothingRight = verticalSmoothingLeft;
    verticalSmoothingLeft *= fast::clamp(mix(0.0, 1.0, barVolumeLeft * 100.0), 0.0, 1.0);
    verticalSmoothingRight *= fast::clamp(mix(0.0, 1.0, barVolumeRight * 100.0), 0.0, 1.0);
    float barLeft = smoothstep(v_TexCoord.y - verticalSmoothingLeft, v_TexCoord.y + verticalSmoothingLeft, barHeightLeft);
    float barRight = smoothstep((1.0 - v_TexCoord.y) - verticalSmoothingRight, (1.0 - v_TexCoord.y) + verticalSmoothingRight, barHeightRight);
    barLeft *= smoothstep(v_TexCoord.y + verticalSmoothingLeft, v_TexCoord.y - verticalSmoothingLeft, (barHeightLeft - tsOfHiding) - (DynamicHiding * barHeightLeft));
    barRight *= smoothstep((1.0 - v_TexCoord.y) + verticalSmoothingRight, (1.0 - v_TexCoord.y) - verticalSmoothingRight, (barHeightRight - tsOfHiding) - (DynamicHiding * barHeightRight));
    barLeft *= float(v_TexCoord.y < 0.4900000095367431640625);
    barRight *= float(v_TexCoord.y > 0.5099999904632568359375);
    float bar = fast::max(barLeft, barRight);
    float3 finalColor = float3(_95.u_BarColor);
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.p_TexCoord);
    float3 param_6 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_7 = finalColor;
    float param_8 = bar * _95.u_BarOpacity;
    finalColor = ApplyBlending(0, param_6, param_7, param_8);
    float alpha = bar * _95.u_BarOpacity;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

