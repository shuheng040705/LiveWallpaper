#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture0Resolution;
    float g_Time;
    float g_Speed;
    float g_Offset;
    float g_Scale;
    float g_Exponent;
    float g_Strength;
    float u_GlobleTimeOffset;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_Direction [[user(locn0)]];
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
    _distance += (_33.u_GlobleTimeOffset * 6.283185482025146484375);
    float2 strength = ((float2(500.0) / _33.g_Texture0Resolution.xy) * _33.g_Strength) * _33.g_Strength;
    float2 offset = float2(in.v_Direction.y, -in.v_Direction.x);
    float val1 = sin(_distance) + _33.g_Offset;
    float s1 = sign(val1);
    val1 = powr(abs(val1), _33.g_Exponent);
    texCoord += (((offset * (val1 * s1)) * strength) * mask);
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    return out;
}

