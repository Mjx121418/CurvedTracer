#pragma once
#include "GeometryCore/Math.h"

namespace geo {

enum class ModelKind : int { H3 = 0, S3 = 1, R3 = 2 };

// Orientation-preserving SO(4), SO+(3,1), or homogeneous SE(3).
struct Isometry {
    ModelKind kind = ModelKind::H3;
    mat4 m = mat4Identity();

    vec4 applyPoint(const vec4& point) const;
    vec4 applyTangent(const vec4& tangent) const;
    Isometry compose(const Isometry& other) const; // this after other
    Isometry inverse() const;
    bool validate(float tolerance = 1e-4f) const;
};

} // namespace geo
