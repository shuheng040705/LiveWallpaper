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
    float3 v_Bitangent [[user(locn0)]];
    float3 v_Normal [[user(locn2)]];
    float3 v_Tangent [[user(locn4)]];
    float4 v_TexCoord [[user(locn5)]];
    float4 v_ViewDir [[user(locn7)]];
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

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _54 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], texture2d<float> g_Texture1 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]], sampler g_Texture1Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 color = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy) * _54.g_Color4;
    float metallic = _54.g_Metallic;
    float roughness = _54.g_Roughness;
    float4 componentMaps = g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.zw);
    float2 compressedNormal = (g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy).xy * 2.0) - float2(1.0);
    float3 normal = float3(compressedNormal, sqrt(fast::clamp((1.0 - (compressedNormal.x * compressedNormal.x)) - (compressedNormal.y * compressedNormal.y), 0.0, 1.0)));
    normal = fast::normalize(normal);
    float3 normalizedViewVector = fast::normalize(in.v_ViewDir.xyz);
    float3x3 tangentSpace = float3x3(float3(in.v_Tangent), float3(in.v_Bitangent), float3(in.v_Normal));
    normal = tangentSpace * normal;
    float3 f0 = float3(0.039999999105930328369140625);
    f0 = mix(f0, color.xyz, float3(metallic));
    float3 param = in.v_WorldPos;
    float3 param_1 = color.xyz;
    float3 param_2 = normal;
    float3 param_3 = normalizedViewVector;
    float3 param_4 = _54.g_SpecularTint;
    float3 param_5 = f0;
    float param_6 = roughness;
    float param_7 = metallic;
    float3 light = PerformLighting_Deprecated(param, param_1, param_2, param_3, param_4, param_5, param_6, param_7);
    float3 ambient = _54.g_LightAmbientColor * color.xyz;
    float3 param_8 = light;
    float3 param_9 = ambient;
    float3 _187 = CombineLighting(param_8, param_9);
    color.x = _187.x;
    color.y = _187.y;
    color.z = _187.z;
    out._fragColor = color;
    return out;
}

