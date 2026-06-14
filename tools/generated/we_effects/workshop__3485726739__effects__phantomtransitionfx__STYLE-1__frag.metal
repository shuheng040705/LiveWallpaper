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
    float2 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float fixMask(thread const float& mask, thread const float& b)
{
    float is0 = step(0.0, b) * step(b, 0.0);
    float is1 = step(1.0, b) * step(b, 1.0);
    return mix(mask, b, is0 + is1);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _58 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float alpha = 1.0;
    float4 t0 = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 t1 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord);
    float2 dir = float2(cos(_58.u_DirectionAngle), sin(_58.u_DirectionAngle));
    float maxProj = fast::max(fast::max(abs(dot(float2(0.5), dir)), abs(dot(float2(-0.5, 0.5), dir))), fast::max(abs(dot(float2(0.5, -0.5), dir)), abs(dot(float2(-0.5), dir))));
    float projection = (dot(in.v_TexCoord - float2(0.5), dir) + maxProj) / (2.0 * maxProj);
    float slidePos = (_58.u_BlendAmount * 1.10000002384185791015625) - 0.100000001490116119384765625;
    float mask = 1.0 - smoothstep(slidePos - (_58.u_Feather * 0.5), slidePos + (_58.u_Feather * 0.5), projection);
    float param = mask;
    float param_1 = _58.u_BlendAmount;
    mask = fixMask(param, param_1);
    out._fragColor = mix(t0, t1, float4(mask * alpha));
    return out;
}

