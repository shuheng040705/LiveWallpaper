#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float g_UniformMultiply;
    float g_Multiply1;
    float g_Multiply2;
    float g_Multiply3;
    float g_Multiply4;
};

struct main0_out
{
    float v_Multiply1 [[user(locn0)]];
    float v_Multiply2 [[user(locn1)]];
    float v_Multiply3 [[user(locn2)]];
    float v_Multiply4 [[user(locn3)]];
    float2 v_TexCoord [[user(locn4)]];
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
    out.v_TexCoord = in.a_TexCoord;
    out.v_Multiply1 = _19.g_UniformMultiply * _19.g_Multiply1;
    out.v_Multiply2 = _19.g_UniformMultiply * _19.g_Multiply2;
    out.v_Multiply3 = _19.g_UniformMultiply * _19.g_Multiply3;
    out.v_Multiply4 = _19.g_UniformMultiply * _19.g_Multiply4;
    return out;
}

