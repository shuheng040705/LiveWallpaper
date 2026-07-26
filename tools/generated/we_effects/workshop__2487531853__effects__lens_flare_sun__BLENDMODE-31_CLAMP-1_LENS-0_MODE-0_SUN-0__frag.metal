#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    packed_float3 u_color1;
    float u_DistOpacity;
    float u_Speed;
    float u_Speed1;
    float u_SpeedRot;
    float g_Time;
    float u_Scale;
    float u_SunScale;
    float2 u_OffSet;
    float4 g_Texture1Resolution;
    float4 g_Texture0Resolution;
    float u_pointerSpeed;
    float2 g_PointerPosition;
    float g_Direction;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float4 v_TexCoord [[user(locn5)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

static inline __attribute__((always_inline))
float _noise(thread const float2& t, texture2d<float> g_Texture1, sampler g_Texture1Smplr, constant _Globals& _102)
{
    return g_Texture1.sample(g_Texture1Smplr, (t / _102.g_Texture1Resolution.xy)).x;
}

static inline __attribute__((always_inline))
float _noise(thread const float& t, texture2d<float> g_Texture1, sampler g_Texture1Smplr, constant _Globals& _102)
{
    return g_Texture1.sample(g_Texture1Smplr, (float2(t, 0.0) / _102.g_Texture1Resolution.xy)).x;
}

static inline __attribute__((always_inline))
float3 lensflare(thread float2& uv, thread const float2& pos, texture2d<float> g_Texture1, sampler g_Texture1Smplr, constant _Globals& _102)
{
    float2 param = pos - float2(0.5);
    float param_1 = -_102.g_Direction;
    uv += (_102.u_OffSet + rotateVec2(param, param_1));
    float2 main = uv - pos;
    float2 uvd = uv * length(uv);
    float ang = precise::atan2(main.x, main.y);
    float dist = length(main);
    dist = powr(dist, 0.100000001490116119384765625);
    float2 param_2 = float2(ang * 16.0, dist * 32.0);
    float n = _noise(param_2, g_Texture1, g_Texture1Smplr, _102);
    float f0 = 1.0 / ((length(uv - pos) * _102.u_SunScale) + 1.0);
    float param_3 = (sin((ang * 2.0) + pos.x) * 4.0) - cos((ang * 3.0) + pos.y);
    f0 += (f0 * (((sin(_noise(param_3, g_Texture1, g_Texture1Smplr, _102) * 16.0) * 0.100000001490116119384765625) + (dist * 0.100000001490116119384765625)) + 0.800000011920928955078125));
    float f1 = fast::max(0.00999999977648258209228515625 - powr(length(uv + (pos * 1.2000000476837158203125)), 1.89999997615814208984375), 0.0) * 7.0;
    float f2 = fast::max(1.0 / (1.0 + (32.0 * powr(length(uvd + (pos * 0.800000011920928955078125)), 2.0))), 0.0) * 0.25;
    float f22 = fast::max(1.0 / (1.0 + (32.0 * powr(length(uvd + (pos * 0.85000002384185791015625)), 2.0))), 0.0) * 0.23000000417232513427734375;
    float f23 = fast::max(1.0 / (1.0 + (32.0 * powr(length(uvd + (pos * 0.89999997615814208984375)), 2.0))), 0.0) * 0.20999999344348907470703125;
    float2 uvx = mix(uv, uvd, float2(-0.5));
    float f4 = fast::max(0.00999999977648258209228515625 - powr(length(uvx + (pos * 0.4000000059604644775390625)), 2.400000095367431640625), 0.0) * 6.0;
    float f42 = fast::max(0.00999999977648258209228515625 - powr(length(uvx + (pos * 0.449999988079071044921875)), 2.400000095367431640625), 0.0) * 5.0;
    float f43 = fast::max(0.00999999977648258209228515625 - powr(length(uvx + (pos * 0.5)), 2.400000095367431640625), 0.0) * 3.0;
    uvx = mix(uv, uvd, float2(-0.4000000059604644775390625));
    float f5 = fast::max(0.00999999977648258209228515625 - powr(length(uvx + (pos * 0.20000000298023223876953125)), 5.5), 0.0) * 2.0;
    float f52 = fast::max(0.00999999977648258209228515625 - powr(length(uvx + (pos * 0.4000000059604644775390625)), 5.5), 0.0) * 2.0;
    float f53 = fast::max(0.00999999977648258209228515625 - powr(length(uvx + (pos * 0.60000002384185791015625)), 5.5), 0.0) * 2.0;
    uvx = mix(uv, uvd, float2(-0.5));
    float f6 = fast::max(0.00999999977648258209228515625 - powr(length(uvx - (pos * 0.300000011920928955078125)), 1.60000002384185791015625), 0.0) * 6.0;
    float f62 = fast::max(0.00999999977648258209228515625 - powr(length(uvx - (pos * 0.324999988079071044921875)), 1.60000002384185791015625), 0.0) * 3.0;
    float f63 = fast::max(0.00999999977648258209228515625 - powr(length(uvx - (pos * 0.3499999940395355224609375)), 1.60000002384185791015625), 0.0) * 5.0;
    float3 c = float3(0.0);
    c.x += (((f2 + f4) + f5) + f6);
    c.y += (((f22 + f42) + f52) + f62);
    c.z += (((f23 + f43) + f53) + f63);
    c += (float3(0.0) + float3(f0 / 1.0));
    return c;
}

static inline __attribute__((always_inline))
float3 cc(thread const float3& color, thread const float& factor, thread const float& factor2)
{
    float w = (color.x + color.y) + color.z;
    return mix(color, float3(w, 0.0, 0.0) * factor, float3(w * factor2));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return A + (B * opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _102 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture0 [[texture(1)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture0Smplr [[sampler(1)]])
{
    main0_out out = {};
    float _we_local_timer_0 = sin(_102.g_Time * _102.u_Speed);
    float2 param = float2(0.5);
    float param_1 = (-_102.u_SpeedRot) * _102.g_Time;
    float2 _we_local_rotation_0 = rotateVec2(param, param_1);
    float _we_local_timer2_0 = cos(_102.g_Time * _102.u_Speed1);
    float pointer = (_102.g_PointerPosition * _102.u_pointerSpeed).x;
    float4 scene = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.xy);
    float2 uv = (((in.v_TexCoord.xy / float2(_102.g_Texture0Resolution.y)) / float2(_102.u_Scale)) * 100.0) - float2(0.5);
    uv.x *= (_102.g_Texture0Resolution.x / _102.g_Texture0Resolution.y);
    float2 param_2 = uv;
    float2 param_3 = (_we_local_rotation_0 + float2(_we_local_timer_0 * _we_local_timer2_0)) + ((_102.g_PointerPosition * _102.u_pointerSpeed) + float2(pointer));
    float3 _552 = lensflare(param_2, param_3, g_Texture1, g_Texture1Smplr, _102);
    float3 color = (float3(1.39999997615814208984375, 1.2000000476837158203125, 1.0) * float3(_102.u_color1)) * _552;
    float2 param_4 = in.v_TexCoord.xy;
    color -= float3(_noise(param_4, g_Texture1, g_Texture1Smplr, _102) * 0.014999999664723873138427734375);
    float3 param_5 = color;
    float param_6 = 0.5;
    float param_7 = 0.100000001490116119384765625;
    color = cc(param_5, param_6, param_7);
    float3 finalColor = color;
    float3 param_8 = mix(finalColor, scene.xyz, float3(scene.w));
    float3 param_9 = finalColor;
    float param_10 = _102.u_DistOpacity;
    finalColor = ApplyBlending(31, param_8, param_9, param_10);
    float alpha = scene.w;
    out._fragColor = float4(finalColor, alpha);
    return out;
}

