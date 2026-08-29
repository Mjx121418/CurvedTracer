#pragma once

#include "GeometryCore/Scene.h"

namespace geo {

// An oriented unit-speed geodesic in one chart coordinate state. Points and
// tangents use the ambient model representation described in CONTRACT.md.
struct Geodesic {
  vec4 point;
  vec4 tangent;

  Geodesic() = default;
  Geodesic(const vec4 &point_, const vec4 &tangent_)
      : point(point_), tangent(tangent_) {}
};

float geodesicTangentLength(const vec4 &tangent, int modelKind);
bool canonicalizeGeodesic(Geodesic &geodesic, int modelKind);
vec4 geodesicPointAt(const Geodesic &geodesic, float distance,
                     int modelKind);
vec4 geodesicTangentAt(const Geodesic &geodesic, float distance,
                       int modelKind);
bool advanceGeodesic(Geodesic &geodesic, float distance, int modelKind);

} // namespace geo
