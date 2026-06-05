#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float u_direction;
    float u_scale;
    float u_speed;
    float u_delay;
    float u_width;
    float u_amount;
    float u_offset;
    float u_timeoffsetScale;
    float3 u_color;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, A + (A * B), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _104 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture3 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture3Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float offset = 0.0;
    mask *= g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float2 param = in.v_TexCoord.xy;
    float param_1 = (-_104.u_direction) + 1.57079637050628662109375;
    float2 shimmerCoord = rotateVec2(param, param_1) * _104.u_scale;
    shimmerCoord.x += (_104.u_offset + (_104.u_speed * (_104.g_Time + offset)));
    shimmerCoord.x = fast::clamp((fract(shimmerCoord.x / (_104.u_scale * _104.u_delay)) * _104.u_scale) * _104.u_delay, 0.0, 1.0);
    float3 shimmerColor = g_Texture3.sample(g_Texture3Smplr, fract(shimmerCoord)).xyz;
    float3 effectAlbedo = shimmerColor * _104.u_color;
    float3 param_2 = albedo.xyz;
    float3 param_3 = effectAlbedo;
    float param_4 = 1.0;
    effectAlbedo = ApplyBlending(32, param_2, param_3, param_4);
    float4 _178 = albedo;
    float3 _188 = mix(_178.xyz, effectAlbedo, (shimmerColor * mask) * _104.u_amount);
    albedo.x = _188.x;
    albedo.y = _188.y;
    albedo.z = _188.z;
    out._fragColor = albedo;
    return out;
}

