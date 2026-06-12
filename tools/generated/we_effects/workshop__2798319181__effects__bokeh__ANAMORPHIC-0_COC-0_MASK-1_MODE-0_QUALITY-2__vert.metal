#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_TexelSize;
    float4 g_Texture0Resolution;
    float u_ratio;
    float u_aperture;
    float u_gamma;
    float u_lightFactor;
};

struct main0_out
{
    float v_Aperture [[user(locn0)]];
    float2 v_Gamma [[user(locn1)]];
    float2 v_Highlights [[user(locn2)]];
    float2 v_PixelSize [[user(locn3)]];
    float2 v_TexCoord [[user(locn4)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _13 [[buffer(0)]])
{
    main0_out out = {};
    float2 ratio = _13.g_TexelSize * _13.g_Texture0Resolution.xy;
    out.v_Aperture = 3.0 * _13.u_aperture;
    out.v_PixelSize = (_13.g_TexelSize + _13.g_TexelSize) * float2((ratio.y / ratio.x) * out.v_Aperture, out.v_Aperture);
    out.v_Highlights = float2(-0.999000012874603271484375, 0.999000012874603271484375) * _13.u_lightFactor;
    out.v_Gamma = float2(_13.u_gamma, 1.0 / _13.u_gamma);
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    return out;
}

