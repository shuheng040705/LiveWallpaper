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
    return mix(A, float3(fast::max(A.x, fast::max(A.y, A.z))) * B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _62 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = _62.g_BlendAlpha;
    mask *= g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float3 param = albedo.xyz;
    float3 param_1 = _62.g_TintColor;
    float param_2 = mask;
    float3 _86 = ApplyBlending(30, param, param_1, param_2);
    albedo.x = _86.x;
    albedo.y = _86.y;
    albedo.z = _86.z;
    out._fragColor = albedo;
    return out;
}

