#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float2 g_Scale;
    float g_Sensitivity;
    float g_Center;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_ParallaxOffset [[user(locn0)]];
    float4 v_TexCoord [[user(locn1)]];
    float2 v_TexCoordMask [[user(locn2)]];
};

static inline __attribute__((always_inline))
float2 ParallaxMapping(thread const float2& texCoords, thread const float2& viewDir, constant _Globals& _26, texture2d<float> g_Texture1, sampler g_Texture1Smplr)
{
    float numLayers = 24.0;
    float layerDepth = 1.0 / numLayers;
    float currentLayerDepth = 1.0;
    float2 P = (viewDir * _26.g_Scale) * 0.100000001490116119384765625;
    float2 deltaTexCoords = P / float2(numLayers);
    float2 currentTexCoords = texCoords;
    float currentDepthMapValue = g_Texture1.sample(g_Texture1Smplr, currentTexCoords).x;
    for (float i = 0.0; (currentLayerDepth > currentDepthMapValue) && (i < numLayers); i += 1.0)
    {
        currentTexCoords -= deltaTexCoords;
        currentDepthMapValue = g_Texture1.sample(g_Texture1Smplr, currentTexCoords).x;
        currentLayerDepth -= layerDepth;
    }
    float2 prevTexCoords = currentTexCoords + deltaTexCoords;
    float afterDepth = currentDepthMapValue - currentLayerDepth;
    float beforeDepth = (g_Texture1.sample(g_Texture1Smplr, prevTexCoords).x - currentLayerDepth) - layerDepth;
    float weight = afterDepth / (afterDepth - beforeDepth);
    float2 finalTexCoords = (prevTexCoords * weight) + (currentTexCoords * (1.0 - weight));
    return finalTexCoords;
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _26 [[buffer(0)]], texture2d<float> g_Texture1 [[texture(0)]], texture2d<float> g_Texture2 [[texture(1)]], texture2d<float> g_Texture0 [[texture(2)]], sampler g_Texture1Smplr [[sampler(0)]], sampler g_Texture2Smplr [[sampler(1)]], sampler g_Texture0Smplr [[sampler(2)]])
{
    main0_out out = {};
    float depth = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord.zw).x;
    float mask = 1.0;
    mask *= g_Texture2.sample(g_Texture2Smplr, in.v_TexCoordMask).x;
    float ctrlSign = step(0.0, _26.g_Sensitivity);
    float negPerspective = -_26.g_Sensitivity;
    float ctrlPerspOrtho = fast::clamp(_26.g_Sensitivity, 0.0, 1.0) + step(9.9999997473787516355514526367188e-05, negPerspective);
    float2 prlx = mix(in.v_ParallaxOffset, float2(1.0) - in.v_ParallaxOffset, float2(ctrlSign));
    float2 coords = mix(in.v_TexCoord.xy, ((in.v_TexCoord.xy - float2(0.5)) / float2(1.0 + (_26.g_Sensitivity * 0.20000000298023223876953125))) + float2(0.5), float2(ctrlSign));
    coords -= ((((((prlx * 2.0) - float2(1.0)) * _26.g_Center) * float2(-0.0500000007450580596923828125, 0.0500000007450580596923828125)) * _26.g_Scale) * mix(-1.0, negPerspective, ctrlPerspOrtho));
    float2 pointer = float2(1.0 - in.v_TexCoord.z, in.v_TexCoord.w);
    float2 ctrlDir = pointer - prlx;
    ctrlDir = mix(float2(1.0 - prlx.x, prlx.y) - float2(0.5), ctrlDir * float2(-negPerspective, negPerspective), float2(ctrlPerspOrtho));
    float2 fakeViewdir = ctrlDir;
    float2 param = coords;
    float2 param_1 = fakeViewdir * mask;
    float2 newCoords = ParallaxMapping(param, param_1, _26, g_Texture1, g_Texture1Smplr);
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, newCoords);
    out._fragColor = albedo;
    return out;
}

