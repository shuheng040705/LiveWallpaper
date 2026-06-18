#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Color4;
    float g_Alpha;
    float u_Threshold;
    float u_Opacity;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _24 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], sampler g_Texture1Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 blendColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw);
    float4 transparentColor = _24.g_Color4;
    transparentColor.w = 0.0;
    blendColors = mix(transparentColor, blendColors, float4((step(0.100000001490116119384765625, ((step(in.v_TexCoord.z, 1.0) * step(in.v_TexCoord.w, 1.0)) * step(0.0, in.v_TexCoord.w)) * step(0.0, in.v_TexCoord.z)) * blendColors.w) * step(_24.u_Threshold, blendColors.w)));
    blendColors.w *= (_24.g_Alpha * _24.u_Opacity);
    out._fragColor = blendColors;
    return out;
}

