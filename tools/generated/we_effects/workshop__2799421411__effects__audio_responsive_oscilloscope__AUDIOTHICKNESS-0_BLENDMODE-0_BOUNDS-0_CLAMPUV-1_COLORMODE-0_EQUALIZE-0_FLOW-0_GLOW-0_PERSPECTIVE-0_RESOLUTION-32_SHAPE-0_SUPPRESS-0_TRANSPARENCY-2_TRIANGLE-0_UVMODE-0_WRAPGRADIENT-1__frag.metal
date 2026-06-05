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
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
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
};

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

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _46 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]])
{
    main0_out out = {};
    spvUnsafeArray<float4, 32> audioValue = {};
    audioValue[0] = in.audioValue_0;
    audioValue[1] = in.audioValue_1;
    audioValue[2] = in.audioValue_2;
    audioValue[3] = in.audioValue_3;
    audioValue[4] = in.audioValue_4;
    audioValue[5] = in.audioValue_5;
    audioValue[6] = in.audioValue_6;
    audioValue[7] = in.audioValue_7;
    audioValue[8] = in.audioValue_8;
    audioValue[9] = in.audioValue_9;
    audioValue[10] = in.audioValue_10;
    audioValue[11] = in.audioValue_11;
    audioValue[12] = in.audioValue_12;
    audioValue[13] = in.audioValue_13;
    audioValue[14] = in.audioValue_14;
    audioValue[15] = in.audioValue_15;
    audioValue[16] = in.audioValue_16;
    audioValue[17] = in.audioValue_17;
    audioValue[18] = in.audioValue_18;
    audioValue[19] = in.audioValue_19;
    audioValue[20] = in.audioValue_20;
    audioValue[21] = in.audioValue_21;
    audioValue[22] = in.audioValue_22;
    audioValue[23] = in.audioValue_23;
    audioValue[24] = in.audioValue_24;
    audioValue[25] = in.audioValue_25;
    audioValue[26] = in.audioValue_26;
    audioValue[27] = in.audioValue_27;
    audioValue[28] = in.audioValue_28;
    audioValue[29] = in.audioValue_29;
    audioValue[30] = in.audioValue_30;
    audioValue[31] = in.audioValue_31;
    float2 ratio = float2(_46.g_Texture0Resolution.x / _46.g_Texture0Resolution.y, 1.0);
    float2 rotation = float2(sin(_46.u_direction), cos(_46.u_direction));
    float scope = round(_46.u_scope + _46.u_scope);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float opacity = 1.0 * _46.u_alpha;
    if (opacity > 0.001000000047497451305389404296875)
    {
        float2 perspCoord = in.v_PerspCoord.xy / float2(fast::max(0.001000000047497451305389404296875, in.v_PerspCoord.z));
        float2 coord = (perspCoord - ((rotation * (_46.u_position - 0.5)) + float2(0.5))) * ratio;
        coord = float2((coord.x * rotation.y) - (coord.y * rotation.x), (coord.x * rotation.x) + (coord.y * rotation.y));
        float X = coord.x + (_46.u_offset * 3.1415927410125732421875);
        float value = 0.0;
        float avgAmplitude = 0.0;
        for (int i = 0; i < 32; i++)
        {
            float f = float(i);
            float amp = audioValue[i >> 2][i & 3];
            float flow = _46.u_flowSpeed * amp;
            float frequencyFactor = exp((f * _46.u_freqExponent) / 6.400000095367431640625);
            float waveY = sin((((X + f) + flow) * frequencyFactor) * scope);
            avgAmplitude += amp;
            value += (waveY * amp);
        }
        value *= (_46.u_scale * 0.03125);
        avgAmplitude /= 32.0;
        float thickness = _46.u_thickness;
        float dist = abs(coord.y + value);
        dist += (step(0.5, fast::max(abs(perspCoord.x - 0.5), abs(perspCoord.y - 0.5))) * 1000000000.0);
        float smoothed = 1.0 - exp((-smoothstep(thickness * 0.014999999664723873138427734375, 0.0, dist)) / fast::max(9.9999999747524270787835121154785e-07, _46.u_smoothness));
        float4 wave = float4(float3(_46.u_color) * _46.u_brightness, smoothed);
        float3 bg = g_Texture2.sample(g_Texture2Smplr, (((in.v_ViewCoord.xy / float2(in.v_ViewCoord.z)) * float2(0.5)) + float2(0.5))).xyz;
        float4 _298 = albedo;
        float _302 = albedo.w;
        float3 _304 = mix(bg, _298.xyz, float3(_302));
        albedo.x = _304.x;
        albedo.y = _304.y;
        albedo.z = _304.z;
        float3 param = albedo.xyz;
        float3 param_1 = wave.xyz;
        float param_2 = opacity * wave.w;
        float3 _322 = ApplyBlending(0, param, param_1, param_2);
        albedo.x = _322.x;
        albedo.y = _322.y;
        albedo.z = _322.z;
        albedo.w = BlendTransparency(albedo.w, wave.w, opacity * step(0.0, in.v_PerspCoord.z));
    }
    out._fragColor = albedo;
    return out;
}

