#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Implementation of the GLSL radians() function
template<typename T>
inline T radians(T d)
{
    return d * T(0.01745329251);
}

struct _Globals
{
    float u_alpha;
    float u_displayInitGamma;
    float u_displayGamma;
    char _m3_pad[4];
    packed_float3 u_channelMultiplier;
    float u_hueShift;
    float u_chroma;
    char _m6_pad[12];
    packed_float3 u_colorFilter;
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
float greyscale(thread const float3& color)
{
    return dot(color, float3(0.10999999940395355224609375, 0.589999973773956298828125, 0.300000011920928955078125));
}

static inline __attribute__((always_inline))
float3 hue(thread const float3& color, constant _Globals& _272)
{
    float cosAngle = cos(radians(_272.u_hueShift));
    return ((color * cosAngle) + (cross(float3(0.57735002040863037109375), color) * sin(radians(_272.u_hueShift)))) + ((float3(0.57735002040863037109375) * dot(float3(0.57735002040863037109375), color)) * (1.0 - cosAngle));
}

static inline __attribute__((always_inline))
float3 rgb2hsv(thread const float3& RGB)
{
    float4 _85;
    if (RGB.y < RGB.z)
    {
        _85 = float4(RGB.zy, -1.0, 0.666666686534881591796875);
    }
    else
    {
        _85 = float4(RGB.yz, 0.0, -0.3333333432674407958984375);
    }
    float4 P = _85;
    float4 _110;
    if (RGB.x < P.x)
    {
        _110 = float4(P.xyw, RGB.x);
    }
    else
    {
        _110 = float4(RGB.x, P.yzx);
    }
    float4 Q = _110;
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
float3 chroma(thread float3& color, constant _Globals& _272)
{
    float3 param = color;
    color = rgb2hsv(param);
    color.y += _272.u_chroma;
    float3 param_1 = color;
    return hsv2rgb(param_1);
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _190;
    if (B.x < 0.5)
    {
        _190 = (2.0 * B.x) * A.x;
    }
    else
    {
        _190 = 1.0 - ((2.0 * (1.0 - B.x)) * (1.0 - A.x));
    }
    float _214;
    if (B.y < 0.5)
    {
        _214 = (2.0 * B.y) * A.y;
    }
    else
    {
        _214 = 1.0 - ((2.0 * (1.0 - B.y)) * (1.0 - A.y));
    }
    float _237;
    if (B.z < 0.5)
    {
        _237 = (2.0 * B.z) * A.z;
    }
    else
    {
        _237 = 1.0 - ((2.0 * (1.0 - B.z)) * (1.0 - A.z));
    }
    return mix(A, float3(_190, _214, _237), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _272 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    bool _335;
    if (true)
    {
        _335 = _272.u_alpha > 0.0;
    }
    else
    {
        _335 = true;
    }
    if (_335)
    {
        float3 param = albedo.xyz;
        float3 _342 = float3(greyscale(param));
        albedo.x = _342.x;
        albedo.y = _342.y;
        albedo.z = _342.z;
        float4 _353 = albedo;
        float3 _355 = _353.xyz * float3(_272.u_colorFilter);
        albedo.x = _355.x;
        albedo.y = _355.y;
        albedo.z = _355.z;
        if (_272.u_hueShift != 0.0)
        {
            float3 param_1 = albedo.xyz;
            float3 _370 = hue(param_1, _272);
            albedo.x = _370.x;
            albedo.y = _370.y;
            albedo.z = _370.z;
        }
        if (_272.u_chroma != 0.0)
        {
            float3 param_2 = albedo.xyz;
            float3 _385 = chroma(param_2, _272);
            albedo.x = _385.x;
            albedo.y = _385.y;
            albedo.z = _385.z;
        }
        float4 _394 = albedo;
        float3 _404 = mix(baseAlbedo.xyz, _394.xyz, ((float3(_272.u_channelMultiplier) * 1.0) * 1.0) * _272.u_alpha);
        albedo.x = _404.x;
        albedo.y = _404.y;
        albedo.z = _404.z;
        float3 param_3 = baseAlbedo.xyz;
        float3 param_4 = albedo.xyz;
        float param_5 = (1.0 * albedo.w) * _272.u_alpha;
        float3 _425 = ApplyBlending(13, param_3, param_4, param_5);
        albedo.x = _425.x;
        albedo.y = _425.y;
        albedo.z = _425.z;
        float4 _432 = albedo;
        float3 _435 = powr(_432.xyz, float3(1.0));
        albedo.x = _435.x;
        albedo.y = _435.y;
        albedo.z = _435.z;
    }
    out._fragColor = albedo;
    return out;
}

