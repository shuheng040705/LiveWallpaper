#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float u_Intensity;
    float u_Thickness;
    float u_Amplitude;
    float u_TimeSpeed;
    float u_Frequency;
    float2 u_OffSet;
    packed_float3 u_WaveColor;
    float u_WaveOpacity;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 _we_ro_v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _48 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 v_TexCoord = in._we_ro_v_TexCoord;
    float4 scene = g_Texture0.sample(g_Texture0Smplr, v_TexCoord);
    float waveCoord = v_TexCoord.x;
    v_TexCoord.x += ((_48.g_Time - (6.283185482025146484375 * trunc(_48.g_Time / 6.283185482025146484375))) * _48.u_TimeSpeed);
    waveCoord = powr(fast::clamp(_48.u_Thickness - abs(sin(((v_TexCoord.x * 10.0) / _48.u_Frequency) + _48.u_OffSet.x) - (((v_TexCoord.y * 10.0) + _48.u_OffSet.y) / _48.u_Amplitude)), 0.0, 1.0), 1.0 / _48.u_Intensity);
    float3 finalColor = float3(_48.u_WaveColor);
    float3 param = scene.xyz;
    float3 param_1 = finalColor;
    float param_2 = _48.u_WaveOpacity * waveCoord;
    finalColor = ApplyBlending(0, param, param_1, param_2);
    float alpha = scene.w;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

