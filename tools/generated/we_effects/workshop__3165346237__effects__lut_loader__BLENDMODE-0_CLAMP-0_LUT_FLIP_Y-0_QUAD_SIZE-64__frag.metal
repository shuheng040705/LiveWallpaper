#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Multiply;
    float g_TranslucentCompensation;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float blendAmount(thread const float& multiply, thread const float& alpha, constant _Globals& _33)
{
    return multiply + (_33.g_TranslucentCompensation * (1.0 - alpha));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _33 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 textureColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float blueColor = textureColor.z * 63.0;
    float quad1y = floor(floor(blueColor) * 0.125);
    float quad2y = floor(ceil(blueColor) * 0.125);
    float2 texPos1;
    texPos1.x = (((floor(blueColor) - (quad1y * 8.0)) * 0.125) + 0.0009765625) + (0.123046875 * textureColor.x);
    texPos1.y = ((quad1y * 0.125) + 0.0009765625) + (0.123046875 * textureColor.y);
    float2 texPos2;
    texPos2.x = (((ceil(blueColor) - (quad2y * 8.0)) * 0.125) + 0.0009765625) + (0.123046875 * textureColor.x);
    texPos2.y = ((quad2y * 0.125) + 0.0009765625) + (0.123046875 * textureColor.y);
    float param = _33.g_Multiply;
    float param_1 = textureColor.w;
    float3 param_2 = textureColor.xyz;
    float3 param_3 = mix(g_Texture1.sample(g_Texture1Smplr, texPos1, level(0.0)).xyz, g_Texture1.sample(g_Texture1Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
    float param_4 = blendAmount(param, param_1, _33);
    out._fragColor = float4(ApplyBlending(0, param_2, param_3, param_4), textureColor.w);
    return out;
}

