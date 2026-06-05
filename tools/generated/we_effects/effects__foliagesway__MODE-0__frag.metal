#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Speed;
    float g_Power;
    float g_Phase;
    float g_Time;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float3 v_Params [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float4 v_TexCoordNoise [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _53 [[buffer(0)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float3 _noise = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoordNoise.xy).xyz;
    float amp = in.v_Params.z;
    float phase = ((((_noise.y * 3.1415927410125732421875) * 2.0) + (in.v_Params.x * 10.0)) + (in.v_Params.y * 5.0)) * _53.g_Phase;
    float4 sines = float4(phase) + (float4(1.0, -0.16161616146564483642578125, 0.008333300240337848663330078125, -0.00019840999448206275701522827148438) * (_53.g_Speed * _53.g_Time));
    sines = sin(sines);
    float4 csines = float4(0.4000000059604644775390625 + phase) + (float4(-0.5, 0.041666664183139801025390625, -0.001388888922519981861114501953125, 2.4801587642286904156208038330078e-05) * (_53.g_Speed * _53.g_Time));
    csines = sin(csines);
    sines = powr(abs(sines), float4(_53.g_Power)) * sign(sines);
    csines = powr(abs(csines), float4(_53.g_Power)) * sign(csines);
    float2 texCoordOffset;
    texCoordOffset.x = in.v_TexCoordNoise.z * dot(sines, float4(amp));
    texCoordOffset.y = in.v_TexCoordNoise.w * dot(csines, float4(amp));
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, (texCoordOffset + in.v_TexCoord.xy));
    return out;
}

