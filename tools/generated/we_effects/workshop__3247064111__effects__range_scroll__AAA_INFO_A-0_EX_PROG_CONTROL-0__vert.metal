#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float g_Time;
    float u_xPos;
    float s_Border;
    float u_ScriptBorderOffset;
    float u_Margin;
    float u_Width;
    float2 u_FadeWidth;
    float u_Timeoffset;
    float u_Speed;
};

struct main0_out
{
    float borderOffset [[user(locn0)]];
    float minAlpha [[user(locn1)]];
    float2 offset [[user(locn2)]];
    float2 reciprocalResolution [[user(locn3)]];
    float totalMargin [[user(locn4)]];
    float4 v_TexCoord [[user(locn5)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _14 [[buffer(0)]])
{
    main0_out out = {};
    out.totalMargin = (float2(_14.u_Margin) + _14.u_FadeWidth).x;
    out.gl_Position = _14.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float4 _60 = out.v_TexCoord;
    float2 _62 = _60.xy * _14.g_Texture0Resolution.xy;
    out.v_TexCoord.x = _62.x;
    out.v_TexCoord.y = _62.y;
    out.v_TexCoord.x -= (_14.u_xPos * (_14.g_Texture0Resolution.x - _14.u_Width));
    out.reciprocalResolution = float2(1.0) / _14.g_Texture0Resolution.xy;
    out.offset.x = (_14.g_Time + _14.u_Timeoffset) * _14.u_Speed;
    out.offset.y = 0.0;
    out.borderOffset = _14.u_ScriptBorderOffset * out.reciprocalResolution.x;
    out.minAlpha = step(float2(_14.g_Texture0Resolution.x - (_14.s_Border * 2.0)), float2(_14.u_Width - _14.u_Margin) - _14.u_FadeWidth).x;
    out.offset *= (1.0 - out.minAlpha);
    return out;
}

