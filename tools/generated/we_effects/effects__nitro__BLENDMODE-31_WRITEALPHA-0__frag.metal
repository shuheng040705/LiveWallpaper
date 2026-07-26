#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_NitroAlpha;
    float3 g_NitroColor0;
    float3 g_NitroColor1;
    float2 g_NitroRanges;
    float g_NitroLOD;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
    float4 v_TexCoordNitro [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _53 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float nitro0 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNitro.xy, level(_53.g_NitroLOD)).x;
    float nitro1 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordNitro.zw, level(_53.g_NitroLOD)).x;
    float remap = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy).x;
    float2 noiseBase = _53.g_NitroRanges;
    float coreNoise = smoothstep(nitro0, nitro1, 0.100000001490116119384765625 + (remap * 0.800000011920928955078125));
    float nitro = smoothstep(noiseBase.y, noiseBase.x, nitro0 * nitro1) * smoothstep(noiseBase.x, noiseBase.y, nitro0 * nitro1);
    nitro = (coreNoise * nitro) * 4.0;
    float3 nitroColor = mix(_53.g_NitroColor0, _53.g_NitroColor1, float3(nitro));
    float blend = nitro * _53.g_NitroAlpha;
    float3 param = albedo.xyz;
    float3 param_1 = nitroColor;
    float param_2 = blend;
    float3 _140 = ApplyBlending(31, param, param_1, param_2);
    albedo.x = _140.x;
    albedo.y = _140.y;
    albedo.z = _140.z;
    out._fragColor = float4(fast::max(float3(0.0), albedo.xyz), albedo.w);
    return out;
}

