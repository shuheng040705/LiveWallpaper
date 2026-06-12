#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float2 g_TexelSize;
    float4 g_Texture0Resolution;
    float u_ratio;
    float u_aperture;
};

struct main0_out
{
    float qualityNormalizer [[user(locn0)]];
    float2 v_PixelSize [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _14 [[buffer(0)]])
{
    main0_out out = {};
    float2 ratio = _14.g_TexelSize * _14.g_Texture0Resolution.xy;
    out.qualityNormalizer = 1.7999999523162841796875;
    out.v_PixelSize = (_14.g_TexelSize + _14.g_TexelSize) * float2((ratio.y / ratio.x) * _14.u_aperture, _14.u_aperture);
    out.gl_Position = _14.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    return out;
}

