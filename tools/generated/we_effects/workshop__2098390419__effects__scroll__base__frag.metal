#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_Scale;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_Scroll [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _18 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoord = fract((in.v_TexCoord + in.v_Scroll) * _18.g_Scale);
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

