#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float g_FlowSpeed;
    float g_FlowPhaseScale;
    float g_CloudsAlpha;
    float g_CloudThreshold;
    float g_CloudFeather;
    float g_CloudLOD;
    float g_CloudScale;
    float g_Distortion;
    float3 g_Color1;
    float3 g_Color2;
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

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _50 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.4979999959468841552734375)) * 2.0;
    float scaledTime = _50.g_Time * _50.g_FlowSpeed;
    float2 cycles = float2(fract(scaledTime), fract(scaledTime + 0.5));
    float blend = 2.0 * abs(cycles.x - 0.5);
    float2 flowUVOffset1 = ((flowMask * _50.g_CloudScale) * 0.1500000059604644775390625) * (cycles.x - 0.5);
    float2 flowUVOffset2 = ((flowMask * _50.g_CloudScale) * 0.1500000059604644775390625) * (cycles.y - 0.5);
    float cloudBackground = g_Texture2.sample(g_Texture2Smplr, ((in.v_TexCoord.xy * _50.g_CloudScale) + float2(scaledTime * 0.100000001490116119384765625)), level(_50.g_CloudLOD)).x;
    float cloud0 = g_Texture2.sample(g_Texture2Smplr, ((in.v_TexCoord.xy * _50.g_CloudScale) + flowUVOffset1), level(_50.g_CloudLOD)).x;
    float cloud1 = g_Texture2.sample(g_Texture2Smplr, ((in.v_TexCoord.xy * _50.g_CloudScale) + flowUVOffset2), level(_50.g_CloudLOD)).x;
    float streamNoise = mix(cloud0, cloud1, blend);
    float2 baseUV = in.v_TexCoord.xy;
    float flowMaskLength = powr(length(flowMask), 2.0);
    baseUV += (((((mix(flowMask, -flowMask, float2(streamNoise)) * cloudBackground) * 0.5) * streamNoise) * flowMaskLength) * _50.g_Distortion);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, baseUV);
    streamNoise = fract(streamNoise + (scaledTime * 0.20000000298023223876953125));
    float colorNoise = smoothstep(0.0, 0.5, streamNoise) * smoothstep(1.0, 0.5, streamNoise);
    float3 cloudColor = mix(_50.g_Color2, _50.g_Color1, float3(colorNoise));
    float blendNoise = mix(colorNoise * flowMaskLength, 1.0, powr(flowMaskLength, 4.0));
    blendNoise = smoothstep(_50.g_CloudThreshold, _50.g_CloudThreshold + _50.g_CloudFeather, blendNoise);
    float streamBlend = _50.g_CloudsAlpha * blendNoise;
    float3 param = albedo.xyz;
    float3 param_1 = cloudColor;
    float param_2 = streamBlend;
    float3 _236 = ApplyBlending(0, param, param_1, param_2);
    albedo.x = _236.x;
    albedo.y = _236.y;
    albedo.z = _236.z;
    out._fragColor = albedo;
    return out;
}

