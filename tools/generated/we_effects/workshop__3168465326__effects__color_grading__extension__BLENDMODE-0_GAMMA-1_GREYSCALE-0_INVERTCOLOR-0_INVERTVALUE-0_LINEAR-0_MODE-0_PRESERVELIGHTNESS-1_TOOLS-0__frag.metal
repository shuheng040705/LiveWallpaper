#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_alpha;
    float u_displayInitGamma;
    float u_displayGamma;
    char _m3_pad[4];
    packed_float3 u_channelMultiplier;
    float u_redBalance;
    float u_greenBalance;
    float u_blueBalance;
    float u_tollerance;
    float u_smooth;
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
float rgbLightness(thread const float3& color)
{
    float fmin = fast::min(fast::min(color.x, color.y), color.z);
    float fmax = fast::max(fast::max(color.x, color.y), color.z);
    return (fmax + fmin) / 2.0;
}

static inline __attribute__((always_inline))
float colorBalance(thread float& channel, thread const float& balance)
{
    float init = channel;
    channel = (channel - 0.5) * 2.0;
    channel = 0.66666698455810546875 * (1.0 - (channel * channel));
    return fast::clamp(init + (channel * balance), 0.0, 1.0);
}

static inline __attribute__((always_inline))
float3 RGBToHSL(thread const float3& color)
{
    float fmin = fast::min(fast::min(color.x, color.y), color.z);
    float fmax = fast::max(fast::max(color.x, color.y), color.z);
    float delta = fmax - fmin;
    float3 hsl;
    hsl.z = (fmax + fmin) / 2.0;
    if (delta == 0.0)
    {
        hsl.x = 0.0;
        hsl.y = 0.0;
    }
    else
    {
        if (hsl.z < 0.5)
        {
            hsl.y = delta / (fmax + fmin);
        }
        else
        {
            hsl.y = delta / ((2.0 - fmax) - fmin);
        }
        float deltaR = (((fmax - color.x) / 6.0) + (delta / 2.0)) / delta;
        float deltaG = (((fmax - color.y) / 6.0) + (delta / 2.0)) / delta;
        float deltaB = (((fmax - color.z) / 6.0) + (delta / 2.0)) / delta;
        if (color.x == fmax)
        {
            hsl.x = deltaB - deltaG;
        }
        else
        {
            if (color.y == fmax)
            {
                hsl.x = (0.3333333432674407958984375 + deltaR) - deltaB;
            }
            else
            {
                if (color.z == fmax)
                {
                    hsl.x = (0.666666686534881591796875 + deltaG) - deltaR;
                }
            }
        }
        if (hsl.x < 0.0)
        {
            hsl.x += 1.0;
        }
        else
        {
            if (hsl.x > 1.0)
            {
                hsl.x -= 1.0;
            }
        }
    }
    return hsl;
}

static inline __attribute__((always_inline))
float HueToRGB(thread const float& f1, thread const float& f2, thread float& hue)
{
    if (hue < 0.0)
    {
        hue += 1.0;
    }
    else
    {
        if (hue > 1.0)
        {
            hue -= 1.0;
        }
    }
    float res;
    if ((6.0 * hue) < 1.0)
    {
        res = f1 + (((f2 - f1) * 6.0) * hue);
    }
    else
    {
        if ((2.0 * hue) < 1.0)
        {
            res = f2;
        }
        else
        {
            if ((3.0 * hue) < 2.0)
            {
                res = f1 + (((f2 - f1) * (0.666666686534881591796875 - hue)) * 6.0);
            }
            else
            {
                res = f1;
            }
        }
    }
    return res;
}

static inline __attribute__((always_inline))
float3 HSLToRGB(thread const float3& hsl)
{
    float3 rgb;
    if (hsl.y == 0.0)
    {
        rgb = float3(hsl.z);
    }
    else
    {
        float f2;
        if (hsl.z < 0.5)
        {
            f2 = hsl.z * (1.0 + hsl.y);
        }
        else
        {
            f2 = (hsl.z + hsl.y) - (hsl.y * hsl.z);
        }
        float f1 = (2.0 * hsl.z) - f2;
        float param = f1;
        float param_1 = f2;
        float param_2 = hsl.x + 0.3333333432674407958984375;
        float _298 = HueToRGB(param, param_1, param_2);
        rgb.x = _298;
        float param_3 = f1;
        float param_4 = f2;
        float param_5 = hsl.x;
        float _307 = HueToRGB(param_3, param_4, param_5);
        rgb.y = _307;
        float param_6 = f1;
        float param_7 = f2;
        float param_8 = hsl.x - 0.3333333432674407958984375;
        float _317 = HueToRGB(param_6, param_7, param_8);
        rgb.z = _317;
    }
    return rgb;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _392 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    bool _398;
    if (true)
    {
        _398 = _392.u_alpha > 0.0;
    }
    else
    {
        _398 = true;
    }
    if (_398)
    {
        float3 param = albedo.xyz;
        float lightness = rgbLightness(param);
        float param_1 = albedo.x;
        float param_2 = _392.u_redBalance * 1.0;
        float _414 = colorBalance(param_1, param_2);
        albedo.x = _414;
        float param_3 = albedo.y;
        float param_4 = _392.u_greenBalance * 1.0;
        float _424 = colorBalance(param_3, param_4);
        albedo.y = _424;
        float param_5 = albedo.z;
        float param_6 = _392.u_blueBalance * 1.0;
        float _434 = colorBalance(param_5, param_6);
        albedo.z = _434;
        float3 param_7 = albedo.xyz;
        float3 newHSL = RGBToHSL(param_7);
        float3 param_8 = float3(newHSL.x, newHSL.y, lightness);
        float3 _448 = HSLToRGB(param_8);
        albedo.x = _448.x;
        albedo.y = _448.y;
        albedo.z = _448.z;
        float4 _457 = albedo;
        float3 _467 = mix(baseAlbedo.xyz, _457.xyz, (float3(_392.u_channelMultiplier) * 1.0) * _392.u_alpha);
        albedo.x = _467.x;
        albedo.y = _467.y;
        albedo.z = _467.z;
        float3 param_9 = baseAlbedo.xyz;
        float3 param_10 = albedo.xyz;
        float param_11 = (1.0 * albedo.w) * _392.u_alpha;
        float3 _488 = ApplyBlending(0, param_9, param_10, param_11);
        albedo.x = _488.x;
        albedo.y = _488.y;
        albedo.z = _488.z;
        float4 _495 = albedo;
        float3 _503 = powr(_495.xyz, float3(2.2000000476837158203125 / _392.u_displayGamma));
        albedo.x = _503.x;
        albedo.y = _503.y;
        albedo.z = _503.z;
    }
    out._fragColor = albedo;
    return out;
}

