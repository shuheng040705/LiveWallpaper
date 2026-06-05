#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture2Resolution;
    float2 g_Scale;
    float g_Strength;
};

struct main0_out
{
    float3 v_RefractTexCoord [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _20 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _20.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 _53 = in.a_TexCoord * _20.g_Scale;
    out.v_RefractTexCoord.x = _53.x;
    out.v_RefractTexCoord.y = _53.y;
    float _59 = out.v_TexCoord.x;
    float _70 = out.v_TexCoord.y;
    float2 _78 = float2((_59 * _20.g_Texture2Resolution.z) / _20.g_Texture2Resolution.x, (_70 * _20.g_Texture2Resolution.w) / _20.g_Texture2Resolution.y);
    out.v_TexCoord.z = _78.x;
    out.v_TexCoord.w = _78.y;
    out.v_RefractTexCoord.z = (sign(_20.g_Strength) * _20.g_Strength) * _20.g_Strength;
    return out;
}

