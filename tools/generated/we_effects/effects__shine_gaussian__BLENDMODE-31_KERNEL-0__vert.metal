#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_Scale;
    float4 g_Texture0Resolution;
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

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _40 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    out.v_TexCoord.z = _40.g_Scale.x / _40.g_Texture0Resolution.z;
    out.v_TexCoord.w = 0.0;
    return out;
}

