#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
    float u_FactorForAutoScale;
    float2 u_CircleAngles;
    float u_CenterDistance;
};

struct main0_out
{
    float autoSaleFactor [[user(locn0)]];
    float reciprocalAspect [[user(locn2)]];
    float4 v_TexCoord [[user(locn4)]];
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
    float aspect = _20.g_Texture0Resolution.z / _20.g_Texture0Resolution.w;
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_TexCoord.x *= aspect;
    out.reciprocalAspect = 1.0 / aspect;
    float g_Texture1ResolutionX = _20.g_Texture1Resolution.x;
    out.autoSaleFactor = ((((g_Texture1ResolutionX / _20.g_Texture1Resolution.y) * _20.u_FactorForAutoScale) * 360.0) / abs(_20.u_CircleAngles.y - _20.u_CircleAngles.x)) - _20.u_CenterDistance;
    return out;
}

