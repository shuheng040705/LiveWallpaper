#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float g_Time;
    float2 g_CursorScale;
    float2 g_CursorScaleMultiplier;
    float2 g_CursorScaleLimit;
    float4 g_Texture1Resolution;
    float4x4 g_EffectTextureProjectionMatrixInverse;
    float2 g_PointerPosition;
    float2 g_PointerPositionLast;
    float4 g_Texture0Resolution;
};

struct main0_out
{
    float4 v_PointerUV [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float2 v_TexCoordIris [[user(locn2)]];
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
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float _44 = out.v_TexCoord.x;
    float _55 = out.v_TexCoord.y;
    float2 _63 = float2((_44 * _20.g_Texture1Resolution.z) / _20.g_Texture1Resolution.x, (_55 * _20.g_Texture1Resolution.w) / _20.g_Texture1Resolution.y);
    out.v_TexCoord.z = _63.x;
    out.v_TexCoord.w = _63.y;
    float2 cursorPositionAdjusted = _20.g_PointerPosition;
    cursorPositionAdjusted.y = 1.0 - cursorPositionAdjusted.y;
    cursorPositionAdjusted.x = (cursorPositionAdjusted.x - 0.5) * 2.0;
    cursorPositionAdjusted.y = (cursorPositionAdjusted.y - 0.5) * 2.0;
    float4 transformedCursorPosition = _20.g_EffectTextureProjectionMatrixInverse * float4(cursorPositionAdjusted, 0.0, 1.0);
    float4 _102 = transformedCursorPosition;
    float2 _110 = fast::clamp(_102.xy, -_20.g_CursorScaleLimit, _20.g_CursorScaleLimit);
    transformedCursorPosition.x = _110.x;
    transformedCursorPosition.y = _110.y;
    transformedCursorPosition.x *= (-1.0);
    float2 da = ((transformedCursorPosition.xy * _20.g_CursorScale) * _20.g_CursorScaleMultiplier) * 0.001000000047497451305389404296875;
    out.v_TexCoordIris = da;
    return out;
}

