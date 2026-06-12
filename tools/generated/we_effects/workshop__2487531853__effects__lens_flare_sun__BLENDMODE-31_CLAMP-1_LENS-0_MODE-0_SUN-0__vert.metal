#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4x4 g_ModelViewProjectionMatrixInverse;
    float2 g_PointerPosition;
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
};

struct main0_out
{
    float4 v_PointerUV [[user(locn4)]];
    float4 v_TexCoord [[user(locn5)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _26 [[buffer(0)]])
{
    main0_out out = {};
    float3 position = in.a_Position;
    out.gl_Position = _26.g_ModelViewProjectionMatrix * float4(position, 1.0);
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    float2 pointer = _26.g_PointerPosition;
    pointer.y = 1.0 - pointer.y;
    float3 _74 = (_26.g_ModelViewProjectionMatrixInverse * float4((pointer * 2.0) - float2(1.0), 0.0, 1.0)).xyw;
    out.v_PointerUV.x = _74.x;
    out.v_PointerUV.y = _74.y;
    out.v_PointerUV.z = _74.z;
    float4 _90 = out.v_PointerUV;
    float2 _92 = _90.xy * (float2(0.5) / _26.g_Texture0Resolution.xy);
    out.v_PointerUV.x = _92.x;
    out.v_PointerUV.y = _92.y;
    out.v_PointerUV.w = _26.g_Texture0Resolution.y / (-_26.g_Texture0Resolution.x);
    return out;
}

