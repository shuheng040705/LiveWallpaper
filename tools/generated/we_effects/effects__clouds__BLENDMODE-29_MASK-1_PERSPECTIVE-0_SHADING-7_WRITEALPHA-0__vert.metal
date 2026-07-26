#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float4 g_Texture2Resolution;
    float g_Time;
    float2 g_CloudSpeeds;
    float4 g_CloudScales;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordClouds [[user(locn1)]];
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
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float aspect = _20.g_Texture0Resolution.z / _20.g_Texture0Resolution.w;
    float2 _69 = (in.a_TexCoord + float2(_20.g_Time * _20.g_CloudSpeeds.x)) * _20.g_CloudScales.xy;
    out.v_TexCoordClouds.x = _69.x;
    out.v_TexCoordClouds.y = _69.y;
    float2 _86 = (in.a_TexCoord + float2(_20.g_Time * _20.g_CloudSpeeds.y)) * _20.g_CloudScales.zw;
    out.v_TexCoordClouds.z = _86.x;
    out.v_TexCoordClouds.w = _86.y;
    float4 _92 = out.v_TexCoordClouds;
    float2 _94 = _92.xz * aspect;
    out.v_TexCoordClouds.x = _94.x;
    out.v_TexCoordClouds.z = _94.y;
    float _100 = out.v_TexCoordClouds.w;
    float _103 = out.v_TexCoordClouds.z;
    float2 _104 = float2(-_100, _103);
    out.v_TexCoordClouds.z = _104.x;
    out.v_TexCoordClouds.w = _104.y;
    float _110 = out.v_TexCoord.x;
    float _119 = out.v_TexCoord.y;
    float2 _126 = float2((_110 * _20.g_Texture2Resolution.z) / _20.g_Texture2Resolution.x, (_119 * _20.g_Texture2Resolution.w) / _20.g_Texture2Resolution.y);
    out.v_TexCoord.z = _126.x;
    out.v_TexCoord.w = _126.y;
    return out;
}

