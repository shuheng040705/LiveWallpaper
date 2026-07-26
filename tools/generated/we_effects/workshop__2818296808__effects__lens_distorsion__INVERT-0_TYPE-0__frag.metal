#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_distorsion;
    float u_radius;
    float u_aberration;
    float2 u_center;
    float u_focusLength;
    float u_general;
    float4 g_Texture0Resolution;
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
float2 computeUV(thread float2& uv, thread const float& amount, thread const float& radius, constant _Globals& _23)
{
    uv = ((uv - float2(0.5)) * float2(_23.g_Texture0Resolution.x / _23.g_Texture0Resolution.y, 1.0)) * 2.0;
    float2 radial = float2(0.0);
    float2 tangential = float2(0.0);
    float2 center = ((float2(1.0) - _23.u_center) - float2(0.5)) * _23.u_general;
    float focusLength = 1.0 / _23.u_focusLength;
    radial += ((uv * ((1.0 + (amount * powr(length(uv), 2.0))) + (radius * powr(length(uv), 4.0)))) * focusLength);
    tangential.x = (((2.0 * center.x) * uv.x) * uv.y) + (center.y * (length(uv) + ((2.0 * uv.x) * uv.x)));
    tangential.y = (center.x * (length(uv) + ((2.0 * uv.y) * uv.y))) + (((2.0 * center.y) * uv.x) * uv.y);
    return ((radial + tangential) / (float2(_23.g_Texture0Resolution.x / _23.g_Texture0Resolution.y, 1.0) * 2.0)) + float2(0.5);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _23 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float offset = (_23.u_aberration * 0.100000001490116119384765625) * _23.u_general;
    float distortion = _23.u_distorsion * _23.u_general;
    float radius = _23.u_radius * _23.u_general;
    float2 param = in.v_TexCoord.xy;
    float param_1 = distortion + offset;
    float param_2 = radius;
    float2 _182 = computeUV(param, param_1, param_2, _23);
    float red = g_Texture0.sample(g_Texture0Smplr, _182).x;
    float2 param_3 = in.v_TexCoord.xy;
    float param_4 = distortion;
    float param_5 = radius;
    float2 _194 = computeUV(param_3, param_4, param_5, _23);
    float green = g_Texture0.sample(g_Texture0Smplr, _194).y;
    float2 param_6 = in.v_TexCoord.xy;
    float param_7 = distortion - offset;
    float param_8 = radius;
    float2 _208 = computeUV(param_6, param_7, param_8, _23);
    float blue = g_Texture0.sample(g_Texture0Smplr, _208).z;
    float2 param_9 = in.v_TexCoord.xy;
    float param_10 = distortion;
    float param_11 = radius;
    float2 _221 = computeUV(param_9, param_10, param_11, _23);
    float alpha = g_Texture0.sample(g_Texture0Smplr, _221).w;
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.xy).x;
    out._fragColor = mix(g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy), float4(red, green, blue, alpha), float4(mask));
    return out;
}

