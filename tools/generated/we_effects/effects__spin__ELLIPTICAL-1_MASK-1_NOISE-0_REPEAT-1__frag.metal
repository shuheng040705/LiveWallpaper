#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture0Resolution;
    float2 g_SpinCenter;
    float g_Size;
    float g_Feather;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordMask [[user(locn1)]];
    float2 v_TexCoordSoftMask [[user(locn2)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _32 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float2 texCoord = in.v_TexCoord.xy;
    texCoord = fract(texCoord);
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, texCoord);
    float2 maskDelta = in.v_TexCoordSoftMask - _32.g_SpinCenter;
    float mask = smoothstep((_32.g_Size + _32.g_Feather) + 9.9999997473787516355514526367188e-06, _32.g_Size - _32.g_Feather, length(maskDelta));
    mask *= g_Texture1.sample(g_Texture1Smplr, in.v_TexCoordMask).x;
    out._fragColor = mix(g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.zw), out._fragColor, float4(mask));
    return out;
}

