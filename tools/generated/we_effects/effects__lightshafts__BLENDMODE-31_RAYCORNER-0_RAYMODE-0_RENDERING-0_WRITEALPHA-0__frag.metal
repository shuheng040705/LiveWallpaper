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
    float4 v_TexCoord [[user(locn0)]];
    float3 v_TexCoordFx [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _66 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 fxCoord = in.v_TexCoordFx.xy / float2(in.v_TexCoordFx.z);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = step(0.0, in.v_TexCoordFx.z);
    float2 shapeScale = _66.g_Scale;
    float2 fxCoordRef = fxCoord;
    mask *= smoothstep(0.500010013580322265625, 0.5 - _66.g_Feather.x, abs(fxCoord.x - 0.5));
    mask *= smoothstep(0.500010013580322265625, 0.5 - _66.g_Feather.y, abs(fxCoord.y - 0.5));
    float grad = 1.0 - fxCoord.y;
    mask *= grad;
    float2 fxCoord2 = fxCoord;
    fxCoord *= float2(0.0541110001504421234130859375 * shapeScale.x, 0.00311099993996322154998779296875 * shapeScale.y);
    fxCoord2 *= float2(0.07333000004291534423828125 * shapeScale.x, 0.0059671108610928058624267578125 * shapeScale.y);
    fxCoord += (float2(0.0030000000260770320892333984375, 0.000375111005268990993499755859375) * (_66.g_Time * _66.g_Speed));
    fxCoord2 -= (float2(0.004711099900305271148681640625, 0.0007398999878205358982086181640625) * (_66.g_Time * _66.g_Speed));
    float fx0 = g_Texture1.sample(g_Texture1Smplr, fxCoord).x;
    float fx1 = g_Texture1.sample(g_Texture1Smplr, fxCoord2).x;
    float fx = fx0 * fx1;
    fx = powr(fx, _66.g_Exponent);
    fx = smoothstep((1.0 - _66.g_Smoothness) * 0.299989998340606689453125, 0.300000011920928955078125 + (_66.g_Smoothness * 0.699999988079071044921875), fx);
    float3 fxColor = mix(_66.g_ColorRaysStart, float3(_66.g_ColorRaysEnd), float3(fxCoordRef.y));
    fx *= mask;
    float3 param = albedo.xyz;
    float3 param_1 = fxColor * _66.g_Intensity;
    float param_2 = fx;
    float3 _216 = ApplyBlending(31, param, param_1, param_2);
    albedo.x = _216.x;
    albedo.y = _216.y;
    albedo.z = _216.z;
    albedo.w = fast::max(albedo.w, fx);
    out._fragColor = albedo;
    return out;
}

