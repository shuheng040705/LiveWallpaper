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
float2 ApplyCompositeOffset(thread const float2& texCoords, thread const float2& textureResolution, constant _Globals& _25)
{
    return texCoords + (_25.g_CompositeOffset / textureResolution);
}

static inline __attribute__((always_inline))
float4 ApplyComposite(thread const float4& original, thread float4& effect, constant _Globals& _25)
{
    float4 _40 = effect;
    float3 _42 = _40.xyz * _25.g_CompositeColor;
    effect.x = _42.x;
    effect.y = _42.y;
    effect.z = _42.z;
    effect.w *= fast::clamp(_25.g_CompositeAlpha, 0.0, 1.0);
    effect = mix(effect, original, float4(original.w));
    return effect;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _25 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 blurredCoords = in.v_TexCoord.xy;
    float2 param = blurredCoords;
    float2 param_1 = _25.g_Texture0Resolution.xy;
    float4 blurred = g_Texture0.sample(g_Texture0Smplr, ApplyCompositeOffset(param, param_1, _25));
    float4 albedoOld = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float div = mix(blurred.w, 1.0, step(blurred.w, 0.0));
    float4 param_2 = albedoOld;
    float4 param_3 = float4(blurred.xyz / float3(div), blurred.w);
    float4 _124 = ApplyComposite(param_2, param_3, _25);
    blurred = _124;
    blurred = mix(albedoOld, blurred, float4(mask));
    out._fragColor = blurred;
    return out;
}

