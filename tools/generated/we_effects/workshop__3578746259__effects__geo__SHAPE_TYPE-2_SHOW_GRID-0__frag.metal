#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    packed_float3 u_gridColor;
    float u_gridOpacity;
    float u_gridSpacing;
    float u_gridThickness;
    char _m4_pad[8];
    packed_float3 u_axisColor;
    float u_axisOpacity;
    float u_axisThickness;
    float2 u_lineP1;
    float2 u_lineP2;
    float2 u_rayOrigin;
    float u_rayAngle;
    float u_rayLength;
    float2 u_arcCenter;
    float u_arcRadius;
    float u_arcTheta1;
    float u_arcTheta2;
    float2 u_sineOrigin;
    float u_sineK;
    float u_sineA;
    float u_sineTheta;
    float2 u_polyOrigin;
    float u_a0;
    float u_a1;
    float u_a2;
    float u_a3;
    float u_a4;
    float u_a5;
    float u_a6;
    float u_a7;
    float u_a8;
    float u_a9;
    float2 u_polyShapeCenter;
    float u_polyShapeRadius;
    float u_polyShapeSides;
    float u_polyShapeAngle;
    float2 u_circleCenter;
    float u_circleRadius;
    char _m37_pad[4];
    packed_float3 u_lineColor;
    float u_lineOpacity;
    float u_lineThickness;
    char _m40_pad[12];
    packed_float3 u_fillColor;
    float u_fillOpacity;
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
    float2 pos_cartesian = (in.v_TexCoord - float2(0.5)) * 2.0;
    pos_cartesian.y *= (-1.0);
    float2 p = pos_cartesian;
    p.x *= aspect;
    float4 originalColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 finalColor = originalColor.xyz;
    float finalAlpha = originalColor.w;
    float smoothness = 0.001000000047497451305389404296875;
    float dist = 1000000000.0;
    bool inRange = true;
    float2 center = _14.u_arcCenter;
    center.x *= aspect;
    float2 p_arc = p - center;
    float angle = (precise::atan2(p_arc.y, p_arc.x) * 180.0) / 3.1415927410125732421875;
    if (angle < 0.0)
    {
        angle += 360.0;
    }
    float r = length(p_arc);
    float start = _14.u_arcTheta1;
    float end = _14.u_arcTheta2;
    bool _119;
    if (start < end)
    {
        _119 = (angle >= start) && (angle <= end);
    }
    else
    {
        _119 = (angle >= start) || (angle <= end);
    }
    inRange = _119;
    if (inRange)
    {
        dist = abs(r - _14.u_arcRadius);
    }
    if (inRange)
    {
        float lineIntensity = 1.0 - smoothstep((_14.u_lineThickness * 0.5) - smoothness, (_14.u_lineThickness * 0.5) + smoothness, dist);
        float effectiveAlpha = lineIntensity * _14.u_lineOpacity;
        finalColor = mix(finalColor, float3(_14.u_lineColor), float3(effectiveAlpha));
        finalAlpha = fast::max(finalAlpha, effectiveAlpha);
    }
    out._fragColor = float4(finalColor, finalAlpha);
    return out;
}

