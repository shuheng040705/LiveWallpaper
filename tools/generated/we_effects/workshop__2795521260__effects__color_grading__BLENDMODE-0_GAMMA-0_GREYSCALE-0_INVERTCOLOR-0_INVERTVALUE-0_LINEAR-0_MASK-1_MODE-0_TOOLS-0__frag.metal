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

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _56 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord).x;
    bool _51 = mask > 0.0;
    bool _62;
    if (_51)
    {
        _62 = _56.u_alpha > 0.0;
    }
    else
    {
        _62 = _51;
    }
    if (_62)
    {
        float4 _65 = albedo;
        float3 _72 = _65.xyz * (_56.u_brightness + 1.0);
        albedo.x = _72.x;
        albedo.y = _72.y;
        albedo.z = _72.z;
        float4 _81 = albedo;
        float3 _92 = ((_81.xyz - float3(0.5)) * (_56.u_contrast + 1.0)) + float3(0.5);
        albedo.x = _92.x;
        albedo.y = _92.y;
        albedo.z = _92.z;
        float4 _101 = albedo;
        float3 _113 = mix(baseAlbedo.xyz, _101.xyz, ((float3(_56.u_channelMultiplier) * 1.0) * mask) * _56.u_alpha);
        albedo.x = _113.x;
        albedo.y = _113.y;
        albedo.z = _113.z;
        float3 param = baseAlbedo.xyz;
        float3 param_1 = albedo.xyz;
        float param_2 = (mask * albedo.w) * _56.u_alpha;
        float3 _135 = ApplyBlending(0, param, param_1, param_2);
        albedo.x = _135.x;
        albedo.y = _135.y;
        albedo.z = _135.z;
        float4 _142 = albedo;
        float3 _145 = powr(_142.xyz, float3(1.0));
        albedo.x = _145.x;
        albedo.y = _145.y;
        albedo.z = _145.z;
    }
    out._fragColor = albedo;
    return out;
}

