#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Length;
    float g_Intensity;
    float3 g_ColorRays;
    float2 g_Center;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _22 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 texCoords = in.v_TexCoord;
    float4 albedo = float4(0.0);
    float2 direction = _22.g_Center - texCoords;
    float dist = length(direction);
    direction /= float2(dist);
    dist *= _22.g_Length;
    texCoords += (direction * dist);
    direction = (direction * dist) / float2(49.0);
    for (int i = 0; i < 50; i++)
    {
        float4 samp_ = g_Texture0.sample(g_Texture0Smplr, texCoords);
        texCoords -= direction;
        albedo += (samp_ * (float(i) / 49.0));
    }
    float4 _91 = albedo;
    float3 _93 = _91.xyz * _22.g_ColorRays;
    albedo.x = _93.x;
    albedo.y = _93.y;
    albedo.z = _93.z;
    out._fragColor = float4(albedo.xyz * (_22.g_Intensity * 0.0599999986588954925537109375), fast::clamp((_22.g_Intensity * 0.0599999986588954925537109375) * albedo.w, 0.0, 1.0));
    return out;
}

