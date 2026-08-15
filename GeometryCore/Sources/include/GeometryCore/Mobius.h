#pragma once
// A Mobius transformation acting on a stereographic chart of H3 or S3.
// Host-only (not included by MSL). Stored as a 4x4 matrix:
//   H3: Lorentz matrix O(3,1)   S3: orthogonal matrix O(4)
// column-major, matching Math.h mat4.
#include "GeometryCore/Math.h"

namespace geo {

enum class ModelKind : int { H3 = 0, S3 = 1 };

struct Mobius {
    ModelKind kind = ModelKind::H3;
    mat4 m = mat4Identity();

    // Apply this map to a chart point (R3 coordinates in a stereographic chart).
    vec3 apply(const vec3& chartPoint) const;

    // this ∘ other (kinds must match).
    Mobius compose(const Mobius& other) const;

    Mobius inverse() const;

    // Image of a Euclidean sphere under this map.
    // If the sphere passes through the projection point it maps to a plane:
    //   outIsPlane = true, outCenter = unit normal, outRadius = signed offset.
    void applySphere(const vec3& center, float radius,
                     vec3& outCenter, float& outRadius, bool& outIsPlane) const;

    // Image of a Euclidean plane {x : dot(n, x) = offset} under this map.
    // The image is a sphere or, if it passes through the projection point, a plane.
    void applyPlane(const vec3& normal, float offset,
                    vec3& outCenter, float& outRadius, bool& outIsPlane) const;
};

} // namespace geo
