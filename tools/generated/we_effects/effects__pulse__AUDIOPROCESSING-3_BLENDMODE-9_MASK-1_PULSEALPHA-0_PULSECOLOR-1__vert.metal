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
    float4 g_Texture1Resolution;
    float4 g_Texture2Resolution;
    float g_Time;
    float2 g_PulseThresholds;
    float g_PulseSpeed;
    float g_PulsePhase;
    float g_PulseAmount;
    float4 g_AudioSpectrum16Left[16];
    float4 g_AudioSpectrum16Right[16];
    float g_AudioFrequencyMin;
    float g_AudioFrequencyMax;
    float g_AudioPower;
    float2 g_AudioBounds;
    float g_AudioMultiply;
};

struct main0_out
{
    float v_Pulse [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float CreateAudioResponse(thread const spvUnsafeArray<float, 16>& bufferLeft, thread const spvUnsafeArray<float, 16>& bufferRight, constant _Globals& _25)
{
    float audioFrequencyEnd = fast::max(_25.g_AudioFrequencyMin, _25.g_AudioFrequencyMax);
    float audioResponse = 0.0;
    int _41 = int(_25.g_AudioFrequencyMin);
    for (int a = _41; a <= int(_25.g_AudioFrequencyMax); a++)
    {
        audioResponse += bufferLeft[a];
        audioResponse += bufferRight[a];
    }
    audioResponse /= (((_25.g_AudioFrequencyMax - _25.g_AudioFrequencyMin) + 1.0) * 2.0);
    audioResponse = smoothstep(_25.g_AudioBounds.x, _25.g_AudioBounds.y, audioResponse);
    audioResponse = fast::clamp(powr(audioResponse, _25.g_AudioPower), 0.0, 1.0) * _25.g_AudioMultiply;
    return audioResponse;
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _25 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _25.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    float2 _143 = float2((in.a_TexCoord.x * _25.g_Texture2Resolution.z) / _25.g_Texture2Resolution.x, (in.a_TexCoord.y * _25.g_Texture2Resolution.w) / _25.g_Texture2Resolution.y);
    out.v_TexCoord.z = _143.x;
    out.v_TexCoord.w = _143.y;
    spvUnsafeArray<float, 16> param;
    param[0] = _25.g_AudioSpectrum16Left[0].x;
    param[1] = _25.g_AudioSpectrum16Left[1].x;
    param[2] = _25.g_AudioSpectrum16Left[2].x;
    param[3] = _25.g_AudioSpectrum16Left[3].x;
    param[4] = _25.g_AudioSpectrum16Left[4].x;
    param[5] = _25.g_AudioSpectrum16Left[5].x;
    param[6] = _25.g_AudioSpectrum16Left[6].x;
    param[7] = _25.g_AudioSpectrum16Left[7].x;
    param[8] = _25.g_AudioSpectrum16Left[8].x;
    param[9] = _25.g_AudioSpectrum16Left[9].x;
    param[10] = _25.g_AudioSpectrum16Left[10].x;
    param[11] = _25.g_AudioSpectrum16Left[11].x;
    param[12] = _25.g_AudioSpectrum16Left[12].x;
    param[13] = _25.g_AudioSpectrum16Left[13].x;
    param[14] = _25.g_AudioSpectrum16Left[14].x;
    param[15] = _25.g_AudioSpectrum16Left[15].x;
    spvUnsafeArray<float, 16> param_1;
    param_1[0] = _25.g_AudioSpectrum16Right[0].x;
    param_1[1] = _25.g_AudioSpectrum16Right[1].x;
    param_1[2] = _25.g_AudioSpectrum16Right[2].x;
    param_1[3] = _25.g_AudioSpectrum16Right[3].x;
    param_1[4] = _25.g_AudioSpectrum16Right[4].x;
    param_1[5] = _25.g_AudioSpectrum16Right[5].x;
    param_1[6] = _25.g_AudioSpectrum16Right[6].x;
    param_1[7] = _25.g_AudioSpectrum16Right[7].x;
    param_1[8] = _25.g_AudioSpectrum16Right[8].x;
    param_1[9] = _25.g_AudioSpectrum16Right[9].x;
    param_1[10] = _25.g_AudioSpectrum16Right[10].x;
    param_1[11] = _25.g_AudioSpectrum16Right[11].x;
    param_1[12] = _25.g_AudioSpectrum16Right[12].x;
    param_1[13] = _25.g_AudioSpectrum16Right[13].x;
    param_1[14] = _25.g_AudioSpectrum16Right[14].x;
    param_1[15] = _25.g_AudioSpectrum16Right[15].x;
    out.v_Pulse = CreateAudioResponse(param, param_1, _25);
    return out;
}

