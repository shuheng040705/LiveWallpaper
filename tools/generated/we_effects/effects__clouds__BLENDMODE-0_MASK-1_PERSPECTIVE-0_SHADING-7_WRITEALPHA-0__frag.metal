#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_CloudsAlpha;
    float g_CloudThreshold;
    float g_CloudFeather;
    float g_CloudLOD;
    float3 g_Color1;
    float3 g_Color2;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordClouds [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _49 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 cloudTexCoods = in.v_TexCoordClouds;
    float cloud0 = g_Texture1.sample(g_Texture1Smplr, cloudTexCoods.xy, level(_49.g_CloudLOD)).x;
    float cloud1 = g_Texture1.sample(g_Texture1Smplr, cloudTexCoods.zw, level(_49.g_CloudLOD)).x;
    float cloudBlend = cloud0 * cloud1;
    float3 cloudColor = float3(1.0);
    cloudBlend = smoothstep(_49.g_CloudThreshold, _49.g_CloudThreshold + _49.g_CloudFeather, cloudBlend);
    float blend = cloudBlend * _49.g_CloudsAlpha;
    cloudColor = (mix(_49.g_Color2, _49.g_Color1, float3(blend)) * cloud0) * cloud1;
    blend *= g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.zw).x;
    float3 param = albedo.xyz;
    float3 param_1 = cloudColor;
    float param_2 = blend;
    float3 _119 = ApplyBlending(0, param, param_1, param_2);
    albedo.x = _119.x;
    albedo.y = _119.y;
    albedo.z = _119.z;
    out._fragColor = albedo;
    return out;
}

