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

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _114 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = _114.g_BlendAlpha;
    float3 param = albedo.xyz;
    float3 param_1 = _114.g_TintColor;
    float param_2 = mask;
    float3 _130 = ApplyBlending(22, param, param_1, param_2);
    albedo.x = _130.x;
    albedo.y = _130.y;
    albedo.z = _130.z;
    out._fragColor = albedo;
    return out;
}

