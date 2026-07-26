#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float g_FlashPower;
    float g_FlashBrightness;
    float3 g_FlashColor;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float v_LightningIntensity [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _53 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 samp_ = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 albedo = samp_;
    float flash = powr(in.v_LightningIntensity, _53.g_FlashPower) * _53.g_FlashBrightness;
    float3 lit = albedo.xyz + ((_53.g_FlashColor * flash) * 1.5);
    float3 param = albedo.xyz;
    float3 param_1 = lit;
    float param_2 = flash;
    float3 _83 = ApplyBlending(31, param, param_1, param_2);
    albedo.x = _83.x;
    albedo.y = _83.y;
    albedo.z = _83.z;
    out._fragColor = float4(fast::max(float3(0.0), albedo.xyz), albedo.w);
    return out;
}

