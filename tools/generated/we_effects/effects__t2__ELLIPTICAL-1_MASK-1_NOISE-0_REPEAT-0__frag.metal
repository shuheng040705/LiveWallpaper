#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_SpinCenter;
    float g_Size;
    float g_Amount;
    float g_Speed;
    float g_Aspect;
    float g_Ratio;
    float g_Axis;
    float g_Time;
    float g_NoiseSpeed;
    float g_NoiseAmount;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float3 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _52 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float aspect = _52.g_Aspect;
    float2 texCoord = in.v_TexCoord.xy;
    float dist = 1.0;
    texCoord -= _52.g_SpinCenter;
    texCoord.x *= aspect;
    float2 param = texCoord;
    float param_1 = _52.g_Axis;
    texCoord = rotateVec2(param, param_1);
    texCoord.x *= _52.g_Ratio;
    float anim = (sin(_52.g_Time * _52.g_Speed) * dist) * _52.g_Amount;
    float2 param_2 = texCoord;
    float param_3 = anim;
    texCoord = rotateVec2(param_2, param_3);
    float2 param_4 = texCoord;
    float param_5 = _52.g_Axis;
    texCoord = rotateVec2(param_4, param_5);
    texCoord.x *= _52.g_Ratio;
    texCoord.x /= aspect;
    texCoord += _52.g_SpinCenter;
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    float mask = 1.0;
    mask *= g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy).x;
    out._fragColor = mix(g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy), out._fragColor, float4(mask));
    return out;
}

