#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float g_Speed;
    float g_Scale;
    float g_Exponent;
    float g_Strength;
    float g_Speed2;
    float g_Scale2;
    float g_Offset2;
    float g_Exponent2;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_Direction [[user(locn0)]];
    float2 v_Direction2 [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _33 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float mask = 1.0;
    float2 texCoord = in.v_TexCoord.xy;
    float2 texCoordMotion = texCoord;
    float pos = abs(dot(texCoordMotion - float2(0.5), in.v_Direction));
    float _distance = (_33.g_Time * _33.g_Speed) + (dot(texCoordMotion, in.v_Direction) * _33.g_Scale);
    float distance2 = ((_33.g_Time + _33.g_Offset2) * _33.g_Speed2) + (dot(texCoordMotion, in.v_Direction2) * _33.g_Scale2);
    float strength = _33.g_Strength * _33.g_Strength;
    float2 offset = float2(in.v_Direction.y, -in.v_Direction.x);
    float val1 = sin(_distance);
    float s1 = sign(val1);
    val1 = powr(abs(val1), _33.g_Exponent);
    float2 offset2 = float2(in.v_Direction2.y, -in.v_Direction2.x);
    float val2 = sin(distance2);
    float s2 = sign(val2);
    val2 = powr(abs(val2), _33.g_Exponent2);
    texCoord += (((offset * (((val1 * s1) * val2) * s2)) * strength) * mask);
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

