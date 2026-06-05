#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float4 g_Texture2Resolution;
    float g_Time;
    float g_NoiseScale;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordNoise [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _19 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _19.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    float aspect = _19.g_Texture0Resolution.z / _19.g_Texture0Resolution.w;
    float t = fract(_19.g_Time);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float2 _65 = (in.a_TexCoord + float2(t)) * _19.g_NoiseScale;
    out.v_TexCoordNoise.x = _65.x;
    out.v_TexCoordNoise.y = _65.y;
    float2 _82 = ((in.a_TexCoord - float2(t * 2.5)) * _19.g_NoiseScale) * 0.519999980926513671875;
    out.v_TexCoordNoise.z = _82.x;
    out.v_TexCoordNoise.w = _82.y;
    out.v_TexCoordNoise *= float4(aspect, 1.0, aspect, 1.0);
    float2 _110 = float2((in.a_TexCoord.x * _19.g_Texture2Resolution.z) / _19.g_Texture2Resolution.x, (in.a_TexCoord.y * _19.g_Texture2Resolution.w) / _19.g_Texture2Resolution.y);
    out.v_TexCoord.z = _110.x;
    out.v_TexCoord.w = _110.y;
    return out;
}

