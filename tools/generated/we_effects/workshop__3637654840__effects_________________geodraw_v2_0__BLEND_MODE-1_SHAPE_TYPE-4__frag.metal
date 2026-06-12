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
    float u_capsL;
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

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _14 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float aspect = _14.g_Texture0Resolution.x / _14.g_Texture0Resolution.y;
    float2 p = (in.v_TexCoord - float2(0.5)) * 2.0;
    p.y = -p.y;
    p.x *= aspect;
    float dist = 1000000000.0;
    float extraLine = 1000000000.0;
    float4 origColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 col = origColor.xyz;
    float alpha = origColor.w;
    float2 capC = (_14.u_capsC - float2(0.5)) * 2.0;
    capC.y = -capC.y;
    capC.x *= aspect;
    float capRad = (_14.u_capsRot * 3.1415927410125732421875) / 180.0;
    float capCos = cos(capRad);
    float capSin = sin(capRad);
    float2 capDir = (float2(capCos, capSin) * _14.u_capsL) * 0.5;
    float2 capA = capC - capDir;
    float2 capB = capC + capDir;
    float2 capPA = p - capA;
    float2 capBA = capB - capA;
    float capLen2 = dot(capBA, capBA);
    float capH = 0.0;
    if (capLen2 > 9.9999997473787516355514526367188e-05)
    {
        capH = fast::clamp(dot(capPA, capBA) / capLen2, 0.0, 1.0);
    }
    dist = length(capPA - (capBA * capH)) - _14.u_capsR;
    float edge = _14.u_lineThick * 0.5;
    float aa = 0.00200000009499490261077880859375;
    float fill = 1.0 - smoothstep(-aa, aa, dist);
    col = mix(col, float3(_14.u_fillColor), float3(fill * _14.u_fillOpacity));
    alpha = fast::max(alpha, fill * _14.u_fillOpacity);
    float stroke = 1.0 - smoothstep(edge - aa, edge + aa, abs(dist));
    col = mix(col, float3(_14.u_lineColor), float3(stroke * _14.u_lineOpacity));
    alpha = fast::max(alpha, stroke * _14.u_lineOpacity);
    if (extraLine < 100000000.0)
    {
        float extraStroke = 1.0 - smoothstep(edge - aa, edge + aa, extraLine);
        col = mix(col, float3(_14.u_lineColor), float3(extraStroke * _14.u_lineOpacity));
        alpha = fast::max(alpha, extraStroke * _14.u_lineOpacity);
    }
    float2 blurOff = ((float2(1.0) / _14.g_Texture0Resolution.xy) * _14.u_blur) * 1.5;
    float blur = origColor.w * 0.4000000059604644775390625;
    blur += (g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + float2(blurOff.x, 0.0))).w * 0.1500000059604644775390625);
    blur += (g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord - float2(blurOff.x, 0.0))).w * 0.1500000059604644775390625);
    blur += (g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord + float2(0.0, blurOff.y))).w * 0.1500000059604644775390625);
    blur += (g_Texture0.sample(g_Texture0Smplr, (in.v_TexCoord - float2(0.0, blurOff.y))).w * 0.1500000059604644775390625);
    float edgeMask = smoothstep(0.0, 0.5, alpha) * (1.0 - smoothstep(0.699999988079071044921875, 1.0, alpha));
    alpha = mix(alpha, blur, edgeMask * 0.89999997615814208984375);
    out._fragColor = float4(col, alpha);
    return out;
}

