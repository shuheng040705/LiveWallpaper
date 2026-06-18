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
    float2 g_SpinCenter3;
    float g_WindDirection4;
    float g_TimeOffset3;
    float2 g_SpinCenter4;
    float g_WindDirection5;
    float g_TimeOffset4;
    float2 g_SpinCenter5;
    float g_WindDirection6;
    float g_TimeOffset5;
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
    float2 v_AspectedRootNodeCenter [[user(locn0)]];
    float2 v_Direction1 [[user(locn1)]];
    float2 v_Direction2 [[user(locn3)]];
    float2 v_Direction3 [[user(locn4)]];
    float2 v_Direction4 [[user(locn5)]];
    float v_EndpointLen1 [[user(locn21)]];
    float v_EndpointLen2 [[user(locn23)]];
    float v_EndpointLen3 [[user(locn24)]];
    float v_EndpointLen4 [[user(locn25)]];
    float v_Len1 [[user(locn41)]];
    float v_Len2 [[user(locn43)]];
    float v_Len3 [[user(locn44)]];
    float v_Len4 [[user(locn45)]];
    float v_MotionRadian1 [[user(locn51)]];
    float v_MotionRadian2 [[user(locn53)]];
    float v_MotionRadian3 [[user(locn54)]];
    float v_MotionRadian4 [[user(locn55)]];
    float v_PosX1 [[user(locn61)]];
    float v_PosX2 [[user(locn63)]];
    float v_PosX3 [[user(locn64)]];
    float v_PosX4 [[user(locn65)]];
    float v_StartpointLen1 [[user(locn72)]];
    float v_StartpointLen2 [[user(locn74)]];
    float v_StartpointLen3 [[user(locn75)]];
    float v_StartpointLen4 [[user(locn76)]];
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
void preCalcNode(thread const int& nodeNum, thread const float2& texCoord, thread const float& aspectFactor, thread const float& motitionOffset, thread const float2& aspectedRootNodeCenter, thread const float2& endpointNodeCenter, thread float2& thisNodeCenter, thread float2& nextNodeCenter, thread const float& thisWindDirection, thread const float& nextWindDirection, thread const float& inertia, thread const float& thisOffset, thread const float& nextOffset, thread float2& thisDirection, thread float& startpointLength, thread float& thisLength, thread float& endpointLength, thread float& thisPosX, thread float& thisMotionRadian, constant _Globals& _50)
{
    thisNodeCenter.x *= aspectFactor;
    nextNodeCenter.x *= aspectFactor;
    float2 nodeVec = thisNodeCenter - nextNodeCenter;
    float2 eNodeVec = endpointNodeCenter - nextNodeCenter;
    thisDirection = fast::normalize(nodeVec);
    float2 endpointDirection = mix(fast::normalize(eNodeVec), thisDirection, float2(_50.g_DirectionalCompensation));
    float2 relativeTexCoord = texCoord - nextNodeCenter;
    thisPosX = dot(relativeTexCoord, endpointDirection);
    thisLength = dot(nodeVec, thisDirection);
    endpointLength = mix(thisLength, dot(eNodeVec, endpointDirection), _50.g_SmoothDistance);
    startpointLength = distance(nextNodeCenter, aspectedRootNodeCenter);
    float thisMotionTime = _50.g_GlobalTimeOffset + (_50.g_Time * _50.g_Speed);
    float prevMotionTime = thisMotionTime;
    float param = 2.0;
    float param_1 = 5.0;
    float param_2 = float(nodeNum);
    thisMotionTime += (motitionOffset * linearStep(param, param_1, param_2));
    float param_3 = 2.0;
    float param_4 = 5.0;
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
    float4 _288 = out.v_TexCoord;
    float2 _290 = _288.xz * out.v_aspect;
    out.v_TexCoord.x = _290.x;
    out.v_TexCoord.z = _290.y;
    out.v_reciprocalAspect = 1.0 / out.v_aspect;
    out.v_AspectedRootNodeCenter = _50.g_SpinCenter5 * out.v_aspect;
    float2 endpointSpinCenter = _50.g_SpinCenter1;
    endpointSpinCenter.x *= out.v_aspect;
    float motitionOffset = _50.g_Inertia * _50.g_SigmentCount;
    int param = 2;
    float2 param_1 = out.v_TexCoord.zw;
    float param_2 = out.v_aspect;
    float param_3 = motitionOffset;
    float2 param_4 = out.v_AspectedRootNodeCenter;
    float2 param_5 = endpointSpinCenter;
    float2 param_6 = _50.g_SpinCenter1;
    float2 param_7 = _50.g_SpinCenter2;
    float param_8 = _50.g_WindDirection2;
    float param_9 = _50.g_WindDirection3;
    float param_10 = _50.g_Inertia;
    float param_11 = _50.g_TimeOffset1;
    float param_12 = _50.g_TimeOffset2;
    float2 param_13;
    float param_14;
    float param_15;
    float param_16;
    float param_17;
    float param_18;
    preCalcNode(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17, param_18, _50);
    out.v_Direction1 = param_13;
    out.v_StartpointLen1 = param_14;
    out.v_Len1 = param_15;
    out.v_EndpointLen1 = param_16;
    out.v_PosX1 = param_17;
    out.v_MotionRadian1 = param_18;
    int param_19 = 3;
    float2 param_20 = out.v_TexCoord.zw;
    float param_21 = out.v_aspect;
    float param_22 = motitionOffset;
    float2 param_23 = out.v_AspectedRootNodeCenter;
    float2 param_24 = endpointSpinCenter;
    float2 param_25 = _50.g_SpinCenter2;
    float2 param_26 = _50.g_SpinCenter3;
    float param_27 = _50.g_WindDirection3;
    float param_28 = _50.g_WindDirection4;
    float param_29 = _50.g_Inertia;
    float param_30 = _50.g_TimeOffset2;
    float param_31 = _50.g_TimeOffset3;
    float2 param_32;
    float param_33;
    float param_34;
    float param_35;
    float param_36;
    float param_37;
    preCalcNode(param_19, param_20, param_21, param_22, param_23, param_24, param_25, param_26, param_27, param_28, param_29, param_30, param_31, param_32, param_33, param_34, param_35, param_36, param_37, _50);
    out.v_Direction2 = param_32;
    out.v_StartpointLen2 = param_33;
    out.v_Len2 = param_34;
    out.v_EndpointLen2 = param_35;
    out.v_PosX2 = param_36;
    out.v_MotionRadian2 = param_37;
    int param_38 = 4;
    float2 param_39 = out.v_TexCoord.zw;
    float param_40 = out.v_aspect;
    float param_41 = motitionOffset;
    float2 param_42 = out.v_AspectedRootNodeCenter;
    float2 param_43 = endpointSpinCenter;
    float2 param_44 = _50.g_SpinCenter3;
    float2 param_45 = _50.g_SpinCenter4;
    float param_46 = _50.g_WindDirection4;
    float param_47 = _50.g_WindDirection5;
    float param_48 = _50.g_Inertia;
    float param_49 = _50.g_TimeOffset3;
    float param_50 = _50.g_TimeOffset4;
    float2 param_51;
    float param_52;
    float param_53;
    float param_54;
    float param_55;
    float param_56;
    preCalcNode(param_38, param_39, param_40, param_41, param_42, param_43, param_44, param_45, param_46, param_47, param_48, param_49, param_50, param_51, param_52, param_53, param_54, param_55, param_56, _50);
    out.v_Direction3 = param_51;
    out.v_StartpointLen3 = param_52;
    out.v_Len3 = param_53;
    out.v_EndpointLen3 = param_54;
    out.v_PosX3 = param_55;
    out.v_MotionRadian3 = param_56;
    int param_57 = 5;
    float2 param_58 = out.v_TexCoord.zw;
    float param_59 = out.v_aspect;
    float param_60 = motitionOffset;
    float2 param_61 = out.v_AspectedRootNodeCenter;
    float2 param_62 = endpointSpinCenter;
    float2 param_63 = _50.g_SpinCenter4;
    float2 param_64 = _50.g_SpinCenter5;
    float param_65 = _50.g_WindDirection5;
    float param_66 = _50.g_WindDirection6;
    float param_67 = _50.g_Inertia;
    float param_68 = _50.g_TimeOffset4;
    float param_69 = _50.g_TimeOffset5;
    float2 param_70;
    float param_71;
    float param_72;
    float param_73;
    float param_74;
    float param_75;
    preCalcNode(param_57, param_58, param_59, param_60, param_61, param_62, param_63, param_64, param_65, param_66, param_67, param_68, param_69, param_70, param_71, param_72, param_73, param_74, param_75, _50);
    out.v_Direction4 = param_70;
    out.v_StartpointLen4 = param_71;
    out.v_Len4 = param_72;
    out.v_EndpointLen4 = param_73;
    out.v_PosX4 = param_74;
    out.v_MotionRadian4 = param_75;
    return out;
}

