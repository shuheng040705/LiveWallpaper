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
    float4 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float4 blur3a(thread const float2& u, thread const float2& d, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    return ((g_Texture0.sample(g_Texture0Smplr, (u + d)) * 0.25) + (g_Texture0.sample(g_Texture0Smplr, u) * 0.5)) + (g_Texture0.sample(g_Texture0Smplr, (u - d)) * 0.25);
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 param = in.v_TexCoord.xy;
    float2 param_1 = in.v_TexCoord.zw;
    float4 albedo = blur3a(param, param_1, g_Texture0, g_Texture0Smplr);
    out._fragColor = albedo;
    return out;
}

