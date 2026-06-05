#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_EffectTextureProjectionMatrixInverse;
    float2 g_PointerPosition;
    float2 g_PointerPositionLast;
    float4 g_Texture0Resolution;
    float g_RippleScale;
};

struct main0_out
{
    float2 v_PointDelta [[user(locn0)]];
    float4 v_PointerUV [[user(locn1)]];
    float4 v_PointerUVLast [[user(locn2)]];
    float2 v_TexCoord [[user(locn3)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _38 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    float2 pointer = _38.g_PointerPosition;
    pointer.y = 1.0 - pointer.y;
    float2 pointerLast = _38.g_PointerPositionLast;
    pointerLast.y = 1.0 - pointerLast.y;
    float4 preTransformPoint = float4((pointer * 2.0) - float2(1.0), 0.0, 1.0);
    float4 preTransformPointLast = float4((pointerLast * 2.0) - float2(1.0), 0.0, 1.0);
    float3 _81 = (_38.g_EffectTextureProjectionMatrixInverse * preTransformPoint).xyw;
    out.v_PointerUV.x = _81.x;
    out.v_PointerUV.y = _81.y;
    out.v_PointerUV.z = _81.z;
    float4 _92 = out.v_PointerUV;
    float2 _94 = _92.xy * 0.5;
    out.v_PointerUV.x = _94.x;
    out.v_PointerUV.y = _94.y;
    float _100 = out.v_PointerUV.z;
    float4 _101 = out.v_PointerUV;
    float2 _104 = _101.xy / float2(_100);
    out.v_PointerUV.x = _104.x;
    out.v_PointerUV.y = _104.y;
    float3 _114 = (_38.g_EffectTextureProjectionMatrixInverse * preTransformPointLast).xyw;
    out.v_PointerUVLast.x = _114.x;
    out.v_PointerUVLast.y = _114.y;
    out.v_PointerUVLast.z = _114.z;
    float4 _121 = out.v_PointerUVLast;
    float2 _123 = _121.xy * 0.5;
    out.v_PointerUVLast.x = _123.x;
    out.v_PointerUVLast.y = _123.y;
    float _129 = out.v_PointerUVLast.z;
    float4 _130 = out.v_PointerUVLast;
    float2 _133 = _130.xy / float2(_129);
    out.v_PointerUVLast.x = _133.x;
    out.v_PointerUVLast.y = _133.y;
    out.v_PointerUV.w = _38.g_Texture0Resolution.y / (-_38.g_Texture0Resolution.x);
    out.v_PointDelta.x = length(_38.g_PointerPosition - _38.g_PointerPositionLast);
    out.v_PointDelta.x *= 100.0;
    out.v_PointDelta.y = 60.0 / fast::max(9.9999997473787516355514526367188e-05, _38.g_RippleScale);
    out.v_PointerUV.w *= (-out.v_PointDelta.y);
    out.v_PointerUVLast.w = out.v_PointerUV.w;
    out.v_PointerUV.z = 1.0;
    float4 _180 = out.v_PointerUV;
    float2 _183 = _180.xy + float2(0.5);
    out.v_PointerUV.x = _183.x;
    out.v_PointerUV.y = _183.y;
    out.v_PointerUV.y = 1.0 - out.v_PointerUV.y;
    out.v_PointerUVLast.z = 1.0;
    float4 _193 = out.v_PointerUVLast;
    float2 _196 = _193.xy + float2(0.5);
    out.v_PointerUVLast.x = _196.x;
    out.v_PointerUVLast.y = _196.y;
    out.v_PointerUVLast.y = 1.0 - out.v_PointerUVLast.y;
    return out;
}

