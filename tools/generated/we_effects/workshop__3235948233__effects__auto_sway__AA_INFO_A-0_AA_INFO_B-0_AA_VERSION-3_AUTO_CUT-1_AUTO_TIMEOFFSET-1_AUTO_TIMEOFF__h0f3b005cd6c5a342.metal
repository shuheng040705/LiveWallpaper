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
    float2 v_AspectedRootNodeCenter [[user(locn0)]];
    float2 v_Direction1 [[user(locn1)]];
    float2 v_Direction2 [[user(locn3)]];
    float2 v_Direction3 [[user(locn4)]];
    float v_EndpointLen1 [[user(locn21)]];
    float v_EndpointLen2 [[user(locn23)]];
    float v_EndpointLen3 [[user(locn24)]];
    float v_Len1 [[user(locn41)]];
    float v_Len2 [[user(locn43)]];
    float v_Len3 [[user(locn44)]];
    float v_MotionRadian1 [[user(locn51)]];
    float v_MotionRadian2 [[user(locn53)]];
    float v_MotionRadian3 [[user(locn54)]];
    float v_PosX1 [[user(locn61)]];
    float v_PosX2 [[user(locn63)]];
    float v_PosX3 [[user(locn64)]];
    float v_StartpointLen1 [[user(locn72)]];
    float v_StartpointLen2 [[user(locn74)]];
    float v_StartpointLen3 [[user(locn75)]];
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
void preCalcNode(thread const int& nodeNum, thread const float2& texCoord, thread const float& aspectFactor, thread const float& motitionOffset, thread const float2& aspectedRootNodeCenter, thread const float2& endpointNodeCenter, thread float2& thisNodeCenter, thread float2& nextNodeCenter, thread const float& thisWindDirection, thread const float& nextWindDirection, thread const float& inertia, thread const float& thisOffset, thread const float& nextOffset, thread float2& thisDirection, thread float& startpointLength, thread float& thisLength, thread float& endpointLength, thread float& thisPosX, thread float& thisMotionRadian, constant _Globals& _82)
{
    thisNodeCenter.x *= aspectFactor;
    nextNodeCenter.x *= aspectFactor;
    float2 nodeVec = thisNodeCenter - nextNodeCenter;
    float2 eNodeVec = endpointNodeCenter - nextNodeCenter;
    thisDirection = fast::normalize(nodeVec);
    float2 endpointDirection = mix(fast::normalize(eNodeVec), thisDirection, float2(_82.g_DirectionalCompensation));
    float2 relativeTexCoord = texCoord - nextNodeCenter;
    thisPosX = dot(relativeTexCoord, endpointDirection);
    thisLength = dot(nodeVec, thisDirection);
    endpointLength = mix(thisLength, dot(eNodeVec, endpointDirection), _82.g_SmoothDistance);
    startpointLength = distance(nextNodeCenter, aspectedRootNodeCenter);
    float thisMotionTime = _82.g_GlobalTimeOffset + (_82.g_Time * _82.g_Speed);
    float prevMotionTime = thisMotionTime;
    float param = 2.0;
    float param_1 = 4.0;
    float param_2 = float(nodeNum);
    thisMotionTime += (motitionOffset * linearStep(param, param_1, param_2));
    float param_3 = 2.0;
    float param_4 = 4.0;
    float param_5 = float(nodeNum + 1);
    prevMotionTime += (motitionOffset * linearStep(param_3, param_4, param_5));
    thisMotionRadian = sin(thisMotionTime * 6.283185482025146484375);
    float prevMotionRadian = sin(prevMotionTime * 6.283185482025146484375) * inertia;
    thisMotionRadian += (sin(thisWindDirection + 1.57079637050628662109375) + sin(_82.g_GlobalWindOffset));
    prevMotionRadian += sin(nextWindDirection + 1.57079637050628662109375);
    prevMotionRadian *= step(0.5, float(nodeNum));
    thisMotionRadian -= prevMotionRadian;
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _82 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _82.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_aspect = _82.g_Texture0Resolution.z / _82.g_Texture0Resolution.w;
    float4 _218 = out.v_TexCoord;
    float2 _220 = _218.xz * out.v_aspect;
    out.v_TexCoord.x = _220.x;
    out.v_TexCoord.z = _220.y;
    out.v_reciprocalAspect = 1.0 / out.v_aspect;
    out.v_AspectedRootNodeCenter = _82.g_SpinCenter4 * out.v_aspect;
    float2 endpointSpinCenter = _82.g_SpinCenter1;
    endpointSpinCenter.x *= out.v_aspect;
    float motitionOffset = _82.g_Inertia * _82.g_SigmentCount;
    int param = 2;
    float2 param_1 = out.v_TexCoord.zw;
    float param_2 = out.v_aspect;
    float param_3 = motitionOffset;
    float2 param_4 = out.v_AspectedRootNodeCenter;
    float2 param_5 = endpointSpinCenter;
    float2 param_6 = _82.g_SpinCenter1;
    float2 param_7 = _82.g_SpinCenter2;
    float param_8 = _82.g_WindDirection2;
    float param_9 = _82.g_WindDirection3;
    float param_10 = _82.g_Inertia;
    float param_11 = _82.g_TimeOffset1;
    float param_12 = _82.g_TimeOffset2;
    float2 param_13;
    float param_14;
    float param_15;
    float param_16;
    float param_17;
    float param_18;
    preCalcNode(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17, param_18, _82);
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
    float2 param_25 = _82.g_SpinCenter2;
    float2 param_26 = _82.g_SpinCenter3;
    float param_27 = _82.g_WindDirection3;
    float param_28 = _82.g_WindDirection4;
    float param_29 = _82.g_Inertia;
    float param_30 = _82.g_TimeOffset2;
    float param_31 = _82.g_TimeOffset3;
    float2 param_32;
    float param_33;
    float param_34;
    float param_35;
    float param_36;
    float param_37;
    preCalcNode(param_19, param_20, param_21, param_22, param_23, param_24, param_25, param_26, param_27, param_28, param_29, param_30, param_31, param_32, param_33, param_34, param_35, param_36, param_37, _82);
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
    float2 param_44 = _82.g_SpinCenter3;
    float2 param_45 = _82.g_SpinCenter4;
    float param_46 = _82.g_WindDirection4;
    float param_47 = _82.g_WindDirection5;
    float param_48 = _82.g_Inertia;
    float param_49 = _82.g_TimeOffset3;
    float param_50 = _82.g_TimeOffset4;
    float2 param_51;
    float param_52;
    float param_53;
    float param_54;
    float param_55;
    float param_56;
    preCalcNode(param_38, param_39, param_40, param_41, param_42, param_43, param_44, param_45, param_46, param_47, param_48, param_49, param_50, param_51, param_52, param_53, param_54, param_55, param_56, _82);
    out.v_Direction3 = param_51;
    out.v_StartpointLen3 = param_52;
    out.v_Len3 = param_53;
    out.v_EndpointLen3 = param_54;
    out.v_PosX3 = param_55;
    out.v_MotionRadian3 = param_56;
    return out;
}

