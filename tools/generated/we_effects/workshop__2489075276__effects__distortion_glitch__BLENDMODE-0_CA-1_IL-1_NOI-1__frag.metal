#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_ScreenBounceX;
    float u_ScreenBounceY;
    float u_Warp;
    float u_InterlaceX;
    float u_InterlaceY;
    float u_FaultMulti1;
    float u_FaultScale1;
    float u_FaultMulti2;
    float u_FaultScale2;
    float u_DistOpacity;
    float u_TimeSpeed;
    float u_NoiseSpeed;
    float u_NoiseOpacity;
    float g_Time;
    float4 g_Texture0Resolution;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float2 interlace(thread float2& uv, thread const float& s, constant _Globals& _84)
{
    uv.x += (s * ((_84.u_InterlaceX * fract((uv.y * _84.g_Texture0Resolution.y) / 2.0)) - 1.0));
    uv.y += (s * ((_84.u_InterlaceY * fract((uv.x * _84.g_Texture0Resolution.x) / 2.0)) - 1.0));
    return uv;
}

static inline __attribute__((always_inline))
float2 fault(thread float2& uv, thread const float& s, constant _Globals& _84)
{
    float v = powr(0.5 - (0.5 * cos((6.28318500518798828125 * uv.y) * _84.u_FaultMulti1)), _84.u_FaultScale1) * sin(6.28318500518798828125 * uv.y);
    uv.x += (v * s);
    return uv;
}

static inline __attribute__((always_inline))
float2 fault2(thread float2& uv, thread const float& s, constant _Globals& _84)
{
    float v = powr(0.5 - (0.5 * cos((3.141592502593994140625 * uv.y) * _84.u_FaultMulti2)), _84.u_FaultScale2) * sin(4.7123889923095703125 * uv.y);
    uv.x += (v * s);
    return uv;
}

static inline __attribute__((always_inline))
float2 rnd(thread float2& uv, thread const float& s, constant _Globals& _84, texture2d<float> g_Texture1, sampler g_Texture1Smplr)
{
    uv.x += (s * ((2.0 * g_Texture1.sample(g_Texture1Smplr, (uv * 0.0500000007450580596923828125)).x) - _84.u_ScreenBounceX));
    uv.y += (s * ((2.0 * g_Texture1.sample(g_Texture1Smplr, (uv * 0.0500000007450580596923828125)).y) - _84.u_ScreenBounceY));
    return uv;
}

static inline __attribute__((always_inline))
float3 colorSplit(thread const float2& uv, thread const float2& s, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    float3 color;
    color.x = g_Texture0.sample(g_Texture0Smplr, (uv - s)).x;
    color.y = g_Texture0.sample(g_Texture0Smplr, uv).y;
    color.z = g_Texture0.sample(g_Texture0Smplr, (uv + s)).z;
    return color;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _84 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float t = fract(_84.g_Time / 10.0) * _84.u_TimeSpeed;
    float2 uv = in.v_TexCoord.xy + (float2(0.5) / _84.g_Texture0Resolution.xy);
    float s = g_Texture1.sample(g_Texture1Smplr, float2(t * 0.20000000298023223876953125, 0.5)).x;
    float2 param = uv;
    float param_1 = s * 0.004999999888241291046142578125;
    float2 _271 = interlace(param, param_1, _84);
    uv = _271;
    float r = g_Texture1.sample(g_Texture1Smplr, float2(t, 0.0)).x;
    float2 param_2 = uv + float2(0.0, fract(t * 2.0));
    float param_3 = (5.0 * sign(r)) * powr(abs(r), 5.0);
    float2 _295 = fault(param_2, param_3, _84);
    uv = _295 - float2(0.0, fract(t * 2.0));
    float2 param_4 = uv + float2(0.0, fract(t * 2.0));
    float param_5 = (5.0 * sign(r)) * powr(abs(r), 5.0);
    float2 _316 = fault2(param_4, param_5, _84);
    uv = _316 - float2(0.0, fract(t * 2.0));
    float2 param_6 = uv;
    float param_7 = s * _84.u_Warp;
    float2 _330 = rnd(param_6, param_7, _84, g_Texture1, g_Texture1Smplr);
    uv = _330;
    float2 param_8 = uv;
    float2 param_9 = float2(s * 0.0199999995529651641845703125, 0.0);
    float3 color = colorSplit(param_8, param_9, g_Texture0, g_Texture0Smplr);
    color = mix(color, g_Texture1.sample(g_Texture1Smplr, ((uv * 0.5) + float2(t * _84.u_NoiseSpeed))).xyz, float3(_84.u_NoiseOpacity));
    float3 finalColor = color;
    float3 param_10 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_11 = finalColor;
    float param_12 = _84.u_DistOpacity;
    finalColor = ApplyBlending(0, param_10, param_11, param_12);
    float alpha = scene.w;
    out._fragColor = float4(finalColor, alpha);
    float t_1;
    return out;
}

