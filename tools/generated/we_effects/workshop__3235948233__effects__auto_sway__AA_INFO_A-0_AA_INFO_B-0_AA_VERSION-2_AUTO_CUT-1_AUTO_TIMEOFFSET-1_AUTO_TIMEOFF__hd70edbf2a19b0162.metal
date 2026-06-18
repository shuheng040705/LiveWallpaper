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
};

struct main0_out
{
    float2 v_Direction1 [[user(locn1)]];
    float2 v_Direction2 [[user(locn3)]];
    float2 v_Direction3 [[user(locn4)]];
    float2 v_Direction4 [[user(locn5)]];
    float2 v_EndpointDirection1 [[user(locn11)]];
    float2 v_EndpointDirection2 [[user(locn13)]];
    float2 v_EndpointDirection3 [[user(locn14)]];
    float2 v_EndpointDirection4 [[user(locn15)]];
    float v_EndpointLen1 [[user(locn21)]];
    float v_EndpointLen2 [[user(locn23)]];
    float v_EndpointLen3 [[user(locn24)]];
    float v_EndpointLen4 [[user(locn25)]];
    float v_EndpointPosX1 [[user(locn31)]];
    float v_EndpointPosX2 [[user(locn33)]];
    float v_EndpointPosX3 [[user(locn34)]];
    float v_EndpointPosX4 [[user(locn35)]];
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
void preCalcNode(thread const int& nodeNum, thread const float2& texCoord, thread const float& aspectFactor, thread const float& motitionOffset, thread const float2& endpointNodeCenter, thread float2& thisNodeCenter, thread float2& nextNodeCenter, thread const float& thisWindDirection, thread const float& nextWindDirection, thread const float& inertia, thread const float& thisOffset, thread const float& nextOffset, thread float2& thisDirection, thread float2& endpointDirection, thread float& thisLength, thread float& endpointLength, thread float& thisPosX, thread float& endpointPosX, thread float& thisMotionRadian, constant _Globals& _81)
{
    thisNodeCenter.x *= aspectFactor;
    nextNodeCenter.x *= aspectFactor;
    float2 nodeVec = thisNodeCenter - nextNodeCenter;
    float2 eNodeVec = endpointNodeCenter - nextNodeCenter;
    thisDirection = fast::normalize(nodeVec);
    endpointDirection = mix(fast::normalize(eNodeVec), thisDirection, float2(_81.g_DirectionalCompensation));
    thisLength = dot(nodeVec, thisDirection);
    endpointLength = mix(thisLength, dot(eNodeVec, endpointDirection), _81.g_SmoothDistance);
    float2 relativeTexCoord = texCoord - nextNodeCenter;
    endpointPosX = dot(relativeTexCoord, endpointDirection);
    thisPosX = dot(relativeTexCoord, endpointDirection);
    float thisMotionTime = _81.g_GlobalTimeOffset + (_81.g_Time * _81.g_Speed);
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
    thisMotionRadian += (sin(thisWindDirection + 1.57079637050628662109375) + sin(_81.g_GlobalWindOffset));
    prevMotionRadian += sin(nextWindDirection + 1.57079637050628662109375);
    prevMotionRadian *= step(0.5, float(nodeNum));
    thisMotionRadian -= prevMotionRadian;
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _81 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _81.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_aspect = _81.g_Texture0Resolution.z / _81.g_Texture0Resolution.w;
    float4 _217 = out.v_TexCoord;
    float2 _219 = _217.xz * out.v_aspect;
    out.v_TexCoord.x = _219.x;
    out.v_TexCoord.z = _219.y;
    out.v_reciprocalAspect = 1.0 / out.v_aspect;
    float2 endpointSpinCenter = _81.g_SpinCenter1;
    endpointSpinCenter.x *= out.v_aspect;
    float motitionOffset = _81.g_Inertia * _81.g_SigmentCount;
    int param = 2;
    float2 param_1 = out.v_TexCoord.zw;
    float param_2 = out.v_aspect;
    float param_3 = motitionOffset;
    float2 param_4 = endpointSpinCenter;
    float2 param_5 = _81.g_SpinCenter1;
    float2 param_6 = _81.g_SpinCenter2;
    float param_7 = _81.g_WindDirection2;
    float param_8 = _81.g_WindDirection3;
    float param_9 = _81.g_Inertia;
    float param_10 = _81.g_TimeOffset1;
    float param_11 = _81.g_TimeOffset2;
    float2 param_12;
    float2 param_13;
    float param_14;
    float param_15;
    float param_16;
    float param_17;
    float param_18;
    preCalcNode(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17, param_18, _81);
    out.v_Direction1 = param_12;
    out.v_EndpointDirection1 = param_13;
    out.v_Len1 = param_14;
    out.v_EndpointLen1 = param_15;
    out.v_PosX1 = param_16;
    out.v_EndpointPosX1 = param_17;
    out.v_MotionRadian1 = param_18;
    int param_19 = 3;
    float2 param_20 = out.v_TexCoord.zw;
    float param_21 = out.v_aspect;
    float param_22 = motitionOffset;
    float2 param_23 = endpointSpinCenter;
    float2 param_24 = _81.g_SpinCenter2;
    float2 param_25 = _81.g_SpinCenter3;
    float param_26 = _81.g_WindDirection3;
    float param_27 = _81.g_WindDirection4;
    float param_28 = _81.g_Inertia;
    float param_29 = _81.g_TimeOffset2;
    float param_30 = _81.g_TimeOffset3;
    float2 param_31;
    float2 param_32;
    float param_33;
    float param_34;
    float param_35;
    float param_36;
    float param_37;
    preCalcNode(param_19, param_20, param_21, param_22, param_23, param_24, param_25, param_26, param_27, param_28, param_29, param_30, param_31, param_32, param_33, param_34, param_35, param_36, param_37, _81);
    out.v_Direction2 = param_31;
    out.v_EndpointDirection2 = param_32;
    out.v_Len2 = param_33;
    out.v_EndpointLen2 = param_34;
    out.v_PosX2 = param_35;
    out.v_EndpointPosX2 = param_36;
    out.v_MotionRadian2 = param_37;
    int param_38 = 4;
    float2 param_39 = out.v_TexCoord.zw;
    float param_40 = out.v_aspect;
    float param_41 = motitionOffset;
    float2 param_42 = endpointSpinCenter;
    float2 param_43 = _81.g_SpinCenter3;
    float2 param_44 = _81.g_SpinCenter4;
    float param_45 = _81.g_WindDirection4;
    float param_46 = _81.g_WindDirection5;
    float param_47 = _81.g_Inertia;
    float param_48 = _81.g_TimeOffset3;
    float param_49 = _81.g_TimeOffset4;
    float2 param_50;
    float2 param_51;
    float param_52;
    float param_53;
    float param_54;
    float param_55;
    float param_56;
    preCalcNode(param_38, param_39, param_40, param_41, param_42, param_43, param_44, param_45, param_46, param_47, param_48, param_49, param_50, param_51, param_52, param_53, param_54, param_55, param_56, _81);
    out.v_Direction3 = param_50;
    out.v_EndpointDirection3 = param_51;
    out.v_Len3 = param_52;
    out.v_EndpointLen3 = param_53;
    out.v_PosX3 = param_54;
    out.v_EndpointPosX3 = param_55;
    out.v_MotionRadian3 = param_56;
    int param_57 = 5;
    float2 param_58 = out.v_TexCoord.zw;
    float param_59 = out.v_aspect;
    float param_60 = motitionOffset;
    float2 param_61 = endpointSpinCenter;
    float2 param_62 = _81.g_SpinCenter4;
    float2 param_63 = _81.g_SpinCenter5;
    float param_64 = _81.g_WindDirection5;
    float param_65 = _81.g_WindDirection6;
    float param_66 = _81.g_Inertia;
    float param_67 = _81.g_TimeOffset4;
    float param_68 = _81.g_TimeOffset5;
    float2 param_69;
    float2 param_70;
    float param_71;
    float param_72;
    float param_73;
    float param_74;
    float param_75;
    preCalcNode(param_57, param_58, param_59, param_60, param_61, param_62, param_63, param_64, param_65, param_66, param_67, param_68, param_69, param_70, param_71, param_72, param_73, param_74, param_75, _81);
    out.v_Direction4 = param_69;
    out.v_EndpointDirection4 = param_70;
    out.v_Len4 = param_71;
    out.v_EndpointLen4 = param_72;
    out.v_PosX4 = param_73;
    out.v_EndpointPosX4 = param_74;
    out.v_MotionRadian4 = param_75;
    return out;
}

