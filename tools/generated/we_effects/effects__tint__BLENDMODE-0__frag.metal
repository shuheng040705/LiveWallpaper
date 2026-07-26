#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_BlendAlpha;
    float3 g_TintColor;
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

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _42 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = _42.g_BlendAlpha;
    float3 param = albedo.xyz;
    float3 param_1 = _42.g_TintColor;
    float param_2 = mask;
    float3 _57 = ApplyBlending(0, param, param_1, param_2);
    albedo.x = _57.x;
    albedo.y = _57.y;
    albedo.z = _57.z;
    albedo.w = 1.0;
    out._fragColor = albedo;
    return out;
}

