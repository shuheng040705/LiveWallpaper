#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float g_Speed;
    float2 g_Scale;
    float g_Smoothness;
    float2 g_Feather;
    float g_Radius;
    float g_NoiseScale;
    float g_NoiseAmount;
    float g_Intensity;
    float g_Exponent;
    float3 g_ColorRaysStart;
    packed_float3 g_ColorRaysEnd;
    float g_StartAngle;
    float g_EndAngle;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float3 v_TexCoordFx [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _57 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 fxCoord = in.v_TexCoordFx.xy / float2(in.v_TexCoordFx.z);
    float4 albedo = float4(0.0);
    float mask = step(0.0, in.v_TexCoordFx.z);
    float2 shapeScale = _57.g_Scale;
    float2 rayCenter = float2(0.0);
    float2 rayDelta = fxCoord - rayCenter;
    rayDelta.x = 1.0 - rayDelta.x;
    fxCoord.x = (precise::atan2(rayDelta.y, rayDelta.x) / 6.28318500518798828125) * 4.0;
    fxCoord.y = fast::max(rayDelta.x, rayDelta.y);
    fxCoord.y += ((g_Texture1.sample(g_Texture1Smplr, float2((fxCoord.x * 0.0541110001504421234130859375) * _57.g_NoiseScale, 0.0)).x * _57.g_NoiseAmount) - (_57.g_NoiseAmount * 0.5));
    fxCoord.y = smoothstep(_57.g_Radius, 1.0, fxCoord.y);
    float2 fxCoordRef = fxCoord;
    shapeScale.x *= 4.0;
    mask *= smoothstep(0.500010013580322265625, 0.5 - _57.g_Feather.x, abs(fxCoord.x - 0.5));
    mask *= smoothstep(0.500010013580322265625, 0.5 - _57.g_Feather.y, abs(fxCoord.y - 0.5));
    float grad = 1.0 - fxCoord.y;
    mask *= grad;
    float2 fxCoord2 = fxCoord;
    fxCoord *= float2(0.0541110001504421234130859375 * shapeScale.x, 0.00311099993996322154998779296875 * shapeScale.y);
    fxCoord2 *= float2(0.07333000004291534423828125 * shapeScale.x, 0.0059671108610928058624267578125 * shapeScale.y);
    fxCoord += (float2(0.0030000000260770320892333984375, 0.000375111005268990993499755859375) * (_57.g_Time * _57.g_Speed));
    fxCoord2 -= (float2(0.004711099900305271148681640625, 0.0007398999878205358982086181640625) * (_57.g_Time * _57.g_Speed));
    float fx0 = g_Texture1.sample(g_Texture1Smplr, fxCoord).x;
    float fx1 = g_Texture1.sample(g_Texture1Smplr, fxCoord2).x;
    float fx = fx0 * fx1;
    fx = powr(fx, _57.g_Exponent);
    fx = smoothstep((1.0 - _57.g_Smoothness) * 0.299989998340606689453125, 0.300000011920928955078125 + (_57.g_Smoothness * 0.699999988079071044921875), fx);
    float2 gradientUVs = float2(fxCoordRef.y, 0.0);
    float3 gradColor = g_Texture2.sample(g_Texture2Smplr, gradientUVs).xyz;
    float3 fxColor = gradColor;
    fx *= mask;
    float3 param = albedo.xyz;
    float3 param_1 = fxColor * _57.g_Intensity;
    float param_2 = fx;
    float3 _270 = ApplyBlending(31, param, param_1, param_2);
    albedo.x = _270.x;
    albedo.y = _270.y;
    albedo.z = _270.z;
    albedo.w = fast::max(albedo.w, fx);
    out._fragColor = albedo;
    return out;
}

