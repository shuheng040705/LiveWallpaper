#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_aperture;
    float u_focusDepth;
    float u_focusScale;
    float u_multiplier;
    float u_exponent;
    float u_offset;
    float2 u_focusPoint;
    float2 u_depthBounds;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture1 [[texture(0)]], sampler g_Texture1Smplr [[sampler(0)]])
{
    main0_out out = {};
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord).x;
    out._fragColor = float4(mask);
    return out;
}

