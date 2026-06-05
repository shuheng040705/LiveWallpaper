#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_strength;
    float u_alpha;
    float3 u_tint;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _49 [[buffer(0)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 baseAlbedo = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord);
    float mask = 1.0;
    bool _55 = _49.u_strength > 0.001000000047497451305389404296875;
    bool _62;
    if (_55)
    {
        _62 = _49.u_alpha > 0.001000000047497451305389404296875;
    }
    else
    {
        _62 = _55;
    }
    float4 albedo;
    if (_62)
    {
        albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord) * float4(_49.u_tint, 1.0);
        float3 param = baseAlbedo.xyz;
        float3 param_1 = albedo.xyz;
        float param_2 = mask * _49.u_alpha;
        float3 _91 = ApplyBlending(31, param, param_1, param_2);
        albedo.x = _91.x;
        albedo.y = _91.y;
        albedo.z = _91.z;
        albedo.w = baseAlbedo.w;
    }
    else
    {
        albedo = baseAlbedo;
    }
    out._fragColor = albedo;
    return out;
}

