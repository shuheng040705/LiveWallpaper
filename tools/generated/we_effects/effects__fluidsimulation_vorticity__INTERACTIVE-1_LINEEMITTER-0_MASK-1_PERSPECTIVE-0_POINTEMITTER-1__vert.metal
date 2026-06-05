#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_EffectTextureProjectionMatrixInverse;
    float2 g_PointerPosition;
    float2 g_PointerPositionLast;
    float4 g_Texture0Resolution;
    float u_CursorInfluence;
};

struct main0_out
{
    float2 v_PointDelta [[user(locn0)]];
    float4 v_PointerUV [[user(locn1)]];
    float4 v_PointerUVLast [[user(locn2)]];
    float2 v_TexCoord [[user(locn3)]];
    float4 v_TexCoordLeftTop [[user(locn4)]];
    float4 v_TexCoordRightBottom [[user(locn6)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _39 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    float2 texelSize = float2(1.0) / _39.g_Texture0Resolution.xy;
    out.v_TexCoordLeftTop = in.a_TexCoord.xyxy;
    out.v_TexCoordRightBottom = in.a_TexCoord.xyxy;
    out.v_TexCoordLeftTop.x -= texelSize.x;
    out.v_TexCoordLeftTop.w += texelSize.y;
    out.v_TexCoordRightBottom.x += texelSize.x;
    out.v_TexCoordRightBottom.w -= texelSize.y;
    float2 pointer = _39.g_PointerPosition;
    pointer.y = 1.0 - pointer.y;
    float2 pointerLast = _39.g_PointerPositionLast;
    pointerLast.y = 1.0 - pointerLast.y;
    float4 preTransformPoint = float4((pointer * 2.0) - float2(1.0), 0.0, 1.0);
    float4 preTransformPointLast = float4((pointerLast * 2.0) - float2(1.0), 0.0, 1.0);
    float3 _122 = (_39.g_EffectTextureProjectionMatrixInverse * preTransformPoint).xyw;
    out.v_PointerUV.x = _122.x;
    out.v_PointerUV.y = _122.y;
    out.v_PointerUV.z = _122.z;
    float4 _131 = out.v_PointerUV;
    float2 _133 = _131.xy * 0.5;
    out.v_PointerUV.x = _133.x;
    out.v_PointerUV.y = _133.y;
    float _139 = out.v_PointerUV.z;
    float4 _140 = out.v_PointerUV;
    float2 _143 = _140.xy / float2(_139);
    out.v_PointerUV.x = _143.x;
    out.v_PointerUV.y = _143.y;
    float3 _153 = (_39.g_EffectTextureProjectionMatrixInverse * preTransformPointLast).xyw;
    out.v_PointerUVLast.x = _153.x;
    out.v_PointerUVLast.y = _153.y;
    out.v_PointerUVLast.z = _153.z;
    float4 _160 = out.v_PointerUVLast;
    float2 _162 = _160.xy * 0.5;
    out.v_PointerUVLast.x = _162.x;
    out.v_PointerUVLast.y = _162.y;
    float _168 = out.v_PointerUVLast.z;
    float4 _169 = out.v_PointerUVLast;
    float2 _172 = _169.xy / float2(_168);
    out.v_PointerUVLast.x = _172.x;
    out.v_PointerUVLast.y = _172.y;
    out.v_PointerUV.w = _39.g_Texture0Resolution.y / (-_39.g_Texture0Resolution.x);
    float moveAmt = length(_39.g_PointerPosition - _39.g_PointerPositionLast);
    out.v_PointDelta.x = (step(0.0, moveAmt) * 0.5) + ((moveAmt * 10.0) * _39.u_CursorInfluence);
    out.v_PointDelta.y = 60.0 / fast::max(9.9999997473787516355514526367188e-05, _39.u_CursorInfluence);
    out.v_PointerUV.w *= (-out.v_PointDelta.y);
    out.v_PointerUVLast.w = out.v_PointerUV.w;
    float4 _222 = out.v_PointerUV;
    float2 _225 = _222.xy + float2(0.5);
    out.v_PointerUV.x = _225.x;
    out.v_PointerUV.y = _225.y;
    out.v_PointerUV.y = 1.0 - out.v_PointerUV.y;
    out.v_PointerUV.z = 1.0;
    float4 _235 = out.v_PointerUVLast;
    float2 _238 = _235.xy + float2(0.5);
    out.v_PointerUVLast.x = _238.x;
    out.v_PointerUVLast.y = _238.y;
    out.v_PointerUVLast.y = 1.0 - out.v_PointerUVLast.y;
    out.v_PointerUVLast.z = 1.0;
    return out;
}

