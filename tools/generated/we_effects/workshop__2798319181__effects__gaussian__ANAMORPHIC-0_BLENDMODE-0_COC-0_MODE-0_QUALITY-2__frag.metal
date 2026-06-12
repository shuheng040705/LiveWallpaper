#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_alpha;
    float u_aperture;
    float u_ratio;
    float2 g_TexelSize;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float qualityNormalizer [[user(locn0)]];
    float2 v_PixelSize [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _39 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float2 depthTex = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord).xy;
    float depth = fast::max(depthTex.x, depthTex.y) * _39.u_aperture;
    depth *= (0.20000000298023223876953125 * in.qualityNormalizer);
    depth = fast::clamp(0.0, 0.1500000059604644775390625, depth);
    bool _60 = depth > 0.00999999977648258209228515625;
    bool _66;
    if (_60)
    {
        _66 = _39.u_aperture > 0.00999999977648258209228515625;
    }
    else
    {
        _66 = _60;
    }
    if (_66)
    {
        float4 startAlbedo = albedo;
        float2 offset = float2(0.0);
        float2 pixelStep = in.v_PixelSize * depth;
        for (int i = -2; i <= 2; i++)
        {
            offset.x = float(i) * pixelStep.x;
            float4 _102 = albedo;
            float3 _104 = _102.xyz + g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + offset)).xyz;
            albedo.x = _104.x;
            albedo.y = _104.y;
            albedo.z = _104.z;
        }
        float4 _115 = albedo;
        float3 _118 = _115.xyz / float3(6.0);
        albedo.x = _118.x;
        albedo.y = _118.y;
        albedo.z = _118.z;
    }
    out._fragColor = albedo;
    return out;
}

