#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float s_Border;
    float u_Margin;
    float u_Width;
    float2 u_FadeWidth;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float borderOffset [[user(locn0)]];
    float minAlpha [[user(locn1)]];
    float2 offset [[user(locn2)]];
    float2 reciprocalResolution [[user(locn3)]];
    float totalMargin [[user(locn4)]];
    float4 v_TexCoord [[user(locn5)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _12 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float alpha = smoothstep(_12.u_Margin, in.totalMargin, in.v_TexCoord.x) * (1.0 - smoothstep(_12.u_Width - in.totalMargin, _12.u_Width - _12.u_Margin, in.v_TexCoord.x));
    float2 texPos = fract((in.v_TexCoord.xy + in.offset) * in.reciprocalResolution);
    texPos.x = mix(in.borderOffset, 1.0 - in.borderOffset, texPos.x);
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, texPos);
    out._fragColor.w *= fast::max(in.minAlpha, alpha);
    return out;
}

