#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Color4;
    float g_Alpha;
    float u_Threshold;
    float u_Opacity;
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
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

static inline __attribute__((always_inline))
float4 blendBg(thread const float4& originalTex, thread const float4& overridedTex, constant _Globals& _35)
{
    float3 param = originalTex.xyz;
    float3 param_1 = overridedTex.xyz;
    float param_2 = _35.g_Alpha * _35.u_Opacity;
    return float4(mix(ApplyBlending(0, param, param_1, param_2), originalTex.xyz, float3(originalTex.w)), fast::max(originalTex.w, (overridedTex.w * _35.g_Alpha) * _35.u_Opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _35 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 blendColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw);
    float4 transparentColor = _35.g_Color4;
    transparentColor.w = 0.0;
    blendColors = mix(transparentColor, blendColors, float4((step(0.100000001490116119384765625, ((step(in.v_TexCoord.z, 1.0) * step(in.v_TexCoord.w, 1.0)) * step(0.0, in.v_TexCoord.w)) * step(0.0, in.v_TexCoord.z)) * blendColors.w) * step(_35.u_Threshold, blendColors.w)));
    float4 param = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 param_1 = blendColors;
    out._fragColor = blendBg(param, param_1, _35);
    return out;
}

