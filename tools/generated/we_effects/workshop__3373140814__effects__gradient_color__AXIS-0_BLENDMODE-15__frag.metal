#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float3 u_Color1;
    packed_float3 u_Color2;
    float u_amount;
    float u_Speed;
    float u_Oscillate;
    float u_Opacity;
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
float3 rgb2hsv(thread const float3& RGB)
{
    float4 _75;
    if (RGB.y < RGB.z)
    {
        _75 = float4(RGB.zy, -1.0, 0.666666686534881591796875);
    }
    else
    {
        _75 = float4(RGB.yz, 0.0, -0.3333333432674407958984375);
    }
    float4 P = _75;
    float4 _100;
    if (RGB.x < P.x)
    {
        _100 = float4(P.xyw, RGB.x);
    }
    else
    {
        _100 = float4(RGB.x, P.yzx);
    }
    float4 Q = _100;
    float C = Q.x - fast::min(Q.w, Q.y);
    float H = abs(((Q.w - Q.y) / ((6.0 * C) + 1.0000000133514319600180897396058e-10)) + Q.z);
    float3 HCV = float3(H, C, Q.x);
    float S = HCV.y / (HCV.z + 1.0000000133514319600180897396058e-10);
    return float3(HCV.x, S, HCV.z);
}

static inline __attribute__((always_inline))
float3 hsv2rgb(thread const float3& c)
{
    float4 K = float4(1.0, 0.666666686534881591796875, 0.3333333432674407958984375, 3.0);
    float3 p = abs((fract(c.xxx + K.xyz) * 6.0) - K.www);
    return mix(K.xxx, fast::clamp(p - K.xxx, float3(0.0), float3(1.0)), float3(c.y)) * c.z;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _172;
    if (B.x < 0.5)
    {
        _172 = fast::max((A.x + (2.0 * B.x)) - 1.0, 0.0);
    }
    else
    {
        _172 = A.x + (2.0 * (B.x - 0.5));
    }
    float _196;
    if (B.y < 0.5)
    {
        _196 = fast::max((A.y + (2.0 * B.y)) - 1.0, 0.0);
    }
    else
    {
        _196 = A.y + (2.0 * (B.y - 0.5));
    }
    float _219;
    if (B.z < 0.5)
    {
        _219 = fast::max((A.z + (2.0 * B.z)) - 1.0, 0.0);
    }
    else
    {
        _219 = A.z + (2.0 * (B.z - 0.5));
    }
    return mix(A, float3(_172, _196, _219), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _254 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float timer = sin(_254.g_Time * _254.u_Oscillate);
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float3 color1 = _254.u_Color1;
    float3 color2 = float3(_254.u_Color2);
    float colorDistanceBlend = powr(in.v_TexCoord.x, _254.u_amount);
    colorDistanceBlend += timer;
    float3 resultColor = mix(color1, color2, float3(colorDistanceBlend));
    float3 param = resultColor;
    resultColor = rgb2hsv(param);
    resultColor.x = fract(resultColor.x + (_254.g_Time * _254.u_Speed));
    float3 param_1 = resultColor;
    resultColor = hsv2rgb(param_1);
    float3 finalColor = resultColor;
    float3 param_2 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_3 = finalColor;
    float param_4 = _254.u_Opacity * mask;
    finalColor = ApplyBlending(15, param_2, param_3, param_4);
    float alpha = scene.w;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

