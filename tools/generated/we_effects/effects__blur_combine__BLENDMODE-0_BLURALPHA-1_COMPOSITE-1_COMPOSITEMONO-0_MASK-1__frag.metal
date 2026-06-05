#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_CompositeAlpha;
    float2 g_CompositeOffset;
    float3 g_CompositeColor;
    float4 g_Texture0Resolution;
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
float2 ApplyCompositeOffset(thread const float2& texCoords, thread const float2& textureResolution, constant _Globals& _42)
{
    return texCoords + (_42.g_CompositeOffset / textureResolution);
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

static inline __attribute__((always_inline))
float4 ApplyComposite(thread const float4& original, thread float4& effect, constant _Globals& _42)
{
    float4 _56 = effect;
    float3 _58 = _56.xyz * _42.g_CompositeColor;
    effect.x = _58.x;
    effect.y = _58.y;
    effect.z = _58.z;
    float3 param = original.xyz;
    float3 param_1 = effect.xyz;
    float param_2 = effect.w * _42.g_CompositeAlpha;
    float3 _84 = ApplyBlending(0, param, param_1, param_2);
    effect.x = _84.x;
    effect.y = _84.y;
    effect.z = _84.z;
    effect.w = fast::max(effect.w * fast::clamp(_42.g_CompositeAlpha, 0.0, 1.0), original.w);
    return effect;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _42 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], texture2d<float> g_Texture1 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]], sampler g_Texture1Smplr [[sampler(2)]])
{
    main0_out out = {};
    float2 blurredCoords = in.v_TexCoord.xy;
    float2 param = blurredCoords;
    float2 param_1 = _42.g_Texture0Resolution.xy;
    float4 blurred = g_Texture0.sample(g_Texture0Smplr, ApplyCompositeOffset(param, param_1, _42));
    float4 albedoOld = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.xy);
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float div = mix(blurred.w, 1.0, step(blurred.w, 0.0));
    float4 param_2 = albedoOld;
    float4 param_3 = float4(blurred.xyz / float3(div), blurred.w);
    float4 _161 = ApplyComposite(param_2, param_3, _42);
    blurred = _161;
    blurred = mix(albedoOld, blurred, float4(mask));
    out._fragColor = blurred;
    return out;
}

