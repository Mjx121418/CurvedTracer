#pragma once
// Host-only helpers for the hyperboloid model H3 (not included by MSL).
// Minkowski R^{3,1} with signature (+++-): <a,b> = a.x b.x + a.y b.y + a.z b.z - a.w b.w
// Points: upper sheet of {<x,x> = -1}, i.e. w > 0.
// Poincare ball <-> hyperboloid model maps (the ball IS the stereographic chart at the origin).
#include "GeometryCore/Math.h"

namespace geo {

inline float mdot(const vec4& a, const vec4& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z - a.w * b.w;
}

namespace H3 {

// Poincare ball (unit ball in R3) -> hyperboloid model.
inline vec4 ballToModel(const vec3& b) {
    float r2 = lengthSq(b);
    float d = 1.0f - r2;
    float s = 2.0f / d;
    return vec4(b.x * s, b.y * s, b.z * s, (1.0f + r2) / d);
}

// Hyperboloid model -> Poincare ball.
inline vec3 modelToBall(const vec4& x) {
    float w1 = 1.0f + x.w;
    return vec3(x.x / w1, x.y / w1, x.z / w1);
}

inline bool onModel(const vec4& x) {
    return mhAbs(mdot(x, x) + 1.0f) < 1e-3f && x.w > 0.0f;
}

// Hyperbolic distance between two model points: cosh(d) = -<a,b>.
inline float distance(const vec4& a, const vec4& b) {
    float v = -mdot(a, b);
    if (v < 1.0f) v = 1.0f;   // clamp out of numeric range to valid acosh domain
    return mhAcosh(v);
}

// Geodesic: unit point p, unit tangent v (<v,v>=1, <p,v>=0). gamma(t)=cosh(t) p + sinh(t) v.
inline vec4 exp(float t, const vec4& p, const vec4& v) {
    return p * mhCosh(t) + v * mhSinh(t);
}

// Reflection across the geodesic hyperplane {<n,x> = 0}, n unit spacelike (<n,n>=1).
inline vec4 reflect(const vec4& n, const vec4& x) {
    float c = 2.0f * mdot(n, x);
    return vec4(x.x - c * n.x, x.y - c * n.y, x.z - c * n.z, x.w - c * n.w);
}

} // namespace H3
} // namespace geo
