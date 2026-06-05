#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 u_size;
    float2 u_position;
    float u_Thickness;
    float u_Softness;
    float2 u_refResolution;
    float u_NotchSize;
    float u_extrudeEdge;
    float u_rotation;
    float2 u_texturePos;
    float2 u_textureScale;
    float u_texOffset;
    float2 u_texOffset2;
    float u_textureAngle;
    float4x4 g_ModelViewProjectionMatrix;
    float4x4 g_LayerModelMatrix;
    float4x4 g_EffectModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float4 g_Texture2Resolution;
};

struct main0_out
{
    float2 v_ScreenCoord [[user(locn0)]];
    float4 v_Size [[user(locn1)]];
    float4 v_TexCoord [[user(locn2)]];
    float3 v_Transform [[user(locn3)]];
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

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _72 [[buffer(0)]])
{
    main0_out out = {};
    out.v_TexCoord.z = in.a_TexCoord.x;
    out.v_TexCoord.w = in.a_TexCoord.y;
    out.v_TexCoord.x = in.a_TexCoord.x;
    out.v_TexCoord.y = in.a_TexCoord.y;
    out.v_ScreenCoord = (_72.g_EffectModelViewProjectionMatrix * float4(in.a_Position, 1.0)).xy;
    float2 right = float2(_72.g_LayerModelMatrix[0].x, _72.g_LayerModelMatrix[0].y);
    float2 up = float2(_72.g_LayerModelMatrix[1].x, _72.g_LayerModelMatrix[1].y);
    float2 scale = float2(length(right), length(up));
    out.v_Transform.x = fast::max(9.9999999747524270787835121154785e-07, (_72.u_NotchSize * _72.u_refResolution.x) * 0.20000000298023223876953125);
    out.v_Transform.x = length(float2(out.v_Transform.x));
    out.v_Transform.y = (_72.u_Thickness * _72.u_refResolution.x) * 0.0500000007450580596923828125;
    out.v_Transform.z = (_72.u_extrudeEdge * _72.u_refResolution.x) * 0.100000001490116119384765625;
    float2 param = (((out.v_TexCoord.xy + _72.u_position) - float2(0.5)) * _72.u_refResolution) * scale;
    float param_1 = _72.u_rotation;
    float2 _167 = rotateVec2(param, param_1);
    out.v_TexCoord.x = _167.x;
    out.v_TexCoord.y = _167.y;
    float2 _193 = (((((_72.u_size * _72.u_refResolution) * 0.5) * scale) - float2(out.v_Transform.y)) - float2(_72.u_Softness)) - float2(_72.u_Softness);
    out.v_Size.x = _193.x;
    out.v_Size.y = _193.y;
    float padding = ((_72.u_Softness + _72.u_Softness) + out.v_Transform.y) + out.v_Transform.y;
    float2 res0 = ((_72.u_refResolution * scale) * _72.u_size) - float2(padding);
    float ratio0 = res0.x / res0.y;
    float ratio1 = _72.g_Texture2Resolution.x / _72.g_Texture2Resolution.y;
    float horizontal = step(ratio0, ratio1);
    float _249;
    if (true)
    {
        _249 = 1.0 - horizontal;
    }
    else
    {
        _249 = horizontal;
    }
    float2 ratio = mix(float2(1.0, ratio1 / ratio0), float2(ratio0 / ratio1, 1.0), float2(_249));
    float2 _266 = ((out.v_TexCoord.xy / res0) * ratio) + float2(0.5);
    out.v_Size.z = _266.x;
    out.v_Size.w = _266.y;
    float S = fast::min(res0.x / _72.g_Texture2Resolution.x, res0.y / _72.g_Texture2Resolution.y);
    float2 excessSize = (res0 - (_72.g_Texture2Resolution.xy * S)) / res0;
    float4 _302 = out.v_Size;
    float2 _304 = _302.zw + (((excessSize * _72.u_texOffset) * ratio) * 0.5);
    out.v_Size.z = _304.x;
    out.v_Size.w = _304.y;
    out.gl_Position = _72.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    return out;
}

