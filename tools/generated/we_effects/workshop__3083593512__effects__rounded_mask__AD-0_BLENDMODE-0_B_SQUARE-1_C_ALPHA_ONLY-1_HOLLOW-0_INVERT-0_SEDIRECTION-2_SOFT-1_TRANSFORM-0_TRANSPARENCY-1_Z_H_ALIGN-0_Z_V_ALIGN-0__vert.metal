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

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _25 [[buffer(0)]])
{
    main0_out out = {};
    out.p_TexCoord = in.a_TexCoord;
    out.v_TexCoord = in.a_TexCoord;
    int xScale = 1;
    int yScale = 1;
    out.v_Size = _25.u_Size;
    out.v_TexCoord.x -= (float(xScale - 1) * 0.5);
    out.v_TexCoord.y -= (float(yScale - 1) * 0.5);
    out.gl_Position = _25.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    return out;
}

