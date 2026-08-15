#pragma once
// Host-only helpers for the spherical model S3 (not included by MSL).
// S3 = unit sphere in R4 with Euclidean dot product.
// Stereographic chart at the south pole (-e4): projection from the north pole e4.
#include "GeometryCore/Math.h"

namespace geo {

inline float sdot(const vec4& a, const vec4& b) { return dot(a, b); }

namespace S3 {

// Chart (R3) -> model (unit vec4 in R4).
inline vec4 chartToModel(const vec3& y) {
    float r2 = lengthSq(y);
    float d = 1.0f + r2;
    return vec4(2.0f * y.x / d, 2.0f * y.y / d, 2.0f * y.z / d, (r2 - 1.0f) / d);
}

// Model -> chart (R3). Singular when x == north pole e4 (the projection point).
inline vec3 modelToChart(const vec4& x) {
    float d = 1.0f - x.w;
    return vec3(x.x / d, x.y / d, x.z / d);
}

inline bool onModel(const vec4& x) {
    return mhAbs(dot(x, x) - 1.0f) < 1e-3f;
}

// Angular distance between two model points.
inline float distance(const vec4& a, const vec4& b) {
    return mhAcos(mhClamp(dot(a, b), -1.0f, 1.0f));
}

// Geodesic: unit p, unit tangent v (dot(p,v)=0). gamma(t)=cos(t) p + sin(t) v.
inline vec4 exp(float t, const vec4& p, const vec4& v) {
    return p * mhCos(t) + v * mhSin(t);
}

// Reflection across the great sphere {x . n = 0}, |n| = 1 (Euclidean hyperplane reflection).
inline vec4 reflect(const vec4& n, const vec4& x) {
    float c = 2.0f * dot(n, x);
    return vec4(x.x - c * n.x, x.y - c * n.y, x.z - c * n.z, x.w - c * n.w);
}

} // namespace S3
} // namespace geo
