#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture1Resolution;
    float4 g_Texture0Resolution;
    float4 g_Texture3Resolution;
    float2 g_Bounds;
};

struct main0_out
{
    float2 v_Bounds [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
    float4 v_TexCoordMask [[user(locn3)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _20 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _20.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float _47 = out.v_TexCoord.x;
    float _58 = out.v_TexCoord.y;
    float2 _66 = float2((_47 * _20.g_Texture1Resolution.z) / _20.g_Texture1Resolution.x, (_58 * _20.g_Texture1Resolution.w) / _20.g_Texture1Resolution.y);
    out.v_TexCoord.z = _66.x;
    out.v_TexCoord.w = _66.y;
    out.v_Bounds.x = _20.g_Bounds.x;
    out.v_Bounds.y = 1.0 / (_20.g_Bounds.y - _20.g_Bounds.x);
    float2 _103 = float2((in.a_TexCoord.x * _20.g_Texture3Resolution.z) / _20.g_Texture3Resolution.x, (in.a_TexCoord.y * _20.g_Texture3Resolution.w) / _20.g_Texture3Resolution.y);
    out.v_TexCoordMask.x = _103.x;
    out.v_TexCoordMask.y = _103.y;
    float2 _118 = float2(_20.g_Texture3Resolution.z / _20.g_Texture3Resolution.x, _20.g_Texture3Resolution.w / _20.g_Texture3Resolution.y);
    out.v_TexCoordMask.z = _118.x;
    out.v_TexCoordMask.w = _118.y;
    return out;
}

