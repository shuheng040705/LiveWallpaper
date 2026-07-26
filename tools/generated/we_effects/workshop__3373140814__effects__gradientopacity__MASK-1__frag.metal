#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_Multiply;
    float u_GradientScale;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _37 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float opactiyMask = 1.0;
    float blend = smoothstep(fast::clamp(mask - _37.u_GradientScale, 0.0, 1.0), fast::clamp(mask + _37.u_GradientScale, 0.0, 1.0), _37.u_Multiply);
    albedo.w *= (1.0 - (blend * opactiyMask));
    out._fragColor = albedo;
    return out;
}

