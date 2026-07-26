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
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, fast::min(A + B, float3(1.0)), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _67 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture3 [[texture(1)]], texture2d<float> g_Texture1 [[texture(2)]], texture2d<float> g_Texture2 [[texture(3)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture3Smplr [[sampler(1)]], sampler g_Texture1Smplr [[sampler(2)]], sampler g_Texture2Smplr [[sampler(3)]])
{
    main0_out out = {};
    float4 samp_ = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 albedo = samp_;
    float pulse = 0.0;
    float flowPhase = g_Texture3.sample(g_Texture3Smplr, in.v_TexCoord.zw).x * 6.283185482025146484375;
    pulse = smoothstep(_67.g_PulseThresholds.x, _67.g_PulseThresholds.y, (sin(((_67.g_Time * _67.g_PulseSpeed) + _67.g_PulsePhase) + flowPhase) * 0.5) + 0.5) * _67.g_PulseAmount;
    float _noise = g_Texture1.sample(g_Texture1Smplr, (float2(_67.g_Time * 0.08333332836627960205078125, _67.g_Time * 0.02777777053415775299072265625) * _67.g_NoiseSpeed)).x * _67.g_NoiseAmount;
    pulse += _noise;
    pulse = powr(pulse, _67.g_Power);
    float3 param = albedo.xyz * _67.g_TintColor1;
    float3 param_1 = albedo.xyz * _67.g_TintColor2;
    float param_2 = pulse;
    float3 _144 = ApplyBlending(9, param, param_1, param_2);
    albedo.x = _144.x;
    albedo.y = _144.y;
    albedo.z = _144.z;
    albedo.w *= pulse;
    float mask = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.zw).x;
    albedo = mix(samp_, albedo, float4(mask));
    out._fragColor = float4(fast::max(float3(0.0), albedo.xyz), albedo.w);
    return out;
}

