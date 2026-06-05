#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float3 g_EyeColor;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordIris [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    mask *= g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float4 iris = g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + (in.v_TexCoordIris * mask)));
    float irisMask = g_Texture1.sample(g_Texture1Smplr, (in.v_TexCoord.zw + (in.v_TexCoordIris * mask))).x;
    albedo = iris;
    out._fragColor = albedo;
    return out;
}

