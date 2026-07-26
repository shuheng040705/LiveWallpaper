#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_BlendAlpha;
    float3 g_TintColor;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _48 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = _48.g_BlendAlpha;
    float3 param = albedo.xyz;
    float3 param_1 = _48.g_TintColor;
    float param_2 = mask;
    float3 _64 = ApplyBlending(31, param, param_1, param_2);
    albedo.x = _64.x;
    albedo.y = _64.y;
    albedo.z = _64.z;
    out._fragColor = albedo;
    return out;
}

