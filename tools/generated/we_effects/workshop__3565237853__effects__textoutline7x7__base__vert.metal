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
    float4 g_Texture0Resolution;
    float g_OutlineWidth;
};

struct main0_out
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
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _19 [[buffer(0)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 49> v_TexCoordKernel = {};
    out.gl_Position = _19.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord;
    float2 texelSize = float2(1.0 / _19.g_Texture0Resolution.z, 1.0 / _19.g_Texture0Resolution.w) * _19.g_OutlineWidth;
    int index = 0;
    for (int y = -3; y <= 3; y++)
    {
        for (int x = -3; x <= 3; x++)
        {
            v_TexCoordKernel[index] = in.a_TexCoord + (float2(float(x), float(y)) * texelSize);
            index++;
        }
    }
    out.v_TexCoordKernel_0 = v_TexCoordKernel[0];
    out.v_TexCoordKernel_1 = v_TexCoordKernel[1];
    out.v_TexCoordKernel_2 = v_TexCoordKernel[2];
    out.v_TexCoordKernel_3 = v_TexCoordKernel[3];
    out.v_TexCoordKernel_4 = v_TexCoordKernel[4];
    out.v_TexCoordKernel_5 = v_TexCoordKernel[5];
    out.v_TexCoordKernel_6 = v_TexCoordKernel[6];
    out.v_TexCoordKernel_7 = v_TexCoordKernel[7];
    out.v_TexCoordKernel_8 = v_TexCoordKernel[8];
    out.v_TexCoordKernel_9 = v_TexCoordKernel[9];
    out.v_TexCoordKernel_10 = v_TexCoordKernel[10];
    out.v_TexCoordKernel_11 = v_TexCoordKernel[11];
    out.v_TexCoordKernel_12 = v_TexCoordKernel[12];
    out.v_TexCoordKernel_13 = v_TexCoordKernel[13];
    out.v_TexCoordKernel_14 = v_TexCoordKernel[14];
    out.v_TexCoordKernel_15 = v_TexCoordKernel[15];
    out.v_TexCoordKernel_16 = v_TexCoordKernel[16];
    out.v_TexCoordKernel_17 = v_TexCoordKernel[17];
    out.v_TexCoordKernel_18 = v_TexCoordKernel[18];
    out.v_TexCoordKernel_19 = v_TexCoordKernel[19];
    out.v_TexCoordKernel_20 = v_TexCoordKernel[20];
    out.v_TexCoordKernel_21 = v_TexCoordKernel[21];
    out.v_TexCoordKernel_22 = v_TexCoordKernel[22];
    out.v_TexCoordKernel_23 = v_TexCoordKernel[23];
    out.v_TexCoordKernel_24 = v_TexCoordKernel[24];
    out.v_TexCoordKernel_25 = v_TexCoordKernel[25];
    out.v_TexCoordKernel_26 = v_TexCoordKernel[26];
    out.v_TexCoordKernel_27 = v_TexCoordKernel[27];
    out.v_TexCoordKernel_28 = v_TexCoordKernel[28];
    out.v_TexCoordKernel_29 = v_TexCoordKernel[29];
    out.v_TexCoordKernel_30 = v_TexCoordKernel[30];
    out.v_TexCoordKernel_31 = v_TexCoordKernel[31];
    out.v_TexCoordKernel_32 = v_TexCoordKernel[32];
    out.v_TexCoordKernel_33 = v_TexCoordKernel[33];
    out.v_TexCoordKernel_34 = v_TexCoordKernel[34];
    out.v_TexCoordKernel_35 = v_TexCoordKernel[35];
    out.v_TexCoordKernel_36 = v_TexCoordKernel[36];
    out.v_TexCoordKernel_37 = v_TexCoordKernel[37];
    out.v_TexCoordKernel_38 = v_TexCoordKernel[38];
    out.v_TexCoordKernel_39 = v_TexCoordKernel[39];
    out.v_TexCoordKernel_40 = v_TexCoordKernel[40];
    out.v_TexCoordKernel_41 = v_TexCoordKernel[41];
    out.v_TexCoordKernel_42 = v_TexCoordKernel[42];
    out.v_TexCoordKernel_43 = v_TexCoordKernel[43];
    out.v_TexCoordKernel_44 = v_TexCoordKernel[44];
    out.v_TexCoordKernel_45 = v_TexCoordKernel[45];
    out.v_TexCoordKernel_46 = v_TexCoordKernel[46];
    out.v_TexCoordKernel_47 = v_TexCoordKernel[47];
    out.v_TexCoordKernel_48 = v_TexCoordKernel[48];
    return out;
}

