#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float4 g_Texture0Resolution;
    float g_GlitterScale;
    float g_GlitterOpacity;
    float3 g_GlitterColor;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, A + (A * B), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _57 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float2 glitterCoords = in.v_TexCoord.xy;
    glitterCoords.x *= (_57.g_Texture0Resolution.x / _57.g_Texture0Resolution.y);
    float glitter = g_Texture1.sample(g_Texture1Smplr, (glitterCoords * _57.g_GlitterScale)).x;
    float3 glitterColor = _57.g_GlitterColor * glitter;
    float3 param = albedo.xyz;
    float3 param_1 = glitterColor;
    float param_2 = _57.g_GlitterOpacity * mask;
    float3 _101 = ApplyBlending(32, param, param_1, param_2);
    albedo.x = _101.x;
    albedo.y = _101.y;
    albedo.z = _101.z;
    out._fragColor = albedo;
    return out;
}

