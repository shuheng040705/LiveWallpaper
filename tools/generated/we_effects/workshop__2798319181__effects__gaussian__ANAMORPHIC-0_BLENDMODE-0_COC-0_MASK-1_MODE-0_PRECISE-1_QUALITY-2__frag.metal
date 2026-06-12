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
    float2 v_PixelSize [[user(locn1)]];
    float2 v_TexCoord [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _39 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float2 depthTex = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord).xy;
    float depth = fast::max(depthTex.x, depthTex.y) * _39.u_aperture;
    depth *= (float(depth < 0.60000002384185791015625) * 6.0);
    depth *= 0.20000000298023223876953125;
    bool _62 = depth > 0.00999999977648258209228515625;
    bool _68;
    if (_62)
    {
        _68 = _39.u_aperture > 0.00999999977648258209228515625;
    }
    else
    {
        _68 = _62;
    }
    if (_68)
    {
        float4 startAlbedo = albedo;
        float2 offset = float2(0.0);
        float2 pixelStep = in.v_PixelSize * depth;
        for (int i = -3; i <= 3; i++)
        {
            offset.x = float(i) * pixelStep.x;
            float4 _104 = albedo;
            float3 _106 = _104.xyz + g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + offset)).xyz;
            albedo.x = _106.x;
            albedo.y = _106.y;
            albedo.z = _106.z;
        }
        float4 _117 = albedo;
        float3 _120 = _117.xyz / float3(8.0);
        albedo.x = _120.x;
        albedo.y = _120.y;
        albedo.z = _120.z;
    }
    out._fragColor = albedo;
    return out;
}

