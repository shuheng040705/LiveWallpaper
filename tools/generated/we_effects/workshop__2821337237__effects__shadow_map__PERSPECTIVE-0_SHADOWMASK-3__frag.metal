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
float ShadowMaskRows(thread float2& uv)
{
    uv.x *= 0.5;
    uv.x -= floor(uv.x);
    if (uv.x < 0.0)
    {
        uv.y += 0.5;
    }
    float param = uv.y;
    float param_1 = 1.2999999523162841796875;
    return Grille(param, param_1);
}

static inline __attribute__((always_inline))
float3 ShadowMask(thread const float2& uv)
{
    float2 param = uv;
    float _132 = ShadowMaskColumns(param);
    float2 param_1 = uv;
    float _135 = ShadowMaskRows(param_1);
    return float3(_132 * _135);
}

static inline __attribute__((always_inline))
float hash(thread const float2& p)
{
    float3 p3 = fract(p.xyx * 0.103100001811981201171875);
    p3 += float3(dot(p3, p3.yzx + float3(33.3300018310546875)));
    return fract((p3.x + p3.y) * p3.z);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _154 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 baseAlbedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    if (_154.u_alpha > 0.0)
    {
        float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
        float2 perspCoord = in.v_PerspCoord.xy / float2(in.v_PerspCoord.z);
        float2 param = perspCoord;
        float4 _180 = albedo;
        float3 _182 = _180.xyz * ShadowMask(param);
        albedo.x = _182.x;
        albedo.y = _182.y;
        albedo.z = _182.z;
        float2 param_1 = round(perspCoord) + float2(_154.g_Time);
        float4 _203 = albedo;
        float3 _205 = _203.xyz * (1.0 - (hash(param_1) * _154.u_noise));
        albedo.x = _205.x;
        albedo.y = _205.y;
        albedo.z = _205.z;
        out._fragColor = albedo;
    }
    else
    {
        out._fragColor = baseAlbedo;
    }
    return out;
}

