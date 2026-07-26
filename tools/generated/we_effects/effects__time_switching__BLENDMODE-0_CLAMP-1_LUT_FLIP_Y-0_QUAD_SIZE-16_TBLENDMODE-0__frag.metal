#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float g_Stage;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float v_Multiply1 [[user(locn0)]];
    float v_Multiply2 [[user(locn1)]];
    float v_Multiply3 [[user(locn2)]];
    float v_Multiply4 [[user(locn3)]];
    float2 v_TexCoord [[user(locn4)]];
};

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _113 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture4 [[texture(1)]], texture2d<float> g_Texture1 [[texture(2)]], texture2d<float> g_Texture2 [[texture(3)]], texture2d<float> g_Texture3 [[texture(4)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture4Smplr [[sampler(1)]], sampler g_Texture1Smplr [[sampler(2)]], sampler g_Texture2Smplr [[sampler(3)]], sampler g_Texture3Smplr [[sampler(4)]])
{
    main0_out out = {};
    float4 textureColor = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    textureColor = fast::clamp(textureColor, float4(0.0), float4(1.0));
    float blueColor = textureColor.z * 15.0;
    float quad1y = floor(floor(blueColor) * 0.25);
    float quad2y = floor(ceil(blueColor) * 0.25);
    float2 texPos1;
    texPos1.x = (((floor(blueColor) - (quad1y * 4.0)) * 0.25) + 0.0078125) + (0.234375 * textureColor.x);
    texPos1.y = ((quad1y * 0.25) + 0.0078125) + (0.234375 * textureColor.y);
    float2 texPos2;
    texPos2.x = (((ceil(blueColor) - (quad2y * 4.0)) * 0.25) + 0.0078125) + (0.234375 * textureColor.x);
    texPos2.y = ((quad2y * 0.25) + 0.0078125) + (0.234375 * textureColor.y);
    bool _118 = _113.g_Stage > 0.0;
    bool _124;
    if (_118)
    {
        _124 = _113.g_Stage < 1.0;
    }
    else
    {
        _124 = _118;
    }
    if (_124)
    {
        float weight = _113.g_Stage;
        float3 param = mix(g_Texture4.sample(g_Texture4Smplr, texPos1, level(0.0)).xyz, g_Texture4.sample(g_Texture4Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
        float3 param_1 = mix(g_Texture1.sample(g_Texture1Smplr, texPos1, level(0.0)).xyz, g_Texture1.sample(g_Texture1Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
        float param_2 = weight;
        float3 param_3 = textureColor.xyz;
        float3 param_4 = ApplyBlending(0, param, param_1, param_2);
        float param_5 = mix(in.v_Multiply4, in.v_Multiply1, weight);
        out._fragColor = float4(ApplyBlending(0, param_3, param_4, param_5), textureColor.w);
    }
    else
    {
        if (_113.g_Stage == 1.0)
        {
            float3 param_6 = textureColor.xyz;
            float3 param_7 = mix(g_Texture1.sample(g_Texture1Smplr, texPos1, level(0.0)).xyz, g_Texture1.sample(g_Texture1Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
            float param_8 = in.v_Multiply1;
            out._fragColor = float4(ApplyBlending(0, param_6, param_7, param_8), textureColor.w);
        }
        else
        {
            bool _217 = _113.g_Stage > 1.0;
            bool _224;
            if (_217)
            {
                _224 = _113.g_Stage < 2.0;
            }
            else
            {
                _224 = _217;
            }
            if (_224)
            {
                float weight_1 = _113.g_Stage - 1.0;
                float3 param_9 = mix(g_Texture1.sample(g_Texture1Smplr, texPos1, level(0.0)).xyz, g_Texture1.sample(g_Texture1Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                float3 param_10 = mix(g_Texture2.sample(g_Texture2Smplr, texPos1, level(0.0)).xyz, g_Texture2.sample(g_Texture2Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                float param_11 = weight_1;
                float3 param_12 = textureColor.xyz;
                float3 param_13 = ApplyBlending(0, param_9, param_10, param_11);
                float param_14 = mix(in.v_Multiply1, in.v_Multiply2, weight_1);
                out._fragColor = float4(ApplyBlending(0, param_12, param_13, param_14), textureColor.w);
            }
            else
            {
                if (_113.g_Stage == 2.0)
                {
                    float3 param_15 = textureColor.xyz;
                    float3 param_16 = mix(g_Texture2.sample(g_Texture2Smplr, texPos1, level(0.0)).xyz, g_Texture2.sample(g_Texture2Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                    float param_17 = in.v_Multiply2;
                    out._fragColor = float4(ApplyBlending(0, param_15, param_16, param_17), textureColor.w);
                }
                else
                {
                    bool _312 = _113.g_Stage > 2.0;
                    bool _319;
                    if (_312)
                    {
                        _319 = _113.g_Stage < 3.0;
                    }
                    else
                    {
                        _319 = _312;
                    }
                    if (_319)
                    {
                        float weight_2 = _113.g_Stage - 2.0;
                        float3 param_18 = mix(g_Texture2.sample(g_Texture2Smplr, texPos1, level(0.0)).xyz, g_Texture2.sample(g_Texture2Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                        float3 param_19 = mix(g_Texture3.sample(g_Texture3Smplr, texPos1, level(0.0)).xyz, g_Texture3.sample(g_Texture3Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                        float param_20 = weight_2;
                        float3 param_21 = textureColor.xyz;
                        float3 param_22 = ApplyBlending(0, param_18, param_19, param_20);
                        float param_23 = mix(in.v_Multiply2, in.v_Multiply3, weight_2);
                        out._fragColor = float4(ApplyBlending(0, param_21, param_22, param_23), textureColor.w);
                    }
                    else
                    {
                        if (_113.g_Stage == 3.0)
                        {
                            float3 param_24 = textureColor.xyz;
                            float3 param_25 = mix(g_Texture3.sample(g_Texture3Smplr, texPos1, level(0.0)).xyz, g_Texture3.sample(g_Texture3Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                            float param_26 = in.v_Multiply3;
                            out._fragColor = float4(ApplyBlending(0, param_24, param_25, param_26), textureColor.w);
                        }
                        else
                        {
                            bool _407 = _113.g_Stage > 3.0;
                            bool _413;
                            if (_407)
                            {
                                _413 = _113.g_Stage < 4.0;
                            }
                            else
                            {
                                _413 = _407;
                            }
                            if (_413)
                            {
                                float weight_3 = _113.g_Stage - 3.0;
                                float3 param_27 = mix(g_Texture3.sample(g_Texture3Smplr, texPos1, level(0.0)).xyz, g_Texture3.sample(g_Texture3Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                                float3 param_28 = mix(g_Texture4.sample(g_Texture4Smplr, texPos1, level(0.0)).xyz, g_Texture4.sample(g_Texture4Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                                float param_29 = weight_3;
                                float3 param_30 = textureColor.xyz;
                                float3 param_31 = ApplyBlending(0, param_27, param_28, param_29);
                                float param_32 = mix(in.v_Multiply3, in.v_Multiply4, weight_3);
                                out._fragColor = float4(ApplyBlending(0, param_30, param_31, param_32), textureColor.w);
                            }
                            else
                            {
                                float3 param_33 = textureColor.xyz;
                                float3 param_34 = mix(g_Texture4.sample(g_Texture4Smplr, texPos1, level(0.0)).xyz, g_Texture4.sample(g_Texture4Smplr, texPos2, level(0.0)).xyz, float3(fract(blueColor)));
                                float param_35 = in.v_Multiply4;
                                out._fragColor = float4(ApplyBlending(0, param_33, param_34, param_35), textureColor.w);
                            }
                        }
                    }
                }
            }
        }
    }
    return out;
}

