#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4x4 g_EffectModelViewProjectionMatrix;
    float g_Time;
    float u_scope;
    float u_ampExponent;
    float u_FreqBalance;
    float u_LRBalance;
    float2 g_Point0;
    float2 g_Point1;
    float2 g_Point2;
    float2 g_Point3;
    float4 g_AudioSpectrum32Left[32];
    float4 g_AudioSpectrum32Right[32];
};

struct main0_out
{
    // audioValue 不再由 vert 传给 frag(见 frag 注释:32×float4 interpolant 超 Metal 上限);frag 内自算。
    float3 v_PerspCoord [[user(locn60)]];
    float2 v_TexCoord [[user(locn61)]];
    float3 v_ViewCoord [[user(locn62)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _31 [[buffer(0)]])
{
    main0_out out = {};
    // 音频频谱已改在 frag 内消费(消除 32×float4 interpolant);vert 只算几何。
    out.gl_Position = _31.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    out.v_ViewCoord = (_31.g_EffectModelViewProjectionMatrix * float4(in.a_Position, 1.0)).xyw;
    out.v_PerspCoord = float3(in.a_TexCoord, 1.0);
    return out;
}

