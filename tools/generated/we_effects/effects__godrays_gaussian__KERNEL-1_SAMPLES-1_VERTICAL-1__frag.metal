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
float4 blur7a(thread const float2& u, thread const float2& d, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    float2 o1 = float2(2.3515644073486328125) * d;
    float2 o2 = float2(0.46943378448486328125) * d;
    float2 o3 = float2(1.40919983386993408203125) * d;
    float2 o4 = float2(3.0) * d;
    return (((g_Texture0.sample(g_Texture0Smplr, (u + o1)) * 0.20281755924224853515625) + (g_Texture0.sample(g_Texture0Smplr, (u + o2)) * 0.4044856727123260498046875)) + (g_Texture0.sample(g_Texture0Smplr, (u - o3)) * 0.3213933408260345458984375)) + (g_Texture0.sample(g_Texture0Smplr, (u - o4)) * 0.071303434669971466064453125);
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 param = in.v_TexCoord.xy;
    float2 param_1 = in.v_TexCoord.zw;
    out._fragColor = blur7a(param, param_1, g_Texture0, g_Texture0Smplr);
    return out;
}

