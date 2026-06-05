#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float g_Time;
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
    float g_Speed;
    float2 g_SpinCenter;
    float g_Ratio;
    float g_Axis;
    float g_Phase;
    float2 g_Friction;
    float g_NoiseSpeed;
    float g_NoiseAmount;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordMask [[user(locn1)]];
    float2 v_TexCoordSoftMask [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _54 [[buffer(0)]])
{
    main0_out out = {};
    float aspect = _54.g_Texture0Resolution.z / _54.g_Texture0Resolution.w;
    float3 position = in.a_Position;
    out.gl_Position = _54.g_ModelViewProjectionMatrix * float4(position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_TexCoordMask = float2((in.a_TexCoord.x * _54.g_Texture1Resolution.z) / _54.g_Texture1Resolution.x, (in.a_TexCoord.y * _54.g_Texture1Resolution.w) / _54.g_Texture1Resolution.y);
    float4 _118 = out.v_TexCoord;
    float2 _120 = _118.xy - _54.g_SpinCenter;
    out.v_TexCoord.x = _120.x;
    out.v_TexCoord.y = _120.y;
    out.v_TexCoord.x *= aspect;
    float2 param = out.v_TexCoord.xy;
    float param_1 = _54.g_Axis;
    float2 _138 = rotateVec2(param, param_1);
    out.v_TexCoord.x = _138.x;
    out.v_TexCoord.y = _138.y;
    out.v_TexCoord.x *= _54.g_Ratio;
    out.v_TexCoordSoftMask = out.v_TexCoord.xy;
    float offset = _54.g_Phase * 6.283185482025146484375;
    float2 param_2 = out.v_TexCoord.xy;
    float param_3 = (_54.g_Speed * _54.g_Time) + offset;
    float2 _172 = rotateVec2(param_2, param_3);
    out.v_TexCoord.x = _172.x;
    out.v_TexCoord.y = _172.y;
    out.v_TexCoord.x /= _54.g_Ratio;
    float2 param_4 = out.v_TexCoord.xy;
    float param_5 = -_54.g_Axis;
    float2 _190 = rotateVec2(param_4, param_5);
    out.v_TexCoord.x = _190.x;
    out.v_TexCoord.y = _190.y;
    float2 param_6 = out.v_TexCoordSoftMask;
    float param_7 = -_54.g_Axis;
    out.v_TexCoordSoftMask = rotateVec2(param_6, param_7);
    out.v_TexCoord.x /= aspect;
    float4 _209 = out.v_TexCoord;
    float2 _211 = _209.xy + _54.g_SpinCenter;
    out.v_TexCoord.x = _211.x;
    out.v_TexCoord.y = _211.y;
    out.v_TexCoordSoftMask += _54.g_SpinCenter;
    return out;
}

