#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_BlendAlpha;
    float3 g_TintColor;
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
        float _294 = HueToRGB(param, param_1, param_2);
        rgb.x = _294;
        float param_3 = f1;
        float param_4 = f2;
        float param_5 = hsl.x;
        float _303 = HueToRGB(param_3, param_4, param_5);
        rgb.y = _303;
        float param_6 = f1;
        float param_7 = f2;
        float param_8 = hsl.x - 0.3333333432674407958984375;
        float _313 = HueToRGB(param_6, param_7, param_8);
        rgb.z = _313;
    }
    return rgb;
}

static inline __attribute__((always_inline))
float3 BlendColor(thread const float3& base, thread const float3& blend)
{
    float3 param = blend;
    float3 blendHSL = RGBToHSL(param);
    float3 param_1 = base;
    float3 param_2 = float3(blendHSL.x, blendHSL.y, RGBToHSL(param_1).z);
    return HSLToRGB(param_2);
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float3 param = A;
    float3 param_1 = B;
    return mix(A, BlendColor(param, param_1), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _369 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = _369.g_BlendAlpha;
    float3 param = albedo.xyz;
    float3 param_1 = _369.g_TintColor;
    float param_2 = mask;
    float3 _385 = ApplyBlending(28, param, param_1, param_2);
    albedo.x = _385.x;
    albedo.y = _385.y;
    albedo.z = _385.z;
    out._fragColor = albedo;
    return out;
}

