#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_aperture;
    float u_focusDepth;
    float u_focusScale;
    float u_multiplier;
    float u_exponent;
    float u_offset;
    float2 u_focusPoint;
    float2 u_depthBounds;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

fragment main0_out main0()
{
    main0_out out = {};
    out._fragColor = float4(1.0);
    return out;
}

