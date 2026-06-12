#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float2 u_size;
    float2 u_position;
    float u_Thickness;
    float u_Softness;
    float2 u_refResolution;
    float u_NotchSize;
    float u_extrudeEdge;
    float u_rotation;
    float4x4 g_LayerModelMatrix;
    float4x4 g_ModelMatrix;
    float4 g_Texture0Resolution;
};

struct main0_out
{
    float2 v_Size [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float3 v_Transform [[user(locn2)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _71 [[buffer(0)]])
{
    main0_out out = {};
    out.v_TexCoord.z = in.a_TexCoord.x;
    out.v_TexCoord.w = in.a_TexCoord.y;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 right = float2(_71.g_LayerModelMatrix[0].x, _71.g_LayerModelMatrix[0].y);
    float2 up = float2(_71.g_LayerModelMatrix[1].x, _71.g_LayerModelMatrix[1].y);
    float2 scale = float2(length(right), length(up));
    out.v_Transform.x = fast::max(9.9999999747524270787835121154785e-07, (_71.u_NotchSize * _71.g_Texture0Resolution.x) * 0.20000000298023223876953125);
    out.v_Transform.x = length(float2(out.v_Transform.x));
    out.v_Transform.y = (_71.u_Thickness * _71.g_Texture0Resolution.x) * 0.0500000007450580596923828125;
    out.v_Transform.z = (_71.u_extrudeEdge * _71.g_Texture0Resolution.x) * 0.100000001490116119384765625;
    float2 param = (((out.v_TexCoord.xy + _71.u_position) - float2(0.5)) * _71.g_Texture0Resolution.xy) * scale;
    float param_1 = _71.u_rotation;
    float2 _154 = rotateVec2(param, param_1);
    out.v_TexCoord.x = _154.x;
    out.v_TexCoord.y = _154.y;
    out.v_Size = (((((_71.u_size * _71.g_Texture0Resolution.xy) * 0.5) * scale) - float2(out.v_Transform.y)) - float2(_71.u_Softness)) - float2(_71.u_Softness);
    out.gl_Position = _71.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    return out;
}

