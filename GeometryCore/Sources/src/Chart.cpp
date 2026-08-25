#include "GeometryCore/Chart.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <queue>

namespace geo {
namespace {
constexpr float PI = 3.14159265358979323846f;
constexpr float POINT_TOL = 2e-3f;
constexpr float CONTAIN_TOL = 2e-4f;
constexpr float PORTAL_REDUCTION_TOL = 1e-6f;
// Keep portal hits well separated from both the reverse trigger and the
// float32 self-hit tolerance. This also provides enough overlap for stable
// compound reductions near quotient-domain edges and vertices.
constexpr float PORTAL_COLLAR = 1e-2f;

bool finite(float x) { return std::isfinite(x); }
bool finite(const vec3 &v) { return finite(v.x) && finite(v.y) && finite(v.z); }
bool finite(const vec4 &v) {
  return finite(v.x) && finite(v.y) && finite(v.z) && finite(v.w);
}
float lorDot(const vec4 &a, const vec4 &b) {
  return a.x * b.x + a.y * b.y + a.z * b.z - a.w * b.w;
}
float metricDot(const vec4 &a, const vec4 &b, int model) {
  return model == GEO_MODEL_H3 ? lorDot(a, b) : dot(a, b);
}

template <class T> void append(std::vector<uint8_t> &out, const T &value) {
  auto p = reinterpret_cast<const uint8_t *>(&value);
  out.insert(out.end(), p, p + sizeof(T));
}
template <class T>
void appendMany(std::vector<uint8_t> &out, const std::vector<T> &v) {
  if (v.empty())
    return;
  auto p = reinterpret_cast<const uint8_t *>(v.data());
  out.insert(out.end(), p, p + sizeof(T) * v.size());
}

bool matrixClose(const mat4 &a, const mat4 &b, float e = 2e-3f) {
  for (int i = 0; i < 16; ++i)
    if (std::fabs(a.m[i] - b.m[i]) > e)
      return false;
  return true;
}

mat4 transpose(const mat4 &m) {
  mat4 out;
  for (int row = 0; row < 4; ++row)
    for (int column = 0; column < 4; ++column)
      out.m[column * 4 + row] = m.m[row * 4 + column];
  return out;
}

float matrixScale(const mat4 &m) {
  float largest = 0;
  for (float value : m.m)
    largest = std::max(largest, std::fabs(value));
  return largest;
}

mat4 normalizedMatrix(const mat4 &m) {
  mat4 out = m;
  float scale = matrixScale(m);
  if (scale == 0 || !finite(scale))
    return out;
  float squaredNorm = 0;
  for (float value : m.m) {
    float scaled = value / scale;
    squaredNorm += scaled * scaled;
  }
  float normalizedScale = std::sqrt(squaredNorm);
  for (float &value : out.m)
    value = (value / scale) / normalizedScale;
  return out;
}

mat4 transformQuadric(const Isometry &m, const mat4 &quadric) {
  mat4 inverse = m.inverse().m;
  return normalizedMatrix(mat4Mul(mat4Mul(transpose(inverse), quadric), inverse));
}

vec4 transformPlane(const Isometry &m, const vec4 &normal, float &offset,
                    int model) {
  if (model != GEO_MODEL_R3)
    return m.applyTangent(normal);
  vec3 u = normal.xyz();
  vec3 up(m.m.m[0] * u.x + m.m.m[4] * u.y + m.m.m[8] * u.z,
          m.m.m[1] * u.x + m.m.m[5] * u.y + m.m.m[9] * u.z,
          m.m.m[2] * u.x + m.m.m[6] * u.y + m.m.m[10] * u.z);
  offset += dot(up, vec3(m.m.m[12], m.m.m[13], m.m.m[14]));
  return vec4(up, 0);
}
} // namespace

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
  cameraTraceRadius_ = 1;
  cameraRight_ = vec3(1, 0, 0);
  cameraUp_ = vec3(0, 1, 0);
  cameraFwd_ = vec3(0, 0, 1);
  fovTan_ = aspect_ = 1;
  maxBounces_ = 4;
  falloffK_ = ambient_ = 0;
  bounceAttenuation_ = 1;
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
bool Atlas::validChartRadius(float r) const {
  if (!finite(r) || r <= 0)
    return false;
  if (modelKind_ == GEO_MODEL_S3)
    return r < PI;
  if (modelKind_ == GEO_MODEL_H3)
    return finite(std::sinh(r)) && finite(std::cosh(r));
  return finite(r * 0.5f);
}

float Atlas::tracingParameter(float r) const {
  if (modelKind_ == GEO_MODEL_S3)
    return std::tan(0.5f * r);
  if (modelKind_ == GEO_MODEL_H3)
    return std::tanh(0.5f * r);
  return 0.5f * r;
}

int Atlas::seed(float r) {
  packet_.clear();
  if (!validModelKind()) {
    setError(6);
    return -1;
  }
  if (!charts_.empty()) {
    setError(5);
    return -1;
  }
  if (!validChartRadius(r)) {
    setError(3);
    return -1;
  }
  Chart c;
  c.id = 0;
  c.radius = r;
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

int Atlas::addChart(float r, int from, const float raw[16], bool safe) {
  packet_.clear();
  if (!validChartId(from) || !validChartRadius(r) || !raw) {
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
  c.radius = r;
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

float Atlas::originDistance(const vec4 &p) const {
  if (modelKind_ == GEO_MODEL_S3)
    return std::acos(std::clamp(p.w, -1.0f, 1.0f));
  if (modelKind_ == GEO_MODEL_H3)
    return std::acosh(std::max(p.w, 1.0f));
  return length(p.xyz());
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

int Atlas::addMaterial(const vec4 &color, const vec4 &spec) {
  packet_.clear();
  if (!finite(color) || !finite(spec) ||
      materials_.size() >= GEO_MAX_MATERIALS) {
    setError(5);
    return -1;
  }
  materials_.push_back(Material{color, spec});
  setError(0);
  return int(materials_.size() - 1);
}

int Atlas::addBall(int chart, const vec4 &raw, float r, int material) {
  return addBallSurface(chart, raw, r, material, GEO_RESPONSE_OPAQUE);
}

int Atlas::addBallSurface(int chart, const vec4 &raw, float r, int material,
                          int response) {
  packet_.clear();
  vec4 center;
  if (!validChartId(chart) || !canonicalizePoint(raw, center) || !finite(r) ||
      r <= 0 || material < 0 || material >= int(materials_.size()) ||
      (response != GEO_RESPONSE_OPAQUE && response != GEO_RESPONSE_MIRROR) ||
      originDistance(center) + r > charts_[chart].radius + CONTAIN_TOL ||
      objects_.size() >= GEO_MAX_OBJECTS) {
    setError(3);
    return -1;
  }
  ChartObject o;
  o.chartId = chart;
  o.responseKind = response;
  if (modelKind_ == GEO_MODEL_R3) {
    o.equationKind = GEO_EQUATION_R3_SPHERE;
    o.geometry = center;
    o.parameter = r;
  } else {
    // A curved-space sphere is an oriented ambient linear section. Negating
    // both sides makes the tangent gradient point away from its center.
    float level = modelKind_ == GEO_MODEL_S3 ? std::cos(r) : -std::cosh(r);
    o.equationKind = GEO_EQUATION_LINEAR;
    o.geometry = -center;
    o.parameter = -level;
  }
  o.colorIdx = material;
  objects_.push_back(o);
  charts_[chart].objectIds.push_back(int(objects_.size() - 1));
  setError(0);
  return int(objects_.size() - 1);
}

bool Atlas::normalizedLinearForm(const vec4 &raw, float offset, vec4 &normal,
                                 float &normalizedOffset) const {
  if (!finite(raw) || !finite(offset))
    return false;
  if (modelKind_ == GEO_MODEL_R3) {
    float scale = length(raw.xyz());
    if (scale < 1e-8f || std::fabs(raw.w) > 1e-5f)
      return false;
    normal = vec4(raw.xyz() / scale, 0);
    normalizedOffset = offset / scale;
    return true;
  }
  float metricNorm = modelKind_ == GEO_MODEL_H3 ? lorDot(raw, raw) : dot(raw, raw);
  float scale = std::fabs(metricNorm) > 1e-8f
                    ? std::sqrt(std::fabs(metricNorm))
                    : length(raw);
  if (scale < 1e-8f)
    return false;
  normal = raw / scale;
  normalizedOffset = offset / scale;
  return true;
}

int Atlas::addLinearSurface(int chart, const vec4 &raw, float offset,
                            int material, int response) {
  packet_.clear();
  vec4 normal;
  float normalizedOffset = 0;
  if (!validChartId(chart) ||
      !normalizedLinearForm(raw, offset, normal, normalizedOffset) ||
      material < 0 || material >= int(materials_.size()) ||
      (response != GEO_RESPONSE_OPAQUE && response != GEO_RESPONSE_MIRROR) ||
      objects_.size() >= GEO_MAX_OBJECTS) {
    setError(3);
    return -1;
  }
  ChartObject o;
  o.chartId = chart;
  o.equationKind = GEO_EQUATION_LINEAR;
  o.responseKind = response;
  o.geometry = normal;
  o.parameter = normalizedOffset;
  o.colorIdx = material;
  o.needsChartBound = true;
  objects_.push_back(o);
  charts_[chart].objectIds.push_back(int(objects_.size() - 1));
  setError(0);
  return int(objects_.size() - 1);
}

vec4 Atlas::planeNormal(const vec3 &u, float d) const {
  if (modelKind_ == GEO_MODEL_S3)
    return vec4(u * std::cos(d), -std::sin(d));
  if (modelKind_ == GEO_MODEL_H3)
    return vec4(u * std::cosh(d), std::sinh(d));
  return vec4(u, 0);
}

int Atlas::addPlane(int chart, const vec3 &dir, float d, int material,
                    int response) {
  float l = length(dir);
  if (!validChartId(chart) || !finite(dir) || l < 1e-8f || !finite(d) ||
      std::fabs(d) > charts_[chart].radius + CONTAIN_TOL) {
    setError(3);
    return -1;
  }
  vec4 normal = planeNormal(dir / l, d);
  float offset = modelKind_ == GEO_MODEL_R3 ? d : 0;
  return addLinearSurface(chart, normal, offset, material, response);
}

int Atlas::addMirrorPlane(int chart, const vec3 &dir, float d, int material) {
  if (!finite(d) || d < 0) {
    setError(3);
    return -1;
  }
  return addPlane(chart, dir, d, material, GEO_RESPONSE_MIRROR);
}

int Atlas::addQuadric(int chart, const float coefficients[16], int material,
                      int response) {
  packet_.clear();
  if (!validChartId(chart) || coefficients == nullptr || material < 0 ||
      material >= int(materials_.size()) ||
      (response != GEO_RESPONSE_OPAQUE && response != GEO_RESPONSE_MIRROR) ||
      objects_.size() >= GEO_MAX_OBJECTS) {
    setError(3);
    return -1;
  }
  mat4 q;
  for (int i = 0; i < 16; ++i) {
    if (!finite(coefficients[i])) {
      setError(3);
      return -1;
    }
    q.m[i] = coefficients[i];
  }
  float scale = matrixScale(q);
  if (!finite(scale) || scale == 0) {
    setError(3);
    return -1;
  }
  for (int row = 0; row < 4; ++row) {
    for (int column = row + 1; column < 4; ++column) {
      if (std::fabs(q.m[column * 4 + row] - q.m[row * 4 + column]) >
          1e-5f * scale) {
        setError(3);
        return -1;
      }
      float symmetric =
          0.5f * (q.m[column * 4 + row] + q.m[row * 4 + column]);
      q.m[column * 4 + row] = symmetric;
      q.m[row * 4 + column] = symmetric;
    }
  }
  ChartObject o;
  o.chartId = chart;
  o.equationKind = GEO_EQUATION_QUADRIC;
  o.responseKind = response;
  o.quadric = normalizedMatrix(q);
  o.colorIdx = material;
  o.needsChartBound = true;
  objects_.push_back(o);
  charts_[chart].objectIds.push_back(int(objects_.size() - 1));
  setError(0);
  return int(objects_.size() - 1);
}

int Atlas::addCliffordTorus(int chart, int material, int response) {
  if (modelKind_ != GEO_MODEL_S3) {
    setError(3);
    return -1;
  }
  float q[16] = {0};
  q[0] = q[5] = 1;
  q[10] = q[15] = -1;
  return addQuadric(chart, q, material, response);
}

int Atlas::addObjectClip(int object, const vec4 &raw, float offset) {
  packet_.clear();
  vec4 normal;
  float normalizedOffset = 0;
  if (object < 0 || object >= int(objects_.size()) ||
      objects_[object].clipIds.size() >= GEO_MAX_CLIPS_PER_OBJECT ||
      clips_.size() >= GEO_MAX_CLIPS ||
      !normalizedLinearForm(raw, offset, normal, normalizedOffset)) {
    setError(3);
    return -1;
  }
  clips_.push_back(ChartClip{normal, normalizedOffset});
  objects_[object].clipIds.push_back(int(clips_.size() - 1));
  setError(0);
  return int(clips_.size() - 1);
}

int Atlas::addObjectClipPlane(int object, const vec3 &dir, float d) {
  float l = length(dir);
  if (object < 0 || object >= int(objects_.size()) || !finite(dir) ||
      l < 1e-8f || !finite(d)) {
    setError(3);
    return -1;
  }
  vec4 normal = planeNormal(dir / l, d);
  float offset = modelKind_ == GEO_MODEL_R3 ? d : 0;
  return addObjectClip(object, normal, offset);
}

int Atlas::addLight(int chart, const vec4 &raw, const vec3 &color,
                    float intensity) {
  packet_.clear();
  vec4 p;
  if (!validChartId(chart) || !canonicalizePoint(raw, p) || !finite(color) ||
      !finite(intensity) || intensity < 0 ||
      originDistance(p) > charts_[chart].radius + CONTAIN_TOL ||
      lights_.size() >= GEO_MAX_LIGHTS) {
    setError(3);
    return -1;
  }
  ChartLight l;
  l.chartId = chart;
  l.position = p;
  l.color = color;
  l.intensity = intensity;
  l.radius = 0.0f;
  l.kind = GEO_LIGHT_POINT;
  lights_.push_back(l);
  charts_[chart].lightIds.push_back(int(lights_.size() - 1));
  setError(0);
  return int(lights_.size() - 1);
}

int Atlas::addSphericalAreaLight(int chart, const vec4 &raw, float radius,
                                 const vec3 &color, float emittedRadiance) {
  packet_.clear();
  vec4 center;
  if (!validChartId(chart) || !canonicalizePoint(raw, center) ||
      !validChartRadius(radius) || !finite(color) ||
      !finite(emittedRadiance) || emittedRadiance < 0 ||
      originDistance(center) + radius >
          charts_[chart].radius + CONTAIN_TOL ||
      lights_.size() >= GEO_MAX_LIGHTS) {
    setError(3);
    return -1;
  }
  ChartLight l;
  l.chartId = chart;
  l.position = center;
  l.color = color;
  l.intensity = emittedRadiance;
  l.radius = radius;
  l.kind = GEO_LIGHT_SPHERE;
  lights_.push_back(l);
  charts_[chart].lightIds.push_back(int(lights_.size() - 1));
  setError(0);
  return int(lights_.size() - 1);
}

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
void Atlas::setControls(int b, float f, float a, float ba) {
  setControls(b, f, a, ba, 0, 0, 0);
}
void Atlas::setControls(int b, float f, float a, float ba, float fm, float fs,
                        float fd) {
  maxBounces_ = b;
  falloffK_ = f;
  ambient_ = a;
  bounceAttenuation_ = ba;
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

int Atlas::cameraChartAt(int chart, const vec4 &raw, float radius) {
  vec4 p;
  if (!validChartId(chart) || !canonicalizePoint(raw, p) ||
      !validChartRadius(radius) ||
      originDistance(p) > charts_[chart].radius + CONTAIN_TOL) {
    setError(4);
    return -1;
  }
  cameraChartId_ = chart;
  cameraPosition_ = p;
  cameraTraceRadius_ = radius;
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

int Atlas::chartTransformsTo(int camera, std::vector<Isometry> &out) const {
  out.resize(charts_.size());
  std::vector<char> seen(charts_.size(), 0);
  out[camera].kind = kind();
  out[camera].m = mat4Identity();
  seen[camera] = 1;
  std::queue<int> q;
  q.push(camera);
  while (!q.empty()) {
    int cur = q.front();
    q.pop();
    for (const auto &e : charts_[cur].edges) {
      Isometry neighborToCur = e.toNeighbor.inverse();
      Isometry candidate = out[cur].compose(neighborToCur);
      if (!seen[e.neighborId]) {
        out[e.neighborId] = candidate;
        seen[e.neighborId] = 1;
        q.push(e.neighborId);
      } else if (!matrixClose(out[e.neighborId].m, candidate.m))
        return 2;
    }
  }
  for (char s : seen)
    if (!s)
      return 1;
  return 0;
}

bool Atlas::validateScene() const {
  if (!validModelKind() || charts_.empty() ||
      objects_.size() > GEO_MAX_OBJECTS ||
      clips_.size() > GEO_MAX_CLIPS || materials_.size() > GEO_MAX_MATERIALS ||
      lights_.size() > GEO_MAX_LIGHTS)
    return false;
  for (const auto &o : objects_) {
    if (o.colorIdx < 0 || o.colorIdx >= int(materials_.size()) ||
        (o.equationKind != GEO_EQUATION_LINEAR &&
         o.equationKind != GEO_EQUATION_R3_SPHERE &&
         o.equationKind != GEO_EQUATION_QUADRIC) ||
        (o.responseKind != GEO_RESPONSE_OPAQUE &&
         o.responseKind != GEO_RESPONSE_MIRROR) ||
        o.clipIds.size() > GEO_MAX_CLIPS_PER_OBJECT)
      return false;
    for (int clipId : o.clipIds)
      if (clipId < 0 || clipId >= int(clips_.size()))
        return false;
  }
  for (const auto &p : portals_)
    if (!p.toNeighbor.validate() || !validChartId(p.neighborId) ||
        p.reversePortal < 0 || p.reversePortal >= int(portals_.size()))
      return false;
  return true;
}

int Atlas::emit(bool flatten, int cameraChart, int depth, int hops,
                int lightHops, int lightStates) {
  packet_.clear();
  if (!validChartId(cameraChart)) {
    setError(4);
    return 4;
  }
  if (!validateScene()) {
    setError(3);
    return 3;
  }
  if (depth <= 0 || depth > GEO_MAX_CHART_DEPTH) {
    setError(5);
    return 5;
  }
  if (!flatten && (hops <= 0 || hops > 128 || lightHops < 0 || lightHops > 4 ||
                   lightStates <= 0 || lightStates > 256)) {
    setError(8);
    return 8;
  }
  if (!flatten) {
    std::vector<char> seen(charts_.size(), 0);
    std::queue<int> q;
    seen[cameraChart] = 1;
    q.push(cameraChart);
    while (!q.empty()) {
      int c = q.front();
      q.pop();
      for (const auto &e : charts_[c].edges)
        if (!seen[e.neighborId]) {
          seen[e.neighborId] = 1;
          q.push(e.neighborId);
        }
      for (int id : charts_[c].portalIds) {
        int n = portals_[id].neighborId;
        if (!seen[n]) {
          seen[n] = 1;
          q.push(n);
        }
      }
    }
    for (char s : seen)
      if (!s) {
        setError(1);
        return 1;
      }
  }
  std::vector<Isometry> toCamera;
  if (flatten) {
    int transitionError = chartTransformsTo(cameraChart, toCamera);
    if (transitionError) {
      setError(transitionError);
      return transitionError;
    }
  }
  std::vector<GPUChart> gpuCharts;
  std::vector<GPUPortal> gpuPortals;
  std::vector<Object> gpuObjects;
  std::vector<Quadric> gpuQuadrics;
  std::vector<PrimitiveClip> gpuClips;
  std::vector<PointLight> gpuLights;
  Isometry recenter = movePointToOrigin(cameraPosition_);
  Isometry localIdentity;
  localIdentity.kind = kind();
  localIdentity.m = mat4Identity();

  auto appendObject = [&](const ChartObject &o, const Isometry &transform,
                          bool developed) {
    Object x{};
    x.equationKind = o.equationKind;
    x.responseKind = o.responseKind;
    x.colorIdx = o.colorIdx;
    x.quadricIndex = -1;
    if (o.equationKind == GEO_EQUATION_LINEAR) {
      x.parameter = o.parameter;
      x.geometry = developed
                       ? transformPlane(transform, o.geometry, x.parameter,
                                        modelKind_)
                       : o.geometry;
    } else if (o.equationKind == GEO_EQUATION_R3_SPHERE) {
      x.geometry = developed ? transform.applyPoint(o.geometry) : o.geometry;
      x.parameter = o.parameter;
    } else {
      x.quadricIndex = int(gpuQuadrics.size());
      gpuQuadrics.push_back(
          Quadric{developed ? transformQuadric(transform, o.quadric)
                            : o.quadric});
    }

    x.firstClip = int(gpuClips.size());
    for (int clipId : o.clipIds) {
      const auto &clip = clips_[clipId];
      PrimitiveClip emitted{};
      emitted.kind = GEO_CLIP_LINEAR;
      emitted.parameter = clip.offset;
      emitted.geometry = developed
                             ? transformPlane(transform, clip.normal,
                                              emitted.parameter, modelKind_)
                             : clip.normal;
      gpuClips.push_back(emitted);
    }
    if (developed && o.needsChartBound) {
      PrimitiveClip bound{};
      bound.kind = GEO_CLIP_BALL;
      bound.geometry = transform.applyPoint(vec4(0, 0, 0, 1));
      float radius = charts_[o.chartId].radius;
      bound.parameter = modelKind_ == GEO_MODEL_S3 ? std::cos(radius)
                        : modelKind_ == GEO_MODEL_H3
                            ? -std::cosh(radius)
                            : radius;
      gpuClips.push_back(bound);
    }
    x.clipCount = int(gpuClips.size()) - x.firstClip;
    gpuObjects.push_back(x);
  };

  if (flatten) {
    GPUChart c{};
    c.intrinsicRadius = cameraTraceRadius_;
    c.tracingParameter = tracingParameter(cameraTraceRadius_);
    c.objectCount = int(objects_.size());
    c.lightCount = int(lights_.size());
    gpuCharts.push_back(c);
    for (const auto &o : objects_) {
      Isometry m = recenter.compose(toCamera[o.chartId]);
      appendObject(o, m, true);
    }
    for (const auto &l : lights_) {
      Isometry m = recenter.compose(toCamera[l.chartId]);
      gpuLights.push_back(
          PointLight{m.applyPoint(l.position), l.color, l.intensity,
                     l.radius, l.kind, 0, 0});
    }
  } else {
    std::vector<int> portalRemap(portals_.size(), -1);
    int nextPortal = 0;
    for (const auto &c : charts_)
      for (int id : c.portalIds)
        portalRemap[id] = nextPortal++;
    for (const auto &c : charts_) {
      GPUChart g{};
      g.intrinsicRadius = c.radius;
      g.tracingParameter = tracingParameter(c.radius);
      g.firstPortal = int(gpuPortals.size());
      g.portalCount = int(c.portalIds.size());
      g.firstObject = int(gpuObjects.size());
      g.objectCount = int(c.objectIds.size());
      g.firstLight = int(gpuLights.size());
      g.lightCount = int(c.lightIds.size());
      for (int id : c.portalIds) {
        const auto &p = portals_[id];
        GPUPortal x{};
        x.toNeighbor = p.toNeighbor.m;
        x.normal = p.normal;
        x.offset = p.offset;
        x.neighborChart = p.neighborId;
        x.reversePortal = portalRemap[p.reversePortal];
        gpuPortals.push_back(x);
      }
      for (int id : c.objectIds) {
        appendObject(objects_[id], localIdentity, false);
      }
      for (int id : c.lightIds) {
        const auto &l = lights_[id];
        gpuLights.push_back(PointLight{l.position, l.color, l.intensity,
                                       l.radius, l.kind, 0, 0});
      }
      gpuCharts.push_back(g);
    }
  }
  if (gpuQuadrics.size() > GEO_MAX_OBJECTS ||
      gpuClips.size() > GEO_MAX_CLIPS) {
    packet_.clear();
    setError(3);
    return 3;
  }
  ScenePacketHeader h{};
  h.meta = {GEO_PACKET_MAGIC, GEO_CONTRACT_VERSION, int(sizeof(Object)),
            int(sizeof(ScenePacketHeader))};
  h.camera.position = flatten ? vec4(0, 0, 0, 1) : cameraPosition_;
  h.camera.fovTan = fovTan_;
  h.camera.aspect = aspect_;
  h.camera.maxTraceDistance = cameraTraceRadius_;
  h.camera.maxTraceParameter = tracingParameter(cameraTraceRadius_);
  h.camera.chartId = flatten ? 0 : cameraChart;
  if (flatten) {
    h.camera.right = vec4(cameraRight_, 0);
    h.camera.up = vec4(cameraUp_, 0);
    h.camera.fwd = vec4(cameraFwd_, 0);
  } else {
    Isometry inv = recenter.inverse();
    h.camera.right = inv.applyTangent(vec4(cameraRight_, 0));
    h.camera.up = inv.applyTangent(vec4(cameraUp_, 0));
    h.camera.fwd = inv.applyTangent(vec4(cameraFwd_, 0));
  }
  h.controls = {maxBounces_,
                modelKind_,
                falloffK_,
                ambient_,
                bounceAttenuation_,
                fogMode_,
                fogStartFraction_,
                fogDensity_,
                flatten ? 1 : hops,
                flatten ? 0 : lightHops,
                flatten ? 1 : lightStates,
                0};
  h.counts = {int(gpuCharts.size()),
              int(gpuPortals.size()),
              int(gpuObjects.size()),
              int(materials_.size()),
              int(gpuLights.size()),
              int(gpuQuadrics.size()),
              int(gpuClips.size()),
              0};
  append(packet_, h);
  appendMany(packet_, gpuCharts);
  appendMany(packet_, gpuPortals);
  appendMany(packet_, gpuObjects);
  appendMany(packet_, gpuQuadrics);
  appendMany(packet_, gpuClips);
  appendMany(packet_, materials_);
  appendMany(packet_, gpuLights);
  setError(0);
  return 0;
}

int Atlas::build(int camera, int depth) {
  return emit(true, camera, depth, 1, 0, 1);
}
int Atlas::buildAtlas(int camera, int hops, int lightHops, int lightStates) {
  return emit(false, camera, GEO_MAX_CHART_DEPTH, hops, lightHops, lightStates);
}

} // namespace geo
