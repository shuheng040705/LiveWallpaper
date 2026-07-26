#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float u_zoom;
    float u_general;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
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
    float2 _54 = ((in.a_TexCoord - float2(0.5)) * (1.0 + ((1.0 - _19.u_zoom) * _19.u_general))) + float2(0.5);
    out.v_TexCoord.x = _54.x;
    out.v_TexCoord.y = _54.y;
    return out;
}

