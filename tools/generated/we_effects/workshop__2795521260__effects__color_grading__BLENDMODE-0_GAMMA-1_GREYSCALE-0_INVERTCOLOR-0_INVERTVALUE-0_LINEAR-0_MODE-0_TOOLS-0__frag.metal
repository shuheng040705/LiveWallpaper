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
    float u_brightness;
    float u_contrast;
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
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _46 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    bool _53;
    if (true)
    {
        _53 = _46.u_alpha > 0.0;
    }
    else
    {
        _53 = true;
    }
    if (_53)
    {
        float4 _56 = albedo;
        float3 _63 = _56.xyz * (_46.u_brightness + 1.0);
        albedo.x = _63.x;
        albedo.y = _63.y;
        albedo.z = _63.z;
        float4 _74 = albedo;
        float3 _85 = ((_74.xyz - float3(0.5)) * (_46.u_contrast + 1.0)) + float3(0.5);
        albedo.x = _85.x;
        albedo.y = _85.y;
        albedo.z = _85.z;
        float4 _94 = albedo;
        float3 _105 = mix(baseAlbedo.xyz, _94.xyz, ((float3(_46.u_channelMultiplier) * 1.0) * 1.0) * _46.u_alpha);
        albedo.x = _105.x;
        albedo.y = _105.y;
        albedo.z = _105.z;
        float3 param = baseAlbedo.xyz;
        float3 param_1 = albedo.xyz;
        float param_2 = (1.0 * albedo.w) * _46.u_alpha;
        float3 _126 = ApplyBlending(0, param, param_1, param_2);
        albedo.x = _126.x;
        albedo.y = _126.y;
        albedo.z = _126.z;
        float4 _133 = albedo;
        float3 _141 = powr(_133.xyz, float3(2.2000000476837158203125 / _46.u_displayGamma));
        albedo.x = _141.x;
        albedo.y = _141.y;
        albedo.z = _141.z;
    }
    out._fragColor = albedo;
    return out;
}

