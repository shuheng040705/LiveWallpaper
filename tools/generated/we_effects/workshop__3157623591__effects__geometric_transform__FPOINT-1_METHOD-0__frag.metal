#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_osCurvature;
    float u_osStrength;
    float u_osRadialStrength;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 _we_ro_v_TexCoord [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _24 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 v_TexCoord = in._we_ro_v_TexCoord;
    float d = abs(v_TexCoord.x - 0.5) * _24.u_osCurvature;
    float offset = sqrt(0.25 - (d * d));
    v_TexCoord.y += (offset * _24.u_osStrength);
    v_TexCoord.x = mix(v_TexCoord.x, (sign(v_TexCoord.x - 0.5) * (0.5 - offset)) + 0.5, _24.u_osRadialStrength * abs(_24.u_osStrength));
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, v_TexCoord);
    out._fragColor = albedo;
    return out;
}

