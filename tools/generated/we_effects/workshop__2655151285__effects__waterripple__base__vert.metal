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
    float g_AnimationSpeed;
    float g_Scale;
    float g_ScrollSpeed;
    float g_Direction;
    float g_Ratio;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn1)]];
    float4 v_TexCoordRipple [[user(locn2)]];
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
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float piFrac = 0.3926990926265716552734375;
    float pi = 3.1410000324249267578125;
    float2 coordsRotated = out.v_TexCoord.xy;
    float2 coordsRotated2 = out.v_TexCoord.xy * 1.3329999446868896484375;
    float2 param = float2(0.0, 1.0);
    float param_1 = _59.g_Direction;
    float2 scroll = ((rotateVec2(param, param_1) * _59.g_ScrollSpeed) * _59.g_ScrollSpeed) * _59.g_Time;
    float2 _131 = (coordsRotated + float2((_59.g_Time * _59.g_AnimationSpeed) * _59.g_AnimationSpeed)) + scroll;
    out.v_TexCoordRipple.x = _131.x;
    out.v_TexCoordRipple.y = _131.y;
    float2 _148 = (coordsRotated2 - float2((_59.g_Time * _59.g_AnimationSpeed) * _59.g_AnimationSpeed)) + scroll;
    out.v_TexCoordRipple.z = _148.x;
    out.v_TexCoordRipple.w = _148.y;
    out.v_TexCoordRipple *= _59.g_Scale;
    float rippleTextureAdjustment = _59.g_Texture0Resolution.x / _59.g_Texture0Resolution.y;
    float4 _168 = out.v_TexCoordRipple;
    float2 _170 = _168.xz * rippleTextureAdjustment;
    out.v_TexCoordRipple.x = _170.x;
    out.v_TexCoordRipple.z = _170.y;
    float4 _178 = out.v_TexCoordRipple;
    float2 _180 = _178.yw * _59.g_Ratio;
    out.v_TexCoordRipple.y = _180.x;
    out.v_TexCoordRipple.w = _180.y;
    float _186 = out.v_TexCoord.x;
    float _195 = out.v_TexCoord.y;
    float2 _202 = float2((_186 * _59.g_Texture1Resolution.z) / _59.g_Texture1Resolution.x, (_195 * _59.g_Texture1Resolution.w) / _59.g_Texture1Resolution.y);
    out.v_TexCoord.z = _202.x;
    out.v_TexCoord.w = _202.y;
    return out;
}

