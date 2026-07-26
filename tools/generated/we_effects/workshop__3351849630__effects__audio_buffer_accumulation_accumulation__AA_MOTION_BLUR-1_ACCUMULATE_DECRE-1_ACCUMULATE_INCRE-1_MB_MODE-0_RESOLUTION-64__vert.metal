#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Frametime;
    float g_DecreaseAmount;
    float g_IncreaseAmount;
};

struct main0_out
{
    float3 v_AccumulationRate [[user(locn0)]];
    float v_OpacityThreshold [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float ratePerFrame(thread const float& amountPerSecond, constant _Globals& _16)
{
    return 1.0 - powr(0.001000000047497451305389404296875, 1.0 - (1.0 / ((_16.g_Frametime * amountPerSecond) + 1.0)));
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _16 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float param = _16.g_IncreaseAmount;
    out.v_AccumulationRate.x = ratePerFrame(param, _16);
    float param_1 = _16.g_DecreaseAmount;
    out.v_AccumulationRate.y = ratePerFrame(param_1, _16);
    out.v_OpacityThreshold = (_16.g_Frametime * 0.300000011920928955078125) / _16.g_DecreaseAmount;
    out.v_AccumulationRate.z = 0.0;
    return out;
}

