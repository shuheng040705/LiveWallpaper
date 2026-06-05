#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_KeyAlpha;
    float g_KeyFuzz;
    float g_KeyTolerance;
    float3 g_KeyColor;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _25 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float delta = dot(abs(_25.g_KeyColor - albedo.xyz), float3(1.0));
    float blend = smoothstep(0.001000000047497451305389404296875, 0.00200000009499490261077880859375 + _25.g_KeyFuzz, delta - _25.g_KeyTolerance);
    albedo.w *= mix(_25.g_KeyAlpha, 1.0, blend);
    out._fragColor = albedo;
    return out;
}

