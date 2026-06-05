#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float g_Time;
    float2 g_Scale;
    float g_Speed;
    float g_Rough;
    float g_NoiseAmount;
    float g_PhaseOffset;
    float4 g_Texture1Resolution;
};

struct main0_out
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordIris [[user(locn1)]];
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
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float _44 = out.v_TexCoord.x;
    float _55 = out.v_TexCoord.y;
    float2 _63 = float2((_44 * _20.g_Texture1Resolution.z) / _20.g_Texture1Resolution.x, (_55 * _20.g_Texture1Resolution.w) / _20.g_Texture1Resolution.y);
    out.v_TexCoord.z = _63.x;
    out.v_TexCoord.w = _63.y;
    float time = (_20.g_Time * _20.g_Speed) + _20.g_PhaseOffset;
    float lowDt = floor(time);
    float2 motion2 = sin((float2(lowDt) + float2(0.0, 1.0)) * 1.89999997615814208984375);
    float4 motion4 = sin(((float4(lowDt) + float4(0.0, 0.0, 1.0, 1.0)) * 2.5) + float4(1.0, 2.0, 1.0, 2.0));
    float2 moveStart = motion2.xx + motion4.xy;
    float2 moveEnd = motion2.yy + motion4.zw;
    float2 da = mix(moveStart, moveEnd, float2(smoothstep(1.0 - _20.g_Rough, 1.0, (cos(fract(time) * 3.1415927410125732421875) * (-0.5)) + 0.5)));
    da.x += (sin(time) * _20.g_NoiseAmount);
    da.y += (cos(time) * _20.g_NoiseAmount);
    da *= (_20.g_Scale * 0.001000000047497451305389404296875);
    out.v_TexCoordIris = da;
    return out;
}

