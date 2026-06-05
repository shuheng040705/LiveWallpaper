#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture1Resolution;
    float g_Direction;
    float g_ReflectionOffset;
};

struct main0_out
{
    float2 v_ReflectedCoord [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
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
    float2 center = float2(0.5);
    float2 delta = in.a_TexCoord - center;
    delta.y += _59.g_ReflectionOffset;
    delta.y = -delta.y;
    float2 param = delta;
    float param_1 = _59.g_Direction;
    delta = rotateVec2(param, param_1);
    out.v_ReflectedCoord = center + delta;
    return out;
}

