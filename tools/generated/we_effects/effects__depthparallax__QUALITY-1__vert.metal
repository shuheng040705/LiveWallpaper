#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture1Resolution;
    float2 g_ParallaxPosition;
    float3 g_Screen;
    float4x4 g_EffectTextureProjectionMatrix;
    float4x4 g_EffectTextureProjectionMatrixInverse;
};

struct main0_out
{
    float2 v_ParallaxOffset [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _21 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _21.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 _67 = float2((in.a_TexCoord.x * _21.g_Texture1Resolution.z) / _21.g_Texture1Resolution.x, (in.a_TexCoord.y * _21.g_Texture1Resolution.w) / _21.g_Texture1Resolution.y);
    out.v_TexCoord.z = _67.x;
    out.v_TexCoord.w = _67.y;
    float3x3 rot = float3x3(_21.g_EffectTextureProjectionMatrixInverse[0].xyz, _21.g_EffectTextureProjectionMatrixInverse[1].xyz, _21.g_EffectTextureProjectionMatrixInverse[2].xyz);
    float2 projectedDirX = (rot * float3(1.0, 0.0, 0.0)).xy;
    float2 projectedDirY = (rot * float3(0.0, 1.0, 0.0)).xy;
    projectedDirX = fast::normalize(projectedDirX);
    projectedDirY = fast::normalize(projectedDirY);
    float2 prlxInput = (_21.g_ParallaxPosition * 2.0) - float2(1.0);
    out.v_ParallaxOffset = (projectedDirX * prlxInput.x) + (projectedDirY * prlxInput.y);
    out.v_ParallaxOffset = (out.v_ParallaxOffset * 0.5) + float2(0.5);
    return out;
}

