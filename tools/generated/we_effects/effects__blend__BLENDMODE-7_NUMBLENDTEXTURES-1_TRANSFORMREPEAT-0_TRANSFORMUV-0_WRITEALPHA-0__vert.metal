#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float g_TextureReductionScale;
    float4 g_Texture1Resolution;
    float4 g_Texture2Resolution;
    float4 g_Texture3Resolution;
    float4 g_Texture4Resolution;
    float4 g_Texture5Resolution;
    float4 g_Texture6Resolution;
    float2 g_BlendOffset;
    float g_BlendAngle;
    float g_BlendScale;
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
    return out;
}

