#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Multiply;
    float g_Multiply2;
    float g_Multiply3;
    float g_Multiply4;
    float g_Multiply5;
    float g_Multiply6;
    float g_AlphaMultiply;
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
    return mix(A, float3(1.0 - ((1.0 - A.x) * (1.0 - B.x)), 1.0 - ((1.0 - A.y) * (1.0 - B.y)), 1.0 - ((1.0 - A.z) * (1.0 - B.z))), float3(opacity));
}

static inline __attribute__((always_inline))
float4 PerformBlend(thread float4& albedo, thread const float4& blendColors, thread float& blendAlpha)
{
    blendAlpha *= blendColors.w;
    float3 param = albedo.xyz;
    float3 param_1 = blendColors.xyz;
    float param_2 = blendAlpha;
    float3 _88 = ApplyBlending(7, param, param_1, param_2);
    albedo.x = _88.x;
    albedo.y = _88.y;
    albedo.z = _88.z;
    return albedo;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _129 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float2 blendUV = in.v_TexCoord.zw;
    float4 blendColors = g_Texture1.sample(g_Texture1Smplr, blendUV);
    float blend = 1.0;
    float2 param = blendUV;
    blend = GetUVBlend(param) * blend;
    float blendAlpha = blend * _129.g_Multiply;
    float4 param_1 = albedo;
    float4 param_2 = blendColors;
    float param_3 = blendAlpha;
    float4 _141 = PerformBlend(param_1, param_2, param_3);
    albedo = _141;
    out._fragColor = albedo;
    return out;
}

