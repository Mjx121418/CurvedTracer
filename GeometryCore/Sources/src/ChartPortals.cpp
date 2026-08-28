#include "ChartInternal.h"

#include <algorithm>
#include <cmath>
#include <queue>

// Portal, camera, and movement operations.
namespace geo {
using namespace chart_detail;

namespace {

mat4 scaled(const mat4 &m, float scale) {
  mat4 out = m;
  for (float &value : out.m)
    value *= scale;
  return out;
}

mat4 tubeQuadric(const vec3 &axis, float radius, int model) {
  mat4 q;
  float transverse = 1.0f;
  float axial = 0.0f;
  float homogeneous = -radius * radius;
  if (model == GEO_MODEL_S3) {
    transverse = std::cos(radius) * std::cos(radius);
    axial = -std::sin(radius) * std::sin(radius);
    homogeneous = axial;
  } else if (model == GEO_MODEL_H3) {
    transverse = std::cosh(radius) * std::cosh(radius);
    axial = std::sinh(radius) * std::sinh(radius);
    homogeneous = -axial;
  }
  float components[3] = {axis.x, axis.y, axis.z};
  for (int row = 0; row < 3; ++row)
    for (int column = 0; column < 3; ++column) {
      float axisProjector = components[row] * components[column];
      float transverseProjector = (row == column ? 1.0f : 0.0f) -
                                  axisProjector;
      q.m[column * 4 + row] = transverse * transverseProjector +
                              axial * axisProjector;
    }
  q.m[15] = homogeneous;
  return normalizedMatrix(q);
}

int quadraticRoots(float a, float b, float c, float &r0, float &r1) {
  constexpr float epsilon = 1e-6f;
  if (std::fabs(a) < epsilon) {
    if (std::fabs(b) < epsilon)
      return 0;
    r0 = r1 = -c / b;
    return 1;
  }
  float discriminant = b * b - 4 * a * c;
  float tolerance = epsilon * (1 + std::fabs(b * b) + std::fabs(4 * a * c));
  if (discriminant < -tolerance)
    return 0;
  float root = std::sqrt(std::max(discriminant, 0.0f));
  float q = -0.5f * (b + std::copysign(root, b));
  r0 = q / a;
  r1 = std::fabs(q) > epsilon ? c / q : r0;
  if (r0 > r1)
    std::swap(r0, r1);
  return discriminant <= tolerance ? 1 : 2;
}

void insertCandidate(float candidate, float maximum, float &first,
                     float &second, int &count) {
  constexpr float epsilon = 1e-6f;
  if (!finite(candidate) || candidate < -epsilon || candidate > maximum)
    return;
  candidate = std::max(candidate, 0.0f);
  if (count > 0 && std::fabs(candidate - first) <= epsilon)
    return;
  if (count == 0 || candidate < first) {
    second = first;
    first = candidate;
    count = std::min(count + 1, 2);
  } else if (count == 1 || candidate < second) {
    second = candidate;
    count = 2;
  }
}

vec4 rayPointAt(const vec4 &point, const vec4 &direction, float distance,
                int model) {
  if (model == GEO_MODEL_S3)
    return point * std::cos(distance) + direction * std::sin(distance);
  if (model == GEO_MODEL_H3)
    return point * std::cosh(distance) + direction * std::sinh(distance);
  return vec4(point.xyz() + direction.xyz() * distance, 1);
}

vec4 rayTangentAt(const vec4 &point, const vec4 &direction, float distance,
                  int model) {
  if (model == GEO_MODEL_S3)
    return point * -std::sin(distance) + direction * std::cos(distance);
  if (model == GEO_MODEL_H3)
    return point * std::sinh(distance) + direction * std::cosh(distance);
  return direction;
}

float tangentLength(const vec4 &tangent, int model) {
  return std::sqrt(std::max(metricDot(tangent, tangent, model), 0.0f));
}

vec4 canonicalTangent(const vec4 &tangent, int model) {
  float magnitude = tangentLength(tangent, model);
  return magnitude > 1e-8f ? tangent / magnitude : vec4();
}

float quadricValue(const mat4 &quadric, const vec4 &a, const vec4 &b) {
  return dot(a, mat4Apply(quadric, b));
}

} // namespace

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
  float triggerA = fa + collar, triggerB = fb + collar;
  if (!validChartId(ca) || !validChartId(cb) || !raw || !finite(da) ||
      !finite(db) || la < 1e-8f || lb < 1e-8f || !finite(fa) || !finite(fb) ||
      !finite(collar) || fa < 0 || fb < 0 || collar < 0 ||
      !validPortalDistance(triggerA) || !validPortalDistance(triggerB) ||
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
  a.normal = planeNormal(da / la, triggerA);
  a.offset = modelKind_ == GEO_MODEL_R3 ? triggerA : 0;
  a.reversePortal = ib;
  a.toNeighbor = ab;
  b.chartId = cb;
  b.neighborId = ca;
  b.normal = planeNormal(db / lb, triggerB);
  b.offset = modelKind_ == GEO_MODEL_R3 ? triggerB : 0;
  b.reversePortal = ia;
  b.toNeighbor = ab.inverse();
  portals_.push_back(a);
  portals_.push_back(b);
  charts_[ca].portalIds.push_back(ia);
  charts_[cb].portalIds.push_back(ib);
  setError(0);
  return ia;
}

int Atlas::addCappedTubePortal(int exteriorChart, int interiorChart,
                               const vec3 &rawAxis, float radius, float lower,
                               float upper, const float raw[16],
                               float collar) {
  packet_.clear();
  float axisLength = length(rawAxis);
  bool validRadius = validGeodesicRadius(radius) && radius > collar;
  if (modelKind_ == GEO_MODEL_S3)
    validRadius = validRadius && radius + collar < 0.5f * PI;
  if (!validChartId(exteriorChart) || !validChartId(interiorChart) ||
      !raw || !finite(rawAxis) || axisLength < 1e-8f || !finite(radius) ||
      !finite(lower) || !finite(upper) || !finite(collar) || collar < 0 ||
      !validRadius || lower >= 0 || upper <= 0 ||
      upper - lower <= 2 * collar || !validSignedDistance(lower - collar) ||
      !validSignedDistance(upper + collar) ||
      portals_.size() + 6 > GEO_MAX_PORTALS ||
      clips_.size() + 8 > GEO_MAX_CLIPS) {
    setError(7);
    return -1;
  }

  Isometry exteriorToInterior = isometryFrom(raw);
  if (!exteriorToInterior.validate()) {
    setError(7);
    return -1;
  }
  Isometry interiorToExterior = exteriorToInterior.inverse();
  vec3 axis = rawAxis / axisLength;

  auto planeClip = [&](const vec3 &outward, float distance) {
    ChartClip clip;
    clip.normal = planeNormal(outward, distance);
    clip.offset = modelKind_ == GEO_MODEL_R3 ? distance : 0;
    return clip;
  };
  auto quadricClip = [&](const mat4 &quadric) {
    ChartClip clip;
    clip.kind = GEO_CLIP_QUADRIC;
    clip.quadric = quadric;
    clip.keepPositive = 0;
    return clip;
  };
  auto transformClipToExterior = [&](ChartClip clip) {
    if (clip.kind == GEO_CLIP_QUADRIC)
      clip.quadric = transformQuadric(interiorToExterior, clip.quadric);
    else
      clip.normal = transformPlane(interiorToExterior, clip.normal,
                                   clip.offset, modelKind_);
    return clip;
  };
  auto appendPortalClips = [&](ChartPortal &portal,
                               const std::vector<ChartClip> &localClips,
                               bool transformToExterior) {
    for (ChartClip clip : localClips) {
      if (transformToExterior)
        clip = transformClipToExterior(clip);
      int id = int(clips_.size());
      clips_.push_back(clip);
      portal.clipIds.push_back(id);
    }
  };

  int firstPortal = int(portals_.size());
  auto appendPair = [&](ChartPortal exterior, ChartPortal interior,
                        const std::vector<ChartClip> &localClips) {
    int exteriorId = int(portals_.size());
    int interiorId = exteriorId + 1;
    exterior.chartId = exteriorChart;
    exterior.neighborId = interiorChart;
    exterior.reversePortal = interiorId;
    exterior.toNeighbor = exteriorToInterior;
    interior.chartId = interiorChart;
    interior.neighborId = exteriorChart;
    interior.reversePortal = exteriorId;
    interior.toNeighbor = interiorToExterior;
    appendPortalClips(exterior, localClips, true);
    appendPortalClips(interior, localClips, false);
    portals_.push_back(exterior);
    portals_.push_back(interior);
    charts_[exteriorChart].portalIds.push_back(exteriorId);
    charts_[interiorChart].portalIds.push_back(interiorId);
  };

  mat4 exteriorSideLocal = scaled(tubeQuadric(axis, radius - collar,
                                              modelKind_),
                                  -1.0f);
  mat4 interiorSide = tubeQuadric(axis, radius + collar, modelKind_);
  ChartPortal exteriorSide, interiorSidePortal;
  exteriorSide.equationKind = GEO_EQUATION_QUADRIC;
  exteriorSide.quadric =
      transformQuadric(interiorToExterior, exteriorSideLocal);
  interiorSidePortal.equationKind = GEO_EQUATION_QUADRIC;
  interiorSidePortal.quadric = interiorSide;
  std::vector<ChartClip> sideClips = {
      planeClip(axis, upper + collar),
      planeClip(-axis, -(lower - collar))};
  appendPair(exteriorSide, interiorSidePortal, sideClips);

  mat4 capClipQuadric = tubeQuadric(axis, radius + collar, modelKind_);
  std::vector<ChartClip> capClips = {quadricClip(capClipQuadric)};

  ChartPortal exteriorTop, interiorTop;
  exteriorTop.normal = planeNormal(-axis, -(upper - collar));
  exteriorTop.offset =
      modelKind_ == GEO_MODEL_R3 ? -(upper - collar) : 0;
  exteriorTop.normal = transformPlane(interiorToExterior, exteriorTop.normal,
                                      exteriorTop.offset, modelKind_);
  interiorTop.normal = planeNormal(axis, upper + collar);
  interiorTop.offset = modelKind_ == GEO_MODEL_R3 ? upper + collar : 0;
  appendPair(exteriorTop, interiorTop, capClips);

  ChartPortal exteriorBottom, interiorBottom;
  exteriorBottom.normal = planeNormal(axis, lower + collar);
  exteriorBottom.offset =
      modelKind_ == GEO_MODEL_R3 ? lower + collar : 0;
  exteriorBottom.normal = transformPlane(
      interiorToExterior, exteriorBottom.normal, exteriorBottom.offset,
      modelKind_);
  interiorBottom.normal = planeNormal(-axis, -(lower - collar));
  interiorBottom.offset =
      modelKind_ == GEO_MODEL_R3 ? -(lower - collar) : 0;
  appendPair(exteriorBottom, interiorBottom, capClips);

  setError(0);
  return firstPortal;
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
  if (modelKind_ == GEO_MODEL_S3) {
    // This is the same minimal rotation as the former
    // -u*u^T/(1+w) formula, written without its antipodal denominator.
    // At the exact antipode the rotation plane is not unique; choose x-w.
    float spatialLength = length(u);
    vec3 axis = spatialLength > 1e-12f ? u / spatialLength : vec3(1, 0, 0);
    float scale = p.w - 1.0f;
    vec3 c0 = vec3(1, 0, 0) + axis * (scale * axis.x),
         c1 = vec3(0, 1, 0) + axis * (scale * axis.y),
         c2 = vec3(0, 0, 1) + axis * (scale * axis.z);
    mat4 &B = out.m;
    B.m[0] = c0.x;
    B.m[1] = c0.y;
    B.m[2] = c0.z;
    B.m[3] = u.x;
    B.m[4] = c1.x;
    B.m[5] = c1.y;
    B.m[6] = c1.z;
    B.m[7] = u.y;
    B.m[8] = c2.x;
    B.m[9] = c2.y;
    B.m[10] = c2.z;
    B.m[11] = u.z;
    B.m[12] = -u.x;
    B.m[13] = -u.y;
    B.m[14] = -u.z;
    B.m[15] = p.w;
    return out;
  }
  float scale = 1.0f / std::max(1.0f + p.w, 1e-6f);
  vec3 c0 = vec3(1, 0, 0) + u * (scale * u.x),
       c1 = vec3(0, 1, 0) + u * (scale * u.y),
       c2 = vec3(0, 0, 1) + u * (scale * u.z);
  mat4 &B = out.m;
  B.m[0] = c0.x;
  B.m[1] = c0.y;
  B.m[2] = c0.z;
  B.m[3] = -u.x;
  B.m[4] = c1.x;
  B.m[5] = c1.y;
  B.m[6] = c1.z;
  B.m[7] = -u.y;
  B.m[8] = c2.x;
  B.m[9] = c2.y;
  B.m[10] = c2.z;
  B.m[11] = -u.z;
  B.m[12] = -u.x;
  B.m[13] = -u.y;
  B.m[14] = -u.z;
  B.m[15] = p.w;
  return out;
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

bool Atlas::insideClip(const ChartClip &clip, const vec4 &point) const {
  if (clip.kind == GEO_CLIP_LINEAR) {
    float scale = 1 + length(clip.normal) + std::fabs(clip.offset);
    return metricDot(clip.normal, point, modelKind_) <=
           clip.offset + 4e-5f * scale;
  }
  if (clip.kind != GEO_CLIP_QUADRIC)
    return false;
  vec4 qPoint = mat4Apply(clip.quadric, point);
  float value = dot(point, qPoint);
  if (!finite(value) || !finite(qPoint))
    return false;
  float scale = 1 + std::fabs(point.x * qPoint.x) +
                std::fabs(point.y * qPoint.y) +
                std::fabs(point.z * qPoint.z) +
                std::fabs(point.w * qPoint.w);
  float tolerance = 8e-5f * scale;
  return clip.keepPositive ? value >= -tolerance : value <= tolerance;
}

bool Atlas::insidePortalClips(const ChartPortal &portal,
                              const vec4 &point) const {
  for (int clipId : portal.clipIds)
    if (!insideClip(clips_[clipId], point))
      return false;
  return true;
}

float Atlas::portalRoot(const ChartPortal &portal, const vec4 &point,
                        const vec4 &direction, float maximum) const {
  float first = INFINITY, second = INFINITY;
  int count = 0;
  if (portal.equationKind == GEO_EQUATION_LINEAR) {
    if (modelKind_ == GEO_MODEL_R3) {
      float denominator = dot(portal.normal.xyz(), direction.xyz());
      if (std::fabs(denominator) < 1e-6f)
        return INFINITY;
      insertCandidate((portal.offset - dot(portal.normal.xyz(), point.xyz())) /
                          denominator,
                      maximum, first, second, count);
    } else {
      float a = metricDot(portal.normal, point, modelKind_);
      float b = metricDot(portal.normal, direction, modelKind_);
      float kappa = modelKind_ == GEO_MODEL_S3 ? 1.0f : -1.0f;
      float u0 = 0, u1 = 0;
      int roots = quadraticRoots(-kappa * (a + portal.offset), 2 * b,
                                 a - portal.offset, u0, u1);
      auto insertU = [&](float u) {
        if (u < 0)
          return;
        float distance = INFINITY;
        if (modelKind_ == GEO_MODEL_S3)
          distance = 2 * std::atan(u);
        else if (u < 1)
          distance = std::log((1 + u) / (1 - u));
        insertCandidate(distance, maximum, first, second, count);
      };
      if (roots > 0)
        insertU(u0);
      if (roots > 1)
        insertU(u1);
    }
  } else if (portal.equationKind == GEO_EQUATION_QUADRIC) {
    float a = quadricValue(portal.quadric, point, point);
    float b = quadricValue(portal.quadric, point, direction);
    float d = quadricValue(portal.quadric, direction, direction);
    if (modelKind_ == GEO_MODEL_R3) {
      float r0 = 0, r1 = 0;
      int roots = quadraticRoots(d, 2 * b, a, r0, r1);
      if (roots > 0)
        insertCandidate(r0, maximum, first, second, count);
      if (roots > 1)
        insertCandidate(r1, maximum, first, second, count);
    } else if (modelKind_ == GEO_MODEL_H3) {
      float mean = 0.5f * (a + d), r0 = 0, r1 = 0;
      int roots = quadraticRoots(mean + b, a - d, mean - b, r0, r1);
      if (roots > 0 && r0 >= 1)
        insertCandidate(0.5f * std::log(r0), maximum, first, second, count);
      if (roots > 1 && r1 >= 1)
        insertCandidate(0.5f * std::log(r1), maximum, first, second, count);
    } else {
      float constantPart = 0.5f * (a + d);
      float cosinePart = 0.5f * (a - d);
      float amplitude = std::sqrt(cosinePart * cosinePart + b * b);
      if (amplitude > 1e-6f &&
          std::fabs(constantPart) <= amplitude + 1e-6f) {
        float target = std::clamp(-constantPart / amplitude, -1.0f, 1.0f);
        float phase = std::atan2(b, cosinePart);
        float alpha = std::acos(target);
        for (float theta : {phase + alpha, phase - alpha}) {
          theta -= std::floor(theta / (2 * PI)) * 2 * PI;
          insertCandidate(0.5f * theta, maximum, first, second, count);
        }
      }
    }
  }

  for (int candidate = 0; candidate < count; ++candidate) {
    float distance = candidate == 0 ? first : second;
    vec4 hit = rayPointAt(point, direction, distance, modelKind_);
    if (!insidePortalClips(portal, hit))
      continue;
    vec4 normal;
    if (portal.equationKind == GEO_EQUATION_LINEAR) {
      normal = portal.normal;
      if (modelKind_ != GEO_MODEL_R3) {
        float kappa = modelKind_ == GEO_MODEL_S3 ? 1.0f : -1.0f;
        normal = normal - hit *
                              (kappa * metricDot(normal, hit, modelKind_));
      }
    } else {
      vec4 covector = mat4Apply(portal.quadric, hit);
      normal = modelKind_ == GEO_MODEL_H3
                   ? vec4(covector.xyz(), -covector.w)
                   : covector;
      if (modelKind_ != GEO_MODEL_R3) {
        float kappa = modelKind_ == GEO_MODEL_S3 ? 1.0f : -1.0f;
        normal = normal - hit *
                              (kappa * metricDot(normal, hit, modelKind_));
      }
    }
    vec4 tangent = rayTangentAt(point, direction, distance, modelKind_);
    if (metricDot(normal, tangent, modelKind_) > 1e-6f)
      return distance;
  }
  return INFINITY;
}

bool Atlas::moveThroughPortals(int &chart, vec4 &point, vec4 &direction,
                               float distance, vec4 *right, vec4 *up,
                               vec4 *forward) const {
  float remaining = distance;
  for (int hop = 0; hop < 128; ++hop) {
    int selected = -1;
    float nearest = remaining + 1;
    for (int id : charts_[chart].portalIds) {
      float root = portalRoot(portals_[id], point, direction, remaining);
      if (root < nearest) {
        nearest = root;
        selected = id;
      }
    }

    float advance = selected >= 0 ? nearest : remaining;
    if (advance > 0) {
      vec4 displacement = direction * advance;
      if (right)
        *right = parallelTransportAlong(point, displacement, *right);
      if (up)
        *up = parallelTransportAlong(point, displacement, *up);
      if (forward)
        *forward = parallelTransportAlong(point, displacement, *forward);
      vec4 nextDirection =
          rayTangentAt(point, direction, advance, modelKind_);
      point = rayPointAt(point, direction, advance, modelKind_);
      direction = canonicalTangent(nextDirection, modelKind_);
      remaining = std::max(remaining - advance, 0.0f);
    }
    if (selected < 0)
      return true;

    const ChartPortal &portal = portals_[selected];
    point = portal.toNeighbor.applyPoint(point);
    direction = canonicalTangent(portal.toNeighbor.applyTangent(direction),
                                 modelKind_);
    if (right)
      *right = portal.toNeighbor.applyTangent(*right);
    if (up)
      *up = portal.toNeighbor.applyTangent(*up);
    if (forward)
      *forward = portal.toNeighbor.applyTangent(*forward);
    chart = portal.neighborId;
  }
  return remaining <= 1e-6f;
}

CameraPlacement Atlas::resolveCameraPlacement(int chart, const vec4 &start,
                                              const vec3 &move) const {
  CameraPlacement result;
  result.chartId = chart;
  vec4 point;
  if (!validChartId(chart) || !canonicalizePoint(start, point) || !finite(move))
    return result;
  Isometry recenter = movePointToOrigin(point);
  vec4 tangent = recenter.inverse().applyTangent(vec4(move, 0));
  float distance = tangentLength(tangent, modelKind_);
  vec4 direction = distance > 1e-8f ? tangent / distance : vec4();
  int current = chart;
  if (distance > 1e-8f &&
      !moveThroughPortals(current, point, direction, distance, nullptr,
                          nullptr, nullptr))
    return result;
  result.chartId = current;
  result.localPosition = point;
  return result;
}

int Atlas::cameraChartAt(int chart, const vec4 &raw, float viewDistance) {
  vec4 p;
  if (!validChartId(chart) || !canonicalizePoint(raw, p) ||
      !validViewDistance(viewDistance)) {
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
  vec4 point = cameraPosition_;
  Isometry oldCenter = movePointToOrigin(point);
  vec4 ambientMove = oldCenter.inverse().applyTangent(vec4(movement, 0));
  vec4 right = oldCenter.inverse().applyTangent(vec4(cameraRight_, 0));
  vec4 up = oldCenter.inverse().applyTangent(vec4(cameraUp_, 0));
  vec4 fwd = oldCenter.inverse().applyTangent(vec4(cameraFwd_, 0));
  float distance = tangentLength(ambientMove, modelKind_);
  vec4 direction = distance > 1e-8f ? ambientMove / distance : vec4();
  if (distance > 1e-8f &&
      !moveThroughPortals(current, point, direction, distance, &right, &up,
                          &fwd)) {
    setError(4);
    return -1;
  }
  Isometry centered = movePointToOrigin(point);
  cameraRight_ = normalize(centered.applyTangent(right).xyz());
  cameraFwd_ = normalize(centered.applyTangent(fwd).xyz());
  cameraRight_ =
      normalize(cameraRight_ - cameraFwd_ * dot(cameraRight_, cameraFwd_));
  cameraUp_ = normalize(cross(cameraFwd_, cameraRight_));
  cameraChartId_ = current;
  cameraPosition_ = point;
  setError(0);
  return cameraChartId_;
}

} // namespace geo
