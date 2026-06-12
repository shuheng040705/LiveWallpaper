#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Implementation of the GLSL mod() function, which is slightly different than Metal fmod()
template<typename Tx, typename Ty>
inline Tx mod(Tx x, Ty y)
{
    return x - y * floor(x / y);
}

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

static inline __attribute__((always_inline))
float distToLineSegment(thread const float2& p, thread const float2& a, thread const float2& b)
{
    float2 pa = p - a;
    float2 ba = b - a;
    float h = fast::clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - (ba * h));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _48 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float aspect = _48.g_Texture0Resolution.x / _48.g_Texture0Resolution.y;
    float2 pos_cartesian = (in.v_TexCoord - float2(0.5)) * 2.0;
    pos_cartesian.y *= (-1.0);
    float2 p = pos_cartesian;
    p.x *= aspect;
    float4 originalColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float3 finalColor = originalColor.xyz;
    float finalAlpha = originalColor.w;
    float aa_grid = 0.00200000009499490261077880859375;
    float spacing = _48.u_gridSpacing;
    float2 grid_pos = abs(mod(p + float2(spacing * 0.5), float2(spacing)) - float2(spacing * 0.5));
    float grid_dist = fast::min(grid_pos.x, grid_pos.y);
    float grid_intensity = 1.0 - smoothstep((_48.u_gridThickness * 0.5) - aa_grid, (_48.u_gridThickness * 0.5) + aa_grid, grid_dist);
    float grid_alpha = grid_intensity * _48.u_gridOpacity;
    finalColor = mix(finalColor, float3(_48.u_gridColor), float3(grid_alpha));
    finalAlpha = fast::max(finalAlpha, grid_alpha);
    float axis_dist = fast::min(abs(p.x), abs(p.y));
    float axis_intensity = 1.0 - smoothstep((_48.u_axisThickness * 0.5) - aa_grid, (_48.u_axisThickness * 0.5) + aa_grid, axis_dist);
    float axis_alpha = axis_intensity * _48.u_axisOpacity;
    finalColor = mix(finalColor, float3(_48.u_axisColor), float3(axis_alpha));
    finalAlpha = fast::max(finalAlpha, axis_alpha);
    float smoothness = 0.001000000047497451305389404296875;
    float dist = 1000000000.0;
    bool inRange = true;
    float2 p1 = _48.u_lineP1;
    p1.x *= aspect;
    float2 p2 = _48.u_lineP2;
    p2.x *= aspect;
    float2 param = p;
    float2 param_1 = p1;
    float2 param_2 = p2;
    dist = distToLineSegment(param, param_1, param_2);
    if (inRange)
    {
        float lineIntensity = 1.0 - smoothstep((_48.u_lineThickness * 0.5) - smoothness, (_48.u_lineThickness * 0.5) + smoothness, dist);
        float effectiveAlpha = lineIntensity * _48.u_lineOpacity;
        finalColor = mix(finalColor, float3(_48.u_lineColor), float3(effectiveAlpha));
        finalAlpha = fast::max(finalAlpha, effectiveAlpha);
    }
    out._fragColor = float4(finalColor, finalAlpha);
    return out;
}

