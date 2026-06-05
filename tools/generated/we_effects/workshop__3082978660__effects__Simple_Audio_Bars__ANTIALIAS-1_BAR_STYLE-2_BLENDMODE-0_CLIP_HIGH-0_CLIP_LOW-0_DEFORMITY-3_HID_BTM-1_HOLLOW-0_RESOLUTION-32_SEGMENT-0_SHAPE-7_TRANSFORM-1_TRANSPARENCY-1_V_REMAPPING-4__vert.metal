#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float2 g_Offset;
    float2 g_Scale;
    float g_Direction;
    float4 g_Texture0Resolution;
};

struct main0_out
{
    float2 p_TexCoord [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
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

static inline __attribute__((always_inline))
float2 applyFx(thread float2& v, constant _Globals& _61)
{
    float2 param = v - float2(0.5);
    float param_1 = -_61.g_Direction;
    v = rotateVec2(param, param_1);
    return (((v + _61.g_Offset) * 1.0) / _61.g_Scale) + float2(0.5);
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _61 [[buffer(0)]])
{
    main0_out out = {};
    out.p_TexCoord = in.a_TexCoord;
    out.v_TexCoord = in.a_TexCoord;
    float2 param = out.v_TexCoord;
    float2 _95 = applyFx(param, _61);
    out.v_TexCoord = _95;
    out.gl_Position = _61.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    return out;
}

