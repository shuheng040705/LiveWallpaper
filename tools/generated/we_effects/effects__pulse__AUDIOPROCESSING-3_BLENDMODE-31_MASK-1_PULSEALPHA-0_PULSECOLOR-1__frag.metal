#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float g_PulseSpeed;
    float g_PulsePhase;
    float g_PulseAmount;
    float2 g_PulseThresholds;
    float g_NoiseSpeed;
    float g_NoiseAmount;
    float g_Power;
    float3 g_TintColor1;
    float3 g_TintColor2;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float v_Pulse [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _57 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 samp_ = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 albedo = samp_;
    float pulse = 0.0;
    pulse = in.v_Pulse;
    float3 param = albedo.xyz * _57.g_TintColor1;
    float3 param_1 = albedo.xyz * _57.g_TintColor2;
    float param_2 = pulse;
    float3 _73 = ApplyBlending(31, param, param_1, param_2);
    albedo.x = _73.x;
    albedo.y = _73.y;
    albedo.z = _73.z;
    float mask = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.zw).x;
    albedo = mix(samp_, albedo, float4(mask));
    out._fragColor = float4(fast::max(float3(0.0), albedo.xyz), albedo.w);
    return out;
}

