#pragma clang diagnostic ignored "-Wmissing-prototypes"

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

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _56 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], texture2d<float> g_Texture1 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]], sampler g_Texture1Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float2 depthTex = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord).xy;
    float depth = fast::max(depthTex.x, depthTex.y) * _56.u_aperture;
    depth *= (float(depth < 0.60000002384185791015625) * 6.0);
    depth *= 0.20000000298023223876953125;
    bool _78 = depth > 0.00999999977648258209228515625;
    bool _84;
    if (_78)
    {
        _84 = _56.u_aperture > 0.00999999977648258209228515625;
    }
    else
    {
        _84 = _78;
    }
    if (_84)
    {
        float4 startAlbedo = albedo;
        float2 offset = float2(0.0);
        float2 pixelStep = in.v_PixelSize * depth;
        for (int i = -3; i <= 3; i++)
        {
            offset.y = float(i) * pixelStep.y;
            float4 _119 = albedo;
            float3 _121 = _119.xyz + g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + offset)).xyz;
            albedo.x = _121.x;
            albedo.y = _121.y;
            albedo.z = _121.z;
        }
        float4 _132 = albedo;
        float3 _135 = _132.xyz / float3(8.0);
        albedo.x = _135.x;
        albedo.y = _135.y;
        albedo.z = _135.z;
    }
    float4 baseAlbedo = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord);
    float3 param = baseAlbedo.xyz;
    float3 param_1 = albedo.xyz;
    float param_2 = _56.u_alpha;
    albedo = float4(ApplyBlending(0, param, param_1, param_2), albedo.w);
    out._fragColor = albedo;
    return out;
}

