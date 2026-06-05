#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_amount;
    float u_direction;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_NoiseCoord [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _86 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float mask = 1.0;
    mask *= g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float3 _noise = g_Texture2.sample(g_Texture2Smplr, in.v_NoiseCoord).xyz;
    float2 uvs = in.v_TexCoord.xy;
    float2 offset = float2((((_noise.x * 2.0) - 1.0) * _86.u_amount) * mask, 0.0);
    float2 param = offset;
    float param_1 = _86.u_direction + 1.57079637050628662109375;
    offset = rotateVec2(param, param_1);
    uvs += offset;
    float dstMask = g_Texture1.sample(g_Texture1Smplr, (in.v_TexCoord.zw + offset)).x;
    uvs = mix(in.v_TexCoord.xy, uvs, float2(dstMask));
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, uvs);
    out._fragColor = albedo;
    return out;
}

