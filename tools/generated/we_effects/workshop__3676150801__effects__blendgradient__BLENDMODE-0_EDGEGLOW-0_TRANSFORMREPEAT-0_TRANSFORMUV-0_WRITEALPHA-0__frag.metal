#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Multiply;
    float g_GradientScale;
    float g_AlphaMultiply;
    float g_EdgeBrightness;
    float3 g_EdgeColor;
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
float GetUVBlend(thread const float2& uv)
{
    return 1.0;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _67 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float2 blendUV = in.v_TexCoord.zw;
    float4 blendColors = g_Texture1.sample(g_Texture1Smplr, blendUV);
    float blend = 1.0;
    float gradient = g_Texture2.sample(g_Texture2Smplr, blendUV).x;
    blend = smoothstep(fast::clamp(gradient - _67.g_GradientScale, 0.0, 1.0), fast::clamp(gradient + _67.g_GradientScale, 0.0, 1.0), _67.g_Multiply);
    float2 param = blendUV;
    float blendAlpha = (GetUVBlend(param) * blend) * blendColors.w;
    float3 param_1 = albedo.xyz;
    float3 param_2 = blendColors.xyz;
    float param_3 = blendAlpha;
    float3 _102 = ApplyBlending(0, param_1, param_2, param_3);
    albedo.x = _102.x;
    albedo.y = _102.y;
    albedo.z = _102.z;
    out._fragColor = albedo;
    return out;
}

