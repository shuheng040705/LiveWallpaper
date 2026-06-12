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
    float3 u_color0;
    packed_float3 u_color1;
    float u_gap;
    float u_radius;
    float u_length;
    float u_origin;
    float u_size;
    float u_alpha;
    float4 g_AudioSpectrum64Left[64];
    float4 g_AudioSpectrum64Right[64];
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
    float v_scale [[user(locn1)]];
};

static inline __attribute__((always_inline))
float bar(thread const float2& uv, thread const float& x, thread const float& y, thread const float& width, thread const float& height, thread float& radius)
{
    radius = fast::min(radius, fast::min(width, height) * 0.5);
    float2 center = float2(x + (width * 0.5), y + (height * 0.5));
    float2 halfSize = (float2(width, height) * 0.5) - float2(radius);
    float2 d = abs(uv - center) - halfSize;
    float dist = (length(fast::max(d, float2(0.0))) + fast::min(fast::max(d.x, d.y), 0.0)) - radius;
    return step(0.0, -dist);
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _109 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], sampler g_Texture0Smplr [[sampler(0)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float gap = _109.u_gap / 6400.0;
    float2 uv = float2(in.v_TexCoord.x, (1.0 - in.v_TexCoord.y) * in.v_scale);
    albedo.w = 0.0;
    spvUnsafeArray<float, 64> left;
    left[0] = _109.g_AudioSpectrum64Left[0].x;
    left[1] = _109.g_AudioSpectrum64Left[1].x;
    left[2] = _109.g_AudioSpectrum64Left[2].x;
    left[3] = _109.g_AudioSpectrum64Left[3].x;
    left[4] = _109.g_AudioSpectrum64Left[4].x;
    left[5] = _109.g_AudioSpectrum64Left[5].x;
    left[6] = _109.g_AudioSpectrum64Left[6].x;
    left[7] = _109.g_AudioSpectrum64Left[7].x;
    left[8] = _109.g_AudioSpectrum64Left[8].x;
    left[9] = _109.g_AudioSpectrum64Left[9].x;
    left[10] = _109.g_AudioSpectrum64Left[10].x;
    left[11] = _109.g_AudioSpectrum64Left[11].x;
    left[12] = _109.g_AudioSpectrum64Left[12].x;
    left[13] = _109.g_AudioSpectrum64Left[13].x;
    left[14] = _109.g_AudioSpectrum64Left[14].x;
    left[15] = _109.g_AudioSpectrum64Left[15].x;
    left[16] = _109.g_AudioSpectrum64Left[16].x;
    left[17] = _109.g_AudioSpectrum64Left[17].x;
    left[18] = _109.g_AudioSpectrum64Left[18].x;
    left[19] = _109.g_AudioSpectrum64Left[19].x;
    left[20] = _109.g_AudioSpectrum64Left[20].x;
    left[21] = _109.g_AudioSpectrum64Left[21].x;
    left[22] = _109.g_AudioSpectrum64Left[22].x;
    left[23] = _109.g_AudioSpectrum64Left[23].x;
    left[24] = _109.g_AudioSpectrum64Left[24].x;
    left[25] = _109.g_AudioSpectrum64Left[25].x;
    left[26] = _109.g_AudioSpectrum64Left[26].x;
    left[27] = _109.g_AudioSpectrum64Left[27].x;
    left[28] = _109.g_AudioSpectrum64Left[28].x;
    left[29] = _109.g_AudioSpectrum64Left[29].x;
    left[30] = _109.g_AudioSpectrum64Left[30].x;
    left[31] = _109.g_AudioSpectrum64Left[31].x;
    left[32] = _109.g_AudioSpectrum64Left[32].x;
    left[33] = _109.g_AudioSpectrum64Left[33].x;
    left[34] = _109.g_AudioSpectrum64Left[34].x;
    left[35] = _109.g_AudioSpectrum64Left[35].x;
    left[36] = _109.g_AudioSpectrum64Left[36].x;
    left[37] = _109.g_AudioSpectrum64Left[37].x;
    left[38] = _109.g_AudioSpectrum64Left[38].x;
    left[39] = _109.g_AudioSpectrum64Left[39].x;
    left[40] = _109.g_AudioSpectrum64Left[40].x;
    left[41] = _109.g_AudioSpectrum64Left[41].x;
    left[42] = _109.g_AudioSpectrum64Left[42].x;
    left[43] = _109.g_AudioSpectrum64Left[43].x;
    left[44] = _109.g_AudioSpectrum64Left[44].x;
    left[45] = _109.g_AudioSpectrum64Left[45].x;
    left[46] = _109.g_AudioSpectrum64Left[46].x;
    left[47] = _109.g_AudioSpectrum64Left[47].x;
    left[48] = _109.g_AudioSpectrum64Left[48].x;
    left[49] = _109.g_AudioSpectrum64Left[49].x;
    left[50] = _109.g_AudioSpectrum64Left[50].x;
    left[51] = _109.g_AudioSpectrum64Left[51].x;
    left[52] = _109.g_AudioSpectrum64Left[52].x;
    left[53] = _109.g_AudioSpectrum64Left[53].x;
    left[54] = _109.g_AudioSpectrum64Left[54].x;
    left[55] = _109.g_AudioSpectrum64Left[55].x;
    left[56] = _109.g_AudioSpectrum64Left[56].x;
    left[57] = _109.g_AudioSpectrum64Left[57].x;
    left[58] = _109.g_AudioSpectrum64Left[58].x;
    left[59] = _109.g_AudioSpectrum64Left[59].x;
    left[60] = _109.g_AudioSpectrum64Left[60].x;
    left[61] = _109.g_AudioSpectrum64Left[61].x;
    left[62] = _109.g_AudioSpectrum64Left[62].x;
    left[63] = _109.g_AudioSpectrum64Left[63].x;
    spvUnsafeArray<float, 64> right;
    right[0] = _109.g_AudioSpectrum64Right[0].x;
    right[1] = _109.g_AudioSpectrum64Right[1].x;
    right[2] = _109.g_AudioSpectrum64Right[2].x;
    right[3] = _109.g_AudioSpectrum64Right[3].x;
    right[4] = _109.g_AudioSpectrum64Right[4].x;
    right[5] = _109.g_AudioSpectrum64Right[5].x;
    right[6] = _109.g_AudioSpectrum64Right[6].x;
    right[7] = _109.g_AudioSpectrum64Right[7].x;
    right[8] = _109.g_AudioSpectrum64Right[8].x;
    right[9] = _109.g_AudioSpectrum64Right[9].x;
    right[10] = _109.g_AudioSpectrum64Right[10].x;
    right[11] = _109.g_AudioSpectrum64Right[11].x;
    right[12] = _109.g_AudioSpectrum64Right[12].x;
    right[13] = _109.g_AudioSpectrum64Right[13].x;
    right[14] = _109.g_AudioSpectrum64Right[14].x;
    right[15] = _109.g_AudioSpectrum64Right[15].x;
    right[16] = _109.g_AudioSpectrum64Right[16].x;
    right[17] = _109.g_AudioSpectrum64Right[17].x;
    right[18] = _109.g_AudioSpectrum64Right[18].x;
    right[19] = _109.g_AudioSpectrum64Right[19].x;
    right[20] = _109.g_AudioSpectrum64Right[20].x;
    right[21] = _109.g_AudioSpectrum64Right[21].x;
    right[22] = _109.g_AudioSpectrum64Right[22].x;
    right[23] = _109.g_AudioSpectrum64Right[23].x;
    right[24] = _109.g_AudioSpectrum64Right[24].x;
    right[25] = _109.g_AudioSpectrum64Right[25].x;
    right[26] = _109.g_AudioSpectrum64Right[26].x;
    right[27] = _109.g_AudioSpectrum64Right[27].x;
    right[28] = _109.g_AudioSpectrum64Right[28].x;
    right[29] = _109.g_AudioSpectrum64Right[29].x;
    right[30] = _109.g_AudioSpectrum64Right[30].x;
    right[31] = _109.g_AudioSpectrum64Right[31].x;
    right[32] = _109.g_AudioSpectrum64Right[32].x;
    right[33] = _109.g_AudioSpectrum64Right[33].x;
    right[34] = _109.g_AudioSpectrum64Right[34].x;
    right[35] = _109.g_AudioSpectrum64Right[35].x;
    right[36] = _109.g_AudioSpectrum64Right[36].x;
    right[37] = _109.g_AudioSpectrum64Right[37].x;
    right[38] = _109.g_AudioSpectrum64Right[38].x;
    right[39] = _109.g_AudioSpectrum64Right[39].x;
    right[40] = _109.g_AudioSpectrum64Right[40].x;
    right[41] = _109.g_AudioSpectrum64Right[41].x;
    right[42] = _109.g_AudioSpectrum64Right[42].x;
    right[43] = _109.g_AudioSpectrum64Right[43].x;
    right[44] = _109.g_AudioSpectrum64Right[44].x;
    right[45] = _109.g_AudioSpectrum64Right[45].x;
    right[46] = _109.g_AudioSpectrum64Right[46].x;
    right[47] = _109.g_AudioSpectrum64Right[47].x;
    right[48] = _109.g_AudioSpectrum64Right[48].x;
    right[49] = _109.g_AudioSpectrum64Right[49].x;
    right[50] = _109.g_AudioSpectrum64Right[50].x;
    right[51] = _109.g_AudioSpectrum64Right[51].x;
    right[52] = _109.g_AudioSpectrum64Right[52].x;
    right[53] = _109.g_AudioSpectrum64Right[53].x;
    right[54] = _109.g_AudioSpectrum64Right[54].x;
    right[55] = _109.g_AudioSpectrum64Right[55].x;
    right[56] = _109.g_AudioSpectrum64Right[56].x;
    right[57] = _109.g_AudioSpectrum64Right[57].x;
    right[58] = _109.g_AudioSpectrum64Right[58].x;
    right[59] = _109.g_AudioSpectrum64Right[59].x;
    right[60] = _109.g_AudioSpectrum64Right[60].x;
    right[61] = _109.g_AudioSpectrum64Right[61].x;
    right[62] = _109.g_AudioSpectrum64Right[62].x;
    right[63] = _109.g_AudioSpectrum64Right[63].x;
    float LenInverse = 0.015625;
    float len = 64.0;
    float width = (1.0 - (len * gap)) * LenInverse;
    float radius = (width * _109.u_radius) * 0.00999999977648258209228515625;
    int i = int(floor(in.v_TexCoord.x * len));
    float l = fast::clamp(mix(left[i], right[i], 0.5), 0.0, 1.0);
    float x = (float(i) * (width + gap)) + (gap * 0.5);
    float height = ((l * _109.u_length) * (1.0 - _109.u_origin)) * in.v_scale;
    float y = _109.u_origin * in.v_scale;
    float2 param = uv;
    float param_1 = x;
    float param_2 = y;
    float param_3 = width;
    float param_4 = height;
    float param_5 = radius;
    float _533 = bar(param, param_1, param_2, param_3, param_4, param_5);
    float solid = _533;
    float3 color = mix(_109.u_color0, float3(_109.u_color1), float3(in.v_TexCoord.y));
    float3 param_6 = albedo.xyz;
    float3 param_7 = color;
    float param_8 = solid;
    float3 _551 = ApplyBlending(0, param_6, param_7, param_8);
    albedo.x = _551.x;
    albedo.y = _551.y;
    albedo.z = _551.z;
    albedo.w += solid;
    albedo.w = mix(albedo.w, _109.u_alpha, solid);
    out._fragColor = albedo;
    return out;
}

