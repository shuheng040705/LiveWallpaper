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
    float4 audioValue_0 [[user(locn0)]];
    float4 audioValue_1 [[user(locn1)]];
    float4 audioValue_2 [[user(locn2)]];
    float4 audioValue_3 [[user(locn3)]];
    float4 audioValue_4 [[user(locn4)]];
    float4 audioValue_5 [[user(locn5)]];
    float4 audioValue_6 [[user(locn6)]];
    float4 audioValue_7 [[user(locn7)]];
    float4 audioValue_8 [[user(locn8)]];
    float4 audioValue_9 [[user(locn9)]];
    float4 audioValue_10 [[user(locn10)]];
    float4 audioValue_11 [[user(locn11)]];
    float4 audioValue_12 [[user(locn12)]];
    float4 audioValue_13 [[user(locn13)]];
    float4 audioValue_14 [[user(locn14)]];
    float4 audioValue_15 [[user(locn15)]];
    float4 audioValue_16 [[user(locn16)]];
    float4 audioValue_17 [[user(locn17)]];
    float4 audioValue_18 [[user(locn18)]];
    float4 audioValue_19 [[user(locn19)]];
    float4 audioValue_20 [[user(locn20)]];
    float4 audioValue_21 [[user(locn21)]];
    float4 audioValue_22 [[user(locn22)]];
    float4 audioValue_23 [[user(locn23)]];
    float4 audioValue_24 [[user(locn24)]];
    float4 audioValue_25 [[user(locn25)]];
    float4 audioValue_26 [[user(locn26)]];
    float4 audioValue_27 [[user(locn27)]];
    float4 audioValue_28 [[user(locn28)]];
    float4 audioValue_29 [[user(locn29)]];
    float4 audioValue_30 [[user(locn30)]];
    float4 audioValue_31 [[user(locn31)]];
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
    spvUnsafeArray<float4, 32> audioValue = {};
    int i = 0;
    spvUnsafeArray<float, 32> audioData;
    for (; i < 32; i++)
    {
        float amplitude = (_31.g_AudioSpectrum32Left[i].x * 0.5) + (_31.g_AudioSpectrum32Right[i].x * 0.5);
        float normalizedFrequency = float(i) / 32.0;
        audioData[i] = powr(1.0 * (amplitude + amplitude), _31.u_ampExponent + 0.00999999977648258209228515625);
    }
    i = 0;
    for (; i < 32; i += 4)
    {
        audioValue[uint(i) / 4u] = float4(audioData[i], audioData[i + 1], audioData[i + 2], audioData[i + 3]);
    }
    out.gl_Position = _31.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    out.v_ViewCoord = (_31.g_EffectModelViewProjectionMatrix * float4(in.a_Position, 1.0)).xyw;
    out.v_PerspCoord = float3(in.a_TexCoord, 1.0);
    out.audioValue_0 = audioValue[0];
    out.audioValue_1 = audioValue[1];
    out.audioValue_2 = audioValue[2];
    out.audioValue_3 = audioValue[3];
    out.audioValue_4 = audioValue[4];
    out.audioValue_5 = audioValue[5];
    out.audioValue_6 = audioValue[6];
    out.audioValue_7 = audioValue[7];
    out.audioValue_8 = audioValue[8];
    out.audioValue_9 = audioValue[9];
    out.audioValue_10 = audioValue[10];
    out.audioValue_11 = audioValue[11];
    out.audioValue_12 = audioValue[12];
    out.audioValue_13 = audioValue[13];
    out.audioValue_14 = audioValue[14];
    out.audioValue_15 = audioValue[15];
    out.audioValue_16 = audioValue[16];
    out.audioValue_17 = audioValue[17];
    out.audioValue_18 = audioValue[18];
    out.audioValue_19 = audioValue[19];
    out.audioValue_20 = audioValue[20];
    out.audioValue_21 = audioValue[21];
    out.audioValue_22 = audioValue[22];
    out.audioValue_23 = audioValue[23];
    out.audioValue_24 = audioValue[24];
    out.audioValue_25 = audioValue[25];
    out.audioValue_26 = audioValue[26];
    out.audioValue_27 = audioValue[27];
    out.audioValue_28 = audioValue[28];
    out.audioValue_29 = audioValue[29];
    out.audioValue_30 = audioValue[30];
    out.audioValue_31 = audioValue[31];
    return out;
}

