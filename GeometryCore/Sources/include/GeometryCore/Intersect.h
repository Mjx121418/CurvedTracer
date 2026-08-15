#pragma once
// Shared with MSL. Euclidean chart-coordinate ray / sphere / plane helpers.
// The GPU renderer composes these into control flow; do not use std headers here.
#include "GeometryCore/Math.h"

namespace geo {

// Ray: p(t) = rayOrigin + t*dir.  The ray origin is almost always the camera
// chart origin (0,0,0) per CONTRACT.md §7.1, but keeping the origin explicit
// makes the function harmless to reuse.  Returns the nearest t > tMin, or -1.
inline float raySphere(const vec3& rayOrigin, const vec3& dir,
                       const vec3& center, float radius, float tMin) {
    vec3 oc = rayOrigin - center;
    float a = dot(dir, dir);
    if (a < 1e-20f) return -1.0f;
    float b = dot(dir, oc);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - a * c;
    if (disc < 0.0f) return -1.0f;
    float sq = mhSqrt(disc);
    float t0 = (-b - sq) / a;
    float t1 = (-b + sq) / a;
    if (t0 > tMin) return t0;
    if (t1 > tMin) return t1;
    return -1.0f;
}

// Ray from the chart origin: p(t) = t*dir.  Plane: dot(normal, p) = offset.
// Returns t, or -1 if the ray is parallel (no unique hit).  The caller applies
// the CONTRACT.md t > eps test.
inline float rayPlane(const vec3& dir, const vec3& normal, float offset) {
    float denom = dot(normal, dir);
    if (mhAbs(denom) < 1e-20f) return -1.0f;
    return offset / denom;
}

// Sphere inversion across a mirror sphere (center mirrorCenter, radius mirrorRadius).
// Sphere (center c, radius r) -> sphere (outCenter, outRadius) or plane
// (outCenter = unit normal, outRadius = signed offset) when D ~= 0.
// D = |c - m|^2 - r^2.  The closed form survives fast-math because the
// near-zero test is an explicit clamped/guarded branch, not a raw division.
inline void invertSphere(const vec3& mirrorCenter, float mirrorRadius,
                         const vec3& c, float r,
                         vec3& outCenter, float& outRadius, bool& outIsPlane) {
    vec3 d = c - mirrorCenter;
    float D = dot(d, d) - r * r;
    float k = mirrorRadius * mirrorRadius;
    float scale = mhMax(dot(d, d), r * r) + 1e-12f;

    if (mhAbs(D) <= 1e-5f * scale) {
        // The source sphere passes through the inversion center: image is a plane.
        float lenD = length(d);
        if (lenD < 1e-12f) {
            // Degenerate: sphere is centered on the inversion center with r ~ 0.
            // This is not a valid mirror object; return a safe finite fallback.
            outCenter = c;
            outRadius = r;
            outIsPlane = false;
            return;
        }
        vec3 n = d / lenD;
        outCenter = n;                                              // unit normal
        outRadius = dot(n, mirrorCenter) + k / (2.0f * lenD);       // signed offset
        outIsPlane = true;
    } else {
        outCenter = mirrorCenter + d * (k / D);
        outRadius = k * r / mhAbs(D);
        outIsPlane = false;
    }
}

// Reflection of a direction across a plane through the origin with unit normal.
inline vec3 reflectPlane(const vec3& dir, const vec3& normal) {
    return dir - normal * (2.0f * dot(normal, dir));
}

} // namespace geo
