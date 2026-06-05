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
};

struct main0_out
{
    float2 v_TexCoord [[user(locn5)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(1)]];
    float2 a_TexCoord [[attribute(2)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _27 [[buffer(0)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    float3 localPos = position;
    out.v_TexCoord = in.a_TexCoord;
    float4 worldPos = _27.g_ModelMatrix * float4(localPos, 1.0);
    float3 viewDir = _27.g_EyePosition - worldPos.xyz;
    out.gl_Position = _27.g_ModelViewProjectionMatrix * float4(localPos, 1.0);
    return out;
}

