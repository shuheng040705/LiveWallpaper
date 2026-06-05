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
    packed_float3 g_Screen;
    float g_Reflectivity;
    float g_ReflectivityDistance;
    float g_Texture3MipMapInfo;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float3 v_Bitangent [[user(locn0)]];
    float3 v_Normal [[user(locn2)]];
    float3 v_ScreenPos [[user(locn3)]];
    float3 v_Tangent [[user(locn4)]];
    float2 v_TexCoord [[user(locn5)]];
    float4 v_ViewDir [[user(locn7)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _24 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture3 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture3Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 color = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord) * _24.g_Color4;
    float metallic = _24.g_Metallic;
    float roughness = _24.g_Roughness;
    float2 compressedNormal = (g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord).xy * 2.0) - float2(1.0);
    float3 normal = float3(compressedNormal, sqrt(fast::clamp((1.0 - (compressedNormal.x * compressedNormal.x)) - (compressedNormal.y * compressedNormal.y), 0.0, 1.0)));
    normal = fast::normalize(normal);
    float3 normalizedViewVector = fast::normalize(in.v_ViewDir.xyz);
    float3x3 tangentSpace = float3x3(float3(in.v_Tangent), float3(in.v_Bitangent), float3(in.v_Normal));
    normal = tangentSpace * normal;
    float2 screenUV = ((in.v_ScreenPos.xy / float2(in.v_ScreenPos.z)) * 0.5) + float2(0.5);
    float reflectivity = _24.g_Reflectivity;
    float2 tangent = fast::normalize(in.v_Tangent.xy);
    float2 bitangent = fast::normalize(in.v_Bitangent.xy);
    float fresnelTerm = fast::max(0.001000000047497451305389404296875, dot(normal, normalizedViewVector));
    normal = fast::normalize(float3x3(_24.g_ViewProjectionMatrix[0].xyz, _24.g_ViewProjectionMatrix[1].xyz, _24.g_ViewProjectionMatrix[2].xyz) * normal);
    float3 _157 = normal;
    float2 _165 = _157.xy * float2(0.1500000059604644775390625, 0.1500000059604644775390625 * _24.g_Screen[2u]);
    normal.x = _165.x;
    normal.y = _165.y;
    screenUV += ((normal.xy * powr(fresnelTerm, 4.0)) * _24.g_ReflectivityDistance);
    float3 reflectionColor = g_Texture3.sample(g_Texture3Smplr, screenUV, level(roughness * _24.g_Texture3MipMapInfo)).xyz;
    reflectionColor = (reflectionColor * (1.0 - fresnelTerm)) * reflectivity;
    reflectionColor = powr(fast::max(float3(0.001000000047497451305389404296875), reflectionColor), float3(2.0 - metallic));
    float4 _212 = color;
    float3 _214 = _212.xyz + (fast::clamp(reflectionColor, float3(0.0), float3(1.0)) * fresnelTerm);
    color.x = _214.x;
    color.y = _214.y;
    color.z = _214.z;
    out._fragColor = color;
    return out;
}

