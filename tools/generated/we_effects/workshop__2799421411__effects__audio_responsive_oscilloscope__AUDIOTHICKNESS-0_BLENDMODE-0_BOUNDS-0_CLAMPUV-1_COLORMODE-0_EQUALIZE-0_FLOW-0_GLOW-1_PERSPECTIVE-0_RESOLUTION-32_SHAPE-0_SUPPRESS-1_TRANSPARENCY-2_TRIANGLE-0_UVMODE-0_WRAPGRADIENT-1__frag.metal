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
    float4 g_Texture0Resolution;
    float g_Time;
    char _m2_pad[12];
    packed_float3 u_color;
    float u_brightness;
    float u_scale;
    float u_size;
    float u_scope;
    float u_position;
    float u_thickness;
    float u_smoothness;
    float u_freqExponent;
    float u_alpha;
    float u_flowSpeed;
    float u_offset;
    float u_direction;
    float2 u_coord;
    float u_ratio;
    float u_bloom;
    float u_falloff;
    float u_whiteLevel;
    float u_feather;
    float u_focus;
    float u_area;
    float u_sides;
    float u_rotation;
    float u_gradientOffset;
    float2 u_bounds;
    float u_suppressFade;
    float u_suppressOffset;
    float u_suppressEdges;
    // 移植修复:audioValue 改在 frag 内计算(原 vert→frag 传 32×float4 interpolant > Metal 片元输入上限
    // → 静默丢失 → 波形恒 0)。音频频谱直接喂进 frag UBO,消除 32 个 interpolant。offset 与 manifest 对齐。
    float u_ampExponent;            // offset 164
    char _pad_audio[8];             // 对齐到 176
    float4 g_AudioSpectrum32Left[32];   // offset 176
    float4 g_AudioSpectrum32Right[32];  // offset 688
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    // audioValue 改在 frag 内计算(见 _Globals 注释)。
    float3 v_PerspCoord [[user(locn60)]];
    float2 v_TexCoord [[user(locn61)]];
    float3 v_ViewCoord [[user(locn62)]];
};

static inline __attribute__((always_inline))
float TnSin(thread float& angle)
{
    angle = (angle * 0.15899999439716339111328125) + 0.25;
    return (4.0 * abs(angle - floor(angle + 0.5))) - 1.0;
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

static inline __attribute__((always_inline))
float BlendTransparency(float base, float blend, float opacity)
{
    float transparency = base;
    transparency = fast::clamp(base + blend, 0.0, 1.0);
    return mix(base, transparency, opacity);
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _67 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    spvUnsafeArray<float4, 32> audioValue = {};
    {
        spvUnsafeArray<float, 32> audioData;
        for (int ai = 0; ai < 32; ai++)
        {
            float amplitude = (_67.g_AudioSpectrum32Left[ai].x * 0.5) + (_67.g_AudioSpectrum32Right[ai].x * 0.5);
            audioData[ai] = powr(amplitude + amplitude, _67.u_ampExponent + 0.001000000047497451305389404296875);
        }
        for (int ai = 0; ai < 32; ai += 4)
        {
            audioValue[ai >> 2] = float4(audioData[ai], audioData[ai + 1], audioData[ai + 2], audioData[ai + 3]);
        }
    }
    float2 ratio = float2(_67.g_Texture0Resolution.x / _67.g_Texture0Resolution.y, 1.0);
    float2 rotation = float2(sin(_67.u_direction), cos(_67.u_direction));
    float scope = round(_67.u_scope + _67.u_scope);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float opacity = 1.0 * _67.u_alpha;
    if (opacity > 0.001000000047497451305389404296875)
    {
        float2 perspCoord = in.v_PerspCoord.xy / float2(fast::max(0.001000000047497451305389404296875, in.v_PerspCoord.z));
        float2 coord = (perspCoord - ((rotation * (_67.u_position - 0.5)) + float2(0.5))) * ratio;
        coord = float2((coord.x * rotation.y) - (coord.y * rotation.x), (coord.x * rotation.x) + (coord.y * rotation.y));
        float X = coord.x + (_67.u_offset * 3.1415927410125732421875);
        float value = 0.0;
        float avgAmplitude = 0.0;
        for (int i = 0; i < 32; i++)
        {
            float f = float(i);
            float amp = audioValue[i >> 2][i & 3];
            float flow = _67.u_flowSpeed * amp;
            float frequencyFactor = exp((f * _67.u_freqExponent) / 6.400000095367431640625);
            float waveY = sin((((X + f) + flow) * frequencyFactor) * scope);
            avgAmplitude += amp;
            value += (waveY * amp);
        }
        value *= (_67.u_scale * 0.03125);
        float param = (((X + 0.0) * ratio.x) * _67.u_suppressEdges) + (_67.u_suppressOffset * 1.57079637050628662109375);
        float _264 = TnSin(param);
        float v = abs(_264);
        value *= fast::min(1.0, smoothstep(1.0, 0.0, v) / fast::max(0.001000000047497451305389404296875, _67.u_suppressFade * 0.5));
        avgAmplitude /= 32.0;
        float thickness = _67.u_thickness;
        float dist = abs(coord.y + value);
        dist += (step(0.5, fast::max(abs(perspCoord.x - 0.5), abs(perspCoord.y - 0.5))) * 1000000000.0);
        float smoothed = 1.0 - exp((-smoothstep(thickness * 0.014999999664723873138427734375, 0.0, dist)) / fast::max(9.9999999747524270787835121154785e-07, _67.u_smoothness));
        float4 wave = float4((float3(_67.u_color) + float3(_67.u_bloom * _67.u_whiteLevel)) * _67.u_brightness, smoothed) * smoothed;
        wave = fast::max(wave, float4(float3(_67.u_color) * _67.u_brightness, (_67.u_bloom * 1.0) * exp(((-dist) * 20.0) / _67.u_falloff)));
        float3 bg = g_Texture2.sample(g_Texture2Smplr, (((in.v_ViewCoord.xy / float2(in.v_ViewCoord.z)) * float2(0.5)) + float2(0.5))).xyz;
        float4 _383 = albedo;
        float _387 = albedo.w;
        float3 _389 = mix(bg, _383.xyz, float3(_387));
        albedo.x = _389.x;
        albedo.y = _389.y;
        albedo.z = _389.z;
        float3 param_1 = albedo.xyz;
        float3 param_2 = wave.xyz;
        float param_3 = opacity * wave.w;
        float3 _407 = ApplyBlending(0, param_1, param_2, param_3);
        albedo.x = _407.x;
        albedo.y = _407.y;
        albedo.z = _407.z;
        albedo.w = BlendTransparency(albedo.w, wave.w, opacity * step(0.0, in.v_PerspCoord.z));
    }
    out._fragColor = albedo;
    return out;
}

