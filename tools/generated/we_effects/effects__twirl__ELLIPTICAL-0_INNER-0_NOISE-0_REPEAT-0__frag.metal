#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_SpinCenter;
    float g_Size;
    float g_Feather;
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
    float4 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _62 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float aspect = in.v_TexCoord.z;
    float2 texCoord = in.v_TexCoord.xy;
    texCoord -= _62.g_SpinCenter;
    texCoord.x *= aspect;
    float feather = smoothstep((_62.g_Size + _62.g_Feather) + 9.9999997473787516355514526367188e-06, _62.g_Size - _62.g_Feather, length(texCoord));
    float dist = length(texCoord) / _62.g_Size;
    float anim = in.v_TexCoord.w * dist;
    float2 param = texCoord;
    float param_1 = anim;
    texCoord = rotateVec2(param, param_1);
    texCoord.x /= aspect;
    texCoord += _62.g_SpinCenter;
    texCoord = mix(in.v_TexCoord.xy, texCoord, float2(feather));
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    float mask = 1.0;
    out._fragColor = mix(g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy), out._fragColor, float4(mask));
    return out;
}

