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
    float u_WeightFadeDistance;
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
void calNode(thread float4& texCoord, thread const float& aspectFactor, thread float2& rootNodeCenter, thread const float& dist, thread const float& thisWidth, thread const float& nextWidth, thread const float2& direction, thread const float& sLen, thread const float& len, thread const float& eLen, thread const float& posX, thread const float& motionRadian, thread const float& damping, thread const float& mask, thread float& autoMask, thread const float& maxMask, thread float& weight, constant _Globals& _127)
{
    rootNodeCenter.x *= aspectFactor;
    float4 relativeTexCoord = texCoord - rootNodeCenter.xyxy;
    float hBoundary = mix(nextWidth, thisWidth, posX / len);
    float posY = abs(dot(relativeTexCoord.zw, float2(direction.y, -direction.x)));
    autoMask = fast::max(autoMask, 1.0 - smoothstep(hBoundary, hBoundary + _127.g_xFeather, posY));
    float param = 0.0;
    float param_1 = eLen;
    float param_2 = dist - sLen;
    weight = sineStep(param, param_1, param_2);
    weight *= ((1.0 - (weight * damping)) * fast::min(maxMask, autoMask * mask));
    float2 param_3 = relativeTexCoord.xy;
    float param_4 = (motionRadian * _127.g_Strength) * weight;
    float2 _171 = rotateVec2(param_3, param_4) + rootNodeCenter;
    texCoord.x = _171.x;
    texCoord.y = _171.y;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _127 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 v_TexCoord = in._we_ro_v_TexCoord;
    float mask = 1.0;
    float param = 0.0;
    float param_1 = in.v_Len4 * _127.u_WeightFadeDistance;
    float param_2 = in.v_PosX4;
    float v_MaxMask = sineStep(param, param_1, param_2);
    float dist = distance(in.v_AspectedRootNodeCenter, v_TexCoord.xy);
    float stageWeight = 0.0;
    float autoMask = 0.0;
    float4 param_3 = v_TexCoord;
    float param_4 = in.v_aspect;
    float2 param_5 = _127.g_SpinCenter2;
    float param_6 = dist;
    float param_7 = _127.g_Size1;
    float param_8 = _127.g_Size2;
    float2 param_9 = in.v_Direction1;
    float param_10 = in.v_StartpointLen1;
    float param_11 = in.v_Len1;
    float param_12 = in.v_EndpointLen1;
    float param_13 = in.v_PosX1;
    float param_14 = in.v_MotionRadian1;
    float param_15 = _127.u_Damping;
    float param_16 = mask;
    float param_17 = autoMask;
    float param_18 = v_MaxMask;
    float param_19;
    calNode(param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17, param_18, param_19, _127);
    v_TexCoord = param_3;
    autoMask = param_17;
    stageWeight = param_19;
    float4 param_20 = v_TexCoord;
    float param_21 = in.v_aspect;
    float2 param_22 = _127.g_SpinCenter3;
    float param_23 = dist;
    float param_24 = _127.g_Size2;
    float param_25 = _127.g_Size3;
    float2 param_26 = in.v_Direction2;
    float param_27 = in.v_StartpointLen2;
    float param_28 = in.v_Len2;
    float param_29 = in.v_EndpointLen2;
    float param_30 = in.v_PosX2;
    float param_31 = in.v_MotionRadian2;
    float param_32 = _127.u_Damping;
    float param_33 = mask;
    float param_34 = autoMask;
    float param_35 = v_MaxMask;
    float param_36;
    calNode(param_20, param_21, param_22, param_23, param_24, param_25, param_26, param_27, param_28, param_29, param_30, param_31, param_32, param_33, param_34, param_35, param_36, _127);
    v_TexCoord = param_20;
    autoMask = param_34;
    stageWeight = param_36;
    float4 param_37 = v_TexCoord;
    float param_38 = in.v_aspect;
    float2 param_39 = _127.g_SpinCenter4;
    float param_40 = dist;
    float param_41 = _127.g_Size3;
    float param_42 = _127.g_Size4;
    float2 param_43 = in.v_Direction3;
    float param_44 = in.v_StartpointLen3;
    float param_45 = in.v_Len3;
    float param_46 = in.v_EndpointLen3;
    float param_47 = in.v_PosX3;
    float param_48 = in.v_MotionRadian3;
    float param_49 = _127.u_Damping;
    float param_50 = mask;
    float param_51 = autoMask;
    float param_52 = v_MaxMask;
    float param_53;
    calNode(param_37, param_38, param_39, param_40, param_41, param_42, param_43, param_44, param_45, param_46, param_47, param_48, param_49, param_50, param_51, param_52, param_53, _127);
    v_TexCoord = param_37;
    autoMask = param_51;
    stageWeight = param_53;
    float4 param_54 = v_TexCoord;
    float param_55 = in.v_aspect;
    float2 param_56 = _127.g_SpinCenter5;
    float param_57 = dist;
    float param_58 = _127.g_Size4;
    float param_59 = _127.g_Size5;
    float2 param_60 = in.v_Direction4;
    float param_61 = in.v_StartpointLen4;
    float param_62 = in.v_Len4;
    float param_63 = in.v_EndpointLen4;
    float param_64 = in.v_PosX4;
    float param_65 = in.v_MotionRadian4;
    float param_66 = _127.u_Damping;
    float param_67 = mask;
    float param_68 = autoMask;
    float param_69 = v_MaxMask;
    float param_70;
    calNode(param_54, param_55, param_56, param_57, param_58, param_59, param_60, param_61, param_62, param_63, param_64, param_65, param_66, param_67, param_68, param_69, param_70, _127);
    v_TexCoord = param_54;
    autoMask = param_68;
    stageWeight = param_70;
    float4 _404 = v_TexCoord;
    float2 _406 = _404.xz * in.v_reciprocalAspect;
    v_TexCoord.x = _406.x;
    v_TexCoord.z = _406.y;
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, v_TexCoord.xy);
    return out;
}

