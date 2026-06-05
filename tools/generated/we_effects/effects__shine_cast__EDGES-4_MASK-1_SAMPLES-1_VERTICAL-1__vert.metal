#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float g_Time;
    float g_Direction;
    float g_Speed;
};

struct main0_out
{
    float4 v_TexCoord01 [[user(locn0)]];
    float4 v_TexCoord23 [[user(locn1)]];
    float4 v_TexCoord45 [[user(locn2)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _83 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord01.x = in.a_TexCoord.x;
    out.v_TexCoord01.y = in.a_TexCoord.y;
    float2 param = float2(0.0, 0.5);
    float param_1 = _83.g_Time * _83.g_Speed;
    float2 baseDirection = rotateVec2(param, param_1);
    float ratio = _83.g_Texture0Resolution.x / _83.g_Texture0Resolution.y;
    float2 param_2 = baseDirection;
    float param_3 = _83.g_Direction;
    float2 _108 = rotateVec2(param_2, param_3);
    out.v_TexCoord01.z = _108.x;
    out.v_TexCoord01.w = _108.y;
    float2 param_4 = float2(-baseDirection.y, baseDirection.x);
    float param_5 = _83.g_Direction;
    float2 _126 = rotateVec2(param_4, param_5);
    out.v_TexCoord23.x = _126.x;
    out.v_TexCoord23.y = _126.y;
    out.v_TexCoord23.z = 0.0;
    out.v_TexCoord23.w = 0.0;
    out.v_TexCoord45.x = 0.0;
    out.v_TexCoord45.y = 0.0;
    out.v_TexCoord45.z = 0.0;
    out.v_TexCoord45.w = 0.0;
    out.v_TexCoord01.w *= ratio;
    float4 _151 = out.v_TexCoord23;
    float2 _153 = _151.yw * ratio;
    out.v_TexCoord23.y = _153.x;
    out.v_TexCoord23.w = _153.y;
    float4 _159 = out.v_TexCoord45;
    float2 _161 = _159.yw * ratio;
    out.v_TexCoord45.y = _161.x;
    out.v_TexCoord45.w = _161.y;
    return out;
}

