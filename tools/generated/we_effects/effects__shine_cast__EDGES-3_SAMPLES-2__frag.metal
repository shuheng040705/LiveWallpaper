#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Length;
    float g_Intensity;
    float3 g_ColorRays;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord01 [[user(locn0)]];
    float4 v_TexCoord23 [[user(locn1)]];
};

static inline __attribute__((always_inline))
float4 GatherDirection(thread float2& texCoords, thread float2& direction, constant _Globals& _30, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    float4 albedo = float4(0.0);
    float dist = length(direction);
    direction /= float2(dist);
    dist *= _30.g_Length;
    texCoords += (direction * dist);
    direction = (direction * dist) / float2(14.0);
    for (int i = 0; i < 15; i++)
    {
        float4 samp_ = g_Texture0.sample(g_Texture0Smplr, texCoords);
        texCoords -= direction;
        albedo += (samp_ * (float(i) / 14.0));
    }
    return albedo;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _30 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoords = in.v_TexCoord01.xy;
    float4 albedo = float4(0.0);
    float2 param = texCoords;
    float2 param_1 = in.v_TexCoord01.zw;
    float4 _95 = GatherDirection(param, param_1, _30, g_Texture0, g_Texture0Smplr);
    albedo += _95;
    float2 param_2 = texCoords;
    float2 param_3 = in.v_TexCoord23.xy;
    float4 _104 = GatherDirection(param_2, param_3, _30, g_Texture0, g_Texture0Smplr);
    albedo += _104;
    float2 param_4 = texCoords;
    float2 param_5 = in.v_TexCoord23.zw;
    float4 _112 = GatherDirection(param_4, param_5, _30, g_Texture0, g_Texture0Smplr);
    albedo += _112;
    float4 _119 = albedo;
    float3 _121 = _119.xyz * _30.g_ColorRays;
    albedo.x = _121.x;
    albedo.y = _121.y;
    albedo.z = _121.z;
    out._fragColor = float4(albedo.xyz * (_30.g_Intensity * 0.20000000298023223876953125), fast::clamp((_30.g_Intensity * 0.20000000298023223876953125) * albedo.w, 0.0, 1.0));
    return out;
}

