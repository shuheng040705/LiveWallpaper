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
float roundedBoxSDF(thread const float2& CenterPosition, thread float2& size, constant _Globals& _39)
{
    size *= 0.5;
    float r = _39.u_Radius * fast::min(size.x, size.y);
    return length(fast::max((abs(CenterPosition) - size) + float2(r), float2(0.0))) - r;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _39 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 pix = g_Texture0.sample(g_Texture0Smplr, in.p_TexCoord);
    float2 param = in.v_TexCoord - float2(0.5);
    float2 param_1 = in.v_Size;
    float _88 = roundedBoxSDF(param, param_1, _39);
    float d = _88;
    float edgeSoftnessI = (_39.u_Softness / fast::max(_39.g_Texture0Resolution.x, _39.g_Texture0Resolution.y)) * 2.0;
    float edgeSoftnessO = 0.0;
    float rAlpha = 1.0 - smoothstep(-edgeSoftnessI, edgeSoftnessO, d);
    float alpha = (pix.w * rAlpha) * _39.u_Alpha;
    float3 param_2 = _39.u_Color;
    float3 param_3 = mix(_39.u_Color, pix.xyz, float3(pix.w));
    float param_4 = alpha;
    out._fragColor = float4(ApplyBlending(0, param_2, param_3, param_4), rAlpha);
    return out;
}

