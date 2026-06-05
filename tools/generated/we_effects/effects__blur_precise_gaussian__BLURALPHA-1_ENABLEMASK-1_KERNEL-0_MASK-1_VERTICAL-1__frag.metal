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
    float2 v_TexCoordMask [[user(locn1)]];
};

static inline __attribute__((always_inline))
float4 blur13a(thread const float2& u, thread const float2& d, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    float2 o1 = float2(1.40919983386993408203125) * d;
    float2 o2 = float2(3.2979347705841064453125) * d;
    float2 o3 = float2(5.20629024505615234375) * d;
    return ((((((g_Texture0.sample(g_Texture0Smplr, u) * 0.1976406574249267578125) + (g_Texture0.sample(g_Texture0Smplr, (u + o1)) * 0.295985519886016845703125)) + (g_Texture0.sample(g_Texture0Smplr, (u - o1)) * 0.295985519886016845703125)) + (g_Texture0.sample(g_Texture0Smplr, (u + o2)) * 0.093533359467983245849609375)) + (g_Texture0.sample(g_Texture0Smplr, (u - o2)) * 0.093533359467983245849609375)) + (g_Texture0.sample(g_Texture0Smplr, (u + o3)) * 0.011660805903375148773193359375)) + (g_Texture0.sample(g_Texture0Smplr, (u - o3)) * 0.011660805903375148773193359375);
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float2 param = in.v_TexCoord.xy;
    float2 param_1 = in.v_TexCoord.zw;
    float4 albedo = blur13a(param, param_1, g_Texture0, g_Texture0Smplr);
    float4 prev = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy);
    albedo = mix(prev, albedo, float4(g_Texture2.sample(g_Texture2Smplr, in.v_TexCoordMask).x));
    out._fragColor = albedo;
    return out;
}

