#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Time;
    float u_brightness;
    float u_glow;
    float u_scale;
    float u_speed;
    float u_timeoffset;
    float u_distortion;
    float u_chromatic;
    float u_blur;
    float3 u_color1;
    float3 u_color2;
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
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, fast::max(B, A), float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _52 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture4 [[texture(1)]], texture2d<float> g_Texture3 [[texture(2)]], texture2d<float> g_Texture2 [[texture(3)]], texture2d<float> g_Texture5 [[texture(4)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture4Smplr [[sampler(1)]], sampler g_Texture3Smplr [[sampler(2)]], sampler g_Texture2Smplr [[sampler(3)]], sampler g_Texture5Smplr [[sampler(4)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float mask = 1.0;
    float ratio = _52.g_Texture0Resolution.x / _52.g_Texture0Resolution.y;
    float2 causticsCoords = in.v_TexCoord.xy;
    causticsCoords.x *= ratio;
    causticsCoords *= _52.u_scale;
    float2 noiseCoords = causticsCoords;
    float2 noiseCoords2 = causticsCoords;
    float2 blendCoords = causticsCoords;
    float2 shiftCoords = causticsCoords;
    noiseCoords *= 0.0199999995529651641845703125;
    noiseCoords2 *= 0.0333000011742115020751953125;
    blendCoords *= 0.013330000452697277069091796875;
    shiftCoords *= 0.0500000007450580596923828125;
    float time = (_52.g_Time * _52.u_speed) + _52.u_timeoffset;
    noiseCoords.x += (time * 0.004999999888241291046142578125);
    noiseCoords2.y += (time * 0.0041109998710453510284423828125);
    blendCoords += float2(time * 0.00377699988894164562225341796875);
    shiftCoords += float2(time * 0.00999999977648258209228515625);
    float4 shiftColor = (g_Texture4.sample(g_Texture4Smplr, shiftCoords) * 2.0) - float4(1.0);
    float4 noiseColor = (g_Texture3.sample(g_Texture3Smplr, noiseCoords) * 2.0) - float4(1.0);
    float4 noiseColor2 = (g_Texture3.sample(g_Texture3Smplr, noiseCoords2) * 2.0) - float4(1.0);
    causticsCoords += ((noiseColor.xy * 0.02500000037252902984619140625) * _52.u_distortion);
    causticsCoords += ((noiseColor2.xy * 0.02500000037252902984619140625) * _52.u_distortion);
    causticsCoords += (shiftColor.xy * _52.u_distortion);
    float2 causticsCoordsLeft = causticsCoords;
    float2 causticsCoordsRight = causticsCoords;
    causticsCoordsLeft.x -= (0.00999999977648258209228515625 * _52.u_chromatic);
    causticsCoordsRight.x += (0.00999999977648258209228515625 * _52.u_chromatic);
    float3 caustics = float3(g_Texture2.sample(g_Texture2Smplr, causticsCoordsLeft).x, g_Texture2.sample(g_Texture2Smplr, causticsCoords).x, g_Texture2.sample(g_Texture2Smplr, causticsCoordsRight).x);
    float glowSample = g_Texture5.sample(g_Texture5Smplr, causticsCoords).x;
    float4 blendColor = g_Texture3.sample(g_Texture3Smplr, blendCoords);
    caustics = mix(caustics, float3(glowSample), float3(_52.u_blur));
    float causticsSample = dot(caustics, float3(0.3333300054073333740234375));
    causticsSample = smoothstep(blendColor.x * 0.800000011920928955078125, 1.0 - (blendColor.y * 0.20000000298023223876953125), causticsSample + (glowSample * _52.u_glow));
    float3 causticsColor = mix(_52.u_color1, _52.u_color2, float3(blendColor.x)) * _52.u_brightness;
    causticsColor *= caustics;
    float3 param = albedo.xyz;
    float3 param_1 = causticsColor;
    float param_2 = mask * causticsSample;
    float3 _286 = ApplyBlending(6, param, param_1, param_2);
    albedo.x = _286.x;
    albedo.y = _286.y;
    albedo.z = _286.z;
    out._fragColor = albedo;
    return out;
}

