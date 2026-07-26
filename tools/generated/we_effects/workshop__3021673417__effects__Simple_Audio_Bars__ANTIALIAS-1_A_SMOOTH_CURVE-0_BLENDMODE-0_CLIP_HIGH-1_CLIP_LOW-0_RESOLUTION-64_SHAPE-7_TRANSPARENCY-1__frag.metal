#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Implementation of the GLSL mod() function, which is slightly different than Metal fmod()
template<typename Tx, typename Ty>
inline Tx mod(Tx x, Ty y)
{
    return x - y * floor(x / y);
}

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
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _48 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 shapeCoord = in.v_TexCoord;
    shapeCoord.y = fract(0.5 - shapeCoord.y);
    float barDist = abs((fract(shapeCoord.x * _48.u_BarCount) * 2.0) - 1.0);
    float frequency = (floor(shapeCoord.x * _48.u_BarCount) / _48.u_BarCount) * 64.0;
    int barFreq1 = int(mod(frequency, 64.0));
    int barFreq2 = int(mod(float(barFreq1 + 1), 64.0));
    float barVolume1L = _48.g_AudioSpectrum64Left[barFreq1].x;
    float barVolume2L = _48.g_AudioSpectrum64Left[barFreq2].x;
    float barVolume1R = _48.g_AudioSpectrum64Right[barFreq1].x;
    float barVolume2R = _48.g_AudioSpectrum64Right[barFreq2].x;
    float barVolumeLeft = mix(barVolume1L, barVolume2L, smoothstep(0.0, 1.0, fract(frequency)));
    float barVolumeRight = mix(barVolume1R, barVolume2R, smoothstep(0.0, 1.0, fract(frequency)));
    bool isLeftChannel = shapeCoord.y < 0.4900000095367431640625;
    bool isRightChannel = shapeCoord.y > 0.5099999904632568359375;
    float barHeightLeft = 0.5 * mix(_48.u_BarBounds.x, _48.u_BarBounds.y, barVolumeLeft);
    float barHeightRight = 0.5 * mix(_48.u_BarBounds.x, _48.u_BarBounds.y, barVolumeRight);
    float verticalSmoothingLeft = _48.u_AASmoothness.y * 0.0500000007450580596923828125;
    float verticalSmoothingRight = verticalSmoothingLeft;
    verticalSmoothingLeft *= fast::clamp(mix(0.0, 1.0, barVolumeLeft * 100.0), 0.0, 1.0);
    verticalSmoothingRight *= fast::clamp(mix(0.0, 1.0, barVolumeRight * 100.0), 0.0, 1.0);
    float barLeft = smoothstep(shapeCoord.y - verticalSmoothingLeft, shapeCoord.y + verticalSmoothingLeft, barHeightLeft);
    float barRight = smoothstep((1.0 - shapeCoord.y) - verticalSmoothingRight, (1.0 - shapeCoord.y) + verticalSmoothingRight, barHeightRight);
    barLeft *= float(isLeftChannel);
    barRight *= float(isRightChannel);
    barLeft *= smoothstep(shapeCoord.y - verticalSmoothingLeft, (1.0 - shapeCoord.y) + verticalSmoothingLeft, _48.u_BarBounds.y);
    barRight *= smoothstep((1.0 - shapeCoord.y) - verticalSmoothingRight, (1.0 - shapeCoord.y) + verticalSmoothingRight, _48.u_BarBounds.y);
    float bar = fast::max(barLeft, barRight);
    bar *= fast::max(1.0 - step(0.00999999977648258209228515625, _48.u_BarSpacing), smoothstep(barDist - _48.u_AASmoothness.x, barDist + _48.u_AASmoothness.x, 1.0 - _48.u_BarSpacing));
    float3 finalColor = float3(_48.u_BarColor);
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 param = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_1 = finalColor;
    float param_2 = bar * _48.u_BarOpacity;
    finalColor = ApplyBlending(0, param, param_1, param_2);
    float alpha = bar * _48.u_BarOpacity;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

