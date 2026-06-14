#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float u_DirectionAngle;
    float u_Amount;
    float u_Feather;
    float u_Speed;
    float u_BlendAmount;
    float u_NoiseScale;
    float u_NoiseSpeed;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float v_ScaleXY [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float fixMask(thread const float& mask, thread const float& b)
{
    float is0 = step(0.0, b) * step(b, 0.0);
    float is1 = step(1.0, b) * step(b, 1.0);
    return mix(mask, b, is0 + is1);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _71 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float alpha = 1.0;
    float4 t0 = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 t1 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord);
    float2 uv = (in.v_TexCoord - float2(0.5)) * float2(in.v_ScaleXY, 1.0);
    float gradient = length(uv);
    float mask = 1.0 - smoothstep(fast::clamp(_71.u_BlendAmount, 0.0, 1.0) - (_71.u_Feather * 0.5), fast::clamp(_71.u_BlendAmount, 0.0, 1.0) + (_71.u_Feather * 0.5), gradient);
    float param = mask;
    float param_1 = _71.u_BlendAmount;
    mask = fixMask(param, param_1);
    out._fragColor = mix(t0, t1, float4(mask * alpha));
    return out;
}

