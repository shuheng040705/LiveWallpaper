#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float g_Time;
    float4 g_NitroSpeeds;
    float2 g_NitroScales;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordNitro [[user(locn1)]];
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
    float2 _68 = (in.a_TexCoord * _20.g_NitroScales.x) + (_20.g_NitroSpeeds.xy * _20.g_Time);
    out.v_TexCoordNitro.x = _68.x;
    out.v_TexCoordNitro.y = _68.y;
    float2 _84 = (in.a_TexCoord * _20.g_NitroScales.y) + (_20.g_NitroSpeeds.zw * _20.g_Time);
    out.v_TexCoordNitro.z = _84.x;
    out.v_TexCoordNitro.w = _84.y;
    float4 _90 = out.v_TexCoordNitro;
    float2 _92 = _90.xz * aspect;
    out.v_TexCoordNitro.x = _92.x;
    out.v_TexCoordNitro.z = _92.y;
    float _98 = out.v_TexCoordNitro.w;
    float _101 = out.v_TexCoordNitro.z;
    float2 _102 = float2(-_98, _101);
    out.v_TexCoordNitro.z = _102.x;
    out.v_TexCoordNitro.w = _102.y;
    return out;
}

