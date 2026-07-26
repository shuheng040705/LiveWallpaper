#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    packed_float3 u_Color;
    float g_Time;
    float2 g_PointerPosition;
    float u_Brightness;
    float u_Speed;
    float4 g_AudioSpectrum64Right[64];
    float4 g_AudioSpectrum64Left[64];
    float u_ReduceValue;
    float u_MinFreqRange;
    float u_MaxFreqRange;
    float u_Radius;
    float2 u_FixedSize;
    float2 g_TexelSize;
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
float getFrequency(thread const float& x, constant _Globals& _71)
{
    float left = 0.100000001490116119384765625;
    float right = 0.100000001490116119384765625;
    int _76 = int(_71.u_MinFreqRange);
    for (int i = _76; i < int(_71.u_MaxFreqRange); i++)
    {
        left += _71.g_AudioSpectrum64Left[i].x;
        right += _71.g_AudioSpectrum64Right[i].x;
    }
    float volume = (left + right) * 0.5;
    return abs(volume / _71.u_ReduceValue);
}

static inline __attribute__((always_inline))
float getFrequency_smooth(thread const float& x, constant _Globals& _71)
{
    float index = floor(x * 128.0) / 128.0;
    float next = floor((x * 128.0) + 1.0) / 128.0;
    float param = index;
    float param_1 = next;
    return mix(getFrequency(param, _71), getFrequency(param_1, _71), smoothstep(0.0, 1.0, fract(x * 128.0)));
}

static inline __attribute__((always_inline))
float getFrequency_blend(thread const float& x, constant _Globals& _71)
{
    float param = x;
    float param_1 = x;
    return mix(getFrequency(param, _71), getFrequency_smooth(param_1, _71), 0.5);
}

static inline __attribute__((always_inline))
float3 circleIllumination(thread const float2& fragment0, thread const float& radius, constant _Globals& _71)
{
    float _distance = length(fragment0);
    float param = 0.0;
    float ring = 1.0 / abs((_distance - radius) - (getFrequency_smooth(param, _71) / 4.5));
    float3 color = float3(0.0);
    float angle = precise::atan2(fragment0.x, fragment0.y);
    color += ((float3(_71.u_Color) * ring) * _71.u_Brightness);
    float param_1 = abs(angle / 3.1415927410125732421875);
    float frequency = fast::max(getFrequency_blend(param_1, _71) - 0.0199999995529651641845703125, 0.0);
    color *= frequency;
    return color;
}

static inline __attribute__((always_inline))
float luma(thread const float3& color)
{
    return dot(color, float3(0.2989999949932098388671875, 0.58700001239776611328125, 0.5));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _71 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float2 fragPos = in.v_TexCoord;
    fragPos = (fragPos - float2(0.5)) * 2.0;
    fragPos.x *= (_71.u_FixedSize.x / _71.u_FixedSize.y);
    float3 color = float3(0.0);
    float2 param = fragPos;
    float param_1 = _71.u_Radius;
    color += circleIllumination(param, param_1, _71);
    float3 param_2 = color;
    color += float3(fast::max(luma(param_2) - 1.0, 0.0));
    float3 param_3 = albedo.xyz;
    float3 param_4 = color;
    float param_5 = 1.0;
    float3 _259 = ApplyBlending(31, param_3, param_4, param_5);
    albedo.x = _259.x;
    albedo.y = _259.y;
    albedo.z = _259.z;
    out._fragColor = float4(fast::max(float3(0.0), albedo.xyz), albedo.w);
    return out;
}

