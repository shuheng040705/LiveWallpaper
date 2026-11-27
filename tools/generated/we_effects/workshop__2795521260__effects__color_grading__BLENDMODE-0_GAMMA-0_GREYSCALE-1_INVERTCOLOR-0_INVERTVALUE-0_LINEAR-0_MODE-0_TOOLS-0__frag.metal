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
float greyscale(thread const float3& color)
{
    return dot(color, float3(0.10999999940395355224609375, 0.589999973773956298828125, 0.300000011920928955078125));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _58 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    bool _65;
    if (true)
    {
        _65 = _58.u_alpha > 0.0;
    }
    else
    {
        _65 = true;
    }
    if (_65)
    {
        float3 param = albedo.xyz;
        float3 _72 = float3(greyscale(param));
        albedo.x = _72.x;
        albedo.y = _72.y;
        albedo.z = _72.z;
        float4 _83 = albedo;
        float3 _90 = _83.xyz * (_58.u_brightness + 1.0);
        albedo.x = _90.x;
        albedo.y = _90.y;
        albedo.z = _90.z;
        float4 _97 = albedo;
        float3 _108 = ((_97.xyz - float3(0.5)) * (_58.u_contrast + 1.0)) + float3(0.5);
        albedo.x = _108.x;
        albedo.y = _108.y;
        albedo.z = _108.z;
        float4 _117 = albedo;
        float3 _128 = mix(baseAlbedo.xyz, _117.xyz, ((float3(_58.u_channelMultiplier) * 1.0) * 1.0) * _58.u_alpha);
        albedo.x = _128.x;
        albedo.y = _128.y;
        albedo.z = _128.z;
        float3 param_1 = baseAlbedo.xyz;
        float3 param_2 = albedo.xyz;
        float param_3 = (1.0 * albedo.w) * _58.u_alpha;
        float3 _149 = ApplyBlending(0, param_1, param_2, param_3);
        albedo.x = _149.x;
        albedo.y = _149.y;
        albedo.z = _149.z;
        float4 _156 = albedo;
        float3 _159 = powr(_156.xyz, float3(1.0));
        albedo.x = _159.x;
        albedo.y = _159.y;
        albedo.z = _159.z;
    }
    out._fragColor = albedo;
    return out;
}

