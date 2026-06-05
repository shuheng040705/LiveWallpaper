#pragma clang diagnostic ignored "-Wmissing-prototypes"

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
    float4 v_TexCoord [[user(locn5)]];
    float4 v_ViewDir [[user(locn7)]];
    float3 v_WorldPos [[user(locn9)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(1)]];
    float2 a_TexCoord [[attribute(2)]];
};

static inline __attribute__((always_inline))
float3x3 BuildTangentSpace(float3x3 modelTransform, float3 normal, float4 signedTangent)
{
    float3 tangent = signedTangent.xyz;
    float3 bitangent = cross(normal, tangent) * signedTangent.w;
    return float3x3(float3(modelTransform * tangent), float3(modelTransform * bitangent), float3(modelTransform * normal));
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _73 [[buffer(0)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    float3 localPos = position;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 _92 = float2((in.a_TexCoord.x * _73.g_Texture2Resolution.z) / _73.g_Texture2Resolution.x, (in.a_TexCoord.y * _73.g_Texture2Resolution.w) / _73.g_Texture2Resolution.y);
    out.v_TexCoord.z = _92.x;
    out.v_TexCoord.w = _92.y;
    float4 worldPos = _73.g_ModelMatrix * float4(localPos, 1.0);
    float3 viewDir = _73.g_EyePosition - worldPos.xyz;
    float3 normal = float3(0.0, 0.0, 1.0);
    float4 tangent = float4(1.0, 0.0, 0.0, 1.0);
    float3x3 tangentSpace = BuildTangentSpace(_73.g_NormalModelMatrix, normal, tangent);
    out.v_Tangent = fast::normalize(tangentSpace[0]);
    out.v_Bitangent = fast::normalize(tangentSpace[1]);
    out.v_Normal = fast::normalize(tangentSpace[2]);
    out.v_WorldPos = worldPos.xyz;
    out.v_ViewDir.x = viewDir.x;
    out.v_ViewDir.y = viewDir.y;
    out.v_ViewDir.z = viewDir.z;
    out.v_ViewDir.w = 0.0;
    out.gl_Position = _73.g_ViewProjectionMatrix * worldPos;
    return out;
}

