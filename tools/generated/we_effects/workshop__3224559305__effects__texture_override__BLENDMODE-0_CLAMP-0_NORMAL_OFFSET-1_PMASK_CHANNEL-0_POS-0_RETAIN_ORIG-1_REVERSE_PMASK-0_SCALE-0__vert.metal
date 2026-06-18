#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
    float2 g_TexelSize;
    float2 g_offset;
    float2 g_TexOffset;
    float g_TexAngle;
    float2 g_TexScale;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _59 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _59.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float aspect = _59.g_Texture0Resolution.z / _59.g_Texture0Resolution.w;
    float2 scale = (_59.g_Texture0Resolution / _59.g_Texture1Resolution).xy;
    float2 offset = float2(0.5) - _59.g_offset;
    float2 rotationCenter = float2(0.5) - offset;
    float4 _112 = out.v_TexCoord;
    float2 _114 = _112.zw - rotationCenter;
    out.v_TexCoord.z = _114.x;
    out.v_TexCoord.w = _114.y;
    out.v_TexCoord.z *= aspect;
    float2 param = out.v_TexCoord.zw;
    float param_1 = _59.g_TexAngle;
    float2 _138 = (rotateVec2(param, param_1) * scale) / _59.g_TexScale;
    out.v_TexCoord.z = _138.x;
    out.v_TexCoord.w = _138.y;
    out.v_TexCoord.z /= aspect;
    float4 _151 = out.v_TexCoord;
    float2 _153 = _151.zw + (rotationCenter + offset);
    out.v_TexCoord.z = _153.x;
    out.v_TexCoord.w = _153.y;
    return out;
}

