#include "ChartInternal.h"

#include <algorithm>
#include <cmath>
#include <queue>

// Core chart lifecycle and coordinate operations.
namespace geo {
using namespace chart_detail;

Atlas::Atlas() { reset(); }

void Atlas::reset() {
  modelKind_ = GEO_MODEL_H3;
  charts_.clear();
  objects_.clear();
  clips_.clear();
  lights_.clear();
  portals_.clear();
  materials_.clear();
  cameraChartId_ = -1;
  cameraPosition_ = vec4(0, 0, 0, 1);
  cameraViewDistance_ = 1;
  cameraRight_ = vec3(1, 0, 0);
  cameraUp_ = vec3(0, 1, 0);
  cameraFwd_ = vec3(0, 0, 1);
  fovTan_ = aspect_ = 1;
  maxBounces_ = 4;
  falloffK_ = ambient_ = 0;
  fogMode_ = fogStartFraction_ = fogDensity_ = 0;
  packet_.clear();
  lastError_ = 0;
}

void Atlas::begin(int model) {
  reset();
  if (model >= GEO_MODEL_H3 && model <= GEO_MODEL_R3)
    modelKind_ = model;
  else {
    modelKind_ = -1;
    setError(6);
  }
}
bool Atlas::validModelKind() const {
  return modelKind_ >= GEO_MODEL_H3 && modelKind_ <= GEO_MODEL_R3;
}
bool Atlas::validGeodesicRadius(float radius) const {
  if (!finite(radius) || radius <= 0)
    return false;
  if (modelKind_ == GEO_MODEL_S3)
    return radius < PI;
  if (modelKind_ == GEO_MODEL_H3)
    return finite(std::sinh(radius)) && finite(std::cosh(radius));
  return finite(radius * 0.5f);
}

bool Atlas::validSignedDistance(float distance) const {
  if (!finite(distance))
    return false;
  float magnitude = std::fabs(distance);
  if (modelKind_ == GEO_MODEL_S3)
    return magnitude < PI;
  if (modelKind_ == GEO_MODEL_H3)
    return finite(std::sinh(distance)) && finite(std::cosh(distance));
  return true;
}

bool Atlas::validPortalDistance(float distance) const {
  return distance >= 0 && validSignedDistance(distance);
}

bool Atlas::validViewDistance(float distance) const {
  if (!finite(distance) || distance <= 0)
    return false;
  if (modelKind_ == GEO_MODEL_S3)
    return distance < PI;
  if (modelKind_ == GEO_MODEL_H3)
    return finite(std::sinh(distance)) && finite(std::cosh(distance));
  return finite(distance * 0.5f);
}

int Atlas::seed() {
  packet_.clear();
  if (!validModelKind()) {
    setError(6);
    return -1;
  }
  if (!charts_.empty()) {
    setError(5);
    return -1;
  }
  Chart c;
  c.id = 0;
  charts_.push_back(c);
  setError(0);
  return 0;
}

Isometry Atlas::isometryFrom(const float raw[16]) const {
  Isometry m;
  m.kind = kind();
  if (raw)
    for (int i = 0; i < 16; ++i)
      m.m.m[i] = raw[i];
  return m;
}

void Atlas::upsertEdge(int a, int b, const Isometry &m, bool safe) {
  for (auto &e : charts_[a].edges)
    if (e.neighborId == b) {
      e.toNeighbor = m;
      e.safe = safe;
      return;
    }
  ChartEdge e;
  e.neighborId = b;
  e.toNeighbor = m;
  e.safe = safe;
  charts_[a].edges.push_back(e);
}

int Atlas::addChart(int from, const float raw[16], bool safe) {
  packet_.clear();
  if (!validChartId(from) || !raw) {
    setError(3);
    return -1;
  }
  Isometry m = isometryFrom(raw);
  if (!m.validate()) {
    setError(3);
    return -1;
  }
  Chart c;
  c.id = int(charts_.size());
  charts_.push_back(c);
  upsertEdge(from, c.id, m, safe);
  upsertEdge(c.id, from, m.inverse(), safe);
  setError(0);
  return c.id;
}

void Atlas::linkCharts(int a, int b, const float raw[16], bool safe) {
  packet_.clear();
  if (!validChartId(a) || !validChartId(b) || a == b || !raw) {
    setError(3);
    return;
  }
  Isometry m = isometryFrom(raw);
  if (!m.validate()) {
    setError(3);
    return;
  }
  upsertEdge(a, b, m, safe);
  upsertEdge(b, a, m.inverse(), safe);
  setError(0);
}

vec4 Atlas::pointFromOriginTangent(const vec3 &t) const {
  if (!finite(t) || !validModelKind())
    return vec4();
  float r = length(t);
  if (r < 1e-8f)
    return vec4(0, 0, 0, 1);
  if (modelKind_ == GEO_MODEL_S3)
    return vec4(t * (std::sin(r) / r), std::cos(r));
  if (modelKind_ == GEO_MODEL_H3)
    return vec4(t * (std::sinh(r) / r), std::cosh(r));
  return vec4(t, 1);
}

bool Atlas::canonicalizePoint(const vec4 &in, vec4 &out) const {
  if (!finite(in))
    return false;
  if (modelKind_ == GEO_MODEL_R3) {
    if (std::fabs(in.w - 1) > POINT_TOL)
      return false;
    out = vec4(in.xyz(), 1);
    return true;
  }
  if (modelKind_ == GEO_MODEL_S3) {
    float q = dot(in, in);
    if (q <= 0 || std::fabs(q - 1) > POINT_TOL)
      return false;
    out = in / std::sqrt(q);
    return true;
  }
  float q = lorDot(in, in);
  if (q >= 0 || in.w <= 0 || std::fabs(q + 1) > POINT_TOL)
    return false;
  out = in / std::sqrt(-q);
  return out.w > 0;
}

float Atlas::intrinsicDistance(const vec4 &a0, const vec4 &b0) const {
  vec4 a, b;
  if (!canonicalizePoint(a0, a) || !canonicalizePoint(b0, b))
    return INFINITY;
  if (modelKind_ == GEO_MODEL_S3)
    return std::acos(std::clamp(dot(a, b), -1.0f, 1.0f));
  if (modelKind_ == GEO_MODEL_H3)
    return std::acosh(std::max(-lorDot(a, b), 1.0f));
  return length(a.xyz() - b.xyz());
}

} // namespace geo
