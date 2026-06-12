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
    packed_float3 g_OutlineColor;
    float g_OutlineThreshold;
    float g_OutlineOpacity;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
    float2 v_TexCoordKernel_0 [[user(locn1)]];
    float2 v_TexCoordKernel_1 [[user(locn2)]];
    float2 v_TexCoordKernel_2 [[user(locn3)]];
    float2 v_TexCoordKernel_3 [[user(locn4)]];
    float2 v_TexCoordKernel_4 [[user(locn5)]];
    float2 v_TexCoordKernel_5 [[user(locn6)]];
    float2 v_TexCoordKernel_6 [[user(locn7)]];
    float2 v_TexCoordKernel_7 [[user(locn8)]];
    float2 v_TexCoordKernel_8 [[user(locn9)]];
    float2 v_TexCoordKernel_9 [[user(locn10)]];
    float2 v_TexCoordKernel_10 [[user(locn11)]];
    float2 v_TexCoordKernel_11 [[user(locn12)]];
    float2 v_TexCoordKernel_12 [[user(locn13)]];
    float2 v_TexCoordKernel_13 [[user(locn14)]];
    float2 v_TexCoordKernel_14 [[user(locn15)]];
    float2 v_TexCoordKernel_15 [[user(locn16)]];
    float2 v_TexCoordKernel_16 [[user(locn17)]];
    float2 v_TexCoordKernel_17 [[user(locn18)]];
    float2 v_TexCoordKernel_18 [[user(locn19)]];
    float2 v_TexCoordKernel_19 [[user(locn20)]];
    float2 v_TexCoordKernel_20 [[user(locn21)]];
    float2 v_TexCoordKernel_21 [[user(locn22)]];
    float2 v_TexCoordKernel_22 [[user(locn23)]];
    float2 v_TexCoordKernel_23 [[user(locn24)]];
    float2 v_TexCoordKernel_24 [[user(locn25)]];
    float2 v_TexCoordKernel_25 [[user(locn26)]];
    float2 v_TexCoordKernel_26 [[user(locn27)]];
    float2 v_TexCoordKernel_27 [[user(locn28)]];
    float2 v_TexCoordKernel_28 [[user(locn29)]];
    float2 v_TexCoordKernel_29 [[user(locn30)]];
    float2 v_TexCoordKernel_30 [[user(locn31)]];
    float2 v_TexCoordKernel_31 [[user(locn32)]];
    float2 v_TexCoordKernel_32 [[user(locn33)]];
    float2 v_TexCoordKernel_33 [[user(locn34)]];
    float2 v_TexCoordKernel_34 [[user(locn35)]];
    float2 v_TexCoordKernel_35 [[user(locn36)]];
    float2 v_TexCoordKernel_36 [[user(locn37)]];
    float2 v_TexCoordKernel_37 [[user(locn38)]];
    float2 v_TexCoordKernel_38 [[user(locn39)]];
    float2 v_TexCoordKernel_39 [[user(locn40)]];
    float2 v_TexCoordKernel_40 [[user(locn41)]];
    float2 v_TexCoordKernel_41 [[user(locn42)]];
    float2 v_TexCoordKernel_42 [[user(locn43)]];
    float2 v_TexCoordKernel_43 [[user(locn44)]];
    float2 v_TexCoordKernel_44 [[user(locn45)]];
    float2 v_TexCoordKernel_45 [[user(locn46)]];
    float2 v_TexCoordKernel_46 [[user(locn47)]];
    float2 v_TexCoordKernel_47 [[user(locn48)]];
    float2 v_TexCoordKernel_48 [[user(locn49)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _64 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 49> v_TexCoordKernel = {};
    v_TexCoordKernel[0] = in.v_TexCoordKernel_0;
    v_TexCoordKernel[1] = in.v_TexCoordKernel_1;
    v_TexCoordKernel[2] = in.v_TexCoordKernel_2;
    v_TexCoordKernel[3] = in.v_TexCoordKernel_3;
    v_TexCoordKernel[4] = in.v_TexCoordKernel_4;
    v_TexCoordKernel[5] = in.v_TexCoordKernel_5;
    v_TexCoordKernel[6] = in.v_TexCoordKernel_6;
    v_TexCoordKernel[7] = in.v_TexCoordKernel_7;
    v_TexCoordKernel[8] = in.v_TexCoordKernel_8;
    v_TexCoordKernel[9] = in.v_TexCoordKernel_9;
    v_TexCoordKernel[10] = in.v_TexCoordKernel_10;
    v_TexCoordKernel[11] = in.v_TexCoordKernel_11;
    v_TexCoordKernel[12] = in.v_TexCoordKernel_12;
    v_TexCoordKernel[13] = in.v_TexCoordKernel_13;
    v_TexCoordKernel[14] = in.v_TexCoordKernel_14;
    v_TexCoordKernel[15] = in.v_TexCoordKernel_15;
    v_TexCoordKernel[16] = in.v_TexCoordKernel_16;
    v_TexCoordKernel[17] = in.v_TexCoordKernel_17;
    v_TexCoordKernel[18] = in.v_TexCoordKernel_18;
    v_TexCoordKernel[19] = in.v_TexCoordKernel_19;
    v_TexCoordKernel[20] = in.v_TexCoordKernel_20;
    v_TexCoordKernel[21] = in.v_TexCoordKernel_21;
    v_TexCoordKernel[22] = in.v_TexCoordKernel_22;
    v_TexCoordKernel[23] = in.v_TexCoordKernel_23;
    v_TexCoordKernel[24] = in.v_TexCoordKernel_24;
    v_TexCoordKernel[25] = in.v_TexCoordKernel_25;
    v_TexCoordKernel[26] = in.v_TexCoordKernel_26;
    v_TexCoordKernel[27] = in.v_TexCoordKernel_27;
    v_TexCoordKernel[28] = in.v_TexCoordKernel_28;
    v_TexCoordKernel[29] = in.v_TexCoordKernel_29;
    v_TexCoordKernel[30] = in.v_TexCoordKernel_30;
    v_TexCoordKernel[31] = in.v_TexCoordKernel_31;
    v_TexCoordKernel[32] = in.v_TexCoordKernel_32;
    v_TexCoordKernel[33] = in.v_TexCoordKernel_33;
    v_TexCoordKernel[34] = in.v_TexCoordKernel_34;
    v_TexCoordKernel[35] = in.v_TexCoordKernel_35;
    v_TexCoordKernel[36] = in.v_TexCoordKernel_36;
    v_TexCoordKernel[37] = in.v_TexCoordKernel_37;
    v_TexCoordKernel[38] = in.v_TexCoordKernel_38;
    v_TexCoordKernel[39] = in.v_TexCoordKernel_39;
    v_TexCoordKernel[40] = in.v_TexCoordKernel_40;
    v_TexCoordKernel[41] = in.v_TexCoordKernel_41;
    v_TexCoordKernel[42] = in.v_TexCoordKernel_42;
    v_TexCoordKernel[43] = in.v_TexCoordKernel_43;
    v_TexCoordKernel[44] = in.v_TexCoordKernel_44;
    v_TexCoordKernel[45] = in.v_TexCoordKernel_45;
    v_TexCoordKernel[46] = in.v_TexCoordKernel_46;
    v_TexCoordKernel[47] = in.v_TexCoordKernel_47;
    v_TexCoordKernel[48] = in.v_TexCoordKernel_48;
    float4 centerColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float centerAlpha = centerColor.w;
    float maxNeighborAlpha = 0.0;
    for (int i = 0; i < 49; i++)
    {
        float neighborAlpha = g_Texture0.sample(g_Texture0Smplr, v_TexCoordKernel[i]).w;
        maxNeighborAlpha = fast::max(maxNeighborAlpha, neighborAlpha);
    }
    bool _68 = centerAlpha < _64.g_OutlineThreshold;
    bool _75;
    if (_68)
    {
        _75 = maxNeighborAlpha > _64.g_OutlineThreshold;
    }
    else
    {
        _75 = _68;
    }
    bool isEdge = _75;
    bool isInside = centerAlpha >= _64.g_OutlineThreshold;
    if (isInside)
    {
        out._fragColor = centerColor;
    }
    else
    {
        if (isEdge)
        {
            float edgeStrength = smoothstep(_64.g_OutlineThreshold - 0.100000001490116119384765625, _64.g_OutlineThreshold + 0.100000001490116119384765625, maxNeighborAlpha);
            out._fragColor = float4(_64.g_OutlineColor[0], _64.g_OutlineColor[1], _64.g_OutlineColor[2], edgeStrength * _64.g_OutlineOpacity);
        }
        else
        {
            out._fragColor = float4(0.0);
        }
    }
    return out;
}

