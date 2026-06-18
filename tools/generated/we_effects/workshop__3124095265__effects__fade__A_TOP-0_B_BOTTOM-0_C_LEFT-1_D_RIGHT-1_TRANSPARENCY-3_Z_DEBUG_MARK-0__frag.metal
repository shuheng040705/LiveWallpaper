#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_LeftWidth;
    float u_RightWidth;
    float u_TopWidth;
    float u_BottomWidth;
    float u_Alpha;
    float3 u_MarkerColor;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 p_TexCoord [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _27 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.p_TexCoord);
    float fAlpha = 1.0;
    fAlpha *= smoothstep(0.0, _27.u_LeftWidth, in.v_TexCoord.x);
    fAlpha *= smoothstep(1.0, 1.0 - _27.u_RightWidth, in.v_TexCoord.x);
    albedo.w = (albedo.w * fAlpha) * _27.u_Alpha;
    out._fragColor = albedo;
    return out;
}

