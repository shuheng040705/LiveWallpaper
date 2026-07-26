#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
    float2 u_textureOffset;
    float2 u_textureScale;
    float2 u_maskOffset;
    float2 u_maskScale;
    float2 u_texScaleCenter;
    float2 u_maskScaleCenter;
    packed_float3 u_baseColor;
    float u_weight;
    float u_threshold;
    float u_alpha;
    float2 u_textureDepth;
    float2 u_maskDepth;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _50 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float2 uvTex = ((((((((in.v_TexCoord.xy * 2.0) - float2(1.0)) - ((_50.u_texScaleCenter * 2.0) - float2(1.0))) / float2(_50.g_Texture1Resolution.x / _50.g_Texture1Resolution.y, _50.g_Texture0Resolution.x / _50.g_Texture0Resolution.y)) / _50.u_textureScale) + float2(1.0)) + ((_50.u_texScaleCenter * 2.0) - float2(1.0))) / float2(2.0)) - _50.u_textureOffset;
    float2 uvMask = (((((((in.v_TexCoord.xy * 2.0) - float2(1.0)) - ((_50.u_maskScaleCenter * 2.0) - float2(1.0))) / _50.u_maskScale) + float2(1.0)) + ((_50.u_maskScaleCenter * 2.0) - float2(1.0))) / float2(2.0)) - _50.u_maskOffset;
    float4 clip = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy);
    float mask = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.xy).x;
    float4 target = clip;
    float3 param = albedo.xyz;
    float3 param_1 = target.xyz;
    float param_2 = (mask * albedo.w) * _50.u_alpha;
    float3 _157 = ApplyBlending(0, param, param_1, param_2);
    albedo.x = _157.x;
    albedo.y = _157.y;
    albedo.z = _157.z;
    out._fragColor = albedo;
    return out;
}

