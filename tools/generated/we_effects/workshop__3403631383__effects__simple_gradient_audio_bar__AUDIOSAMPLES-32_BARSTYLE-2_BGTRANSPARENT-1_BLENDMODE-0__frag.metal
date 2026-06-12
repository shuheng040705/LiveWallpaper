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
    float4 g_AudioSpectrum32Left[32];
    float4 g_AudioSpectrum32Right[32];
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
    float gap = _109.u_gap / 3200.0;
    float2 uv = float2(in.v_TexCoord.x, (1.0 - in.v_TexCoord.y) * in.v_scale);
    albedo.w = 0.0;
    spvUnsafeArray<float, 32> left;
    left[0] = _109.g_AudioSpectrum32Left[0].x;
    left[1] = _109.g_AudioSpectrum32Left[1].x;
    left[2] = _109.g_AudioSpectrum32Left[2].x;
    left[3] = _109.g_AudioSpectrum32Left[3].x;
    left[4] = _109.g_AudioSpectrum32Left[4].x;
    left[5] = _109.g_AudioSpectrum32Left[5].x;
    left[6] = _109.g_AudioSpectrum32Left[6].x;
    left[7] = _109.g_AudioSpectrum32Left[7].x;
    left[8] = _109.g_AudioSpectrum32Left[8].x;
    left[9] = _109.g_AudioSpectrum32Left[9].x;
    left[10] = _109.g_AudioSpectrum32Left[10].x;
    left[11] = _109.g_AudioSpectrum32Left[11].x;
    left[12] = _109.g_AudioSpectrum32Left[12].x;
    left[13] = _109.g_AudioSpectrum32Left[13].x;
    left[14] = _109.g_AudioSpectrum32Left[14].x;
    left[15] = _109.g_AudioSpectrum32Left[15].x;
    left[16] = _109.g_AudioSpectrum32Left[16].x;
    left[17] = _109.g_AudioSpectrum32Left[17].x;
    left[18] = _109.g_AudioSpectrum32Left[18].x;
    left[19] = _109.g_AudioSpectrum32Left[19].x;
    left[20] = _109.g_AudioSpectrum32Left[20].x;
    left[21] = _109.g_AudioSpectrum32Left[21].x;
    left[22] = _109.g_AudioSpectrum32Left[22].x;
    left[23] = _109.g_AudioSpectrum32Left[23].x;
    left[24] = _109.g_AudioSpectrum32Left[24].x;
    left[25] = _109.g_AudioSpectrum32Left[25].x;
    left[26] = _109.g_AudioSpectrum32Left[26].x;
    left[27] = _109.g_AudioSpectrum32Left[27].x;
    left[28] = _109.g_AudioSpectrum32Left[28].x;
    left[29] = _109.g_AudioSpectrum32Left[29].x;
    left[30] = _109.g_AudioSpectrum32Left[30].x;
    left[31] = _109.g_AudioSpectrum32Left[31].x;
    spvUnsafeArray<float, 32> right;
    right[0] = _109.g_AudioSpectrum32Right[0].x;
    right[1] = _109.g_AudioSpectrum32Right[1].x;
    right[2] = _109.g_AudioSpectrum32Right[2].x;
    right[3] = _109.g_AudioSpectrum32Right[3].x;
    right[4] = _109.g_AudioSpectrum32Right[4].x;
    right[5] = _109.g_AudioSpectrum32Right[5].x;
    right[6] = _109.g_AudioSpectrum32Right[6].x;
    right[7] = _109.g_AudioSpectrum32Right[7].x;
    right[8] = _109.g_AudioSpectrum32Right[8].x;
    right[9] = _109.g_AudioSpectrum32Right[9].x;
    right[10] = _109.g_AudioSpectrum32Right[10].x;
    right[11] = _109.g_AudioSpectrum32Right[11].x;
    right[12] = _109.g_AudioSpectrum32Right[12].x;
    right[13] = _109.g_AudioSpectrum32Right[13].x;
    right[14] = _109.g_AudioSpectrum32Right[14].x;
    right[15] = _109.g_AudioSpectrum32Right[15].x;
    right[16] = _109.g_AudioSpectrum32Right[16].x;
    right[17] = _109.g_AudioSpectrum32Right[17].x;
    right[18] = _109.g_AudioSpectrum32Right[18].x;
    right[19] = _109.g_AudioSpectrum32Right[19].x;
    right[20] = _109.g_AudioSpectrum32Right[20].x;
    right[21] = _109.g_AudioSpectrum32Right[21].x;
    right[22] = _109.g_AudioSpectrum32Right[22].x;
    right[23] = _109.g_AudioSpectrum32Right[23].x;
    right[24] = _109.g_AudioSpectrum32Right[24].x;
    right[25] = _109.g_AudioSpectrum32Right[25].x;
    right[26] = _109.g_AudioSpectrum32Right[26].x;
    right[27] = _109.g_AudioSpectrum32Right[27].x;
    right[28] = _109.g_AudioSpectrum32Right[28].x;
    right[29] = _109.g_AudioSpectrum32Right[29].x;
    right[30] = _109.g_AudioSpectrum32Right[30].x;
    right[31] = _109.g_AudioSpectrum32Right[31].x;
    float LenInverse = 0.03125;
    float len = 32.0;
    float width = (1.0 - (len * gap)) * LenInverse;
    float radius = (width * _109.u_radius) * 0.00999999977648258209228515625;
    int i = int(floor(in.v_TexCoord.x * len));
    float l = fast::clamp(mix(left[i], right[i], 0.5), 0.0, 1.0);
    float x = (float(i) * (width + gap)) + (gap * 0.5);
    float height = (l * _109.u_length) * in.v_scale;
    float y = (0.5 * in.v_scale) - (height * 0.5);
    float2 param = uv;
    float param_1 = x;
    float param_2 = y;
    float param_3 = width;
    float param_4 = height;
    float param_5 = radius;
    float _370 = bar(param, param_1, param_2, param_3, param_4, param_5);
    float solid = _370;
    float3 color = mix(_109.u_color0, float3(_109.u_color1), float3(in.v_TexCoord.y));
    float3 param_6 = albedo.xyz;
    float3 param_7 = color;
    float param_8 = solid;
    float3 _388 = ApplyBlending(0, param_6, param_7, param_8);
    albedo.x = _388.x;
    albedo.y = _388.y;
    albedo.z = _388.z;
    albedo.w += solid;
    albedo.w = mix(albedo.w, _109.u_alpha, solid);
    out._fragColor = albedo;
    return out;
}

