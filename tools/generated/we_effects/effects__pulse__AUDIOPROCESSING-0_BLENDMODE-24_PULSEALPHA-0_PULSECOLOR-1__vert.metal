#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture1Resolution;
    float g_Time;
    float2 g_PulseThresholds;
    float g_PulseSpeed;
    float g_PulsePhase;
    float g_PulseAmount;
};

struct main0_out
{
    float v_Pulse [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
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
    out.v_Pulse = smoothstep(_20.g_PulseThresholds.x, _20.g_PulseThresholds.y, (sin((_20.g_Time * _20.g_PulseSpeed) + ((_20.g_PulsePhase - 0.25) * 6.283185482025146484375)) * 0.5) + 0.5) * _20.g_PulseAmount;
    return out;
}

