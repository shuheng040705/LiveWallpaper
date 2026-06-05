#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_RippleStrength;
    float g_ShadingAmount;
    float3 g_ShadingHigh;
    packed_float3 g_ShadingLow;
    float g_ShadingDirection;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _52 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 srcCoords = in.v_TexCoord;
    float2 rippleCoords = in.v_TexCoord;
    float rippleMask = 1.0;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, rippleCoords);
    albedo *= albedo;
    float2 dir = float2(albedo.x - albedo.z, albedo.y - albedo.w);
    float distortAmt = _52.g_RippleStrength;
    float2 offset = dir;
    offset *= (((-0.100000001490116119384765625) * distortAmt) * rippleMask);
    float4 screen = g_Texture1.sample(g_Texture1Smplr, (srcCoords + offset));
    out._fragColor = screen;
    return out;
}

