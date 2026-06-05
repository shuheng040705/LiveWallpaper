#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture2Resolution;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _39 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float _36 = out.v_TexCoord.x;
    float _49 = out.v_TexCoord.y;
    float2 _57 = float2((_36 * _39.g_Texture2Resolution.z) / _39.g_Texture2Resolution.x, (_49 * _39.g_Texture2Resolution.w) / _39.g_Texture2Resolution.y);
    out.v_TexCoord.z = _57.x;
    out.v_TexCoord.w = _57.y;
    return out;
}

