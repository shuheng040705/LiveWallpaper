#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_CloudsAlpha;
    float g_CloudThreshold;
    float g_CloudFeather;
    float g_CloudLOD;
    float3 g_Color1;
    packed_float3 g_Color2;
    float g_Time;
    float4 g_CloudSpeeds;
    float4 g_CloudScales;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
    float3 v_TexCoordPerspective [[user(locn2)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, (A + B) / float3(2.0), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _70 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], texture2d<float> g_Texture2 [[texture(2)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]], sampler g_Texture2Smplr [[sampler(2)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float2 perspectiveCoords = in.v_TexCoordPerspective.xy / float2(in.v_TexCoordPerspective.z);
    float4 cloudTexCoods = perspectiveCoords.xyxy;
    float4 _66 = cloudTexCoods;
    float2 _86 = (_66.xy + (_70.g_CloudSpeeds.xy * _70.g_Time)) * _70.g_CloudScales.xy;
    cloudTexCoods.x = _86.x;
    cloudTexCoods.y = _86.y;
    float4 _93 = cloudTexCoods;
    float2 _105 = (_93.zw + (_70.g_CloudSpeeds.zw * _70.g_Time)) * _70.g_CloudScales.zw;
    cloudTexCoods.z = _105.x;
    cloudTexCoods.w = _105.y;
    float _112 = cloudTexCoods.w;
    float _115 = cloudTexCoods.z;
    float2 _116 = float2(-_112, _115);
    cloudTexCoods.z = _116.x;
    cloudTexCoods.w = _116.y;
    float cloud0 = g_Texture1.sample(g_Texture1Smplr, cloudTexCoods.xy, level(_70.g_CloudLOD)).x;
    float cloud1 = g_Texture1.sample(g_Texture1Smplr, cloudTexCoods.zw, level(_70.g_CloudLOD)).x;
    float cloudBlend = cloud0 * cloud1;
    float3 cloudColor = float3(1.0);
    cloudBlend = smoothstep(_70.g_CloudThreshold, _70.g_CloudThreshold + _70.g_CloudFeather, cloudBlend);
    float blend = cloudBlend * _70.g_CloudsAlpha;
    blend *= step(0.0, in.v_TexCoordPerspective.z);
    cloudColor = (mix(float3(_70.g_Color2), _70.g_Color1, float3(blend)) * cloud0) * cloud1;
    blend *= g_Texture2.sample(g_Texture2Smplr, in.v_TexCoord.zw).x;
    float3 param = albedo.xyz;
    float3 param_1 = cloudColor;
    float param_2 = blend;
    float3 _199 = ApplyBlending(24, param, param_1, param_2);
    albedo.x = _199.x;
    albedo.y = _199.y;
    albedo.z = _199.z;
    out._fragColor = albedo;
    return out;
}

