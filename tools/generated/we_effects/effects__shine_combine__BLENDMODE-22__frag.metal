#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _26;
    if (A.x == 1.0)
    {
        _26 = A.x;
    }
    else
    {
        _26 = fast::min((B.x * B.x) / (1.0 - A.x), 1.0);
    }
    float _47;
    if (A.y == 1.0)
    {
        _47 = A.y;
    }
    else
    {
        _47 = fast::min((B.y * B.y) / (1.0 - A.y), 1.0);
    }
    float _68;
    if (A.z == 1.0)
    {
        _68 = A.z;
    }
    else
    {
        _68 = fast::min((B.z * B.z) / (1.0 - A.z), 1.0);
    }
    return mix(A, float3(_26, _47, _68), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 rays = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.zw);
    float4 albedo = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy);
    float3 param = albedo.xyz;
    float3 param_1 = rays.xyz;
    float param_2 = rays.w;
    float3 _128 = ApplyBlending(22, param, param_1, param_2);
    albedo.x = _128.x;
    albedo.y = _128.y;
    albedo.z = _128.z;
    albedo.w = fast::clamp(albedo.w + rays.w, 0.0, 1.0);
    out._fragColor = albedo;
    return out;
}

