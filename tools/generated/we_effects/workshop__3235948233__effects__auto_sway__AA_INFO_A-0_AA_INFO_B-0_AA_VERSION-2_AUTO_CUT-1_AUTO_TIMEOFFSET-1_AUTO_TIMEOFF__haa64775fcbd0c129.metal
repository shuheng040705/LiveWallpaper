#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture0Resolution;
    float g_Time;
    float g_Strength;
    float u_Damping;
    float g_xFeather;
    float2 g_SpinCenter1;
    float g_Size1;
    float g_WindDirection1;
    float g_WindDirection2;
    float2 g_SpinCenter2;
    float g_Size2;
    float g_WindDirection3;
    float2 g_SpinCenter3;
    float g_Size3;
    float g_WindDirection4;
    float2 g_SpinCenter4;
    float g_Size4;
    float g_WindDirection5;
    float2 g_SpinCenter5;
    float g_Size5;
    float g_WindDirection6;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
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
    float4 _we_ro_v_TexCoord [[user(locn82)]];
    float v_aspect [[user(locn83)]];
    float v_reciprocalAspect [[user(locn84)]];
};

static inline __attribute__((always_inline))
float sineStep(thread const float& lower, thread const float& upper, thread const float& x)
{
    return sin((fast::clamp((x - lower) / (upper - lower), 0.0, 1.0) * 3.1415927410125732421875) * 0.5);
}

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

static inline __attribute__((always_inline))
void calNode(thread float4& texCoord, thread const float& aspectFactor, thread float2& rootNodeCenter, thread const float& thisWidth, thread const float& nextWidth, thread const float2& direction, thread const float2& eDirection, thread const float& len, thread const float& eLen, thread const float& posX, thread const float& ePosX, thread const float& motionRadian, thread const float& damping, thread const float& mask, thread float& autoMask, thread float& weight, constant _Globals& _126)
{
    rootNodeCenter.x *= aspectFactor;
    float4 relativeTexCoord = texCoord - rootNodeCenter.xyxy;
    float hBoundary = mix(nextWidth, thisWidth, posX / len);
    float posY = abs(dot(relativeTexCoord.zw, float2(direction.y, -direction.x)));
    autoMask = fast::max(autoMask, 1.0 - smoothstep(hBoundary, hBoundary + _126.g_xFeather, posY));
    float param = 0.0;
    float param_1 = eLen;
    float param_2 = ePosX;
    weight = sineStep(param, param_1, param_2);
    weight *= (((1.0 - (weight * damping)) * autoMask) * mask);
    float2 param_3 = relativeTexCoord.xy;
    float param_4 = (motionRadian * _126.g_Strength) * weight;
    float2 _166 = rotateVec2(param_3, param_4) + rootNodeCenter;
    texCoord.x = _166.x;
    texCoord.y = _166.y;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _126 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 v_TexCoord = in._we_ro_v_TexCoord;
    float mask = 1.0;
    float stageWeight = 0.0;
    float autoMask = 0.0;
    float4 param = v_TexCoord;
    float param_1 = in.v_aspect;
    float2 param_2 = _126.g_SpinCenter2;
    float param_3 = _126.g_Size1;
    float param_4 = _126.g_Size2;
    float2 param_5 = in.v_Direction1;
    float2 param_6 = in.v_EndpointDirection1;
    float param_7 = in.v_Len1;
    float param_8 = in.v_EndpointLen1;
    float param_9 = in.v_PosX1;
    float param_10 = in.v_EndpointPosX1;
    float param_11 = in.v_MotionRadian1;
    float param_12 = _126.u_Damping;
    float param_13 = mask;
    float param_14 = autoMask;
    float param_15;
    calNode(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, _126);
    v_TexCoord = param;
    autoMask = param_14;
    stageWeight = param_15;
    float4 param_16 = v_TexCoord;
    float param_17 = in.v_aspect;
    float2 param_18 = _126.g_SpinCenter3;
    float param_19 = _126.g_Size2;
    float param_20 = _126.g_Size3;
    float2 param_21 = in.v_Direction2;
    float2 param_22 = in.v_EndpointDirection2;
    float param_23 = in.v_Len2;
    float param_24 = in.v_EndpointLen2;
    float param_25 = in.v_PosX2;
    float param_26 = in.v_EndpointPosX2;
    float param_27 = in.v_MotionRadian2;
    float param_28 = _126.u_Damping;
    float param_29 = mask;
    float param_30 = autoMask;
    float param_31;
    calNode(param_16, param_17, param_18, param_19, param_20, param_21, param_22, param_23, param_24, param_25, param_26, param_27, param_28, param_29, param_30, param_31, _126);
    v_TexCoord = param_16;
    autoMask = param_30;
    stageWeight = param_31;
    float4 param_32 = v_TexCoord;
    float param_33 = in.v_aspect;
    float2 param_34 = _126.g_SpinCenter4;
    float param_35 = _126.g_Size3;
    float param_36 = _126.g_Size4;
    float2 param_37 = in.v_Direction3;
    float2 param_38 = in.v_EndpointDirection3;
    float param_39 = in.v_Len3;
    float param_40 = in.v_EndpointLen3;
    float param_41 = in.v_PosX3;
    float param_42 = in.v_EndpointPosX3;
    float param_43 = in.v_MotionRadian3;
    float param_44 = _126.u_Damping;
    float param_45 = mask;
    float param_46 = autoMask;
    float param_47;
    calNode(param_32, param_33, param_34, param_35, param_36, param_37, param_38, param_39, param_40, param_41, param_42, param_43, param_44, param_45, param_46, param_47, _126);
    v_TexCoord = param_32;
    autoMask = param_46;
    stageWeight = param_47;
    float4 param_48 = v_TexCoord;
    float param_49 = in.v_aspect;
    float2 param_50 = _126.g_SpinCenter5;
    float param_51 = _126.g_Size4;
    float param_52 = _126.g_Size5;
    float2 param_53 = in.v_Direction4;
    float2 param_54 = in.v_EndpointDirection4;
    float param_55 = in.v_Len4;
    float param_56 = in.v_EndpointLen4;
    float param_57 = in.v_PosX4;
    float param_58 = in.v_EndpointPosX4;
    float param_59 = in.v_MotionRadian4;
    float param_60 = _126.u_Damping;
    float param_61 = mask;
    float param_62 = autoMask;
    float param_63;
    calNode(param_48, param_49, param_50, param_51, param_52, param_53, param_54, param_55, param_56, param_57, param_58, param_59, param_60, param_61, param_62, param_63, _126);
    v_TexCoord = param_48;
    autoMask = param_62;
    stageWeight = param_63;
    float4 _378 = v_TexCoord;
    float2 _380 = _378.xz * in.v_reciprocalAspect;
    v_TexCoord.x = _380.x;
    v_TexCoord.z = _380.y;
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, v_TexCoord.xy);
    return out;
}

