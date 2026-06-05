#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelMatrix;
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Rotation;
    float2 g_Texture0Translation;
    float4 g_Texture2Resolution;
    float3 g_EyePosition;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn5)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(1)]];
    float2 a_TexCoord [[attribute(2)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _36 [[buffer(0)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    float3 localPos = position;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 _56 = float2((in.a_TexCoord.x * _36.g_Texture2Resolution.z) / _36.g_Texture2Resolution.x, (in.a_TexCoord.y * _36.g_Texture2Resolution.w) / _36.g_Texture2Resolution.y);
    out.v_TexCoord.z = _56.x;
    out.v_TexCoord.w = _56.y;
    float4 worldPos = _36.g_ModelMatrix * float4(localPos, 1.0);
    float3 viewDir = _36.g_EyePosition - worldPos.xyz;
    out.gl_Position = _36.g_ModelViewProjectionMatrix * float4(localPos, 1.0);
    return out;
}

