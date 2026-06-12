#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_noise;
    float u_vignette;
    float2 u_borders;
    float u_alpha;
    float g_Time;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float3 v_PerspCoord [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float Grille(thread const float& x, thread const float& offset)
{
    return smoothstep(0.0, 1.0, sin(x * 6.283185482025146484375) + offset);
}

static inline __attribute__((always_inline))
float ShadowMaskColumns(thread float2& uv)
{
    uv.y *= 0.5;
    uv.y -= floor(uv.y);
    if (uv.y < 0.0)
    {
        uv.x += 0.5;
    }
    float param = uv.x;
    float param_1 = 1.2999999523162841796875;
    return Grille(param, param_1);
}

static inline __attribute__((always_inline))
float3 ShadowMask(thread const float2& uv)
{
    float2 param = uv;
    float _102 = ShadowMaskColumns(param);
    return float3(_102);
}

static inline __attribute__((always_inline))
float hash(thread const float2& p)
{
    float3 p3 = fract(p.xyx * 0.103100001811981201171875);
    p3 += float3(dot(p3, p3.yzx + float3(33.3300018310546875)));
    return fract((p3.x + p3.y) * p3.z);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _120 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 baseAlbedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    if (_120.u_alpha > 0.0)
    {
        float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
        float2 perspCoord = in.v_PerspCoord.xy / float2(in.v_PerspCoord.z);
        float2 param = perspCoord;
        float4 _146 = albedo;
        float3 _148 = _146.xyz * ShadowMask(param);
        albedo.x = _148.x;
        albedo.y = _148.y;
        albedo.z = _148.z;
        float2 param_1 = round(perspCoord) + float2(_120.g_Time);
        float4 _169 = albedo;
        float3 _171 = _169.xyz * (1.0 - (hash(param_1) * _120.u_noise));
        albedo.x = _171.x;
        albedo.y = _171.y;
        albedo.z = _171.z;
        out._fragColor = albedo;
    }
    else
    {
        out._fragColor = baseAlbedo;
    }
    return out;
}

