#include "ChartInternal.h"

#include <algorithm>
#include <cmath>
#include <queue>

// Portal, camera, and movement operations.
namespace geo {
using namespace chart_detail;

int Atlas::addPortalPair(int ca, const vec3 &da, float fa, int cb,
                         const vec3 &db, float fb, const float raw[16]) {
  return addPortalPairWithCollar(ca, da, fa, cb, db, fb, raw,
                                 PORTAL_COLLAR);
}

int Atlas::addPortalPairWithCollar(int ca, const vec3 &da, float fa, int cb,
                                   const vec3 &db, float fb,
                                   const float raw[16], float collar) {
  packet_.clear();
  float la = length(da), lb = length(db);
  if (!validChartId(ca) || !validChartId(cb) || !raw || !finite(da) ||
      !finite(db) || la < 1e-8f || lb < 1e-8f || !finite(fa) || !finite(fb) ||
      !finite(collar) || fa < 0 || fb < 0 || collar < 0 ||
      fa + collar > charts_[ca].radius + CONTAIN_TOL ||
      fb + collar > charts_[cb].radius + CONTAIN_TOL ||
      portals_.size() + 2 > GEO_MAX_PORTALS) {
    setError(7);
    return -1;
  }
  Isometry ab = isometryFrom(raw);
  if (!ab.validate()) {
    setError(7);
    return -1;
  }
  vec3 ua = da / la, ub = db / lb;
  vec4 faceA = pointFromOriginTangent(ua * fa),
       faceB = pointFromOriginTangent(ub * fb);
  vec4 mappedFace = ab.applyPoint(faceA), canonicalMapped;
  if (!canonicalizePoint(mappedFace, canonicalMapped) ||
      intrinsicDistance(canonicalMapped, faceB) > 3e-3f) {
    setError(7);
    return -1;
  }
  vec4 outwardA = planeNormal(ua, fa), outwardB = planeNormal(ub, fb);
  if (modelKind_ != GEO_MODEL_R3) {
    outwardA = outwardA - metricDot(outwardA, faceA, modelKind_) *
                              (modelKind_ == GEO_MODEL_S3 ? 1.0f : -1.0f) *
                              faceA;
    outwardB = outwardB - metricDot(outwardB, faceB, modelKind_) *
                              (modelKind_ == GEO_MODEL_S3 ? 1.0f : -1.0f) *
                              faceB;
  }
  outwardA =
      outwardA /
      std::sqrt(std::max(metricDot(outwardA, outwardA, modelKind_), 1e-12f));
  outwardB =
      outwardB /
      std::sqrt(std::max(metricDot(outwardB, outwardB, modelKind_), 1e-12f));
  if (metricDot(ab.applyTangent(outwardA), outwardB, modelKind_) > -0.995f) {
    setError(7);
    return -1;
  }
  int ia = int(portals_.size()), ib = ia + 1;
  ChartPortal a, b;
  a.chartId = ca;
  a.neighborId = cb;
  a.normal = planeNormal(da / la, fa + collar);
  a.offset = modelKind_ == GEO_MODEL_R3 ? fa + collar : 0;
  a.reversePortal = ib;
  a.toNeighbor = ab;
  b.chartId = cb;
  b.neighborId = ca;
  b.normal = planeNormal(db / lb, fb + collar);
  b.offset = modelKind_ == GEO_MODEL_R3 ? fb + collar : 0;
  b.reversePortal = ia;
  b.toNeighbor = ab.inverse();
  portals_.push_back(a);
  portals_.push_back(b);
  charts_[ca].portalIds.push_back(ia);
  charts_[cb].portalIds.push_back(ib);
  setError(0);
  return ia;
}

void Atlas::setCamera(float f, float a, const vec3 &r, const vec3 &u,
                      const vec3 &fw) {
  if (!finite(f) || !finite(a) || f <= 0 || a <= 0 || length(r) < 1e-8f ||
      length(u) < 1e-8f || length(fw) < 1e-8f) {
    setError(3);
    return;
  }
  cameraFwd_ = normalize(fw);
  cameraRight_ = normalize(r - cameraFwd_ * dot(r, cameraFwd_));
  cameraUp_ = normalize(cross(cameraFwd_, cameraRight_));
  if (dot(cameraUp_, u) < 0) {
    cameraRight_ = -cameraRight_;
    cameraUp_ = -cameraUp_;
  }
  fovTan_ = f;
  aspect_ = a;
  setError(0);
}
void Atlas::setControls(int b, float f, float a) {
  setControls(b, f, a, 0, 0, 0);
}
void Atlas::setControls(int b, float f, float a, float fm, float fs, float fd) {
  maxBounces_ = b;
  falloffK_ = f;
  ambient_ = a;
  fogMode_ = fm;
  fogStartFraction_ = fs;
  fogDensity_ = fd;
}

void Atlas::cameraRotate(const vec3 &axis, float angle) {
  vec3 n = normalize(axis);
  if (lengthSq(n) < 1e-12f || !finite(angle))
    return;
  auto rot = [&](vec3 v) {
    return v * std::cos(angle) + cross(n, v) * std::sin(angle) +
           n * (dot(n, v) * (1 - std::cos(angle)));
  };
  cameraFwd_ = normalize(rot(cameraFwd_));
  cameraRight_ = normalize(rot(cameraRight_) -
                           cameraFwd_ * dot(rot(cameraRight_), cameraFwd_));
  cameraUp_ = normalize(cross(cameraFwd_, cameraRight_));
}
void Atlas::cameraRoll(float angle) { cameraRotate(cameraFwd_, angle); }

Isometry Atlas::movePointToOrigin(const vec4 &p) const {
  Isometry out;
  out.kind = kind();
  if (modelKind_ == GEO_MODEL_R3) {
    out.m = mat4Identity();
    out.m.m[12] = -p.x;
    out.m.m[13] = -p.y;
    out.m.m[14] = -p.z;
    return out;
  }
  vec3 u = p.xyz();
  float k = modelKind_ == GEO_MODEL_S3 ? 1.0f : -1.0f;
  float scale = -k / std::max(1.0f + p.w, 1e-6f);
  vec3 c0 = vec3(1, 0, 0) + u * (scale * u.x),
       c1 = vec3(0, 1, 0) + u * (scale * u.y),
       c2 = vec3(0, 0, 1) + u * (scale * u.z);
  mat4 &B = out.m;
  B.m[0] = c0.x;
  B.m[1] = c0.y;
  B.m[2] = c0.z;
  B.m[3] = k * u.x;
  B.m[4] = c1.x;
  B.m[5] = c1.y;
  B.m[6] = c1.z;
  B.m[7] = k * u.y;
  B.m[8] = c2.x;
  B.m[9] = c2.y;
  B.m[10] = c2.z;
  B.m[11] = k * u.z;
  B.m[12] = -u.x;
  B.m[13] = -u.y;
  B.m[14] = -u.z;
  B.m[15] = p.w;
  return out;
}

vec4 Atlas::expMap(const vec4 &p, const vec4 &v) const {
  float r = std::sqrt(std::max(metricDot(v, v, modelKind_), 0.0f));
  if (r < 1e-8f)
    return p;
  if (modelKind_ == GEO_MODEL_S3)
    return p * std::cos(r) + v * (std::sin(r) / r);
  if (modelKind_ == GEO_MODEL_H3)
    return p * std::cosh(r) + v * (std::sinh(r) / r);
  return vec4(p.xyz() + v.xyz(), 1);
}

vec4 Atlas::parallelTransportAlong(const vec4 &point, const vec4 &displacement,
                                   const vec4 &tangent) const {
  if (modelKind_ == GEO_MODEL_R3)
    return tangent;

  float distance = std::sqrt(
      std::max(metricDot(displacement, displacement, modelKind_), 0.0f));
  if (distance < 1e-8f)
    return tangent;

  vec4 direction = displacement / distance;
  vec4 transportedDirection =
      modelKind_ == GEO_MODEL_S3
          ? point * -std::sin(distance) + direction * std::cos(distance)
          : point * std::sinh(distance) + direction * std::cosh(distance);
  float component = metricDot(tangent, direction, modelKind_);
  return tangent + (transportedDirection - direction) * component;
}

float Atlas::planeValue(const ChartPortal &p, const vec4 &x) const {
  return metricDot(p.normal, x, modelKind_) - p.offset;
}

CameraPlacement Atlas::resolveCameraPlacement(int chart, const vec4 &start,
                                              const vec3 &move) const {
  CameraPlacement result;
  result.chartId = chart;
  vec4 p;
  if (!validChartId(chart) || !canonicalizePoint(start, p) || !finite(move))
    return result;
  Isometry recenter = movePointToOrigin(p);
  vec4 tangent = recenter.inverse().applyTangent(vec4(move, 0));
  p = expMap(p, tangent);
  int current = chart;
  for (int hop = 0; hop < 128; ++hop) {
    int chosen = -1;
    float worst = PORTAL_REDUCTION_TOL;
    for (int id : charts_[current].portalIds) {
      float v = planeValue(portals_[id], p);
      if (v > worst) {
        worst = v;
        chosen = id;
      }
    }
    if (chosen < 0)
      break;
    const auto &portal = portals_[chosen];
    p = portal.toNeighbor.applyPoint(p);
    current = portal.neighborId;
  }
  if (originDistance(p) > charts_[current].radius + CONTAIN_TOL) {
    bool found = false;
    for (const auto &e : charts_[current].edges) {
      vec4 q = e.toNeighbor.applyPoint(p);
      if (originDistance(q) <= charts_[e.neighborId].radius + CONTAIN_TOL) {
        p = q;
        current = e.neighborId;
        found = true;
        break;
      }
    }
    if (!found) {
      float d = originDistance(p);
      if (d > 0) {
        vec3 t = p.xyz();
        p = pointFromOriginTangent(
            normalize(t) * (charts_[current].radius * (1 - CONTAIN_TOL)));
      }
    }
  }
  result.chartId = current;
  result.localPosition = p;
  return result;
}

int Atlas::cameraChartAt(int chart, const vec4 &raw, float viewDistance) {
  vec4 p;
  if (!validChartId(chart) || !canonicalizePoint(raw, p) ||
      !validViewDistance(viewDistance) ||
      originDistance(p) > charts_[chart].radius + CONTAIN_TOL) {
    setError(4);
    return -1;
  }
  cameraChartId_ = chart;
  cameraPosition_ = p;
  cameraViewDistance_ = viewDistance;
  setError(0);
  return chart;
}

int Atlas::cameraMove(const vec3 &movement) {
  if (!validChartId(cameraChartId_) || !finite(movement)) {
    setError(4);
    return -1;
  }
  int current = cameraChartId_;
  vec4 oldP = cameraPosition_;
  Isometry oldCenter = movePointToOrigin(oldP);
  vec4 ambientMove = oldCenter.inverse().applyTangent(vec4(movement, 0));
  vec4 right = oldCenter.inverse().applyTangent(vec4(cameraRight_, 0));
  vec4 up = oldCenter.inverse().applyTangent(vec4(cameraUp_, 0));
  vec4 fwd = oldCenter.inverse().applyTangent(vec4(cameraFwd_, 0));
  vec4 p = expMap(oldP, ambientMove);
  right = parallelTransportAlong(oldP, ambientMove, right);
  up = parallelTransportAlong(oldP, ambientMove, up);
  fwd = parallelTransportAlong(oldP, ambientMove, fwd);
  for (int hop = 0; hop < 128; ++hop) {
    int chosen = -1;
    float worst = PORTAL_REDUCTION_TOL;
    for (int id : charts_[current].portalIds) {
      float v = planeValue(portals_[id], p);
      if (v > worst) {
        worst = v;
        chosen = id;
      }
    }
    if (chosen < 0)
      break;
    const auto &portal = portals_[chosen];
    p = portal.toNeighbor.applyPoint(p);
    right = portal.toNeighbor.applyTangent(right);
    up = portal.toNeighbor.applyTangent(up);
    fwd = portal.toNeighbor.applyTangent(fwd);
    current = portal.neighborId;
  }
  if (originDistance(p) > charts_[current].radius + CONTAIN_TOL) {
    for (const auto &e : charts_[current].edges) {
      vec4 q = e.toNeighbor.applyPoint(p);
      if (originDistance(q) <= charts_[e.neighborId].radius + CONTAIN_TOL) {
        p = q;
        right = e.toNeighbor.applyTangent(right);
        up = e.toNeighbor.applyTangent(up);
        fwd = e.toNeighbor.applyTangent(fwd);
        current = e.neighborId;
        break;
      }
    }
  }
  Isometry centered = movePointToOrigin(p);
  cameraRight_ = normalize(centered.applyTangent(right).xyz());
  cameraFwd_ = normalize(centered.applyTangent(fwd).xyz());
  cameraRight_ =
      normalize(cameraRight_ - cameraFwd_ * dot(cameraRight_, cameraFwd_));
  cameraUp_ = normalize(cross(cameraFwd_, cameraRight_));
  cameraChartId_ = current;
  cameraPosition_ = p;
  setError(0);
  return cameraChartId_;
}

} // namespace geo
