#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_ReflectionAlpha;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_ReflectedCoord [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, fast::min(A + B, float3(1.0)), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _66 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float2 reflectedCoord = in.v_ReflectedCoord;
    float4 reflected = g_Texture0.sample(g_Texture0Smplr, reflectedCoord);
    float3 param = albedo.xyz;
    float3 param_1 = reflected.xyz;
    float param_2 = mask * _66.g_ReflectionAlpha;
    float3 _79 = ApplyBlending(9, param, param_1, param_2);
    out._fragColor.x = _79.x;
    out._fragColor.y = _79.y;
    out._fragColor.z = _79.z;
    out._fragColor.w = fast::min(1.0, albedo.w + ((reflected.w * mask) * _66.g_ReflectionAlpha));
    return out;
}

