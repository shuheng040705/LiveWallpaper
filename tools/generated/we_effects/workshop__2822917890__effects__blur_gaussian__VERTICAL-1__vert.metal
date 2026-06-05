#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_TexelSize;
    float4 g_Texture0Resolution;
    float u_radius;
    float u_strength;
};

struct main0_out
{
    float2 v_SizeMultiplier [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _13 [[buffer(0)]])
{
    main0_out out = {};
    float2 ratio = _13.g_Texture0Resolution.xy * _13.g_TexelSize;
    out.v_SizeMultiplier = (_13.g_TexelSize * float2(1.0, ratio.x / ratio.y)) * _13.u_radius;
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    return out;
}

