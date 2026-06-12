#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float2 g_TexelSize;
    float u_CutOutSkew;
    float u_SkewShift;
    float u_SkewWarp;
    float4x4 g_ModelViewProjectionMatrix;
};

struct main0_out
{
    float2 v_BaseCenterCoords [[user(locn0)]];
    float2 v_CutUV [[user(locn1)]];
    float3 v_TexCoord [[user(locn2)]];
    float2 v_TexelUVRatio [[user(locn3)]];
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
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    out.v_TexCoord.z = out.v_TexCoord.x + (_20.g_Time * 0.039999999105930328369140625);
    out.v_TexelUVRatio = float2(_20.g_TexelSize.y / _20.g_TexelSize.x, 1.0);
    out.v_CutUV = float2(_20.u_SkewShift + dot(float2(out.v_TexCoord.y, -0.5), float2(_20.u_CutOutSkew)), _20.u_SkewWarp) - out.v_TexCoord.xy;
    return out;
}

