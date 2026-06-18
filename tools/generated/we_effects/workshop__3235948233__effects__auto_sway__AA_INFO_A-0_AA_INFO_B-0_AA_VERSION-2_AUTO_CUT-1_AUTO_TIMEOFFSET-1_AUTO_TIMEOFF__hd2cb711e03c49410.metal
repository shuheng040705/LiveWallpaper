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
    float3 u_debugBgColor;
    float2 g_SpinCenter1;
    float g_Size1;
    float g_WindDirection1;
    float g_WindDirection2;
    float2 g_SpinCenter2;
    float g_Size2;
    float g_WindDirection3;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_Direction1 [[user(locn1)]];
    float2 v_EndpointDirection1 [[user(locn11)]];
    float v_EndpointLen1 [[user(locn21)]];
    float v_EndpointPosX1 [[user(locn31)]];
    float v_Len1 [[user(locn41)]];
    float v_MotionRadian1 [[user(locn51)]];
    float v_PosX1 [[user(locn61)]];
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
void calNode(thread float4& texCoord, thread const float& aspectFactor, thread float2& rootNodeCenter, thread const float& thisWidth, thread const float& nextWidth, thread const float2& direction, thread const float2& eDirection, thread const float& len, thread const float& eLen, thread const float& posX, thread const float& ePosX, thread const float& motionRadian, thread const float& damping, thread const float& mask, thread float& autoMask, thread float& weight, constant _Globals& _127)
{
    rootNodeCenter.x *= aspectFactor;
    float4 relativeTexCoord = texCoord - rootNodeCenter.xyxy;
    float hBoundary = mix(nextWidth, thisWidth, posX / len);
    float posY = abs(dot(relativeTexCoord.zw, float2(direction.y, -direction.x)));
    autoMask = fast::max(autoMask, 1.0 - smoothstep(hBoundary, hBoundary + _127.g_xFeather, posY));
    float param = 0.0;
    float param_1 = eLen;
    float param_2 = ePosX;
    weight = sineStep(param, param_1, param_2);
    weight *= (((1.0 - (weight * damping)) * autoMask) * mask);
    float2 param_3 = relativeTexCoord.xy;
    float param_4 = (motionRadian * _127.g_Strength) * weight;
    float2 _167 = rotateVec2(param_3, param_4) + rootNodeCenter;
    texCoord.x = _167.x;
    texCoord.y = _167.y;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _127 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 v_TexCoord = in._we_ro_v_TexCoord;
    float mask = 1.0;
    float3 texColor = _127.u_debugBgColor;
    float stageWeight = 0.0;
    float autoMask = 0.0;
    float prevStageWeight = 0.0;
    float4 param = v_TexCoord;
    float param_1 = in.v_aspect;
    float2 param_2 = _127.g_SpinCenter2;
    float param_3 = _127.g_Size1;
    float param_4 = _127.g_Size2;
    float2 param_5 = in.v_Direction1;
    float2 param_6 = in.v_EndpointDirection1;
    float param_7 = in.v_Len1;
    float param_8 = in.v_EndpointLen1;
    float param_9 = in.v_PosX1;
    float param_10 = in.v_EndpointPosX1;
    float param_11 = in.v_MotionRadian1;
    float param_12 = _127.u_Damping;
    float param_13 = mask;
    float param_14 = autoMask;
    float param_15;
    calNode(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, _127);
    v_TexCoord = param;
    autoMask = param_14;
    stageWeight = param_15;
    texColor = mix(texColor, float3(1.0, 0.0, 0.0), float3((stageWeight - prevStageWeight) * mask));
    prevStageWeight = stageWeight;
    float4 _252 = v_TexCoord;
    float2 _254 = _252.xz * in.v_reciprocalAspect;
    v_TexCoord.x = _254.x;
    v_TexCoord.z = _254.y;
    out._fragColor = float4(texColor, g_Texture0.sample(g_Texture0Smplr, v_TexCoord.zw).w);
    return out;
}

