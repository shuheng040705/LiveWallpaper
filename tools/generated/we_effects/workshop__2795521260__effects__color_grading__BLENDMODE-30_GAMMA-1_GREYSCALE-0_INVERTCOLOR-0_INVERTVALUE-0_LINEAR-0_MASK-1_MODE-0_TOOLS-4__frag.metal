#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _Globals
{
    float u_alpha;
    float u_displayInitGamma;
    float u_displayGamma;
    char _m3_pad[4];
    packed_float3 u_channelMultiplier;
    float u_colorTemp;
    float u_whiteTint;
    float u_tollerance;
    float u_smooth;
};

struct main0_out
{
    float4 _fragColor [[color(0)]];
};

struct main0_in
{
    float2 v_TexCoord [[user(locn0)]];
};

static inline __attribute__((always_inline))
float3 whiteBalance(thread const float3& color, constant _Globals& _52)
{
    float t1 = _52.u_colorTemp * 1.66666698455810546875;
    float t2 = _52.u_whiteTint * 1.66666698455810546875;
    float x = 0.312709987163543701171875 - (t1 * ((t1 < 0.0) ? 0.100000001490116119384765625 : 0.0500000007450580596923828125));
    float standardIlluminantY = ((2.86999988555908203125 * x) - ((3.0 * x) * x)) - 0.2750950753688812255859375;
    float y = standardIlluminantY + (t2 * 0.0500000007450580596923828125);
    float X = x / y;
    float Z = ((1.0 - x) - y) / y;
    float L = ((0.732800006866455078125 * X) + 0.4296000003814697265625) - (0.1624000072479248046875 * Z);
    float M = (((-0.703599989414215087890625) * X) + 1.6974999904632568359375) + (0.006099999882280826568603515625 * Z);
    float S = ((0.0030000000260770320892333984375 * X) + 0.013600000180304050445556640625) + (0.98339998722076416015625 * Z);
    float3 w2 = float3(L, M, S);
    float3 balance = float3(0.94923698902130126953125 / w2.x, 1.035419940948486328125 / w2.y, 1.0872800350189208984375 / w2.z);
    float3 lms = color * float3x3(float3(0.390404999256134033203125, 0.549941003322601318359375, 0.008926319889724254608154296875), float3(0.070841602981090545654296875, 0.963172018527984619140625, 0.001357750035822391510009765625), float3(0.02310819923877716064453125, 0.1280210018157958984375, 0.936245024204254150390625));
    return (lms * balance) * float3x3(float3(2.85846996307373046875, -1.62879002094268798828125, -0.0248910002410411834716796875), float3(-0.21018199622631072998046875, 1.1582000255584716796875, 0.0003242809907533228397369384765625), float3(-0.0418119989335536956787109375, -0.118169002234935760498046875, 1.0686700344085693359375));
}

static inline __attribute__((always_inline))
float3 ApplyBlending(int blendMode, thread const float3& A, thread const float3& B, thread const float& opacity)
{
    return mix(A, float3(fast::max(A.x, fast::max(A.y, A.z))) * B, float3(opacity));
}

fragment main0_out main0(main0_in in [[stage_in]], constant _Globals& _52 [[buffer(0)]], texture2d<float> g_Texture0 [[texture(0)]], texture2d<float> g_Texture1 [[texture(1)]], sampler g_Texture0Smplr [[sampler(0)]], sampler g_Texture1Smplr [[sampler(1)]])
{
    main0_out out = {};
    float4 albedo = g_Texture0.sample(g_Texture0Smplr, in.v_TexCoord);
    float4 baseAlbedo = albedo;
    float mask = g_Texture1.sample(g_Texture1Smplr, in.v_TexCoord).x;
    bool _212 = mask > 0.0;
    bool _219;
    if (_212)
    {
        _219 = _52.u_alpha > 0.0;
    }
    else
    {
        _219 = _212;
    }
    if (_219)
    {
        bool _224 = _52.u_colorTemp != 0.0;
        bool _231;
        if (!_224)
        {
            _231 = _52.u_whiteTint != 0.0;
        }
        else
        {
            _231 = _224;
        }
        if (_231)
        {
            float3 param = albedo.xyz;
            float3 _237 = whiteBalance(param, _52);
            albedo.x = _237.x;
            albedo.y = _237.y;
            albedo.z = _237.z;
            float4 _246 = albedo;
            float3 _254 = mix(baseAlbedo.xyz, _246.xyz, float3((1.0 * mask) * _52.u_alpha));
            albedo.x = _254.x;
            albedo.y = _254.y;
            albedo.z = _254.z;
        }
        float4 _263 = albedo;
        float3 _275 = mix(baseAlbedo.xyz, _263.xyz, ((float3(_52.u_channelMultiplier) * 1.0) * mask) * _52.u_alpha);
        albedo.x = _275.x;
        albedo.y = _275.y;
        albedo.z = _275.z;
        float3 param_1 = baseAlbedo.xyz;
        float3 param_2 = albedo.xyz;
        float param_3 = (mask * albedo.w) * _52.u_alpha;
        float3 _298 = ApplyBlending(30, param_1, param_2, param_3);
        albedo.x = _298.x;
        albedo.y = _298.y;
        albedo.z = _298.z;
        float4 _305 = albedo;
        float3 _313 = powr(_305.xyz, float3(2.2000000476837158203125 / _52.u_displayGamma));
        albedo.x = _313.x;
        albedo.y = _313.y;
        albedo.z = _313.z;
    }
    out._fragColor = albedo;
    return out;
}

