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
    float u_alpha;
    float u_strength;
    float u_gamma;
    float u_threshold;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float v_Damp [[user(locn0)]];
    float2 v_TexCoord_0 [[user(locn1)]];
    float2 v_TexCoord_1 [[user(locn2)]];
    float2 v_TexCoord_2 [[user(locn3)]];
    float2 v_TexCoord_3 [[user(locn4)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _18 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    spvUnsafeArray<float2, 4> v_TexCoord = {};
    v_TexCoord[0] = in.v_TexCoord_0;
    v_TexCoord[1] = in.v_TexCoord_1;
    v_TexCoord[2] = in.v_TexCoord_2;
    v_TexCoord[3] = in.v_TexCoord_3;
    float weight = 0.0;
    float luma = 0.0;
    float4 lightMap = float4(0.0);
    bool _25 = _18.u_strength > 0.001000000047497451305389404296875;
    bool _32;
    if (_25)
    {
        _32 = _18.u_alpha > 0.001000000047497451305389404296875;
    }
    else
    {
        _32 = _25;
    }
    if (_32)
    {
        float4 _92;
        for (int i = 0; i < 4; i++)
        {
            float emitters = 1.0;
            float4 samp_ = g_Texture0.sample(g_Texture0Smplr, v_TexCoord[i]);
            float4 _65 = samp_;
            float3 _73 = powr(_65.xyz, float3(_18.u_gamma)) * emitters;
            samp_.x = _73.x;
            samp_.y = _73.y;
            samp_.z = _73.z;
            luma = dot(samp_.xyz, float3(1.0));
            if (luma > _18.u_threshold)
            {
                _92 = lightMap + samp_;
            }
            else
            {
                _92 = lightMap;
            }
            lightMap = _92;
            weight += ((samp_.x + samp_.y) + samp_.z);
        }
    }
    out._fragColor = float4((lightMap.xyz * fast::max(0.001000000047497451305389404296875, mix(weight, 1.0, in.v_Damp))) / float3(4.0), 1.0);
    return out;
}

