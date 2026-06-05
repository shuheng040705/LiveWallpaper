#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Frametime;
    float4 g_Texture0Resolution;
    float u_Dissipation;
    float u_Viscosity;
    float m_Dissipation;
    float u_Lifetime;
    float u_Saturation;
    float u_ConstantVelocityAngle;
    float u_ConstantVelocityStrength;
    float2 m_EmitterPos0;
    float m_EmitterSize0;
    float3 m_EmitterColor0;
    float2 m_EmitterPos1;
    float m_EmitterSize1;
    float3 m_EmitterColor1;
    float2 m_EmitterPos2;
    float m_EmitterSize2;
    float3 m_EmitterColor2;
    float2 m_EmitterPos3;
    float m_EmitterSize3;
    float3 m_EmitterColor3;
    float2 m_LineEmitterPosA0;
    float2 m_LineEmitterPosB0;
    float m_LineEmitterSize0;
    float3 m_LineEmitterColor0;
    float2 m_LineEmitterPosA1;
    float2 m_LineEmitterPosB1;
    float m_LineEmitterSize1;
    float3 m_LineEmitterColor1;
    float2 m_LineEmitterPosA2;
    float2 m_LineEmitterPosB2;
    float m_LineEmitterSize2;
    float3 m_LineEmitterColor2;
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
float4 AddEmitterColor(thread const float2& texCoord, thread const float& amt, thread const float4& currentColor, thread const float3& emitterColor)
{
    return fast::min(currentColor + float4(amt), float4(1.0));
}

static inline __attribute__((always_inline))
float4 EmitterColor(thread const float2& texCoord, thread const float& aspect, thread const float4& currentColor, thread const float2& position, thread const float& size, thread const float3& emitterColor)
{
    float2 delta = position - texCoord;
    delta.y *= aspect;
    float amt = smoothstep(size, 0.0, length(delta));
    float2 param = texCoord;
    float param_1 = amt;
    float4 param_2 = currentColor;
    float3 param_3 = emitterColor;
    return AddEmitterColor(param, param_1, param_2, param_3);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _75 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 vUv = in.v_TexCoord;
    float2 texelSize = float2(1.0) / _75.g_Texture0Resolution.xy;
    float dt = fast::min(0.0500000007450580596923828125, _75.g_Frametime);
    float2 coord = vUv - ((g_Texture0.sample(g_Texture0Smplr, vUv).xy * dt) * texelSize);
    float4 result = g_Texture1.sample(g_Texture1Smplr, coord);
    float decayFactor = _75.u_Dissipation;
    float boundaryMask = ((step(0.0, coord.x) * step(coord.x, 1.0)) * step(0.0, coord.y)) * step(coord.y, 1.0);
    float decay = 1.0 + ((decayFactor * _75.m_Dissipation) * dt);
    float lowPass = step(length(result.xyz), _75.u_Lifetime) * 0.5;
    result *= boundaryMask;
    out._fragColor = result / float4(decay + lowPass);
    float aspect = _75.g_Texture0Resolution.y / _75.g_Texture0Resolution.x;
    float2 emitterUV = in.v_TexCoord;
    float2 param = emitterUV;
    float param_1 = aspect;
    float4 param_2 = out._fragColor;
    float2 param_3 = _75.m_EmitterPos0;
    float param_4 = _75.m_EmitterSize0;
    float3 param_5 = _75.m_EmitterColor0;
    out._fragColor = EmitterColor(param, param_1, param_2, param_3, param_4, param_5);
    return out;
}

