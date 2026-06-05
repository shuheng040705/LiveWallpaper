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

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _35 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_TexCoord.z *= (_35.g_Texture1Resolution.z / _35.g_Texture1Resolution.x);
    out.v_TexCoord.w *= (_35.g_Texture1Resolution.w / _35.g_Texture1Resolution.y);
    float2 _70 = in.a_TexCoord + float2(_35.g_Time * _35.g_NoiseSpeed);
    out.v_NoiseTexCoord.x = _70.x;
    out.v_NoiseTexCoord.y = _70.y;
    float2 _95 = (float2(in.a_TexCoord.y, -in.a_TexCoord.x) * 0.63300001621246337890625) + ((float2(-_35.g_Time, _35.g_Time) * 0.5) * _35.g_NoiseSpeed);
    out.v_NoiseTexCoord.w = _95.x;
    out.v_NoiseTexCoord.z = _95.y;
    out.v_NoiseTexCoord *= _35.g_NoiseScale;
    return out;
}

