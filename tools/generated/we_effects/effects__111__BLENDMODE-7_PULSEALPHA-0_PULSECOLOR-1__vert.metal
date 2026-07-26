#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float g_Time;
    float g_StrikeSpeed;
    float g_StrikeErratic;
    float g_StrikeAmount;
};

struct main0_out
{
    float v_LightningIntensity [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float hash11(thread const float& p)
{
    return fract(sin((p * 127.09999847412109375) + 311.70001220703125) * 43758.546875);
}

static inline __attribute__((always_inline))
float noise1D(thread const float& p)
{
    float i = floor(p);
    float f = fract(p);
    f = (f * f) * (3.0 - (2.0 * f));
    float param = i;
    float param_1 = i + 1.0;
    return mix(hash11(param), hash11(param_1), f);
}

static inline __attribute__((always_inline))
float LightningTiming(thread const float& time, thread const float& speed, thread const float& erratic, thread const float& amount)
{
    float t = time * speed;
    float param = t * 0.100000001490116119384765625;
    float gate = noise1D(param);
    float param_1 = (t * 0.3499999940395355224609375) + 3.0;
    float param_2 = (t * 0.25) + 7.0;
    float cluster = (noise1D(param_1) * noise1D(param_2)) * gate;
    float burst = smoothstep(0.100000001490116119384765625, 0.3499999940395355224609375, cluster + (erratic * 0.02999999932944774627685546875));
    float dt = 0.039999999105930328369140625;
    float param_3 = t * 4.0;
    float param_4 = (t - dt) * 4.0;
    float d1 = fast::max(0.0, noise1D(param_3) - noise1D(param_4)) * 6.0;
    float param_5 = (t * 6.0) + 5.0;
    float param_6 = ((t - dt) * 6.0) + 5.0;
    float d2 = fast::max(0.0, noise1D(param_5) - noise1D(param_6)) * 6.0;
    float param_7 = (t * 9.0) + 11.0;
    float param_8 = ((t - dt) * 9.0) + 11.0;
    float d3 = fast::max(0.0, noise1D(param_7) - noise1D(param_8)) * 6.0;
    float flash = fast::max(d1, fast::max(d2, d3)) * burst;
    return fast::clamp(flash * amount, 0.0, 1.0);
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _174 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _174.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float param = _174.g_Time;
    float param_1 = _174.g_StrikeSpeed;
    float param_2 = _174.g_StrikeErratic;
    float param_3 = _174.g_StrikeAmount;
    out.v_LightningIntensity = LightningTiming(param, param_1, param_2, param_3);
    return out;
}

