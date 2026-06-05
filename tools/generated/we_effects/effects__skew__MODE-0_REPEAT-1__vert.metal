#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float g_TextureReductionScale;
    float g_Top;
    float g_Bottom;
    float g_Left;
    float g_Right;
};

struct main0_out
{
    float2 v_TexCoord [[user(locn0)]];
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
    float3 position = in.a_Position;
    out.gl_Position = _25.g_ModelViewProjectionMatrix * float4(position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    out.v_TexCoord.x -= ((step(in.a_TexCoord.y, 0.5) * _25.g_Top) + (step(0.5, in.a_TexCoord.y) * _25.g_Bottom));
    out.v_TexCoord.y += ((step(in.a_TexCoord.x, 0.5) * _25.g_Left) + (step(0.5, in.a_TexCoord.x) * _25.g_Right));
    return out;
}

