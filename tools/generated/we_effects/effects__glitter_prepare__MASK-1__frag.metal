#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float g_Speed;
    float g_Density;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_NoiseCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _21 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], sampler g_Texture1Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = float4(1.0);
    float3 effectAlbedo = albedo.xyz;
    float density = _21.g_Density * _21.g_Density;
    float time = (_21.g_Time * _21.g_Speed) * density;
    float2 noiseCoord = in.v_NoiseCoord;
    float4 noise0 = g_Texture1.sample(g_Texture1Smplr, noiseCoord);
    noise0.x *= (1.0 - noise0.y);
    float timer0 = fract((noise0.x * 100.0) + time);
    float glitterDensity = density * 0.5;
    float glitter0 = smoothstep(0.5 - glitterDensity, 0.5, timer0) * smoothstep(0.5 + glitterDensity, 0.5, timer0);
    glitter0 = smoothstep(0.5, 1.0, glitter0);
    glitter0 *= glitter0;
    effectAlbedo = float3(glitter0);
    albedo.x = effectAlbedo.x;
    albedo.y = effectAlbedo.y;
    albedo.z = effectAlbedo.z;
    out._fragColor = albedo;
    return out;
}

