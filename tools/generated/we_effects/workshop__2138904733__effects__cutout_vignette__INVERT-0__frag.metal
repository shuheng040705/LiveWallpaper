#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    char _m1_pad[12];
    packed_float3 u_CutOutColor;
    float u_CutOutAlpha;
    float u_scale;
    float u_offset;
    float u_smoothstep1;
    float u_smoothstep2;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_CutUV [[user(locn1)]];
    float3 v_TexCoord [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _29 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float3 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy).xyz;
    float scale = powr(length(abs(in.v_TexCoord.xy - float2(_29.u_offset)) * 1.0), 3.0) * _29.u_scale;
    float cutAmount = dot(in.v_CutUV, in.v_CutUV) + scale;
    cutAmount = smoothstep(_29.u_smoothstep1, _29.u_smoothstep2, cutAmount) * _29.u_CutOutAlpha;
    albedo = mix(albedo, float3(_29.u_CutOutColor), float3(cutAmount));
    out._fragColor = float4(albedo, 1.0);
    return out;
}

