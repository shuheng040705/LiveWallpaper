#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Rotation;
    float2 g_Texture0Translation;
};

struct main0_out
{
    float2 v_TexCoord [[user(locn9)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _31 [[buffer(0)]])
{
    main0_out out = {};
    float3 localPos = in.a_Position;
    out.v_TexCoord = in.a_TexCoord;
    out.gl_Position = _31.g_ModelViewProjectionMatrix * float4(localPos, 1.0);
    return out;
}

