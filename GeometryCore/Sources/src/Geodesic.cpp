#include "GeometryCore/Geodesic.h"

#include <algorithm>
#include <cmath>

namespace geo {
namespace {

bool finite(float value) { return std::isfinite(value); }

bool finite(const vec4 &value) {
  return finite(value.x) && finite(value.y) && finite(value.z) &&
         finite(value.w);
}

float metricDot(const vec4 &a, const vec4 &b, int modelKind) {
  if (modelKind == GEO_MODEL_H3)
    return a.x * b.x + a.y * b.y + a.z * b.z - a.w * b.w;
  return dot(a, b);
}

bool validModel(int modelKind) {
  return modelKind == GEO_MODEL_H3 || modelKind == GEO_MODEL_S3 ||
         modelKind == GEO_MODEL_R3;
}

} // namespace

float geodesicTangentLength(const vec4 &tangent, int modelKind) {
  if (!validModel(modelKind) || !finite(tangent))
    return 0.0f;
  return std::sqrt(std::max(metricDot(tangent, tangent, modelKind), 0.0f));
}

bool canonicalizeGeodesic(Geodesic &geodesic, int modelKind) {
  if (!validModel(modelKind) || !finite(geodesic.point) ||
      !finite(geodesic.tangent))
    return false;

  if (modelKind == GEO_MODEL_R3) {
    geodesic.point.w = 1.0f;
    geodesic.tangent.w = 0.0f;
  } else {
    float pointNorm = metricDot(geodesic.point, geodesic.point, modelKind);
    float sign = modelKind == GEO_MODEL_S3 ? 1.0f : -1.0f;
    if (!finite(pointNorm) || sign * pointNorm <= 1e-8f)
      return false;
    geodesic.point = geodesic.point / std::sqrt(sign * pointNorm);
    if (modelKind == GEO_MODEL_H3 && geodesic.point.w <= 0.0f)
      return false;
    geodesic.tangent =
        geodesic.tangent -
        geodesic.point *
            (sign * metricDot(geodesic.tangent, geodesic.point, modelKind));
  }

  float tangentLength = geodesicTangentLength(geodesic.tangent, modelKind);
  if (!finite(tangentLength) || tangentLength <= 1e-8f)
    return false;
  geodesic.tangent = geodesic.tangent / tangentLength;
  return finite(geodesic.point) && finite(geodesic.tangent);
}

vec4 geodesicPointAt(const Geodesic &geodesic, float distance,
                     int modelKind) {
  if (modelKind == GEO_MODEL_S3)
    return geodesic.point * std::cos(distance) +
           geodesic.tangent * std::sin(distance);
  if (modelKind == GEO_MODEL_H3)
    return geodesic.point * std::cosh(distance) +
           geodesic.tangent * std::sinh(distance);
  return vec4(geodesic.point.xyz() + geodesic.tangent.xyz() * distance, 1);
}

vec4 geodesicTangentAt(const Geodesic &geodesic, float distance,
                       int modelKind) {
  if (modelKind == GEO_MODEL_S3)
    return geodesic.point * -std::sin(distance) +
           geodesic.tangent * std::cos(distance);
  if (modelKind == GEO_MODEL_H3)
    return geodesic.point * std::sinh(distance) +
           geodesic.tangent * std::cosh(distance);
  return geodesic.tangent;
}

bool advanceGeodesic(Geodesic &geodesic, float distance, int modelKind) {
  if (!finite(distance) || !canonicalizeGeodesic(geodesic, modelKind))
    return false;
  Geodesic advanced(geodesicPointAt(geodesic, distance, modelKind),
                    geodesicTangentAt(geodesic, distance, modelKind));
  if (!canonicalizeGeodesic(advanced, modelKind))
    return false;
  geodesic = advanced;
  return true;
}

} // namespace geo
