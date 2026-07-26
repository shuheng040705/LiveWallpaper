#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float g_Time;
    float4 g_Texture1Resolution;
    float4 g_Texture2Resolution;
    float g_Direction;
};

struct main0_out
{
    float2 v_Direction [[user(locn0)]];
    float4 v_TexCoord [[user(locn2)]];
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
    out.v_TexCoord.z *= (_59.g_Texture2Resolution.z / _59.g_Texture2Resolution.x);
    out.v_TexCoord.w *= (_59.g_Texture2Resolution.w / _59.g_Texture2Resolution.y);
    float2 param = float2(0.0, 1.0);
    float param_1 = _59.g_Direction;
    out.v_Direction = rotateVec2(param, param_1);
    return out;
}

