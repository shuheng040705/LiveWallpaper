#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture1Resolution;
    float4 g_Texture2Resolution;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn1)]];
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
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float2 _63 = float2((in.a_TexCoord.x * _19.g_Texture2Resolution.z) / _19.g_Texture2Resolution.x, (in.a_TexCoord.y * _19.g_Texture2Resolution.w) / _19.g_Texture2Resolution.y);
    out.v_TexCoord.z = _63.x;
    out.v_TexCoord.w = _63.y;
    return out;
}

