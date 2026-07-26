#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
    float g_Time;
    float g_NoiseSpeed;
    float g_NoiseScale;
};

struct main0_out
{
    float4 v_NoiseTexCoord [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _42 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float _39 = out.v_TexCoord.x;
    float _53 = out.v_TexCoord.y;
    float2 _61 = float2((_39 * _42.g_Texture1Resolution.z) / _42.g_Texture1Resolution.x, (_53 * _42.g_Texture1Resolution.w) / _42.g_Texture1Resolution.y);
    out.v_TexCoord.z = _61.x;
    out.v_TexCoord.w = _61.y;
    float2 _76 = in.a_TexCoord + float2(_42.g_Time * _42.g_NoiseSpeed);
    out.v_NoiseTexCoord.x = _76.x;
    out.v_NoiseTexCoord.y = _76.y;
    float2 _101 = (float2(in.a_TexCoord.y, -in.a_TexCoord.x) * 0.63300001621246337890625) + ((float2(-_42.g_Time, _42.g_Time) * 0.5) * _42.g_NoiseSpeed);
    out.v_NoiseTexCoord.w = _101.x;
    out.v_NoiseTexCoord.z = _101.y;
    out.v_NoiseTexCoord *= _42.g_NoiseScale;
    return out;
}

