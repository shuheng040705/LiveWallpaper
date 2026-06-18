#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
    float g_Time;
    float2 g_SpinCenter1;
    float g_WindDirection1;
    float g_WindDirection2;
    float g_TimeOffset1;
    float2 g_SpinCenter2;
    float g_WindDirection3;
    float g_TimeOffset2;
    float g_GlobalWindOffset;
    float g_GlobalTimeOffset;
    float g_Speed;
    float g_Inertia;
    float g_SigmentCount;
    float g_Exponent;
    float g_SmoothDistance;
    float g_DirectionalCompensation;
    float2 g_Friction;
    float g_NoiseSpeed;
    float g_NoiseAmount;
};

struct main0_out
{
    float2 v_Direction1 [[user(locn1)]];
    float2 v_EndpointDirection1 [[user(locn11)]];
    float v_EndpointLen1 [[user(locn21)]];
    float v_EndpointPosX1 [[user(locn31)]];
    float v_Len1 [[user(locn41)]];
    float v_MotionRadian1 [[user(locn51)]];
    float v_PosX1 [[user(locn61)]];
    float4 v_TexCoord [[user(locn82)]];
    float v_aspect [[user(locn83)]];
    float v_reciprocalAspect [[user(locn84)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float linearStep(thread const float& lower, thread const float& upper, thread const float& x)
{
    return fast::clamp((x - lower) / (upper - lower), 0.0, 1.0);
}

static inline __attribute__((always_inline))
float calcNoise(thread const float& time, constant _Globals& _50)
{
    float4 sines = fract(float4(1.0, -0.16161616146564483642578125, 0.008333300240337848663330078125, -0.00019840999448206275701522827148438) * ((_50.g_NoiseSpeed * time) / 6.283185482025146484375)) * 6.283185482025146484375;
    float4 csines = cos(sines);
    sines = sin(sines);
    float4 base = step(float4(0.0), csines);
    sines = (sines * 0.4979999959468841552734375) + float4(0.5);
    sines = mix(float4(1.0) - powr(float4(1.0) - sines, float4(_50.g_Friction.x)), powr(sines, float4(_50.g_Friction.y)), base);
    return (dot(float4(0.5), sines) - 1.0) * _50.g_NoiseAmount;
}

static inline __attribute__((always_inline))
void preCalcNode(thread const int& nodeNum, thread const float2& texCoord, thread const float& aspectFactor, thread const float& motitionOffset, thread const float2& endpointNodeCenter, thread float2& thisNodeCenter, thread float2& nextNodeCenter, thread const float& thisWindDirection, thread const float& nextWindDirection, thread const float& inertia, thread const float& thisOffset, thread const float& nextOffset, thread float2& thisDirection, thread float2& endpointDirection, thread float& thisLength, thread float& endpointLength, thread float& thisPosX, thread float& endpointPosX, thread float& thisMotionRadian, constant _Globals& _50)
{
    thisNodeCenter.x *= aspectFactor;
    nextNodeCenter.x *= aspectFactor;
    float2 nodeVec = thisNodeCenter - nextNodeCenter;
    float2 eNodeVec = endpointNodeCenter - nextNodeCenter;
    thisDirection = fast::normalize(nodeVec);
    endpointDirection = mix(fast::normalize(eNodeVec), thisDirection, float2(_50.g_DirectionalCompensation));
    thisLength = dot(nodeVec, thisDirection);
    endpointLength = mix(thisLength, dot(eNodeVec, endpointDirection), _50.g_SmoothDistance);
    float2 relativeTexCoord = texCoord - nextNodeCenter;
    endpointPosX = dot(relativeTexCoord, endpointDirection);
    thisPosX = dot(relativeTexCoord, endpointDirection);
    float thisMotionTime = _50.g_GlobalTimeOffset + (_50.g_Time * _50.g_Speed);
    float prevMotionTime = thisMotionTime;
    float param = 2.0;
    float param_1 = 2.0;
    float param_2 = float(nodeNum);
    thisMotionTime += (motitionOffset * linearStep(param, param_1, param_2));
    float param_3 = 2.0;
    float param_4 = 2.0;
    float param_5 = float(nodeNum + 1);
    prevMotionTime += (motitionOffset * linearStep(param_3, param_4, param_5));
    thisMotionRadian = sin(thisMotionTime * 6.283185482025146484375);
    float prevMotionRadian = sin(prevMotionTime * 6.283185482025146484375) * inertia;
    thisMotionRadian += (sin(thisWindDirection + 1.57079637050628662109375) + sin(_50.g_GlobalWindOffset));
    prevMotionRadian += sin(nextWindDirection + 1.57079637050628662109375);
    prevMotionRadian *= step(0.5, float(nodeNum));
    float param_6 = thisMotionTime;
    thisMotionRadian += calcNoise(param_6, _50);
    float param_7 = prevMotionTime;
    prevMotionRadian += calcNoise(param_7, _50);
    thisMotionRadian -= prevMotionRadian;
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _50 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _50.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_aspect = _50.g_Texture0Resolution.z / _50.g_Texture0Resolution.w;
    float4 _286 = out.v_TexCoord;
    float2 _288 = _286.xz * out.v_aspect;
    out.v_TexCoord.x = _288.x;
    out.v_TexCoord.z = _288.y;
    out.v_reciprocalAspect = 1.0 / out.v_aspect;
    float2 endpointSpinCenter = _50.g_SpinCenter1;
    endpointSpinCenter.x *= out.v_aspect;
    float motitionOffset = _50.g_Inertia * _50.g_SigmentCount;
    int param = 2;
    float2 param_1 = out.v_TexCoord.zw;
    float param_2 = out.v_aspect;
    float param_3 = motitionOffset;
    float2 param_4 = endpointSpinCenter;
    float2 param_5 = _50.g_SpinCenter1;
    float2 param_6 = _50.g_SpinCenter2;
    float param_7 = _50.g_WindDirection2;
    float param_8 = _50.g_WindDirection3;
    float param_9 = _50.g_Inertia;
    float param_10 = _50.g_TimeOffset1;
    float param_11 = _50.g_TimeOffset2;
    float2 param_12;
    float2 param_13;
    float param_14;
    float param_15;
    float param_16;
    float param_17;
    float param_18;
    preCalcNode(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17, param_18, _50);
    out.v_Direction1 = param_12;
    out.v_EndpointDirection1 = param_13;
    out.v_Len1 = param_14;
    out.v_EndpointLen1 = param_15;
    out.v_PosX1 = param_16;
    out.v_EndpointPosX1 = param_17;
    out.v_MotionRadian1 = param_18;
    return out;
}

