#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelMatrix;
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Rotation;
    float2 g_Texture0Translation;
    float3 g_EyePosition;
    float3x3 g_NormalModelMatrix;
    float4x4 g_AltModelMatrix;
    float3x3 g_AltNormalModelMatrix;
    float4x4 g_AltViewProjectionMatrix;
    float4x4 g_ViewProjectionMatrix;
};

struct main0_out
{
    float3 v_Bitangent [[user(locn0)]];
    float3 v_Normal [[user(locn2)]];
    float3 v_Tangent [[user(locn4)]];
    float2 v_TexCoord [[user(locn5)]];
    float4 v_ViewDir [[user(locn7)]];
    float3 v_WorldNormal [[user(locn8)]];
    float3 v_WorldPos [[user(locn9)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(1)]];
    float2 a_TexCoord [[attribute(2)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _28 [[buffer(0)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    float3 localPos = position;
    out.v_TexCoord = in.a_TexCoord;
    float4 worldPos = _28.g_ModelMatrix * float4(localPos, 1.0);
    float3 viewDir = _28.g_EyePosition - worldPos.xyz;
    float3 normal = float3(0.0, 0.0, 1.0);
    out.v_WorldPos = worldPos.xyz;
    out.v_WorldNormal = _28.g_NormalModelMatrix * float3(0.0, 0.0, 1.0);
    out.v_ViewDir.x = viewDir.x;
    out.v_ViewDir.y = viewDir.y;
    out.v_ViewDir.z = viewDir.z;
    out.v_ViewDir.w = 0.0;
    out.gl_Position = _28.g_ViewProjectionMatrix * worldPos;
    return out;
}

