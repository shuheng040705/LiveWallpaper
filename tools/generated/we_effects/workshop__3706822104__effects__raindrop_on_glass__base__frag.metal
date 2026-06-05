#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture0Resolution;
    float g_Time;
    float u_rainAmount;
    float u_backgroundBlur;
    float u_rainSpeed;
    float u_dropDensity;
    float u_fogStrength;
    float u_vignetteStrength;
    float3 u_dropShadowColor;
    float3 u_dropHighlightColor;
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
float s(thread const float& a, thread const float& b, thread const float& t)
{
    return smoothstep(a, b, t);
}

static inline __attribute__((always_inline))
float3 n13(thread const float& p)
{
    float3 p3 = fract(float3(p) * float3(0.103100001811981201171875, 0.113689996302127838134765625, 0.13786999881267547607421875));
    p3 += float3(dot(p3, p3.yzx + float3(19.1900005340576171875)));
    return fract(float3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
}

static inline __attribute__((always_inline))
float saw(thread const float& b, thread const float& t)
{
    float param = 0.0;
    float param_1 = b;
    float param_2 = t;
    float param_3 = 1.0;
    float param_4 = b;
    float param_5 = t;
    return s(param, param_1, param_2) * s(param_3, param_4, param_5);
}

static inline __attribute__((always_inline))
float staticDrops(thread const float2& uv_in, thread const float& t)
{
    float2 uv = uv_in * 40.0;
    float2 id = floor(uv);
    uv = fract(uv) - float2(0.5);
    float param = (id.x * 107.4499969482421875) + (id.y * 3543.654052734375);
    float3 _noise = n13(param);
    float2 p = (_noise.xy - float2(0.5)) * 0.699999988079071044921875;
    float d = length(uv - p);
    float param_1 = 0.02500000037252902984619140625;
    float param_2 = fract(t + _noise.z);
    float fade = saw(param_1, param_2);
    float param_3 = 0.300000011920928955078125;
    float param_4 = 0.0;
    float param_5 = d;
    return (s(param_3, param_4, param_5) * fract(_noise.z * 10.0)) * fade;
}

static inline __attribute__((always_inline))
float n(thread const float& t)
{
    return fract(sin(t * 12345.564453125) * 7658.759765625);
}

static inline __attribute__((always_inline))
float2 dropLayer2(thread const float2& uv_in, thread const float& t, constant _Globals& _157)
{
    float2 uv_base = uv_in;
    float2 uv = uv_in;
    uv.y += (t * 0.75);
    float2 a = float2(_157.u_dropDensity, 1.0);
    float2 grid = a * 2.0;
    float2 id = floor(uv * grid);
    float param = id.x;
    float col_shift = n(param);
    uv.y += col_shift;
    id = floor(uv * grid);
    float param_1 = (id.x * 35.200000762939453125) + (id.y * 2376.10009765625);
    float3 _noise = n13(param_1);
    float2 st = fract(uv * grid) - float2(0.5, 0.0);
    float x = _noise.x - 0.5;
    float y = uv_base.y * 20.0;
    float wiggle = sin(y + sin(y));
    x += ((wiggle * (0.5 - abs(x))) * (_noise.z - 0.5));
    x *= 0.699999988079071044921875;
    float ti = fract(t + _noise.z);
    float param_2 = 0.85000002384185791015625;
    float param_3 = ti;
    y = ((saw(param_2, param_3) - 0.5) * 0.89999997615814208984375) + 0.5;
    float2 p = float2(x, y);
    float d = length((st - p) * a.yx);
    float param_4 = 0.4000000059604644775390625;
    float param_5 = 0.0;
    float param_6 = d;
    float main_drop = s(param_4, param_5, param_6);
    float param_7 = 1.0;
    float param_8 = y;
    float param_9 = st.y;
    float r = sqrt(s(param_7, param_8, param_9));
    float cd = abs(st.x - x);
    float param_10 = 0.23000000417232513427734375 * r;
    float param_11 = (0.1500000059604644775390625 * r) * r;
    float param_12 = cd;
    float trail = s(param_10, param_11, param_12);
    float param_13 = -0.0199999995529651641845703125;
    float param_14 = 0.0199999995529651641845703125;
    float param_15 = st.y - y;
    float trail_front = s(param_13, param_14, param_15);
    trail *= ((trail_front * r) * r);
    y = uv_base.y;
    float param_16 = 0.20000000298023223876953125 * r;
    float param_17 = 0.0;
    float param_18 = cd;
    float trail2 = s(param_16, param_17, param_18);
    float droplets = ((fast::max(0.0, sin((y * (1.0 - y)) * 120.0) - st.y) * trail2) * trail_front) * _noise.z;
    y = fract(y * 10.0) + (st.y - 0.5);
    float dd = length(st - float2(x, y));
    float param_19 = 0.300000011920928955078125;
    float param_20 = 0.0;
    float param_21 = dd;
    droplets = s(param_19, param_20, param_21);
    float mask = main_drop + ((droplets * r) * trail_front);
    return float2(mask, trail);
}

static inline __attribute__((always_inline))
float2 drops(thread const float2& uv, thread const float& t, thread const float& l0, thread const float& l1, thread const float& l2, constant _Globals& _157)
{
    float2 param = uv;
    float param_1 = t;
    float s0 = staticDrops(param, param_1) * l0;
    float2 param_2 = uv;
    float param_3 = t;
    float2 m1 = dropLayer2(param_2, param_3, _157) * l1;
    float2 param_4 = uv * 1.85000002384185791015625;
    float param_5 = t;
    float2 m2 = dropLayer2(param_4, param_5, _157) * l2;
    float c = (s0 + m1.x) + m2.x;
    float param_6 = 0.300000011920928955078125;
    float param_7 = 1.0;
    float param_8 = c;
    c = s(param_6, param_7, param_8);
    return float2(c, fast::max(m1.y * l0, m2.y * l1));
}

static inline __attribute__((always_inline))
float3 sampleBackground(thread const float2& uv, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    float2 sample_uv = fast::clamp(uv, float2(0.0), float2(1.0));
    return g_Texture0.sample(g_Texture0Smplr, sample_uv).xyz;
}

static inline __attribute__((always_inline))
float3 frostedGlass(thread const float2& texture_uv, thread const float2& normal, thread const float& blur, constant _Globals& _157, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    float2 base = fast::clamp(texture_uv + normal, float2(0.0), float2(1.0));
    float2 px = float2(blur) / _157.g_Texture0Resolution.xy;
    float3 col = float3(0.0);
    float2 param = base;
    col += (sampleBackground(param, g_Texture0, g_Texture0Smplr) * 0.20000000298023223876953125);
    float2 param_1 = base + float2(px.x, 0.0);
    col += (sampleBackground(param_1, g_Texture0, g_Texture0Smplr) * 0.12999999523162841796875);
    float2 param_2 = base - float2(px.x, 0.0);
    col += (sampleBackground(param_2, g_Texture0, g_Texture0Smplr) * 0.12999999523162841796875);
    float2 param_3 = base + float2(0.0, px.y);
    col += (sampleBackground(param_3, g_Texture0, g_Texture0Smplr) * 0.12999999523162841796875);
    float2 param_4 = base - float2(0.0, px.y);
    col += (sampleBackground(param_4, g_Texture0, g_Texture0Smplr) * 0.12999999523162841796875);
    float2 param_5 = base + px;
    col += (sampleBackground(param_5, g_Texture0, g_Texture0Smplr) * 0.070000000298023223876953125);
    float2 param_6 = base - px;
    col += (sampleBackground(param_6, g_Texture0, g_Texture0Smplr) * 0.070000000298023223876953125);
    float2 param_7 = base + float2(px.x, -px.y);
    col += (sampleBackground(param_7, g_Texture0, g_Texture0Smplr) * 0.070000000298023223876953125);
    float2 param_8 = base + float2(-px.x, px.y);
    col += (sampleBackground(param_8, g_Texture0, g_Texture0Smplr) * 0.070000000298023223876953125);
    return col;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _157 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float2 uv = in.v_TexCoord;
    float2 flipped_uv = float2(uv.x, 1.0 - uv.y);
    float2 resolution = _157.g_Texture0Resolution.xy;
    float2 frag_coord = flipped_uv * resolution;
    float2 rain_uv = (frag_coord - (resolution * 0.5)) / float2(resolution.y);
    float rain_amount = fast::clamp(_157.u_rainAmount, 0.0, 1.0);
    float t = _157.g_Time * _157.u_rainSpeed;
    float param = -0.5;
    float param_1 = 1.0;
    float param_2 = rain_amount;
    float static_drops = s(param, param_1, param_2) * 2.0;
    float param_3 = 0.25;
    float param_4 = 0.75;
    float param_5 = rain_amount;
    float layer1 = s(param_3, param_4, param_5);
    float param_6 = 0.0;
    float param_7 = 0.5;
    float param_8 = rain_amount;
    float layer2 = s(param_6, param_7, param_8);
    float2 param_9 = rain_uv;
    float param_10 = t;
    float param_11 = static_drops;
    float param_12 = layer1;
    float param_13 = layer2;
    float2 c = drops(param_9, param_10, param_11, param_12, param_13, _157);
    float2 e = float2(0.001000000047497451305389404296875, 0.0);
    float2 param_14 = rain_uv + e;
    float param_15 = t;
    float param_16 = static_drops;
    float param_17 = layer1;
    float param_18 = layer2;
    float cx = drops(param_14, param_15, param_16, param_17, param_18, _157).x;
    float2 param_19 = rain_uv + e.yx;
    float param_20 = t;
    float param_21 = static_drops;
    float param_22 = layer1;
    float param_23 = layer2;
    float cy = drops(param_19, param_20, param_21, param_22, param_23, _157).x;
    float2 normal = float2(cx - c.x, cy - c.x);
    float min_blur = 2.5;
    float max_blur = mix(4.0, 7.0, rain_amount);
    float param_24 = 0.07999999821186065673828125;
    float param_25 = 0.2199999988079071044921875;
    float param_26 = c.x;
    float focus = mix(max_blur - c.y, min_blur, s(param_24, param_25, param_26));
    float2 texture_normal = float2(normal.x, -normal.y) * 1.2000000476837158203125;
    float blur = fast::max(0.0, focus * _157.u_backgroundBlur);
    float2 param_27 = uv;
    float2 param_28 = texture_normal;
    float param_29 = blur;
    float3 col = frostedGlass(param_27, param_28, param_29, _157, g_Texture0, g_Texture0Smplr);
    float fog = smoothstep(min_blur, max_blur, focus);
    col = mix(col, float3(0.7200000286102294921875, 0.7400000095367431640625, 0.7799999713897705078125), float3(fog * _157.u_fogStrength));
    col += (_157.u_dropHighlightColor * c.y);
    col += ((_157.u_dropShadowColor * c.x) * 0.119999997317790985107421875);
    float2 vignette_uv = flipped_uv - float2(0.5);
    float vignette = 1.0 - (dot(vignette_uv, vignette_uv) * _157.u_vignetteStrength);
    col *= vignette;
    out._fragColor = float4(col, 1.0);
    return out;
}

