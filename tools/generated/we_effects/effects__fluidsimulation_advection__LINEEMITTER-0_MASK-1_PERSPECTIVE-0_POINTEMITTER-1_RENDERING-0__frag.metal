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
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _19 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 vUv = in.v_TexCoord;
    float2 texelSize = float2(1.0) / _19.g_Texture0Resolution.xy;
    float dt = fast::min(0.0500000007450580596923828125, _19.g_Frametime);
    float2 coord = vUv - ((g_Texture0.sample(g_Texture0Smplr, vUv).xy * dt) * texelSize);
    float4 result = g_Texture1.sample(g_Texture1Smplr, coord);
    float decayFactor = _19.u_Viscosity;
    float decay = 1.0 + ((decayFactor * _19.m_Dissipation) * dt);
    float lowPass = step(length(result.xyz), _19.u_Lifetime) * 0.5;
    out._fragColor = result / float4(decay + lowPass);
    float aspect = _19.g_Texture0Resolution.y / _19.g_Texture0Resolution.x;
    float2 constantSpeed = float2(sin(_19.u_ConstantVelocityAngle), -cos(_19.u_ConstantVelocityAngle)) * _19.u_ConstantVelocityStrength;
    constantSpeed.y *= aspect;
    float4 _120 = out._fragColor;
    float2 _122 = _120.xy + (constantSpeed * _19.g_Frametime);
    out._fragColor.x = _122.x;
    out._fragColor.y = _122.y;
    return out;
}

