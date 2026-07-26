#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, fast::min(A + B, float3(1.0)), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 rays = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.zw);
    float4 albedo = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy);
    float3 param = albedo.xyz;
    float3 param_1 = rays.xyz;
    float param_2 = rays.w;
    float3 _68 = ApplyBlending(9, param, param_1, param_2);
    albedo.x = _68.x;
    albedo.y = _68.y;
    albedo.z = _68.z;
    albedo.w = fast::clamp(albedo.w + rays.w, 0.0, 1.0);
    out._fragColor = albedo;
    return out;
}

