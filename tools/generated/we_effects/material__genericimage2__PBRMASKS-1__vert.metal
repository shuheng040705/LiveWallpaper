#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Rotation;
    float2 g_Texture0Translation;
    float4 g_Texture2Resolution;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn9)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _34 [[buffer(0)]])
{
    main0_out out = {};
    float3 localPos = in.a_Position;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 _54 = float2((in.a_TexCoord.x * _34.g_Texture2Resolution.z) / _34.g_Texture2Resolution.x, (in.a_TexCoord.y * _34.g_Texture2Resolution.w) / _34.g_Texture2Resolution.y);
    out.v_TexCoord.z = _54.x;
    out.v_TexCoord.w = _54.y;
    out.gl_Position = _34.g_ModelViewProjectionMatrix * float4(localPos, 1.0);
    return out;
}

