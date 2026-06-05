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
    float3 v_RefractTexCoord [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 DecompressNormal(thread float4& normal)
{
    float4 _15 = normal;
    float2 _21 = (_15.wy * 2.0) - float2(1.0);
    normal.x = _21.x;
    normal.y = _21.y;
    normal.z = sqrt(fast::clamp((1.0 - (normal.x * normal.x)) - (normal.y * normal.y), 0.0, 1.0));
    return normal.xyz;
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float mask = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.zw).x;
    float2 texCoord = in.v_TexCoord.xy;
    float4 param = g_Texture1.sample(g_Texture1Smplr, in.v_RefractTexCoord.xy);
    float3 _77 = DecompressNormal(param);
    float3 normal = _77;
    texCoord += ((normal.xy * in.v_RefractTexCoord.z) * mask);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, texCoord);
    out._fragColor = albedo;
    return out;
}

