#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_BarCount;
    float2 u_BarBounds;
    float2 u_CircleAngles;
    char _m3_pad[8];
    packed_float3 u_BarColor;
    float u_BarOpacity;
    float u_BarSpacing;
    float2 u_AASmoothness;
    float4 g_AudioSpectrum16Left[16];
    float4 g_AudioSpectrum16Right[16];
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
float mod2(thread const float& x, thread const float& y)
{
    return x - (y * floor(x / y));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _58 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 circleCoord = (in.v_TexCoord - float2(0.5)) * 2.0;
    float startAngle = _58.u_CircleAngles.x * 0.00277777784503996372222900390625;
    float endAngle = _58.u_CircleAngles.y * 0.00277777784503996372222900390625;
    float2 shapeCoord;
    shapeCoord.x = (precise::atan2(circleCoord.y, circleCoord.x) + 3.1415927410125732421875) / 6.283185482025146484375;
    float param = shapeCoord.x - fast::min(startAngle, endAngle);
    float param_1 = 1.0;
    shapeCoord.x = mod2(param, param_1);
    float param_2 = (endAngle - startAngle) - 1.0;
    float param_3 = 4.0;
    shapeCoord.x /= (abs(mod2(param_2, param_3) - 2.0) - 1.0);
    shapeCoord.x += float((endAngle - startAngle) < 0.0);
    shapeCoord.y = sqrt((circleCoord.x * circleCoord.x) + (circleCoord.y * circleCoord.y));
    shapeCoord.y = 1.0 - shapeCoord.y;
    float frequency = shapeCoord.x * 16.0;
    float param_4 = frequency;
    float param_5 = 16.0;
    float barFreq1 = mod2(param_4, param_5);
    float param_6 = barFreq1 + 1.0;
    float param_7 = 16.0;
    float barFreq2 = mod2(param_6, param_7);
    float barVolume1 = (_58.g_AudioSpectrum16Left[int(barFreq1)].x + _58.g_AudioSpectrum16Right[int(barFreq1)].x) * 0.5;
    float barVolume2 = (_58.g_AudioSpectrum16Left[int(barFreq2)].x + _58.g_AudioSpectrum16Right[int(barFreq2)].x) * 0.5;
    float barVolume = mix(barVolume1, barVolume2, smoothstep(0.0, 1.0, fract(frequency)));
    float barHeight = mix(_58.u_BarBounds.x, _58.u_BarBounds.y, barVolume);
    float bar = step(1.0 - shapeCoord.y, barHeight);
    bar *= (1.0 - step(1.0 - shapeCoord.y, _58.u_BarBounds.x));
    bool _208 = shapeCoord.x > 0.0;
    bool _219;
    if (_208)
    {
        _219 = (shapeCoord.x * sign(endAngle - startAngle)) < 1.0;
    }
    else
    {
        _219 = _208;
    }
    bar *= float(_219);
    float3 finalColor = float3(_58.u_BarColor);
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 param_8 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_9 = finalColor;
    float param_10 = bar * _58.u_BarOpacity;
    finalColor = ApplyBlending(0, param_8, param_9, param_10);
    float alpha = bar * _58.u_BarOpacity;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

