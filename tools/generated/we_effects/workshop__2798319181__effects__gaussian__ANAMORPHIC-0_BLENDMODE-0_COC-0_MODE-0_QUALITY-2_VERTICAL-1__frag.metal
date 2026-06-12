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
    float qualityNormalizer [[user(locn0)]];
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
    depth *= (0.20000000298023223876953125 * in.qualityNormalizer);
    depth = fast::clamp(0.0, 0.1500000059604644775390625, depth);
    bool _76 = depth > 0.00999999977648258209228515625;
    bool _82;
    if (_76)
    {
        _82 = _56.u_aperture > 0.00999999977648258209228515625;
    }
    else
    {
        _82 = _76;
    }
    if (_82)
    {
        float4 startAlbedo = albedo;
        float2 offset = float2(0.0);
        float2 pixelStep = in.v_PixelSize * depth;
        for (int i = -2; i <= 2; i++)
        {
            offset.y = float(i) * pixelStep.y;
            float4 _117 = albedo;
            float3 _119 = _117.xyz + g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + offset)).xyz;
            albedo.x = _119.x;
            albedo.y = _119.y;
            albedo.z = _119.z;
        }
        float4 _130 = albedo;
        float3 _133 = _130.xyz / float3(6.0);
        albedo.x = _133.x;
        albedo.y = _133.y;
        albedo.z = _133.z;
    }
    float4 baseAlbedo = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord);
    float3 param = baseAlbedo.xyz;
    float3 param_1 = albedo.xyz;
    float param_2 = _56.u_alpha * fast::clamp((depth * 9.0) * _56.u_aperture, 0.0, 1.0);
    albedo = float4(ApplyBlending(0, param, param_1, param_2), albedo.w);
    out._fragColor = albedo;
    return out;
}

