#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture0Resolution;
    float g_Time;
    char _m2_pad[12];
    packed_float3 color;
    float alpha;
    float speed;
    float skew;
    float ringRadius;
    float ringWidth;
    float ringSegmentCount;
    float ringSegmentWidth;
    float sectorOffset;
    float sectorWidth;
    float sectorSegmentCount;
    float sectorSegmentWidth;
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
float we_mod(thread const float& x, thread const float& y)
{
    return x - (y * floor(x / y));
}

static inline __attribute__((always_inline))
float saw(thread const float& x)
{
    float param = (x * 2.0) + 1.0;
    float param_1 = 2.0;
    return abs(we_mod(param, param_1) - 1.0);
}

static inline __attribute__((always_inline))
float simpleStripes(thread const float& c, thread const float& thresh, thread const float& x)
{
    float t = 1.0 - thresh;
    float param = x * c;
    return (step(t, saw(param)) * float(x >= 0.0)) * float(x <= 1.0);
}

static inline __attribute__((always_inline))
float ring(thread const float& dist, thread const float& width, thread const float& stripeCount, thread const float& stripeThresh, thread const float2& puv)
{
    float param = stripeCount;
    float param_1 = stripeThresh;
    float param_2 = ((puv.x - dist) + (width / 2.0)) / width;
    return simpleStripes(param, param_1, param_2);
}

static inline __attribute__((always_inline))
float sector(thread const float& pos, thread const float& width, thread const float& stripeCount, thread const float& stripeThresh, thread const float2& puv)
{
    float sector_1 = fract(puv.y - fract(pos - (width / 2.0)));
    float param = stripeCount;
    float param_1 = stripeThresh;
    float param_2 = sector_1 / width;
    return simpleStripes(param, param_1, param_2);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _160 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 background = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float2 uv = in.v_TexCoord.xy - float2(0.5);
    uv = float2(length(uv) * 2.0, (precise::atan2(uv.x, uv.y) / 6.283185482025146484375) + 0.5);
    float centerPerimeter = (_160.ringRadius * 2.0) * 3.1415927410125732421875;
    float currentPerimeter = (uv.x * 2.0) * 3.1415927410125732421875;
    float pRatio = currentPerimeter / centerPerimeter;
    uv.y += ((((uv.x - _160.ringRadius) / _160.ringWidth) / pRatio) * _160.skew);
    float t = _160.g_Time;
    float param = _160.ringRadius;
    float param_1 = _160.ringWidth;
    float param_2 = 1.0;
    float param_3 = 1.0;
    float2 param_4 = uv;
    float r = ring(param, param_1, param_2, param_3, param_4);
    float sectorPos = _160.sectorOffset + (t * _160.speed);
    float param_5 = sectorPos;
    float param_6 = _160.sectorWidth;
    float param_7 = _160.sectorSegmentCount;
    float param_8 = _160.sectorSegmentWidth;
    float2 param_9 = uv;
    float s = sector(param_5, param_6, param_7, param_8, param_9);
    float ringSector = r * s;
    float finalAlpha = ringSector * _160.alpha;
    out._fragColor = (background * (1.0 - finalAlpha)) + float4(float3(_160.color) * finalAlpha, 1.0);
    return out;
}

