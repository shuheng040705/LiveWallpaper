#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float2 g_PointerPosition;
    float u_ShiftValue;
    float u_ShiftStrength;
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
    float u_AudioShift [[user(locn0)]];
    float4 v_TexCoord [[user(locn3)]];
};

static inline __attribute__((always_inline))
float3 rgb2hsv(thread const float3& RGB)
{
    float4 _67;
    if (RGB.y < RGB.z)
    {
        _67 = float4(RGB.zy, -1.0, 0.666666686534881591796875);
    }
    else
    {
        _67 = float4(RGB.yz, 0.0, -0.3333333432674407958984375);
    }
    float4 P = _67;
    float4 _92;
    if (RGB.x < P.x)
    {
        _92 = float4(P.xyw, RGB.x);
    }
    else
    {
        _92 = float4(RGB.x, P.yzx);
    }
    float4 Q = _92;
    float C = Q.x - fast::min(Q.w, Q.y);
    float H = abs(((Q.w - Q.y) / ((6.0 * C) + 1.0000000133514319600180897396058e-10)) + Q.z);
    float3 HCV = float3(H, C, Q.x);
    float S = HCV.y / (HCV.z + 1.0000000133514319600180897396058e-10);
    return float3(HCV.x, S, HCV.z);
}

static inline __attribute__((always_inline))
float3 hsv2rgb(thread const float3& c)
{
    float4 K = float4(1.0, 0.666666686534881591796875, 0.3333333432674407958984375, 3.0);
    float3 p = abs((fract(c.xxx + K.xyz) * 6.0) - K.www);
    return mix(K.xxx, fast::clamp(p - K.xxx, float3(0.0), float3(1.0)), float3(c.y)) * c.z;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _171 [[buffer(0)]], texture2d<float> g_Texture2 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture2Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float flowPhase = g_Texture2.sample(g_Texture2Smplr, (in.v_TexCoord.xy * _171.g_FlowPhaseScale)).x;
    float2 flowColors = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).xy;
    float2 flowMask = (flowColors - float2(0.4979999959468841552734375)) * 2.0;
    float flowAmount = length(flowMask);
    float4 cycles = float4(fract(_171.g_Time * _171.g_FlowSpeed), fract((_171.g_Time * _171.g_FlowSpeed) + 0.5), fract(0.25 + (_171.g_Time * _171.g_FlowSpeed)), fract((0.25 + (_171.g_Time * _171.g_FlowSpeed)) + 0.5));
    float blend = 2.0 * abs(cycles.x - 0.5);
    float blend2 = 2.0 * abs(cycles.z - 0.5);
    cycles -= float4(0.5);
    float4 flowUVOffset = ((flowMask.xyxy * _171.g_FlowAmp) * 0.100000001490116119384765625) * cycles.xxyy;
    float4 flowUVOffset2 = ((flowMask.xyxy * _171.g_FlowAmp) * 0.100000001490116119384765625) * cycles.zzww;
    float warp = _171.g_Time * in.u_AudioShift;
    float4 albedo = mix(g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset.xy)), g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset.zw)), float4(blend));
    float4 flowAlbedo = mix(g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset.xy)), g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset.zw)), float4(blend));
    float4 flowAlbedo2 = mix(g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset2.xy)), g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord.xy + flowUVOffset2.zw)), float4(blend2));
    float3 param = albedo.xyz;
    float3 _334 = rgb2hsv(param);
    flowAlbedo.x = _334.x;
    flowAlbedo.y = _334.y;
    flowAlbedo.z = _334.z;
    flowAlbedo.x = fract((flowAlbedo.x / _171.u_ShiftStrength) + warp);
    float3 param_1 = flowAlbedo.xyz;
    float3 _354 = hsv2rgb(param_1);
    flowAlbedo.x = _354.x;
    flowAlbedo.y = _354.y;
    flowAlbedo.z = _354.z;
    float3 param_2 = albedo.xyz;
    float3 _364 = rgb2hsv(param_2);
    flowAlbedo2.x = _364.x;
    flowAlbedo2.y = _364.y;
    flowAlbedo2.z = _364.z;
    flowAlbedo2.x = fract((flowAlbedo2.x / _171.u_ShiftStrength) + warp);
    float3 param_3 = flowAlbedo2.xyz;
    float3 _383 = hsv2rgb(param_3);
    flowAlbedo2.x = _383.x;
    flowAlbedo2.y = _383.y;
    flowAlbedo2.z = _383.z;
    flowAlbedo = mix(flowAlbedo, flowAlbedo2, float4(smoothstep(0.20000000298023223876953125, 0.800000011920928955078125, flowPhase)));
    out._fragColor = mix(albedo, flowAlbedo, float4(flowAmount));
    return out;
}

