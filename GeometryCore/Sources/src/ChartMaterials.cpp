#include "ChartInternal.h"

#include <algorithm>
#include <cmath>
#include <queue>

// Material, object, clipping, and light construction.
namespace geo {
using namespace chart_detail;

int Atlas::addMaterial(const vec4 &baseColor, float roughness, float metallic,
                       float ior, float transmission, const vec3 &emission) {
  packet_.clear();
  bool validBaseColor =
      baseColor.x >= 0 && baseColor.x <= 1 && baseColor.y >= 0 &&
      baseColor.y <= 1 && baseColor.z >= 0 && baseColor.z <= 1 &&
      baseColor.w >= 0 && baseColor.w <= 1;
  bool validEmission = emission.x >= 0 && emission.y >= 0 && emission.z >= 0;
  if (!finite(baseColor) || !validBaseColor || !finite(roughness) ||
      roughness < 0 || roughness > 1 || !finite(metallic) || metallic < 0 ||
      metallic > 1 || !finite(ior) || ior < 1 || !finite(transmission) ||
      transmission < 0 || transmission > 1 || !finite(emission) ||
      !validEmission || materials_.size() >= GEO_MAX_MATERIALS) {
    setError(5);
    return -1;
  }
  materials_.push_back(
      Material{baseColor, emission, roughness, metallic, ior, transmission, 0});
  setError(0);
  return int(materials_.size() - 1);
}

int Atlas::addBall(int chart, const vec4 &raw, float r, int material) {
  return addBallSurface(chart, raw, r, material);
}

int Atlas::addBallSurface(int chart, const vec4 &raw, float r, int material) {
  packet_.clear();
  vec4 center;
  if (!validChartId(chart) || !canonicalizePoint(raw, center) || !finite(r) ||
      r <= 0 || material < 0 || material >= int(materials_.size()) ||
      originDistance(center) + r > charts_[chart].radius + CONTAIN_TOL ||
      objects_.size() >= GEO_MAX_OBJECTS) {
    setError(3);
    return -1;
  }
  ChartObject o;
  o.chartId = chart;
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
                            int material) {
  packet_.clear();
  vec4 normal;
  float normalizedOffset = 0;
  if (!validChartId(chart) ||
      !normalizedLinearForm(raw, offset, normal, normalizedOffset) ||
      material < 0 || material >= int(materials_.size()) ||
      objects_.size() >= GEO_MAX_OBJECTS) {
    setError(3);
    return -1;
  }
  ChartObject o;
  o.chartId = chart;
  o.equationKind = GEO_EQUATION_LINEAR;
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

int Atlas::addPlane(int chart, const vec3 &dir, float d, int material) {
  float l = length(dir);
  if (!validChartId(chart) || !finite(dir) || l < 1e-8f || !finite(d) ||
      std::fabs(d) > charts_[chart].radius + CONTAIN_TOL) {
    setError(3);
    return -1;
  }
  vec4 normal = planeNormal(dir / l, d);
  float offset = modelKind_ == GEO_MODEL_R3 ? d : 0;
  return addLinearSurface(chart, normal, offset, material);
}

bool Atlas::normalizedQuadric(const float coefficients[16],
                              mat4 &normalized) const {
  if (coefficients == nullptr)
    return false;
  mat4 q;
  for (int i = 0; i < 16; ++i) {
    if (!finite(coefficients[i]))
      return false;
    q.m[i] = coefficients[i];
  }
  float scale = matrixScale(q);
  if (!finite(scale) || scale == 0)
    return false;
  for (int row = 0; row < 4; ++row) {
    for (int column = row + 1; column < 4; ++column) {
      if (std::fabs(q.m[column * 4 + row] - q.m[row * 4 + column]) >
          1e-5f * scale) {
        return false;
      }
      float symmetric =
          0.5f * (q.m[column * 4 + row] + q.m[row * 4 + column]);
      q.m[column * 4 + row] = symmetric;
      q.m[row * 4 + column] = symmetric;
    }
  }
  normalized = normalizedMatrix(q);
  return true;
}

int Atlas::addQuadric(int chart, const float coefficients[16], int material) {
  packet_.clear();
  if (!validChartId(chart) || material < 0 ||
      material >= int(materials_.size()) ||
      objects_.size() >= GEO_MAX_OBJECTS) {
    setError(3);
    return -1;
  }
  mat4 normalized;
  if (!normalizedQuadric(coefficients, normalized)) {
    setError(3);
    return -1;
  }
  ChartObject o;
  o.chartId = chart;
  o.equationKind = GEO_EQUATION_QUADRIC;
  o.quadric = normalized;
  o.colorIdx = material;
  o.needsChartBound = true;
  objects_.push_back(o);
  charts_[chart].objectIds.push_back(int(objects_.size() - 1));
  setError(0);
  return int(objects_.size() - 1);
}

int Atlas::addCliffordTorus(int chart, int material) {
  if (modelKind_ != GEO_MODEL_S3) {
    setError(3);
    return -1;
  }
  float q[16] = {0};
  q[0] = q[5] = 1;
  q[10] = q[15] = -1;
  return addQuadric(chart, q, material);
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
  ChartClip clip;
  clip.normal = normal;
  clip.offset = normalizedOffset;
  clips_.push_back(clip);
  objects_[object].clipIds.push_back(int(clips_.size() - 1));
  setError(0);
  return int(clips_.size() - 1);
}

int Atlas::addObjectClipQuadric(int object, const float coefficients[16],
                                bool keepPositive) {
  packet_.clear();
  if (object < 0 || object >= int(objects_.size()) ||
      objects_[object].clipIds.size() >= GEO_MAX_CLIPS_PER_OBJECT ||
      clips_.size() >= GEO_MAX_CLIPS) {
    setError(3);
    return -1;
  }
  mat4 normalized;
  if (!normalizedQuadric(coefficients, normalized)) {
    setError(3);
    return -1;
  }
  ChartClip clip;
  clip.kind = GEO_CLIP_QUADRIC;
  clip.keepPositive = keepPositive ? 1 : 0;
  clip.quadric = normalized;
  clips_.push_back(clip);
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

} // namespace geo
