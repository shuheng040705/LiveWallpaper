#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4 g_Texture0Resolution;
    float2 u_FrameAlpha;
    float2 u_OutAlpha;
    float2 u_InAlpha;
    float u_opacity;
    float u_Softness;
    float u_NotchSize;
    float u_NotchSize2;
    float u_Thickness;
    float u_extrudeEdge;
    float u_refResolution;
    float3 u_InColor;
    float3 u_FrameColor;
    packed_float3 u_OutColor;
    float u_Notch1;
    float u_Notch2;
    float u_Notch3;
    float u_Notch4;
    float2 u_size;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_ScreenCoord [[user(locn0)]];
    float4 v_Size [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
    float3 v_Transform [[user(locn3)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

static inline __attribute__((always_inline))
float BlendTransparency(float base, float blend, float opacity)
{
    float transparency = base;
    transparency = blend;
    return mix(base, transparency, opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _71 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture3 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture3Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 pix = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord.zw);
    bool _58 = in.v_TexCoord.x < 0.0;
    bool _65;
    if (_58)
    {
        _65 = in.v_TexCoord.y < 0.0;
    }
    else
    {
        _65 = _58;
    }
    float _66;
    if (_65)
    {
        _66 = _71.u_Notch1;
    }
    else
    {
        _66 = 0.0;
    }
    float notchEnabled = _66;
    bool _80 = in.v_TexCoord.x > 0.0;
    bool _86;
    if (_80)
    {
        _86 = in.v_TexCoord.y < 0.0;
    }
    else
    {
        _86 = _80;
    }
    float _87;
    if (_86)
    {
        _87 = _71.u_Notch2;
    }
    else
    {
        _87 = notchEnabled;
    }
    notchEnabled = _87;
    bool _98 = in.v_TexCoord.x > 0.0;
    bool _104;
    if (_98)
    {
        _104 = in.v_TexCoord.y > 0.0;
    }
    else
    {
        _104 = _98;
    }
    float _105;
    if (_104)
    {
        _105 = _71.u_Notch3;
    }
    else
    {
        _105 = notchEnabled;
    }
    notchEnabled = _105;
    bool _116 = in.v_TexCoord.x < 0.0;
    bool _122;
    if (_116)
    {
        _122 = in.v_TexCoord.y > 0.0;
    }
    else
    {
        _122 = _116;
    }
    float _123;
    if (_122)
    {
        _123 = _71.u_Notch4;
    }
    else
    {
        _123 = notchEnabled;
    }
    notchEnabled = _123;
    float2 sdf = (abs(in.v_TexCoord.xy) - in.v_Size.xy) - float2(in.v_Transform.z);
    float notchSize = in.v_Transform.x * notchEnabled;
    float notch = 1.0;
    notch = (length(((abs(in.v_TexCoord.xy) - in.v_Size.xy) + float2(notchSize)) - float2(in.v_Transform.y)) - notchSize) + in.v_Transform.y;
    float2 quadrant = in.v_TexCoord.xy - ((in.v_Size.xy - float2(notchSize - in.v_Transform.y)) * sign(in.v_TexCoord.xy));
    bool _196 = sign(in.v_TexCoord.x) == sign(quadrant.x);
    bool _206;
    if (_196)
    {
        _206 = sign(in.v_TexCoord.y) == sign(quadrant.y);
    }
    else
    {
        _206 = _196;
    }
    notch = _206 ? notch : (-100000.0);
    float edge = fast::max(notch, fast::max(sdf.x, sdf.y));
    float outside = 1.0;
    float inside = 0.0;
    if (edge >= in.v_Transform.y)
    {
        edge = (in.v_Transform.y - edge) + _71.u_Softness;
        outside = 0.0;
    }
    if (edge > _71.u_Softness)
    {
        outside = 0.0;
    }
    edge = fast::clamp(smoothstep(-_71.u_Softness, _71.u_Softness, edge), 0.0, 1.0);
    float alpha = _71.u_opacity;
    float3 bg = g_Texture3.sample(g_Texture3Smplr, ((in.v_ScreenCoord * 0.5) + float2(0.5))).xyz;
    float3 outColor = mix(pix.xyz, float3(_71.u_OutColor), float3(_71.u_OutAlpha.x));
    float3 inColor = mix(pix.xyz, _71.u_InColor, float3(_71.u_InAlpha.x));
    float3 frameColor = mix(pix.xyz, _71.u_FrameColor, float3(_71.u_FrameAlpha.x));
    float4 outSmooth = mix(float4(mix(bg, outColor, float3(_71.u_OutAlpha.y)), 1.0), float4(frameColor, _71.u_FrameAlpha.y), float4(edge));
    float4 inSmooth = mix(float4(mix(bg, inColor, float3(_71.u_InAlpha.y)), 1.0), float4(frameColor, _71.u_FrameAlpha.y), float4(edge));
    float4 final = select(outSmooth, inSmooth, bool4(outside != 0.0));
    float3 param = pix.xyz;
    float3 param_1 = final.xyz;
    float param_2 = alpha;
    float3 _357 = ApplyBlending(0, param, param_1, param_2);
    final.x = _357.x;
    final.y = _357.y;
    final.z = _357.z;
    final.w = BlendTransparency(pix.w, final.w, alpha);
    out._fragColor = final;
    return out;
}

