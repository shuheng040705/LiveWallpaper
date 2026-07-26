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
    float u_luminance;
    float u_saturation;
    float u_vibrance;
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
float3 luminance(thread float3& color, thread const float& luma, constant _Globals& _62)
{
    color /= float3(luma);
    color *= (luma + _62.u_luminance);
    return color;
}

static inline __attribute__((always_inline))
float3 vibrance(thread const float3& color, thread const float& luma, constant _Globals& _62)
{
    float color_saturation = fast::max(color.x, fast::max(color.y, color.z)) - fast::min(color.x, fast::min(color.y, color.z));
    return mix(float3(luma), color, float3(1.0 + (_62.u_vibrance * (1.0 - (sign(_62.u_vibrance) * color_saturation)))));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _62 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    bool _117;
    if (true)
    {
        _117 = _62.u_alpha > 0.0;
    }
    else
    {
        _117 = true;
    }
    if (_117)
    {
        float luma = dot(albedo.xyz, float3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
        if (_62.u_luminance != 0.0)
        {
            float3 param = albedo.xyz;
            float param_1 = luma;
            float3 _138 = luminance(param, param_1, _62);
            albedo.x = _138.x;
            albedo.y = _138.y;
            albedo.z = _138.z;
        }
        if (_62.u_saturation != 0.0)
        {
            float4 _153 = albedo;
            float3 _159 = mix(float3(luma), _153.xyz, float3(_62.u_saturation + 1.0));
            albedo.x = _159.x;
            albedo.y = _159.y;
            albedo.z = _159.z;
        }
        if (_62.u_vibrance != 0.0)
        {
            float3 param_2 = albedo.xyz;
            float param_3 = luma;
            float3 _176 = vibrance(param_2, param_3, _62);
            albedo.x = _176.x;
            albedo.y = _176.y;
            albedo.z = _176.z;
        }
        float4 _185 = albedo;
        float3 _196 = mix(baseAlbedo.xyz, _185.xyz, ((float3(_62.u_channelMultiplier) * 1.0) * 1.0) * _62.u_alpha);
        albedo.x = _196.x;
        albedo.y = _196.y;
        albedo.z = _196.z;
        float3 param_4 = baseAlbedo.xyz;
        float3 param_5 = albedo.xyz;
        float param_6 = (1.0 * albedo.w) * _62.u_alpha;
        float3 _217 = ApplyBlending(0, param_4, param_5, param_6);
        albedo.x = _217.x;
        albedo.y = _217.y;
        albedo.z = _217.z;
        float4 _224 = albedo;
        float3 _227 = powr(_224.xyz, float3(1.0));
        albedo.x = _227.x;
        albedo.y = _227.y;
        albedo.z = _227.z;
    }
    out._fragColor = albedo;
    return out;
}

