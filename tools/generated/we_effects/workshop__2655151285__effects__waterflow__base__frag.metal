#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float g_FlowSpeed;
    float g_FlowAmp;
    float g_FlowPhaseScale;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _22 [[buffer(0)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float flowPhase = g_Texture2.sample(g_Texture2Smplr, (in.v_TexCoord.xy * _22.g_FlowPhaseScale)).x;
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.4979999959468841552734375)) * 2.0;
    float flowAmount = length(flowMask);
    float4 cycles = float4(fract(_22.g_Time * _22.g_FlowSpeed), fract((_22.g_Time * _22.g_FlowSpeed) + 0.5), fract(0.25 + (_22.g_Time * _22.g_FlowSpeed)), fract((0.25 + (_22.g_Time * _22.g_FlowSpeed)) + 0.5));
    float blend = 2.0 * abs(cycles.x - 0.5);
    float blend2 = 2.0 * abs(cycles.z - 0.5);
    cycles -= float4(0.5);
    float4 flowUVOffset = ((flowMask.xyxy * _22.g_FlowAmp) * 0.100000001490116119384765625) * cycles.xxyy;
    float4 flowUVOffset2 = ((flowMask.xyxy * _22.g_FlowAmp) * 0.100000001490116119384765625) * cycles.zzww;
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 flowAlbedo = mix(g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset.xy)), g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset.zw)), float4(blend));
    float4 flowAlbedo2 = mix(g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset2.xy)), g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset2.zw)), float4(blend2));
    flowAlbedo = mix(flowAlbedo, flowAlbedo2, float4(smoothstep(0.20000000298023223876953125, 0.800000011920928955078125, flowPhase)));
    out._fragColor = mix(albedo, flowAlbedo, float4(flowAmount));
    return out;
}

