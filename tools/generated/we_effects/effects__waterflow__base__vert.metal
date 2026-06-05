#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture1Resolution;
    float g_Time;
    float g_FlowSpeed;
    float g_PhaseFeather;
};

struct main0_out
{
    float2 v_Blend [[user(locn0)]];
    float4 v_Cycles [[user(locn1)]];
    float4 v_TexCoord [[user(locn3)]];
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
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float _47 = out.v_TexCoord.x;
    float _58 = out.v_TexCoord.y;
    float2 _66 = float2((_47 * _19.g_Texture1Resolution.z) / _19.g_Texture1Resolution.x, (_58 * _19.g_Texture1Resolution.w) / _19.g_Texture1Resolution.y);
    out.v_TexCoord.z = _66.x;
    out.v_TexCoord.w = _66.y;
    float4 cycles = float4(fract(_19.g_Time * _19.g_FlowSpeed), fract((_19.g_Time * _19.g_FlowSpeed) + 0.5), fract(0.25 + (_19.g_Time * _19.g_FlowSpeed)), fract((0.25 + (_19.g_Time * _19.g_FlowSpeed)) + 0.5));
    float blend = 2.0 * abs(cycles.x - 0.5);
    float blend2 = 2.0 * abs(cycles.z - 0.5);
    float2 smoothParams = float2(0.5 - _19.g_PhaseFeather, 0.5 + _19.g_PhaseFeather);
    blend = smoothstep(smoothParams.x, smoothParams.y, blend);
    blend2 = smoothstep(smoothParams.x, smoothParams.y, blend2);
    out.v_Cycles = cycles - float4(0.5);
    out.v_Blend = float2(blend, blend2);
    return out;
}

