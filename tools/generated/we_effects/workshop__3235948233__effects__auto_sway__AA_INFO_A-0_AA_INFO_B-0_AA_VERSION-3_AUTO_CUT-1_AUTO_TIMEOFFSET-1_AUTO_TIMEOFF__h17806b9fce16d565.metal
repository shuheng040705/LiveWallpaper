#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Returns the determinant of a 2x2 matrix.
static inline __attribute__((always_inline))
float spvDet2x2(float a1, float a2, float b1, float b2)
{
    return a1 * b2 - b1 * a2;
}

// Returns the inverse of a matrix, by using the algorithm of calculating the classical
// adjoint and dividing by the determinant. The contents of the matrix are changed.
static inline __attribute__((always_inline))
float3x3 spvInverse3x3(float3x3 m)
{
    float3x3 adj;	// The adjoint matrix (inverse after dividing by determinant)

    // Create the transpose of the cofactors, as the classical adjoint of the matrix.
    adj[0][0] =  spvDet2x2(m[1][1], m[1][2], m[2][1], m[2][2]);
    adj[0][1] = -spvDet2x2(m[0][1], m[0][2], m[2][1], m[2][2]);
    adj[0][2] =  spvDet2x2(m[0][1], m[0][2], m[1][1], m[1][2]);

    adj[1][0] = -spvDet2x2(m[1][0], m[1][2], m[2][0], m[2][2]);
    adj[1][1] =  spvDet2x2(m[0][0], m[0][2], m[2][0], m[2][2]);
    adj[1][2] = -spvDet2x2(m[0][0], m[0][2], m[1][0], m[1][2]);

    adj[2][0] =  spvDet2x2(m[1][0], m[1][1], m[2][0], m[2][1]);
    adj[2][1] = -spvDet2x2(m[0][0], m[0][1], m[2][0], m[2][1]);
    adj[2][2] =  spvDet2x2(m[0][0], m[0][1], m[1][0], m[1][1]);

    // Calculate the determinant as a combination of the cofactors of the first row.
    float det = (adj[0][0] * m[0][0]) + (adj[0][1] * m[1][0]) + (adj[0][2] * m[2][0]);

    // Divide the classical adjoint matrix by the determinant.
    // If determinant is zero, matrix is not invertable, so leave it unchanged.
    return (det != 0.0f) ? (adj * (1.0f / det)) : m;
}

struct _Globals
{
    float4x4 g_ModelViewProjectionMatrix;
    float4 g_Texture0Resolution;
    float4 g_Texture1Resolution;
    float g_Time;
    float2 g_SpinCenter1;
    float g_WindDirection1;
    float g_WindDirection2;
    float g_TimeOffset1;
    float2 g_SpinCenter2;
    float g_WindDirection3;
    float g_TimeOffset2;
    float2 g_SpinCenter3;
    float g_WindDirection4;
    float g_TimeOffset3;
    float2 g_SpinCenter4;
    float g_WindDirection5;
    float g_TimeOffset4;
    float g_GlobalWindOffset;
    float g_GlobalTimeOffset;
    float g_Speed;
    float g_Inertia;
    float g_SigmentCount;
    float g_Exponent;
    float g_SmoothDistance;
    float g_DirectionalCompensation;
    float2 g_Point0;
    float2 g_Point1;
    float2 g_Point2;
    float2 g_Point3;
};

struct main0_out
{
    float2 v_AspectedRootNodeCenter [[user(locn0)]];
    float2 v_Direction1 [[user(locn1)]];
    float2 v_Direction2 [[user(locn3)]];
    float2 v_Direction3 [[user(locn4)]];
    float v_EndpointLen1 [[user(locn21)]];
    float v_EndpointLen2 [[user(locn23)]];
    float v_EndpointLen3 [[user(locn24)]];
    float v_Len1 [[user(locn41)]];
    float v_Len2 [[user(locn43)]];
    float v_Len3 [[user(locn44)]];
    float v_MotionRadian1 [[user(locn51)]];
    float v_MotionRadian2 [[user(locn53)]];
    float v_MotionRadian3 [[user(locn54)]];
    float v_PosX1 [[user(locn61)]];
    float v_PosX2 [[user(locn63)]];
    float v_PosX3 [[user(locn64)]];
    float3 v_QuadMaskCoord [[user(locn71)]];
    float v_StartpointLen1 [[user(locn72)]];
    float v_StartpointLen2 [[user(locn74)]];
    float v_StartpointLen3 [[user(locn75)]];
    float4 v_TexCoord [[user(locn82)]];
    float v_aspect [[user(locn83)]];
    float v_reciprocalAspect [[user(locn84)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 a_Position [[attribute(0)]];
    float2 a_TexCoord [[attribute(1)]];
};

static inline __attribute__((always_inline))
float3x3 squareToQuad(thread const float2& p0, thread const float2& p1, thread const float2& p2, thread const float2& p3)
{
    float3x3 m = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0));
    float dx0 = p0.x;
    float dy0 = p0.y;
    float dx1 = p1.x;
    float dy1 = p1.y;
    float dx2 = p3.x;
    float dy2 = p3.y;
    float dx3 = p2.x;
    float dy3 = p2.y;
    float diffx1 = dx1 - dx3;
    float diffy1 = dy1 - dy3;
    float diffx2 = dx2 - dx3;
    float diffy2 = dy2 - dy3;
    float det = (diffx1 * diffy2) - (diffx2 * diffy1);
    float sumx = ((dx0 - dx1) + dx3) - dx2;
    float sumy = ((dy0 - dy1) + dy3) - dy2;
    bool _126 = det == 0.0;
    bool _135;
    if (!_126)
    {
        _135 = (sumx == 0.0) && (sumy == 0.0);
    }
    else
    {
        _135 = _126;
    }
    if (_135)
    {
        m[0].x = dx1 - dx0;
        m[0].y = dy1 - dy0;
        m[0].z = 0.0;
        m[1].x = dx3 - dx1;
        m[1].y = dy3 - dy1;
        m[1].z = 0.0;
        m[2].x = dx0;
        m[2].y = dy0;
        m[2].z = 1.0;
        return m;
    }
    else
    {
        float ovdet = 1.0 / det;
        float g = ((sumx * diffy2) - (diffx2 * sumy)) * ovdet;
        float h = ((diffx1 * sumy) - (sumx * diffy1)) * ovdet;
        m[0].x = (dx1 - dx0) + (g * dx1);
        m[0].y = (dy1 - dy0) + (g * dy1);
        m[0].z = g;
        m[1].x = (dx2 - dx0) + (h * dx2);
        m[1].y = (dy2 - dy0) + (h * dy2);
        m[1].z = h;
        m[2].x = dx0;
        m[2].y = dy0;
        m[2].z = 1.0;
        return m;
    }
}

static inline __attribute__((always_inline))
float linearStep(thread const float& lower, thread const float& upper, thread const float& x)
{
    return fast::clamp((x - lower) / (upper - lower), 0.0, 1.0);
}

static inline __attribute__((always_inline))
void preCalcNode(thread const int& nodeNum, thread const float2& texCoord, thread const float& aspectFactor, thread const float& motitionOffset, thread const float2& aspectedRootNodeCenter, thread const float2& endpointNodeCenter, thread float2& thisNodeCenter, thread float2& nextNodeCenter, thread const float& thisWindDirection, thread const float& nextWindDirection, thread const float& inertia, thread const float& thisOffset, thread const float& nextOffset, thread float2& thisDirection, thread float& startpointLength, thread float& thisLength, thread float& endpointLength, thread float& thisPosX, thread float& thisMotionRadian, constant _Globals& _273)
{
    thisNodeCenter.x *= aspectFactor;
    nextNodeCenter.x *= aspectFactor;
    float2 nodeVec = thisNodeCenter - nextNodeCenter;
    float2 eNodeVec = endpointNodeCenter - nextNodeCenter;
    thisDirection = fast::normalize(nodeVec);
    float2 endpointDirection = mix(fast::normalize(eNodeVec), thisDirection, float2(_273.g_DirectionalCompensation));
    float2 relativeTexCoord = texCoord - nextNodeCenter;
    thisPosX = dot(relativeTexCoord, endpointDirection);
    thisLength = dot(nodeVec, thisDirection);
    endpointLength = mix(thisLength, dot(eNodeVec, endpointDirection), _273.g_SmoothDistance);
    startpointLength = distance(nextNodeCenter, aspectedRootNodeCenter);
    float thisMotionTime = _273.g_GlobalTimeOffset + (_273.g_Time * _273.g_Speed);
    float prevMotionTime = thisMotionTime;
    float param = 2.0;
    float param_1 = 4.0;
    float param_2 = float(nodeNum);
    thisMotionTime += (motitionOffset * linearStep(param, param_1, param_2));
    float param_3 = 2.0;
    float param_4 = 4.0;
    float param_5 = float(nodeNum + 1);
    prevMotionTime += (motitionOffset * linearStep(param_3, param_4, param_5));
    thisMotionRadian = sin(thisMotionTime * 6.283185482025146484375);
    float prevMotionRadian = sin(prevMotionTime * 6.283185482025146484375) * inertia;
    thisMotionRadian += (sin(thisWindDirection + 1.57079637050628662109375) + sin(_273.g_GlobalWindOffset));
    prevMotionRadian += sin(nextWindDirection + 1.57079637050628662109375);
    prevMotionRadian *= step(0.5, float(nodeNum));
    thisMotionRadian -= prevMotionRadian;
}

vertex main0_out main0(main0_in in [[stage_in]], constant _Globals& _273 [[buffer(0)]])
{
    main0_out out = {};
    out.gl_Position = _273.g_ModelViewProjectionMatrix * float4(in.a_Position, 1.0);
    out.v_TexCoord = in.a_TexCoord.xyxy;
    out.v_aspect = _273.g_Texture0Resolution.z / _273.g_Texture0Resolution.w;
    float4 _404 = out.v_TexCoord;
    float2 _406 = _404.xz * out.v_aspect;
    out.v_TexCoord.x = _406.x;
    out.v_TexCoord.z = _406.y;
    out.v_reciprocalAspect = 1.0 / out.v_aspect;
    out.v_AspectedRootNodeCenter = _273.g_SpinCenter4 * out.v_aspect;
    float2 param = _273.g_Point0;
    float2 param_1 = _273.g_Point1;
    float2 param_2 = _273.g_Point2;
    float2 param_3 = _273.g_Point3;
    float3x3 xform = spvInverse3x3(squareToQuad(param, param_1, param_2, param_3));
    out.v_QuadMaskCoord = xform * float3(in.a_TexCoord, 1.0);
    float2 endpointSpinCenter = _273.g_SpinCenter1;
    endpointSpinCenter.x *= out.v_aspect;
    float motitionOffset = _273.g_Inertia * _273.g_SigmentCount;
    int param_4 = 2;
    float2 param_5 = out.v_TexCoord.zw;
    float param_6 = out.v_aspect;
    float param_7 = motitionOffset;
    float2 param_8 = out.v_AspectedRootNodeCenter;
    float2 param_9 = endpointSpinCenter;
    float2 param_10 = _273.g_SpinCenter1;
    float2 param_11 = _273.g_SpinCenter2;
    float param_12 = _273.g_WindDirection2;
    float param_13 = _273.g_WindDirection3;
    float param_14 = _273.g_Inertia;
    float param_15 = _273.g_TimeOffset1;
    float param_16 = _273.g_TimeOffset2;
    float2 param_17;
    float param_18;
    float param_19;
    float param_20;
    float param_21;
    float param_22;
    preCalcNode(param_4, param_5, param_6, param_7, param_8, param_9, param_10, param_11, param_12, param_13, param_14, param_15, param_16, param_17, param_18, param_19, param_20, param_21, param_22, _273);
    out.v_Direction1 = param_17;
    out.v_StartpointLen1 = param_18;
    out.v_Len1 = param_19;
    out.v_EndpointLen1 = param_20;
    out.v_PosX1 = param_21;
    out.v_MotionRadian1 = param_22;
    int param_23 = 3;
    float2 param_24 = out.v_TexCoord.zw;
    float param_25 = out.v_aspect;
    float param_26 = motitionOffset;
    float2 param_27 = out.v_AspectedRootNodeCenter;
    float2 param_28 = endpointSpinCenter;
    float2 param_29 = _273.g_SpinCenter2;
    float2 param_30 = _273.g_SpinCenter3;
    float param_31 = _273.g_WindDirection3;
    float param_32 = _273.g_WindDirection4;
    float param_33 = _273.g_Inertia;
    float param_34 = _273.g_TimeOffset2;
    float param_35 = _273.g_TimeOffset3;
    float2 param_36;
    float param_37;
    float param_38;
    float param_39;
    float param_40;
    float param_41;
    preCalcNode(param_23, param_24, param_25, param_26, param_27, param_28, param_29, param_30, param_31, param_32, param_33, param_34, param_35, param_36, param_37, param_38, param_39, param_40, param_41, _273);
    out.v_Direction2 = param_36;
    out.v_StartpointLen2 = param_37;
    out.v_Len2 = param_38;
    out.v_EndpointLen2 = param_39;
    out.v_PosX2 = param_40;
    out.v_MotionRadian2 = param_41;
    int param_42 = 4;
    float2 param_43 = out.v_TexCoord.zw;
    float param_44 = out.v_aspect;
    float param_45 = motitionOffset;
    float2 param_46 = out.v_AspectedRootNodeCenter;
    float2 param_47 = endpointSpinCenter;
    float2 param_48 = _273.g_SpinCenter3;
    float2 param_49 = _273.g_SpinCenter4;
    float param_50 = _273.g_WindDirection4;
    float param_51 = _273.g_WindDirection5;
    float param_52 = _273.g_Inertia;
    float param_53 = _273.g_TimeOffset3;
    float param_54 = _273.g_TimeOffset4;
    float2 param_55;
    float param_56;
    float param_57;
    float param_58;
    float param_59;
    float param_60;
    preCalcNode(param_42, param_43, param_44, param_45, param_46, param_47, param_48, param_49, param_50, param_51, param_52, param_53, param_54, param_55, param_56, param_57, param_58, param_59, param_60, _273);
    out.v_Direction3 = param_55;
    out.v_StartpointLen3 = param_56;
    out.v_Len3 = param_57;
    out.v_EndpointLen3 = param_58;
    out.v_PosX3 = param_59;
    out.v_MotionRadian3 = param_60;
    return out;
}

