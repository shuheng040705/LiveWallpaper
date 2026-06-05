#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4x4 g_EffectTextureProjectionMatrixInverse;
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
    float2 g_PointerPosition;
    float g_PointerScale;
};

struct main0_out
{
    float v_PointerScale [[user(locn0)]];
    float4 v_PointerUV [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _20 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _20.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float _47 = out.v_TexCoord.x;
    float _58 = out.v_TexCoord.y;
    float2 _66 = float2((_47 * _20.g_Texture1Resolution.z) / _20.g_Texture1Resolution.x, (_58 * _20.g_Texture1Resolution.w) / _20.g_Texture1Resolution.y);
    out.v_TexCoord.z = _66.x;
    out.v_TexCoord.w = _66.y;
    float2 pointer = _20.g_PointerPosition;
    pointer.y = 1.0 - pointer.y;
    float3 _96 = (_20.g_EffectTextureProjectionMatrixInverse * float4((pointer * 2.0) - float2(1.0), 0.0, 1.0)).xyw;
    out.v_PointerUV.x = _96.x;
    out.v_PointerUV.y = _96.y;
    out.v_PointerUV.z = _96.z;
    float4 _104 = out.v_PointerUV;
    float2 _106 = _104.xy * 0.5;
    out.v_PointerUV.x = _106.x;
    out.v_PointerUV.y = _106.y;
    out.v_PointerUV.w = _20.g_Texture0Resolution.y / (-_20.g_Texture0Resolution.x);
    out.v_PointerScale = mix(999.0, 1.0 / _20.g_PointerScale, step(0.001000000047497451305389404296875, _20.g_PointerScale));
    return out;
}

