#pragma once

#include "GeometryCore/Chart.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace geo::chart_detail {

constexpr float PI = 3.14159265358979323846f;
constexpr float POINT_TOL = 2e-3f;
constexpr float CONTAIN_TOL = 2e-4f;
// Keep portal hits well separated from both the reverse trigger and the
// float32 self-hit tolerance. This also provides enough overlap for stable
// compound reductions near quotient-domain edges and vertices.
constexpr float PORTAL_COLLAR = 1e-2f;

inline bool finite(float x) { return std::isfinite(x); }
inline bool finite(const vec3 &v) {
  return finite(v.x) && finite(v.y) && finite(v.z);
}
inline bool finite(const vec4 &v) {
  return finite(v.x) && finite(v.y) && finite(v.z) && finite(v.w);
}
inline bool finite(const mat4 &m) {
  for (float value : m.m)
    if (!finite(value))
      return false;
  return true;
}
inline float lorDot(const vec4 &a, const vec4 &b) {
  return a.x * b.x + a.y * b.y + a.z * b.z - a.w * b.w;
}
inline float metricDot(const vec4 &a, const vec4 &b, int model) {
  return model == GEO_MODEL_H3 ? lorDot(a, b) : dot(a, b);
}

template <class T>
inline void append(std::vector<uint8_t> &out, const T &value) {
  auto p = reinterpret_cast<const uint8_t *>(&value);
  out.insert(out.end(), p, p + sizeof(T));
}

template <class T>
inline void appendMany(std::vector<uint8_t> &out, const std::vector<T> &v) {
  if (v.empty())
    return;
  auto p = reinterpret_cast<const uint8_t *>(v.data());
  out.insert(out.end(), p, p + sizeof(T) * v.size());
}

inline bool matrixClose(const mat4 &a, const mat4 &b, float e = 2e-3f) {
  for (int i = 0; i < 16; ++i)
    if (std::fabs(a.m[i] - b.m[i]) > e)
      return false;
  return true;
}

inline mat4 transpose(const mat4 &m) {
  mat4 out;
  for (int row = 0; row < 4; ++row)
    for (int column = 0; column < 4; ++column)
      out.m[column * 4 + row] = m.m[row * 4 + column];
  return out;
}

inline float matrixScale(const mat4 &m) {
  float largest = 0;
  for (float value : m.m)
    largest = std::max(largest, std::fabs(value));
  return largest;
}

inline mat4 normalizedMatrix(const mat4 &m) {
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

inline mat4 transformQuadric(const Isometry &m, const mat4 &quadric) {
  mat4 inverse = m.inverse().m;
  return normalizedMatrix(mat4Mul(mat4Mul(transpose(inverse), quadric), inverse));
}

inline vec4 transformPlane(const Isometry &m, const vec4 &normal,
                           float &offset, int model) {
  if (model != GEO_MODEL_R3)
    return m.applyTangent(normal);
  vec3 u = normal.xyz();
  vec3 up(m.m.m[0] * u.x + m.m.m[4] * u.y + m.m.m[8] * u.z,
          m.m.m[1] * u.x + m.m.m[5] * u.y + m.m.m[9] * u.z,
          m.m.m[2] * u.x + m.m.m[6] * u.y + m.m.m[10] * u.z);
  offset += dot(up, vec3(m.m.m[12], m.m.m[13], m.m.m[14]));
  return vec4(up, 0);
}

} // namespace geo::chart_detail
