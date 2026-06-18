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

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 v_TexCoord = in._we_ro_v_TexCoord;
    float mask = g_Texture1.sample(g_Texture1Smplr, v_TexCoord.zw).x;
    float4 origPix = g_Texture0.sample(g_Texture0Smplr, v_TexCoord.zw);
    float4 transPix = g_Texture0.sample(g_Texture0Smplr, v_TexCoord.xy);
    out._fragColor = mix(origPix, transPix, float4(mask));
    return out;
}

