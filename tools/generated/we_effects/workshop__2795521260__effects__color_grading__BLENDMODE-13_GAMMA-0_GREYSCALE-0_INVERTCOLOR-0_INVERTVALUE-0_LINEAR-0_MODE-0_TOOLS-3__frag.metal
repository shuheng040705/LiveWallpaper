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
float3 hue(thread const float3& color, constant _Globals& _260)
{
    float cosAngle = cos(radians(_260.u_hueShift));
    return ((color * cosAngle) + (cross(float3(0.57735002040863037109375), color) * sin(radians(_260.u_hueShift)))) + ((float3(0.57735002040863037109375) * dot(float3(0.57735002040863037109375), color)) * (1.0 - cosAngle));
}

static inline __attribute__((always_inline))
float3 rgb2hsv(thread const float3& RGB)
{
    float4 _81;
    if (RGB.y < RGB.z)
    {
        _81 = float4(RGB.zy, -1.0, 0.666666686534881591796875);
    }
    else
    {
        _81 = float4(RGB.yz, 0.0, -0.3333333432674407958984375);
    }
    float4 P = _81;
    float4 _106;
    if (RGB.x < P.x)
    {
        _106 = float4(P.xyw, RGB.x);
    }
    else
    {
        _106 = float4(RGB.x, P.yzx);
    }
    float4 Q = _106;
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
float3 chroma(thread float3& color, constant _Globals& _260)
{
    float3 param = color;
    color = rgb2hsv(param);
    color.y += _260.u_chroma;
    float3 param_1 = color;
    return hsv2rgb(param_1);
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    float _178;
    if (B.x < 0.5)
    {
        _178 = (2.0 * B.x) * A.x;
    }
    else
    {
        _178 = 1.0 - ((2.0 * (1.0 - B.x)) * (1.0 - A.x));
    }
    float _202;
    if (B.y < 0.5)
    {
        _202 = (2.0 * B.y) * A.y;
    }
    else
    {
        _202 = 1.0 - ((2.0 * (1.0 - B.y)) * (1.0 - A.y));
    }
    float _225;
    if (B.z < 0.5)
    {
        _225 = (2.0 * B.z) * A.z;
    }
    else
    {
        _225 = 1.0 - ((2.0 * (1.0 - B.z)) * (1.0 - A.z));
    }
    return mix(A, float3(_178, _202, _225), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _260 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    bool _323;
    if (true)
    {
        _323 = _260.u_alpha > 0.0;
    }
    else
    {
        _323 = true;
    }
    if (_323)
    {
        float4 _330 = albedo;
        float3 _332 = _330.xyz * float3(_260.u_colorFilter);
        albedo.x = _332.x;
        albedo.y = _332.y;
        albedo.z = _332.z;
        if (_260.u_hueShift != 0.0)
        {
            float3 param = albedo.xyz;
            float3 _347 = hue(param, _260);
            albedo.x = _347.x;
            albedo.y = _347.y;
            albedo.z = _347.z;
        }
        if (_260.u_chroma != 0.0)
        {
            float3 param_1 = albedo.xyz;
            float3 _362 = chroma(param_1, _260);
            albedo.x = _362.x;
            albedo.y = _362.y;
            albedo.z = _362.z;
        }
        float4 _371 = albedo;
        float3 _381 = mix(baseAlbedo.xyz, _371.xyz, ((float3(_260.u_channelMultiplier) * 1.0) * 1.0) * _260.u_alpha);
        albedo.x = _381.x;
        albedo.y = _381.y;
        albedo.z = _381.z;
        float3 param_2 = baseAlbedo.xyz;
        float3 param_3 = albedo.xyz;
        float param_4 = (1.0 * albedo.w) * _260.u_alpha;
        float3 _402 = ApplyBlending(13, param_2, param_3, param_4);
        albedo.x = _402.x;
        albedo.y = _402.y;
        albedo.z = _402.z;
        float4 _409 = albedo;
        float3 _412 = powr(_409.xyz, float3(1.0));
        albedo.x = _412.x;
        albedo.y = _412.y;
        albedo.z = _412.z;
    }
    out._fragColor = albedo;
    return out;
}

