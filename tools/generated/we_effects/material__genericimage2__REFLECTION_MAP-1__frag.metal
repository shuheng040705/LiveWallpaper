#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Brightness;
    float g_UserAlpha;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn9)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _22 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 color = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 _29 = color;
    float3 _31 = _29.xyz * _22.g_Brightness;
    color.x = _31.x;
    color.y = _31.y;
    color.z = _31.z;
    color.w *= _22.g_UserAlpha;
    out._fragColor = color;
    return out;
}

