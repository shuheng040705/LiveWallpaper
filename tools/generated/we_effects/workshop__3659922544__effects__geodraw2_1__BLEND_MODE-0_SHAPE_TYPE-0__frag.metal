#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    packed_float3 u_lineColor;
    float u_lineOpacity;
    float u_lineThick;
    char _m3_pad[12];
    packed_float3 u_fillColor;
    float u_fillOpacity;
    float u_blur;
    float2 u_circleC;
    float u_circleR;
    float u_circleA1;
    float u_circleA2;
    float u_showRadius;
    float2 u_triA;
    float2 u_triB;
    float2 u_triC;
    float2 u_rectC;
    float u_rectW;
    float u_rectH;
    float u_rectRot;
    float2 u_regC;
    float u_regR;
    float u_regSides;
    float u_regRot;
    float2 u_capsC;
    float u_capsW;
    float u_capsH;
    float u_capsR;
    float u_capsRot;
    float2 u_lineP1;
    float2 u_lineP2;
    float u_sineK;
    float u_sineFreq;
    float u_sinePhase;
    float u_pA1;
    float u_pA2;
    float u_pA3;
    float4 g_Texture0Resolution;
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
float LineDist(thread const float2& pt, thread const float2& a, thread const float2& b)
{
    float2 pa = pt - a;
    float2 ba = b - a;
    float len2 = dot(ba, ba);
    if (len2 < 9.9999997473787516355514526367188e-05)
    {
        return length(pa);
    }
    float h = fast::clamp(dot(pa, ba) / len2, 0.0, 1.0);
    return length(pa - (ba * h));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _59 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float aspect = _59.g_Texture0Resolution.x / _59.g_Texture0Resolution.y;
    float2 p = (in.v_TexCoord - float2(0.5)) * 2.0;
    p.y = -p.y;
    p.x *= aspect;
    float dist = 1000000000.0;
    float extraLine = 1000000000.0;
    float4 origColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 col = float3(0.0);
    float alpha = 0.0;
    float2 cc = (_59.u_circleC - float2(0.5)) * 2.0;
    cc.y = -cc.y;
    cc.x *= aspect;
    float2 cq = p - cc;
    float clen = length(cq);
    float cang = (precise::atan2(cq.y, cq.x) * 180.0) / 3.1415927410125732421875;
    if (cang < 0.0)
    {
        cang += 360.0;
    }
    float a1 = _59.u_circleA1;
    float a2 = _59.u_circleA2;
    float fullCircle = 0.0;
    bool _160 = abs(a2 - a1) < 0.00999999977648258209228515625;
    bool _170;
    if (!_160)
    {
        _170 = abs((a2 - a1) - 360.0) < 0.00999999977648258209228515625;
    }
    else
    {
        _170 = _160;
    }
    bool _180;
    if (!_170)
    {
        _180 = abs((a1 - a2) - 360.0) < 0.00999999977648258209228515625;
    }
    else
    {
        _180 = _170;
    }
    if (_180)
    {
        fullCircle = 1.0;
    }
    float inArc = 0.0;
    if (fullCircle > 0.5)
    {
        inArc = 1.0;
    }
    else
    {
        if (a1 <= a2)
        {
            if ((cang >= a1) && (cang <= a2))
            {
                inArc = 1.0;
            }
        }
        else
        {
            if ((cang >= a1) || (cang <= a2))
            {
                inArc = 1.0;
            }
        }
    }
    if (inArc > 0.5)
    {
        dist = clen - _59.u_circleR;
    }
    if ((_59.u_showRadius > 0.5) && (fullCircle < 0.5))
    {
        float rad1 = (a1 * 3.1415927410125732421875) / 180.0;
        float rad2 = (a2 * 3.1415927410125732421875) / 180.0;
        float2 edge1 = cc + (float2(cos(rad1), sin(rad1)) * _59.u_circleR);
        float2 edge2 = cc + (float2(cos(rad2), sin(rad2)) * _59.u_circleR);
        float2 param = p;
        float2 param_1 = cc;
        float2 param_2 = edge1;
        float2 param_3 = p;
        float2 param_4 = cc;
        float2 param_5 = edge2;
        extraLine = fast::min(LineDist(param, param_1, param_2), LineDist(param_3, param_4, param_5));
    }
    float edge = _59.u_lineThick * 0.5;
    float aa = 0.00200000009499490261077880859375;
    float fill = 1.0 - smoothstep(-aa, aa, dist);
    col = mix(col, float3(_59.u_fillColor), float3(fill * _59.u_fillOpacity));
    alpha = fast::max(alpha, fill * _59.u_fillOpacity);
    float stroke = 1.0 - smoothstep(edge - aa, edge + aa, abs(dist));
    col = mix(col, float3(_59.u_lineColor), float3(stroke * _59.u_lineOpacity));
    alpha = fast::max(alpha, stroke * _59.u_lineOpacity);
    if (extraLine < 100000000.0)
    {
        float extraStroke = 1.0 - smoothstep(edge - aa, edge + aa, extraLine);
        col = mix(col, float3(_59.u_lineColor), float3(extraStroke * _59.u_lineOpacity));
        alpha = fast::max(alpha, extraStroke * _59.u_lineOpacity);
    }
    out._fragColor = float4(col, alpha);
    return out;
}

