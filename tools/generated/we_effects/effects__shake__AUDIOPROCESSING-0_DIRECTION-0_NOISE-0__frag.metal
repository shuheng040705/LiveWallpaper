#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float g_Speed;
    float g_Amp;
    float2 g_Friction;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_Bounds [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _36 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float flowPhase = 0.0;
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.4979999959468841552734375)) * 2.0;
    float offset = 0.0;
    float time = (_36.g_Speed * _36.g_Time) + flowPhase;
    offset = sin(fract(time / 6.283185482025146484375) * 6.283185482025146484375);
    offset = (offset * 0.4979999959468841552734375) + 0.5;
    float base = step(0.0, cos(time));
    offset = mix(1.0 - powr(1.0 - offset, _36.g_Friction.x), powr(offset, _36.g_Friction.y), base);
    offset = fast::clamp((offset - in.v_Bounds.x) * in.v_Bounds.y, 0.0, 1.0);
    offset = (offset * 2.0) - 1.0;
    float2 texCoordOffset = flowMask * ((offset * _36.g_Amp) * _36.g_Amp);
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, (texCoordOffset + in.v_TexCoord.xy));
    return out;
}

