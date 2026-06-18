#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float3 u_Color;
    float4 g_Texture0Resolution;
    float u_Radius;
    float u_BorderWidth;
    float u_Softness;
    float u_Alpha;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 p_TexCoord [[user(locn0)]];
    float2 v_Size [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
};

static inline __attribute__((always_inline))
float roundedBoxSDF(thread const float2& CenterPosition, thread float2& size, constant _Globals& _23)
{
    size *= 0.5;
    float r = _23.u_Radius * fast::min(size.x, size.y);
    return length(fast::max((abs(CenterPosition) - size) + float2(r), float2(0.0))) - r;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _23 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 pix = g_Texture0.sample(g_Texture0Smplr, in.p_TexCoord);
    float2 param = in.v_TexCoord - float2(0.5);
    float2 param_1 = in.v_Size;
    float _73 = roundedBoxSDF(param, param_1, _23);
    float d = _73;
    float edgeSoftnessI = (_23.u_Softness / fast::max(_23.g_Texture0Resolution.x, _23.g_Texture0Resolution.y)) * 2.0;
    float edgeSoftnessO = 0.0;
    float rAlpha = 1.0 - smoothstep(-edgeSoftnessI, edgeSoftnessO, d);
    float alpha = fast::max(0.0, pix.w - (rAlpha * _23.u_Alpha));
    out._fragColor = float4(pix.xyz, alpha);
    return out;
}

