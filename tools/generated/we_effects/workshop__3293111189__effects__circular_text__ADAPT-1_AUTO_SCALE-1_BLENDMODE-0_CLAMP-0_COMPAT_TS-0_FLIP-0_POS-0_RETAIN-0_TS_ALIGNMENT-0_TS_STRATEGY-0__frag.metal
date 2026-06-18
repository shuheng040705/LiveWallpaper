#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Alpha;
    float u_CenterDistance;
    float2 u_CircleAngles;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float autoSaleFactor [[user(locn0)]];
    float reciprocalAspect [[user(locn2)]];
    float4 _we_ro_v_TexCoord [[user(locn4)]];
};

static inline __attribute__((always_inline))
float mod2(thread const float& x, thread const float& y)
{
    return x - (y * floor(x / y));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _42 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 v_TexCoord = in._we_ro_v_TexCoord;
    float2 circleCoord = (v_TexCoord.xy - float2(0.5)) * 2.0;
    float startAngle = (_42.u_CircleAngles.x * 0.00277777784503996372222900390625) * in.reciprocalAspect;
    float endAngle = (_42.u_CircleAngles.y * 0.00277777784503996372222900390625) * in.reciprocalAspect;
    v_TexCoord.x = (precise::atan2(circleCoord.y, circleCoord.x) + 3.1415927410125732421875) / 6.283185482025146484375;
    float param = v_TexCoord.x - fast::min(startAngle, endAngle);
    float param_1 = 1.0;
    v_TexCoord.x = mod2(param, param_1);
    float param_2 = (endAngle - startAngle) - 1.0;
    float param_3 = 4.0;
    v_TexCoord.x /= (abs(mod2(param_2, param_3) - 2.0) - 1.0);
    v_TexCoord.x += float((endAngle - startAngle) < 0.0);
    v_TexCoord.y = sqrt((circleCoord.x * circleCoord.x) + (circleCoord.y * circleCoord.y));
    float scale = in.autoSaleFactor;
    v_TexCoord.y = mix(-scale, 1.0, v_TexCoord.y);
    v_TexCoord.y = 1.0 - v_TexCoord.y;
    v_TexCoord.y += _42.u_CenterDistance;
    v_TexCoord.x *= in.reciprocalAspect;
    out._fragColor = g_Texture0.sample(g_Texture0Smplr, v_TexCoord.zw);
    return out;
}

