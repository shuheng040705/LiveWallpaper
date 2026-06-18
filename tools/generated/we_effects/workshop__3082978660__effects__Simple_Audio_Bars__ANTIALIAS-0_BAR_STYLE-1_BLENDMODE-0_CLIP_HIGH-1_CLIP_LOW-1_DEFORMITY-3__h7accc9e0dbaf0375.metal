#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float2 g_Offset;
    float2 g_Scale;
    float g_Direction;
    float4 g_Texture0Resolution;
};

struct main0_out
{
    float i_DCorrectingFactor [[user(locn0)]];
    float2 p_TexCoord [[user(locn1)]];
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
    out.i_DCorrectingFactor = 1.0;
    out.i_DCorrectingFactor = _22.g_Texture0Resolution.x / _22.g_Texture0Resolution.y;
    out.gl_Position = _22.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    return out;
}

