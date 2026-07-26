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
    float2 g_Scale;
    float4 g_Texture0Resolution;
};

struct main0_out
{
    float2 v_TexCoord_0 [[user(locn0)]];
    float2 v_TexCoord_1 [[user(locn1)]];
    float2 v_TexCoord_2 [[user(locn2)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _34 [[buffer(0)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 3> v_TexCoord = {};
    out.gl_Position = float4(in.a_Position, 1.0);
    float offsetX = 0.0;
    float offsetY = _34.g_Scale.y / _34.g_Texture0Resolution.w;
    v_TexCoord[0] = float2(in.a_TexCoord.x - offsetX, in.a_TexCoord.y - offsetY);
    v_TexCoord[1] = float2(in.a_TexCoord.x, in.a_TexCoord.y);
    v_TexCoord[2] = float2(in.a_TexCoord.x + offsetX, in.a_TexCoord.y + offsetY);
    out.v_TexCoord_0 = v_TexCoord[0];
    out.v_TexCoord_1 = v_TexCoord[1];
    out.v_TexCoord_2 = v_TexCoord[2];
    return out;
}

