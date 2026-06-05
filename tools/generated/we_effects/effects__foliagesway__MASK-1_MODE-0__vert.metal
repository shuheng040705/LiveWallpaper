#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float g_Time;
    float g_Speed;
    float g_Strength;
    float g_Phase;
    float g_Power;
    float2 g_DirectionWeights;
    float4 g_CornerWeights;
    float2 g_Bounds;
    float g_NoiseScale;
    float g_Ratio;
    float g_Direction;
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
};

struct main0_out
{
    float3 v_Params [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float4 v_TexCoordNoise [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float2 rotateVec2(thread const float2& v, thread const float& r)
{
    float2 cs = float2(cos(r), sin(r));
    return float2((v.x * cs.x) - (v.y * cs.y), (v.x * cs.y) + (v.y * cs.x));
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _70 [[buffer(0)]])
{
    main0_out out = {};
    out.v_TexCoord.z = 0.0;
    out.v_TexCoord.w = 0.0;
    out.gl_Position = _70.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    float2 _106 = float2((in.a_TexCoord.x * _70.g_Texture1Resolution.z) / _70.g_Texture1Resolution.x, (in.a_TexCoord.y * _70.g_Texture1Resolution.w) / _70.g_Texture1Resolution.y);
    out.v_TexCoord.z = _106.x;
    out.v_TexCoord.w = _106.y;
    float aspect = (_70.g_Texture0Resolution.z / _70.g_Texture0Resolution.w) * _70.g_Ratio;
    float2 param = float2(1.0 / aspect, aspect);
    float param_1 = _70.g_Direction;
    float2 _132 = rotateVec2(param, param_1);
    out.v_TexCoordNoise.z = _132.x;
    out.v_TexCoordNoise.w = _132.y;
    float2 _141 = in.a_TexCoord * _70.g_NoiseScale;
    out.v_TexCoordNoise.x = _141.x;
    out.v_TexCoordNoise.y = _141.y;
    float2 param_2 = in.a_TexCoord;
    float param_3 = _70.g_Direction;
    float2 _153 = rotateVec2(param_2, param_3);
    out.v_Params.x = _153.x;
    out.v_Params.y = _153.y;
    out.v_Params.z = (_70.g_Strength * _70.g_Strength) * 0.004999999888241291046142578125;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    return out;
}

