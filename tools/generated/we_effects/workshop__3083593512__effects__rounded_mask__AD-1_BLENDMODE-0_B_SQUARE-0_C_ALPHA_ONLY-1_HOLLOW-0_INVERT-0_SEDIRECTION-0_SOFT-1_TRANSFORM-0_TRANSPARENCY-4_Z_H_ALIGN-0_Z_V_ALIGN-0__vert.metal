#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float2 u_Size;
    float2 g_Offset;
    float2 g_Scale;
    float g_Direction;
    float4 g_Texture0Resolution;
};

struct main0_out
{
    float2 p_TexCoord [[user(locn0)]];
    float2 v_Size [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _22 [[buffer(0)]])
{
    main0_out out = {};
    out.p_TexCoord = in.a_TexCoord;
    out.v_TexCoord = in.a_TexCoord;
    float xScale = fast::max(1.0, _22.g_Texture0Resolution.x / _22.g_Texture0Resolution.y);
    float yScale = fast::max(1.0, _22.g_Texture0Resolution.y / _22.g_Texture0Resolution.x);
    out.v_TexCoord.x *= xScale;
    out.v_TexCoord.y *= yScale;
    out.v_Size.x = _22.u_Size.x * xScale;
    out.v_Size.y = _22.u_Size.y * yScale;
    out.v_TexCoord.x -= ((xScale - 1.0) * 0.5);
    out.v_TexCoord.y -= ((yScale - 1.0) * 0.5);
    out.gl_Position = _22.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    return out;
}

