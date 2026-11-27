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
    return mix(A, float3(1.0 - ((1.0 - A.x) * (1.0 - B.x)), 1.0 - ((1.0 - A.y) * (1.0 - B.y)), 1.0 - ((1.0 - A.z) * (1.0 - B.z))), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _81 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    bool _88;
    if (true)
    {
        _88 = _81.u_alpha > 0.0;
    }
    else
    {
        _88 = true;
    }
    if (_88)
    {
        float4 _91 = albedo;
        float3 _97 = _91.xyz * (_81.u_brightness + 1.0);
        albedo.x = _97.x;
        albedo.y = _97.y;
        albedo.z = _97.z;
        float4 _104 = albedo;
        float3 _115 = ((_104.xyz - float3(0.5)) * (_81.u_contrast + 1.0)) + float3(0.5);
        albedo.x = _115.x;
        albedo.y = _115.y;
        albedo.z = _115.z;
        float4 _124 = albedo;
        float3 _135 = mix(baseAlbedo.xyz, _124.xyz, ((float3(_81.u_channelMultiplier) * 1.0) * 1.0) * _81.u_alpha);
        albedo.x = _135.x;
        albedo.y = _135.y;
        albedo.z = _135.z;
        float3 param = baseAlbedo.xyz;
        float3 param_1 = albedo.xyz;
        float param_2 = (1.0 * albedo.w) * _81.u_alpha;
        float3 _157 = ApplyBlending(7, param, param_1, param_2);
        albedo.x = _157.x;
        albedo.y = _157.y;
        albedo.z = _157.z;
        float4 _164 = albedo;
        float3 _167 = powr(_164.xyz, float3(1.0));
        albedo.x = _167.x;
        albedo.y = _167.y;
        albedo.z = _167.z;
    }
    out._fragColor = albedo;
    return out;
}

