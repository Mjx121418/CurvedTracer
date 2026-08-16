#pragma once
// Host-only disk-chart helpers for CONTRACT v4.
#include "GeometryCore/Math.h"

namespace geo {
namespace disk {

// Chart coordinate x -> ambient point on S³.
inline vec4 toAmbient(const vec3& x) {
    float r2 = lengthSq(x);
    float w = mhSqrt(mhMax(0.0f, 1.0f - r2));
    return vec4(x, w);
}

// Ambient point on S³ -> chart coordinate x.
inline vec3 fromAmbient(const vec4& X) {
    return X.xyz();
}

// Disk chart coordinate -> Poincare ball coordinate (H³ upper-hemisphere model).
inline vec3 toPoincare(const vec3& x) {
    float w = mhSqrt(mhMax(0.0f, 1.0f - lengthSq(x)));
    return x / (1.0f + w);
}

// Poincare ball coordinate -> disk chart coordinate.
inline vec3 fromPoincare(const vec3& p) {
    float r2 = lengthSq(p);
    return p * (2.0f / (1.0f + r2));
}

} // namespace disk
} // namespace geo
