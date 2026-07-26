#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_VolumeScale;
    float4 g_AudioSpectrum32Left[32];
    float4 g_AudioSpectrum32Right[32];
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float3 v_AccumulationRate [[user(locn0)]];
    float4 v_TexCoord [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _44 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], sampler g_Texture1Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 pastAlbedo = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy, level(0.0));
    int index = int(floor(in.v_TexCoord.x * 32.0));
    float4 albedo;
    albedo.w = 1.0;
    albedo.z = _44.u_VolumeScale;
    float leftAudio = _44.g_AudioSpectrum32Left[index].x * _44.u_VolumeScale;
    float rightAudio = _44.g_AudioSpectrum32Right[index].x * _44.u_VolumeScale;
    float leftRate = (step(leftAudio * 2.0, pastAlbedo.x + pastAlbedo.z) * in.v_AccumulationRate.y) + (step(pastAlbedo.x + pastAlbedo.z, leftAudio * 2.0) * in.v_AccumulationRate.x);
    float rightRate = (step(rightAudio * 2.0, pastAlbedo.y + pastAlbedo.w) * in.v_AccumulationRate.y) + (step(pastAlbedo.y + pastAlbedo.w, rightAudio * 2.0) * in.v_AccumulationRate.x);
    albedo.x = mix(pastAlbedo.x, fast::min(leftAudio * 2.0, 1.0), leftRate);
    albedo.y = mix(pastAlbedo.y, fast::min(rightAudio * 2.0, 1.0), rightRate);
    albedo.z = mix(pastAlbedo.z, fast::max((leftAudio * 2.0) - 1.0, 0.0), leftRate);
    albedo.w = mix(pastAlbedo.w, fast::max((rightAudio * 2.0) - 1.0, 0.0), rightRate);
    out._fragColor = albedo;
    return out;
}

