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
    float4 g_AudioSpectrum16Left[16];
    float4 g_AudioSpectrum16Right[16];
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
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _68 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 v_TexCoord = in._we_ro_v_TexCoord;
    float2 circleCoord = (v_TexCoord - float2(0.5)) * 2.0;
    float2 angleRange = _68.u_CircleAngles * 0.00277777784503996372222900390625;
    v_TexCoord.x = ((precise::atan2(circleCoord.y, circleCoord.x) + 3.1415927410125732421875) * 1.0) / 6.283185482025146484375;
    float param = v_TexCoord.x - fast::min(angleRange.x, angleRange.y);
    float param_1 = 1.0;
    v_TexCoord.x = mod2(param, param_1);
    float param_2 = (angleRange.y - angleRange.x) - 1.0;
    float param_3 = 4.0;
    v_TexCoord.x /= (abs(mod2(param_2, param_3) - 2.0) - 1.0);
    v_TexCoord.x += float((angleRange.y - angleRange.x) < 0.0);
    v_TexCoord.y = sqrt((circleCoord.x * circleCoord.x) + (circleCoord.y * circleCoord.y));
    v_TexCoord.y = 1.0 - v_TexCoord.y;
    float frequency = v_TexCoord.x * 16.0;
    float param_4 = frequency;
    float param_5 = 16.0;
    float barFreq1 = mod2(param_4, param_5);
    float param_6 = barFreq1 + 1.0;
    float param_7 = 16.0;
    float barFreq2 = mod2(param_6, param_7);
    float u_BarBoundsX = _68.u_BarBounds.x;
    float u_BarBoundsY = _68.u_BarBounds.y;
    float tsOfHiding = _68.u_TsOfHiding;
    float DynamicHiding = _68.u_DynamicHiding;
    float barVolume1 = (_68.g_AudioSpectrum16Left[int(barFreq1)].x + _68.g_AudioSpectrum16Right[int(barFreq1)].x) * 0.5;
    float barVolume2 = (_68.g_AudioSpectrum16Left[int(barFreq2)].x + _68.g_AudioSpectrum16Right[int(barFreq2)].x) * 0.5;
    float param_8 = mix(barVolume1, barVolume2, smoothstep(0.0, 1.0, fract(frequency)));
    float barVolume = remapVolume(param_8);
    float barHeight = mix(u_BarBoundsX, u_BarBoundsY, barVolume);
    float verticalSmoothing = _68.u_AASmoothness.y * 0.0500000007450580596923828125;
    verticalSmoothing *= fast::clamp(mix(0.0, 1.0, barVolume * 100.0), 0.0, 1.0);
    float bar = smoothstep((1.0 - v_TexCoord.y) - verticalSmoothing, (1.0 - v_TexCoord.y) + verticalSmoothing, barHeight);
    bar *= smoothstep((1.0 - v_TexCoord.y) - verticalSmoothing, (1.0 - v_TexCoord.y) + verticalSmoothing, u_BarBoundsY);
    bool _260 = v_TexCoord.x > 0.0;
    bool _273;
    if (_260)
    {
        _273 = (v_TexCoord.x * sign(angleRange.y - angleRange.x)) < 1.0;
    }
    else
    {
        _273 = _260;
    }
    bar *= float(_273);
    float3 finalColor = float3(_68.u_BarColor);
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.p_TexCoord);
    float3 param_9 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_10 = finalColor;
    float param_11 = bar * _68.u_BarOpacity;
    finalColor = ApplyBlending(0, param_9, param_10, param_11);
    float alpha = fast::max(scene.w, bar * _68.u_BarOpacity);
    out._fragColor = float4(finalColor, alpha);
    return out;
}

