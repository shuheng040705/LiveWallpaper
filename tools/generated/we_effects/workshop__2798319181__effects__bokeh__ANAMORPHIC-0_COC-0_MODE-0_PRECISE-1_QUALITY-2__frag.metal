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
    float u_gamma;
    float u_lightFactor;
    float u_ratio;
};

constant spvUnsafeArray<float2, 22> _115 = spvUnsafeArray<float2, 22>({ float2(0.0), float2(0.533333361148834228515625, 0.0), float2(0.3325279057025909423828125, 0.41697680950164794921875), float2(-0.118677847087383270263671875, 0.5199615955352783203125), float2(-0.480516731739044189453125, 0.23140470683574676513671875), float2(-0.480516731739044189453125, -0.23140467703342437744140625), float2(-0.11867763102054595947265625, -0.519961655139923095703125), float2(0.3325278460979461669921875, -0.4169768989086151123046875), float2(1.0, 0.0), float2(0.900968849658966064453125, 0.4338837563991546630859375), float2(0.623489797115325927734375, 0.7818315029144287109375), float2(0.2225209772586822509765625, 0.9749279022216796875), float2(-0.22252094745635986328125, 0.9749279022216796875), float2(-0.62348997592926025390625, 0.78183138370513916015625), float2(-0.900968849658966064453125, 0.4338838160037994384765625), float2(-1.0, 0.0), float2(-0.900968849658966064453125, -0.4338837563991546630859375), float2(-0.6234896183013916015625, -0.78183162212371826171875), float2(-0.22252054512500762939453125, -0.97492802143096923828125), float2(0.22252149879932403564453125, -0.97492778301239013671875), float2(0.623489677906036376953125, -0.78183162212371826171875), float2(0.900968849658966064453125, -0.4338837563991546630859375) });

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float v_Aperture [[user(locn0)]];
    float2 v_Gamma [[user(locn1)]];
    float2 v_Highlights [[user(locn2)]];
    float2 v_PixelSize [[user(locn3)]];
    float2 v_TexCoord [[user(locn4)]];
};

static inline __attribute__((always_inline))
float3 toneMap(thread const float3& color, thread const float& highlights)
{
    float luma = dot(color, float3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
    return color / float3(1.0 + (luma * highlights));
}

static inline __attribute__((always_inline))
float3 bokeh(thread const float2& coord, thread const float2& texelSize, thread const float2& gamma, thread const float2& highlights, texture2d<float> g_Texture0, sampler g_Texture0Smplr)
{
    float3 color = float3(0.0);
    for (int i = 0; i < 22; i++)
    {
        float2 offset = _115[i] * texelSize;
        float3 param = powr(fast::clamp(g_Texture0.sample(g_Texture0Smplr, (coord + offset)).xyz, float3(0.0), float3(1.0)), float3(gamma.x));
        float param_1 = highlights.x;
        color += toneMap(param, param_1);
    }
    float3 param_2 = color / float3(22.0);
    float param_3 = highlights.y;
    return powr(toneMap(param_2, param_3), float3(gamma.y));
}

fragment main0_out main0(main0_in in [[stage_in]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float2 depthTex = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord).xy;
    float depth = fast::max(depthTex.x, depthTex.y);
    bool _189 = depth > 0.00999999977648258209228515625;
    bool _196;
    if (_189)
    {
        _196 = in.v_Aperture > 0.00999999977648258209228515625;
    }
    else
    {
        _196 = _189;
    }
    if (_196)
    {
        float2 param = in.v_TexCoord;
        float2 param_1 = in.v_PixelSize * depth;
        float2 param_2 = in.v_Gamma;
        float2 param_3 = in.v_Highlights;
        albedo = float4(bokeh(param, param_1, param_2, param_3, g_Texture0, g_Texture0Smplr), albedo.w);
    }
    out._fragColor = albedo;
    return out;
}

