#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float u_DirectionAngle;
    float u_Amount;
    float u_Feather;
    float u_Speed;
    float u_BlendAmount;
    float u_NoiseScale;
    float u_NoiseSpeed;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn1)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _38 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float alpha = 1.0;
    float4 t0 = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 t1 = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord);
    float2 quantizedUV = floor(in.v_TexCoord * 32.0) / float2(32.0);
    quantizedUV += float2(fract(_38.g_Time * 0.001000000047497451305389404296875));
    float pixelLife = fract((sin((quantizedUV.x * 1000.0) + (quantizedUV.y * 1234.0)) * _38.u_BlendAmount) * 10.0);
    float pixelMask = step(0.800000011920928955078125, pixelLife) * alpha;
    float4 pixelColor = mix(t0, t1, float4(smoothstep(0.0, 1.0, _38.u_BlendAmount) * alpha));
    out._fragColor = select(pixelColor, t1, bool4(pixelMask == 1.0));
    return out;
}

