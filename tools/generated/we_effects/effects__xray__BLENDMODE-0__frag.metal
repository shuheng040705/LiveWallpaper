#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Multiply;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float v_PointerScale [[user(locn0)]];
    float4 v_PointerUV [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _52 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw);
    float blend = mask.w * _52.g_Multiply;
    float2 unprojectedUVs = in.v_PointerUV.xy / float2(in.v_PointerUV.z);
    float2 texSource = in.v_TexCoord.xy;
    texSource.y = 1.0 - texSource.y;
    unprojectedUVs = texSource - unprojectedUVs;
    unprojectedUVs = fast::clamp(unprojectedUVs, float2(0.0), float2(1.0));
    unprojectedUVs -= float2(0.5);
    unprojectedUVs *= (float2(1.0, in.v_PointerUV.w) * in.v_PointerScale);
    unprojectedUVs += float2(0.5);
    float2 blendSample = g_Texture2.sample(g_Texture2Smplr, unprojectedUVs).xw;
    blend *= (blendSample.x * blendSample.y);
    float3 param = albedo.xyz;
    float3 param_1 = mask.xyz;
    float param_2 = blend;
    float3 _123 = ApplyBlending(0, param, param_1, param_2);
    albedo.x = _123.x;
    albedo.y = _123.y;
    albedo.z = _123.z;
    out._fragColor = albedo;
    return out;
}

