#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 _we_ro_v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 v_TexCoord = in._we_ro_v_TexCoord;
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, v_TexCoord.xy);
    return out;
}

