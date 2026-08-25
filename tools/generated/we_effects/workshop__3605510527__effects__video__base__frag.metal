#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_AudioSpectrum64Left[64];
    float R;
    char _m2_pad[12];
    packed_float3 u_userNewColor;
    float u_soundStrength;
    float4 g_AudioSpectrum64Right[64];
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
float volumNum(thread const float& barID, constant _Globals& _147)
{
    return fast::clamp(0.0, 1.0, _147.g_AudioSpectrum64Left[int(barID)].x);
}

static inline __attribute__((always_inline))
float2 centerUV(thread float2& uv)
{
    uv -= float2(0.5);
    return uv;
}

static inline __attribute__((always_inline))
float2 rotate(thread const float2& uv, thread const float& th)
{
    return float2x2(float2(cos(th), sin(th)), float2(-sin(th), cos(th))) * uv;
}

static inline __attribute__((always_inline))
float sdRect(thread float2& uv, thread const float& width, thread const float& height, thread const float& angle, thread const float2& offset)
{
    float2 param = uv;
    float2 _106 = centerUV(param);
    uv = _106;
    float x = uv.x - offset.x;
    float y = uv.y - offset.y;
    float2 param_1 = float2(x, y);
    float param_2 = angle;
    float2 rotated = rotate(param_1, param_2);
    x = rotated.x;
    y = rotated.y;
    return fast::max(abs(x) - width, abs(y) - height);
}

static inline __attribute__((always_inline))
float sdCircle(thread float2& uv, thread const float& r, thread const float2& offset)
{
    float2 param = uv;
    float2 _80 = centerUV(param);
    uv = _80;
    float x = uv.x - offset.x;
    float y = uv.y - offset.y;
    return length(float2(x, y)) - r;
}

static inline __attribute__((always_inline))
float unionSD(thread const float& a, thread const float& b)
{
    return fast::min(a, b);
}

static inline __attribute__((always_inline))
float3 drawSence(thread const float2& uv, constant _Globals& _147)
{
    float4 col = float4(0.0);
    for (float i = 0.0; i < 64.0; i += 1.0)
    {
        float theta = ((3.141592502593994140625 * i) * 2.0) / 64.0;
        float param = i;
        float height = volumNum(param, _147) * _147.u_soundStrength;
        float2 param_1 = uv;
        float param_2 = 0.0040000001899898052215576171875;
        float param_3 = height;
        float param_4 = theta;
        float2 param_5 = float2(_147.R * sin(theta), _147.R * cos(theta));
        float _209 = sdRect(param_1, param_2, param_3, param_4, param_5);
        float rect = _209;
        float2 param_6 = uv;
        float param_7 = 0.0040000001899898052215576171875;
        float2 param_8 = float2((_147.R - height) * sin(theta), (_147.R - height) * cos(theta));
        float _230 = sdCircle(param_6, param_7, param_8);
        float circle1 = _230;
        float2 param_9 = uv;
        float param_10 = 0.0040000001899898052215576171875;
        float2 param_11 = float2((_147.R + height) * sin(theta), (_147.R + height) * cos(theta));
        float _251 = sdCircle(param_9, param_10, param_11);
        float circle2 = _251;
        float param_12 = rect;
        float param_13 = circle1;
        float sence = unionSD(param_12, param_13);
        float param_14 = sence;
        float param_15 = circle2;
        sence = unionSD(param_14, param_15);
        col = float4(mix(float3(_147.u_userNewColor), col.xyz, float3(step(0.0, sence))), 1.0);
    }
    return col.xyz;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _147 [[buffer(0)]])
{
    main0_out out = {};
    float2 uv = in.v_TexCoord;
    float2 param = uv;
    float3 col = drawSence(param, _147);
    out._fragColor = float4(col, 1.0);
    return out;
}
