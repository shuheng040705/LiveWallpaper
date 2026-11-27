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

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _68 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord).x;
    bool _63 = mask > 0.0;
    bool _74;
    if (_63)
    {
        _74 = _68.u_alpha > 0.0;
    }
    else
    {
        _74 = _63;
    }
    if (_74)
    {
        float3 param = albedo.xyz;
        float3 _81 = float3(greyscale(param));
        albedo.x = _81.x;
        albedo.y = _81.y;
        albedo.z = _81.z;
        float4 _90 = albedo;
        float3 _97 = _90.xyz * (_68.u_brightness + 1.0);
        albedo.x = _97.x;
        albedo.y = _97.y;
        albedo.z = _97.z;
        float4 _104 = albedo;
        float3 _115 = ((_104.xyz - float3(0.5)) * (_68.u_contrast + 1.0)) + float3(0.5);
        albedo.x = _115.x;
        albedo.y = _115.y;
        albedo.z = _115.z;
        float4 _124 = albedo;
        float3 _136 = mix(baseAlbedo.xyz, _124.xyz, ((float3(_68.u_channelMultiplier) * 1.0) * mask) * _68.u_alpha);
        albedo.x = _136.x;
        albedo.y = _136.y;
        albedo.z = _136.z;
        float3 param_1 = baseAlbedo.xyz;
        float3 param_2 = albedo.xyz;
        float param_3 = (mask * albedo.w) * _68.u_alpha;
        float3 _158 = ApplyBlending(0, param_1, param_2, param_3);
        albedo.x = _158.x;
        albedo.y = _158.y;
        albedo.z = _158.z;
        float4 _165 = albedo;
        float3 _168 = powr(_165.xyz, float3(1.0));
        albedo.x = _168.x;
        albedo.y = _168.y;
        albedo.z = _168.z;
    }
    out._fragColor = albedo;
    return out;
}

