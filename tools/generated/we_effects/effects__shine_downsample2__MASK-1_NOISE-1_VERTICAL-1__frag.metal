#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Threshold;
    float g_NoiseAmount;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_NoiseTexCoord [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _54 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float4 samp_ = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float noiseSample = g_Texture2.sample(g_Texture2Smplr, in.v_NoiseTexCoord.xy).x * g_Texture2.sample(g_Texture2Smplr, in.v_NoiseTexCoord.zw).x;
    noiseSample = mix(samp_.w, samp_.w * noiseSample, _54.g_NoiseAmount);
    float _62 = samp_.w;
    float4 _64 = samp_;
    float3 _66 = _64.xyz * _62;
    samp_.x = _66.x;
    samp_.y = _66.y;
    samp_.z = _66.z;
    samp_.w = 1.0;
    out._fragColor = (samp_ * mask) * step(_54.g_Threshold, dot(float3(0.10999999940395355224609375, 0.589999973773956298828125, 0.300000011920928955078125), samp_.xyz));
    out._fragColor.w *= noiseSample;
    return out;
}

