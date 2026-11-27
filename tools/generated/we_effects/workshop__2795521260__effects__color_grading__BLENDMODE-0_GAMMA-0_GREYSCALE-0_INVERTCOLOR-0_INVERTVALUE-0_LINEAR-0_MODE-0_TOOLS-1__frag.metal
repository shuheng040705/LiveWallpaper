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
    float u_exposure;
    float u_blackLevel;
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
        if (_46.u_exposure != 0.0)
        {
            float4 _66 = albedo;
            float3 _68 = _66.xyz * powr(2.0, _46.u_exposure);
            albedo.x = _68.x;
            albedo.y = _68.y;
            albedo.z = _68.z;
        }
        float4 _84 = albedo;
        float3 _87 = _84.xyz - float3(_46.u_blackLevel / 10.0);
        albedo.x = _87.x;
        albedo.y = _87.y;
        albedo.z = _87.z;
        float4 _96 = albedo;
        float3 _108 = mix(baseAlbedo.xyz, _96.xyz, ((float3(_46.u_channelMultiplier) * 1.0) * 1.0) * _46.u_alpha);
        albedo.x = _108.x;
        albedo.y = _108.y;
        albedo.z = _108.z;
        float3 param = baseAlbedo.xyz;
        float3 param_1 = albedo.xyz;
        float param_2 = (1.0 * albedo.w) * _46.u_alpha;
        float3 _129 = ApplyBlending(0, param, param_1, param_2);
        albedo.x = _129.x;
        albedo.y = _129.y;
        albedo.z = _129.z;
        float4 _136 = albedo;
        float3 _139 = powr(_136.xyz, float3(1.0));
        albedo.x = _139.x;
        albedo.y = _139.y;
        albedo.z = _139.z;
    }
    out._fragColor = albedo;
    return out;
}

