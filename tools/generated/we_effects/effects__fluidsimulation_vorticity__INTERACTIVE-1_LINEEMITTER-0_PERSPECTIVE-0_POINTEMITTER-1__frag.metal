#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Frametime;
    float g_Time;
    float4 g_PointerState;
    float4 g_Texture0Resolution;
    float u_Curl;
    float2 m_EmitterPos0;
    float m_EmitterAngle0;
    float m_EmitterSize0;
    float m_EmitterSpeed0;
    float2 m_EmitterPos1;
    float m_EmitterAngle1;
    float m_EmitterSize1;
    float m_EmitterSpeed1;
    float2 m_EmitterPos2;
    float m_EmitterAngle2;
    float m_EmitterSize2;
    float m_EmitterSpeed2;
    float2 m_EmitterPos3;
    float m_EmitterAngle3;
    float m_EmitterSize3;
    float m_EmitterSpeed3;
    float2 m_LineEmitterPosA0;
    float2 m_LineEmitterPosB0;
    float m_LineEmitterAngle0;
    float m_LineEmitterSize0;
    float m_LineEmitterSpeed0;
    float2 m_LineEmitterPosA1;
    float2 m_LineEmitterPosB1;
    float m_LineEmitterAngle1;
    float m_LineEmitterSize1;
    float m_LineEmitterSpeed1;
    float2 m_LineEmitterPosA2;
    float2 m_LineEmitterPosB2;
    float m_LineEmitterAngle2;
    float m_LineEmitterSize2;
    float m_LineEmitterSpeed2;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_PointDelta [[user(locn0)]];
    float4 v_PointerUV [[user(locn1)]];
    float4 v_PointerUVLast [[user(locn2)]];
    float2 v_TexCoord [[user(locn3)]];
    float4 v_TexCoordLeftTop [[user(locn4)]];
    float4 v_TexCoordRightBottom [[user(locn6)]];
};

static inline __attribute__((always_inline))
float2 EmitterVelocity(thread const float2& texCoord, thread const float& aspect, thread const float2& position, thread const float& angle, thread const float& size, thread const float& speed)
{
    float2 delta = position - texCoord;
    float amt = step(length(delta), size) * speed;
    float2 emitterSpeed = float2(sin(angle), -cos(angle)) * amt;
    return emitterSpeed;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _47 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float dt = fast::min(0.0500000007450580596923828125, _47.g_Frametime);
    float2 vUv = in.v_TexCoord;
    float2 vL = in.v_TexCoordLeftTop.xy;
    float2 vR = in.v_TexCoordRightBottom.xy;
    float2 vT = in.v_TexCoordLeftTop.zw;
    float2 vB = in.v_TexCoordRightBottom.zw;
    float L = g_Texture1.sample(g_Texture1Smplr, vL).x;
    float R = g_Texture1.sample(g_Texture1Smplr, vR).x;
    float T = g_Texture1.sample(g_Texture1Smplr, vT).x;
    float B = g_Texture1.sample(g_Texture1Smplr, vB).x;
    float C = g_Texture1.sample(g_Texture1Smplr, vUv).x;
    float2 force = float2(abs(T) - abs(B), abs(R) - abs(L)) * 0.5;
    force /= float2(length(force) + 9.9999997473787516355514526367188e-05);
    force *= (_47.u_Curl * C);
    force.y *= (-1.0);
    float2 velocity = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord).xy;
    velocity += (force * dt);
    velocity = fast::min(fast::max(velocity, float2(-1000.0)), float2(1000.0));
    float2 emitterUV = in.v_TexCoord;
    float aspect = _47.g_Texture0Resolution.y / _47.g_Texture0Resolution.x;
    float2 param = emitterUV;
    float param_1 = aspect;
    float2 param_2 = _47.m_EmitterPos0;
    float param_3 = _47.m_EmitterAngle0;
    float param_4 = _47.m_EmitterSize0;
    float param_5 = _47.g_Frametime * _47.m_EmitterSpeed0;
    velocity += EmitterVelocity(param, param_1, param_2, param_3, param_4, param_5);
    float2 texSource = in.v_TexCoord;
    float2 unprojectedUVs = in.v_PointerUV.xy;
    float2 unprojectedUVsLast = in.v_PointerUVLast.xy;
    float rippleMask = 1.0;
    float2 lDelta = unprojectedUVs - unprojectedUVsLast;
    float2 texDelta = texSource - unprojectedUVsLast;
    float distLDelta = length(lDelta) + 9.9999997473787516355514526367188e-05;
    lDelta /= float2(distLDelta);
    float distOnLine = dot(lDelta, texDelta);
    float rayMask = fast::max(step(0.0, distOnLine) * step(distOnLine, distLDelta), step(distLDelta, 0.100000001490116119384765625));
    distOnLine = fast::clamp(distOnLine / distLDelta, 0.0, 1.0) * distLDelta;
    float2 posOnLine = unprojectedUVsLast + (lDelta * distOnLine);
    unprojectedUVs = (texSource - posOnLine) * float2(in.v_PointDelta.y, in.v_PointerUV.w);
    float pointerDist = length(unprojectedUVs);
    pointerDist = fast::clamp(1.0 - pointerDist, 0.0, 1.0);
    pointerDist *= (rayMask * rippleMask);
    float timeAmt = 1.0;
    float pointerMoveAmt = in.v_PointDelta.x;
    float inputStrength = (pointerDist * timeAmt) * (pointerMoveAmt + _47.g_PointerState.z);
    float2 impulseDir = lDelta;
    float2 colorAdd = float2(impulseDir.x * inputStrength, impulseDir.y * inputStrength);
    velocity += (colorAdd * 300.0);
    out._fragColor = float4(velocity, 0.0, 1.0);
    return out;
}

