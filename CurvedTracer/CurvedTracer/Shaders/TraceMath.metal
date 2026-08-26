#ifndef CURVED_TRACER_TRACE_MATH_METAL
#define CURVED_TRACER_TRACE_MATH_METAL

// Space-form ray math and tangent-frame helpers.

#include "TraceTypes.metal"

static float kappa() {
    return SPACE_FORM == MODEL_S3 ? 1.0f : SPACE_FORM == MODEL_H3 ? -1.0f : 0.0f;
}
static float mdot(float4 a, float4 b) {
    return SPACE_FORM == MODEL_H3 ? dot(a.xyz, b.xyz) - a.w * b.w : dot(a, b);
}
static float4 origin() { return float4(0, 0, 0, 1); }
static float distanceFromU(float u) {
    if (SPACE_FORM == MODEL_S3)
        return 2 * atan(u);
    if (SPACE_FORM == MODEL_H3)
        return u < 1 ? log((1 + u) / (1 - u)) : INF;
    return 2 * u;
}
static float areaRadius(float d) {
    return SPACE_FORM == MODEL_S3 ? sin(d) : SPACE_FORM == MODEL_H3 ? sinh(d) : d;
}
static void radial(float d, thread float &C, thread float &S) {
    if (SPACE_FORM == MODEL_S3) {
        C = cos(d);
        S = sin(d);
    } else if (SPACE_FORM == MODEL_H3) {
        C = cosh(d);
        S = sinh(d);
    } else {
        C = 1;
        S = d;
    }
}
static float4 rayPoint(float4 p, float4 v, float d) {
    float C, S;
    radial(d, C, S);
    return C * p + S * v;
}
static float4 rayTangent(float4 p, float4 v, float d) {
    if (SPACE_FORM == MODEL_S3)
        return -sin(d) * p + cos(d) * v;
    if (SPACE_FORM == MODEL_H3)
        return sinh(d) * p + cosh(d) * v;
    return v;
}
static float4 tangentNormalize(float4 v) {
    float q = max(mdot(v, v), 0.0f);
    return q > EPS * EPS ? v * rsqrt(q) : float4(0);
}

static bool canonicalizeRayState(thread float4 &point, thread float4 &tangent) {
    if (SPACE_FORM == MODEL_R3) {
        point.w = 1.0f;
        tangent = float4(tangent.xyz, 0.0f);
    } else {
        float pointNorm = mdot(point, point);
        float expectedSign = kappa();
        if (!isfinite(pointNorm) || expectedSign * pointNorm <= EPS)
            return false;
        point *= rsqrt(expectedSign * pointNorm);
        if (SPACE_FORM == MODEL_H3 && point.w <= 0.0f)
            return false;
        tangent -= kappa() * mdot(tangent, point) * point;
    }

    tangent = tangentNormalize(tangent);
    return all(isfinite(point)) && all(isfinite(tangent)) &&
    mdot(tangent, tangent) > 0.5f;
}

static float4 bsdfAmbientAxis(int index) {
    if (index == 0)
        return float4(1, 0, 0, 0);
    if (index == 1)
        return float4(0, 1, 0, 0);
    if (index == 2)
        return float4(0, 0, 1, 0);
    return float4(0, 0, 0, 1);
}

static float4 bsdfProjectToTangent(float4 vector, float4 point) {
    if (SPACE_FORM == MODEL_R3)
        return float4(vector.xyz, 0);
    return vector - kappa() * mdot(vector, point) * point;
}

static bool bsdfCanonicalNormal(
    float4 point,
    float4 normal,
    thread float4 &canonicalNormal
) {
    canonicalNormal = tangentNormalize(
        bsdfProjectToTangent(normal, point));
    return all(isfinite(canonicalNormal)) &&
    mdot(canonicalNormal, canonicalNormal) > 0.5f;
}

static bool bsdfTangentFrame(
    float4 point,
    float4 normal,
    thread float4 &first,
    thread float4 &second
) {
    float bestFirstNorm = 0.0f;
    first = float4(0);
    int candidateCount = SPACE_FORM == MODEL_R3 ? 3 : 4;
    for (int axis = 0; axis < candidateCount; ++axis) {
        float4 candidate = bsdfProjectToTangent(
            bsdfAmbientAxis(axis), point);
        candidate -= mdot(candidate, normal) * normal;
        float candidateNorm = mdot(candidate, candidate);
        if (isfinite(candidateNorm) && candidateNorm > bestFirstNorm) {
            bestFirstNorm = candidateNorm;
            first = candidate;
        }
    }
    if (bestFirstNorm <= EPS * EPS)
        return false;
    first *= rsqrt(bestFirstNorm);

    float bestSecondNorm = 0.0f;
    second = float4(0);
    for (int axis = 0; axis < candidateCount; ++axis) {
        float4 candidate = bsdfProjectToTangent(
            bsdfAmbientAxis(axis), point);
        candidate -= mdot(candidate, normal) * normal;
        candidate -= mdot(candidate, first) * first;
        float candidateNorm = mdot(candidate, candidate);
        if (isfinite(candidateNorm) && candidateNorm > bestSecondNorm) {
            bestSecondNorm = candidateNorm;
            second = candidate;
        }
    }
    if (bestSecondNorm <= EPS * EPS)
        return false;
    second *= rsqrt(bestSecondNorm);
    return all(isfinite(first)) && all(isfinite(second)) &&
    mdot(first, first) > 0.5f && mdot(second, second) > 0.5f;
}


#endif
