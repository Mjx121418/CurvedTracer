#pragma once
// A Mobius/chart transition for CONTRACT v4 disk charts.
// Host-only (not included by MSL). Stored as a 4x4 matrix:
//   H3: Lorentz matrix O(3,1)   S3: orthogonal matrix O(4)
// column-major, matching Math.h mat4.
#include "GeometryCore/Math.h"

namespace geo {

enum class ModelKind : int { H3 = 0, S3 = 1 };

struct Mobius {
    ModelKind kind = ModelKind::H3;
    mat4 m = mat4Identity();

    // CONTRACT v4: apply this map to a disk-chart point.
    vec3 applyChartPoint(const vec3& chartPoint) const;

    // Apply this map to an augmented chart point (x,w). For S³ the full
    // signed-w vector is transformed directly; for H³ the x part is
    // transformed and w is recomputed as sqrt(1-|x'|²).
    vec4 applyChartPointAugmented(const vec4& chartPoint) const;

    // this ∘ other (kinds must match).
    Mobius compose(const Mobius& other) const;

    Mobius inverse() const;

    // CONTRACT v4: transform a disk-chart hyperplane section
    //     a·x + b·sqrt(1-|x|²) = c
    // into a new chart.
    void applySurface(const vec3& a, float b, float c,
                      vec3& outA, float& outB, float& outC) const;

private:
    // Legacy helpers used only by applySurface for H3. They operate on the
    // Poincare-ball model, which is an internal host-side representation.
    vec3 apply(const vec3& poincarePoint) const;
    void applySphere(const vec3& center, float radius,
                     vec3& outCenter, float& outRadius, bool& outIsPlane) const;
    void applyPlane(const vec3& normal, float offset,
                    vec3& outCenter, float& outRadius, bool& outIsPlane) const;
    void fitTransformedPrimitive(const vec3 src[4],
                                 vec3& oc, float& orr, bool& op) const;
};

} // namespace geo
