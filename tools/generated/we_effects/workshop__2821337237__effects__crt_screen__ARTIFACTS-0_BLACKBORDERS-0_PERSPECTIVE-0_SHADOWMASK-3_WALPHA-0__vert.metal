#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 u_borders;
    float u_curvature;
    float2 g_Point0;
    float2 g_Point1;
    float2 g_Point2;
    float2 g_Point3;
    float4x4 g_ModelViewProjectionMatrix;
};

struct main0_out
{
    float3 v_PerspCoord [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
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
    out.v_TexCoord = in.a_TexCoord;
    out.v_PerspCoord = float3(in.a_TexCoord, 1.0);
    return out;
}

