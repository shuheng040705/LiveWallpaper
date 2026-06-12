#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Implementation of the GLSL mod() function, which is slightly different than Metal fmod()
template<typename Tx, typename Ty>
inline Tx mod(Tx x, Ty y)
{
    return x - y * floor(x / y);
}

struct _Globals
{
    float u_frequency;
    float u_strength1;
    float u_amount1;
    float u_size1;
    float u_strength2;
    float u_amount2;
    float u_offset2;
    float u_brightness;
    float u_saturation;
    float u_curvature;
    float u_resolution;
    float u_bloom;
    float u_alpha;
    float2 u_borders;
    float g_Time;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float3 v_PerspCoord [[user(locn0)]];
    float2 v_TexCoord [[user(locn1)]];
};

static inline __attribute__((always_inline))
float3 bloom(thread float3& color, thread const float2& uv, constant _Globals& _35, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    color = powr(color, float3(_35.u_bloom));
    float2 right = float2(0.00200000009499490261077880859375, 0.0);
    float2 up = float2(0.0, 0.00200000009499490261077880859375);
    float3 colorT = g_Texture0.sample(g_Texture0Smplr, (uv + up)).xyz;
    float3 colorB = g_Texture0.sample(g_Texture0Smplr, (uv - up)).xyz;
    float3 colorL = g_Texture0.sample(g_Texture0Smplr, (uv - right)).xyz;
    float3 colorR = g_Texture0.sample(g_Texture0Smplr, (uv + right)).xyz;
    color += ((((colorT + colorB) + colorL) + colorR) * 0.0500000007450580596923828125);
    return powr(color, float3(1.0 / _35.u_bloom));
}

static inline __attribute__((always_inline))
float3 saturation(thread float3& color, constant _Globals& _35)
{
    float3 weights_ = float3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875);
    float luminance_ = dot(color, weights_);
    color = mix(float3(luminance_), color, float3(_35.u_saturation));
    return color;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _35 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 baseAlbedo = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord);
    float opacity = _35.u_alpha * 1.0;
    opacity *= baseAlbedo.w;
    if (opacity > 0.001000000047497451305389404296875)
    {
        float2 perspCoord = (in.v_PerspCoord.xy / float2(in.v_PerspCoord.z)) - float2(0.5);
        float2 perspUV = perspCoord * _35.u_borders;
        float z = sqrt((0.5 - ((perspUV.x * perspUV.x) * _35.u_curvature)) - ((perspUV.y * perspUV.y) * _35.u_curvature));
        float2 uv = perspUV / float2(fast::max(9.9999997473787516355514526367188e-05, z * 0.7070000171661376953125));
        float2 uvImage = ((in.v_TexCoord - float2(0.5)) / float2(fast::max(9.9999997473787516355514526367188e-05, z * (1.414000034332275390625 * (1.0 + (_35.u_curvature * 0.100000001490116119384765625)))))) + float2(0.5);
        float4 albedo = float4(1.0);
        float3 param = g_Texture0.sample(g_Texture0Smplr, uvImage).xyz;
        float2 param_1 = uvImage;
        float3 _216 = bloom(param, param_1, _35, g_Texture0, g_Texture0Smplr);
        albedo.x = _216.x;
        albedo.y = _216.y;
        albedo.z = _216.z;
        float4 _227 = albedo;
        float3 _229 = _227.xyz * (1.0 - (length(perspCoord) * 1.0));
        albedo.x = _229.x;
        albedo.y = _229.y;
        albedo.z = _229.z;
        float4 image = albedo;
        float3 param_2 = albedo.xyz;
        float3 _241 = saturation(param_2, _35);
        albedo.x = _241.x;
        albedo.y = _241.y;
        albedo.z = _241.z;
        float4 _254 = albedo;
        float3 _256 = _254.xyz * (_35.u_brightness + _35.u_brightness);
        albedo.x = _256.x;
        albedo.y = _256.y;
        albedo.z = _256.z;
        float speed = _35.g_Time * _35.u_frequency;
        float4 _291 = albedo;
        float3 _293 = _291.xyz * (1.0 - (fast::min(1.0, mod((1.0 - (uv.y * _35.u_amount1)) + speed, 1.0) * _35.u_size1) * _35.u_strength1));
        albedo.x = _293.x;
        albedo.y = _293.y;
        albedo.z = _293.z;
        float4 _322 = albedo;
        float3 _324 = _322.xyz * (1.0 - (abs(mod((1.0 - ((uv.y + _35.u_offset2) * _35.u_amount2)) + speed, 2.0) - 1.0) * _35.u_strength2));
        albedo.x = _324.x;
        albedo.y = _324.y;
        albedo.z = _324.z;
        albedo *= smoothstep(0.5099999904632568359375, 0.5, fast::max(abs(uv.x), abs(uv.y)));
        float4 _344 = albedo;
        float3 _357 = mix(baseAlbedo.xyz, _344.xyz, float3(step(fast::max(abs(perspCoord.x), abs(perspCoord.y)), 0.5) * opacity));
        albedo.x = _357.x;
        albedo.y = _357.y;
        albedo.z = _357.z;
        albedo.w = baseAlbedo.w;
        out._fragColor = albedo;
    }
    else
    {
        out._fragColor = baseAlbedo;
    }
    return out;
}

