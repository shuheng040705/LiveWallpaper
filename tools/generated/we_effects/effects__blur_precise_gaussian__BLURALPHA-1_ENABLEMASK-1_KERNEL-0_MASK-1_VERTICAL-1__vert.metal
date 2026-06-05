#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float2 g_Scale;
    float4 g_Texture0Resolution;
    float4 g_Texture2Resolution;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordMask [[user(locn1)]];
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
    out.v_TexCoord.z = 0.0;
    out.v_TexCoord.w = _20.g_Scale.y / _20.g_Texture0Resolution.w;
    out.v_TexCoordMask = float2((out.v_TexCoord.x * _20.g_Texture2Resolution.z) / _20.g_Texture2Resolution.x, (out.v_TexCoord.y * _20.g_Texture2Resolution.w) / _20.g_Texture2Resolution.y);
    return out;
}

