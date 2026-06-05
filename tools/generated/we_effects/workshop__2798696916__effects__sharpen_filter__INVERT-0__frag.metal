#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_strength;
    float u_radius;
    float2 g_TexelSize;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float4 sharpen(thread const float2& fragCoord, thread const float& mask, texture2d<float> g_Texture0, sampler g_Texture0Smplr, constant _Globals& _28)
{
    float4 orig = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(0.0) * _28.g_TexelSize)));
    float4 c1 = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(-_28.u_radius, -_28.u_radius) * _28.g_TexelSize)));
    float4 c2 = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(0.0, -_28.u_radius) * _28.g_TexelSize)));
    float4 c3 = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(_28.u_radius, -_28.u_radius) * _28.g_TexelSize)));
    float4 c4 = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(-_28.u_radius, 0.0) * _28.g_TexelSize)));
    float4 c5 = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(_28.u_radius, 0.0) * _28.g_TexelSize)));
    float4 c6 = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(-_28.u_radius, _28.u_radius) * _28.g_TexelSize)));
    float4 c7 = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(0.0, _28.u_radius) * _28.g_TexelSize)));
    float4 c8 = g_Texture0.sample(g_Texture0Smplr, (fragCoord + (float2(_28.u_radius, _28.u_radius) * _28.g_TexelSize)));
    float4 blur = (((((c1 + c3) + c6) + c8) + ((((c2 + c4) + c5) + c7) * 2.0)) + (orig * 4.0)) / float4(16.0);
    float4 corr = (orig * (1.0 + (_28.u_strength * mask))) - (blur * (_28.u_strength * mask));
    return corr;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _28 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy).x;
    float _204;
    if (false)
    {
        _204 = 1.0 - mask;
    }
    else
    {
        _204 = mask;
    }
    mask = _204;
    if (mask > 0.100000001490116119384765625)
    {
        float2 param = in.v_TexCoord.xy;
        float param_1 = mask;
        albedo = sharpen(param, param_1, g_Texture0, g_Texture0Smplr, _28);
    }
    out._fragColor = albedo;
    return out;
}

