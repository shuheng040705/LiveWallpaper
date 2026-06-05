#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ViewProjectionMatrix;
    float4 g_Color4;
    float g_Roughness;
    float g_Metallic;
    float3 g_SpecularTint;
    packed_float3 g_EmissiveColor;
    float g_EmissiveBrightness;
    float3 g_LightAmbientColor;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn5)]];
    float4 v_ViewDir [[user(locn7)]];
    float3 v_WorldNormal [[user(locn8)]];
    float3 v_WorldPos [[user(locn9)]];
};

static inline __attribute__((always_inline))
float3 PerformLighting_Deprecated(thread const float3& worldPos, thread const float3& color, thread const float3& normal, thread const float3& viewVector, thread const float3& specularTint, thread const float3& ambient, thread const float& roughness, thread const float& metallic)
{
    float3 light = float3(0.0);
    return light;
}

static inline __attribute__((always_inline))
float3 CombineLighting(thread const float3& light, thread const float3& ambient)
{
    return ambient + light;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _53 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 color = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord) * _53.g_Color4;
    float metallic = _53.g_Metallic;
    float roughness = _53.g_Roughness;
    float3 normal = fast::normalize(in.v_WorldNormal);
    float3 normalizedViewVector = fast::normalize(in.v_ViewDir.xyz);
    float3 f0 = float3(0.039999999105930328369140625);
    f0 = mix(f0, color.xyz, float3(metallic));
    float3 param = in.v_WorldPos;
    float3 param_1 = color.xyz;
    float3 param_2 = normal;
    float3 param_3 = normalizedViewVector;
    float3 param_4 = _53.g_SpecularTint;
    float3 param_5 = f0;
    float param_6 = roughness;
    float param_7 = metallic;
    float3 light = PerformLighting_Deprecated(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7);
    float3 ambient = _53.g_LightAmbientColor * color.xyz;
    float3 param_8 = light;
    float3 param_9 = ambient;
    float3 _123 = CombineLighting(param_8, param_9);
    color.x = _123.x;
    color.y = _123.y;
    color.z = _123.z;
    out._fragColor = color;
    return out;
}

