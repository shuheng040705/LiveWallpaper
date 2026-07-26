#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_Direction;
    float u_Strength;
    float u_CenterFalloff;
    float2 u_Center;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _17 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 delta = in.v_TexCoord.xy - _17.u_Center;
    float falloff = mix(0.5 / (length(delta) + 9.9999997473787516355514526367188e-05), 1.0, _17.u_CenterFalloff);
    delta *= ((_17.u_Strength * 0.00999999977648258209228515625) * falloff);
    float2 coords0 = in.v_TexCoord.xy + delta;
    float2 coords1 = in.v_TexCoord.xy - delta;
    float4 sc = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float4 s0 = g_Texture0.sample(g_Texture0Smplr, coords0);
    float4 s1 = g_Texture0.sample(g_Texture0Smplr, coords1);
    float4 albedo = sc;
    albedo.y = s1.y;
    albedo.z = s0.z;
    out._fragColor = albedo;
    return out;
}

