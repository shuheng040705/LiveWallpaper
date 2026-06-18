#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float g_Time;
    float4 g_CloudSpeeds;
    float4 g_CloudScales;
    float g_timeoffset;
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

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _19 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _19.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float aspect = _19.g_Texture0Resolution.z / _19.g_Texture0Resolution.w;
    float2 _72 = (in.a_TexCoord + (_19.g_CloudSpeeds.xy * (_19.g_Time + _19.g_timeoffset))) * _19.g_CloudScales.xy;
    out.v_TexCoordClouds.x = _72.x;
    out.v_TexCoordClouds.y = _72.y;
    float2 _93 = (in.a_TexCoord + (_19.g_CloudSpeeds.zw * (_19.g_Time + _19.g_timeoffset))) * _19.g_CloudScales.zw;
    out.v_TexCoordClouds.z = _93.x;
    out.v_TexCoordClouds.w = _93.y;
    float4 _99 = out.v_TexCoordClouds;
    float2 _101 = _99.xz * aspect;
    out.v_TexCoordClouds.x = _101.x;
    out.v_TexCoordClouds.z = _101.y;
    float _107 = out.v_TexCoordClouds.w;
    float _110 = out.v_TexCoordClouds.z;
    float2 _111 = float2(-_107, _110);
    out.v_TexCoordClouds.z = _111.x;
    out.v_TexCoordClouds.w = _111.y;
    return out;
}

