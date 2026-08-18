#pragma once
// Shared math. Compiled by BOTH host C++ and Metal shaders (MSL).
// Rules: no <std*> headers, no exceptions, no allocation, no recursion, float32 only.
// Everything lives in namespace geo.

#if defined(__METAL_VERSION__)
#include <metal_stdlib>
using namespace metal;
#else
#include <cmath>
#endif

namespace geo {

// ---- scalar wrappers: same name, MSL vs std implementation ----
#if defined(__METAL_VERSION__)
inline float mhSqrt(float x)                 { return sqrt(x); }
inline float mhCos(float x)                  { return cos(x); }
inline float mhSin(float x)                  { return sin(x); }
inline float mhCosh(float x)                 { return cosh(x); }
inline float mhSinh(float x)                 { return sinh(x); }
inline float mhTanh(float x)                 { return tanh(x); }
inline float mhAcos(float x)                 { return acos(x); }
inline float mhAcosh(float x)                { return acosh(x); }
inline float mhAtan2(float y, float x)       { return atan2(y, x); }
inline float mhLog(float x)                  { return log(x); }
inline float mhAtanh(float x)                { return 0.5f * log((1.0f + x) / (1.0f - x)); }
inline float mhExp(float x)                  { return exp(x); }
inline float mhAbs(float x)                  { return abs(x); }
inline float mhMin(float a, float b)         { return min(a, b); }
inline float mhMax(float a, float b)         { return max(a, b); }
#else
inline float mhSqrt(float x)                 { return std::sqrt(x); }
inline float mhCos(float x)                  { return std::cos(x); }
inline float mhSin(float x)                  { return std::sin(x); }
inline float mhCosh(float x)                 { return std::cosh(x); }
inline float mhSinh(float x)                 { return std::sinh(x); }
inline float mhTanh(float x)                 { return std::tanh(x); }
inline float mhAcos(float x)                 { return std::acos(x); }
inline float mhAcosh(float x)                { return std::acosh(x); }
inline float mhAtan2(float y, float x)       { return std::atan2(y, x); }
inline float mhLog(float x)                  { return std::log(x); }
inline float mhAtanh(float x)                { return 0.5f * std::log((1.0f + x) / (1.0f - x)); }
inline float mhExp(float x)                  { return std::exp(x); }
inline float mhAbs(float x)                  { return std::fabs(x); }
inline float mhMin(float a, float b)         { return std::fmin(a, b); }
inline float mhMax(float a, float b)         { return std::fmax(a, b); }
#endif

inline float mhClamp(float x, float lo, float hi) { return mhMin(mhMax(x, lo), hi); }

// ---- vectors ----
struct vec3 {
    float x, y, z;
    vec3() : x(0.0f), y(0.0f), z(0.0f) {}
    vec3(float x_, float y_, float z_) : x(x_), y(y_), z(z_) {}
};

struct vec4 {
    float x, y, z, w;
    vec4() : x(0.0f), y(0.0f), z(0.0f), w(0.0f) {}
    vec4(float x_, float y_, float z_, float w_) : x(x_), y(y_), z(z_), w(w_) {}
    vec4(vec3 v, float w_) : x(v.x), y(v.y), z(v.z), w(w_) {}
    vec3 xyz() const { return vec3(x, y, z); }
};

// vec3 ops
inline vec3 operator+(const vec3& a, const vec3& b) { return vec3(a.x + b.x, a.y + b.y, a.z + b.z); }
inline vec3 operator-(const vec3& a, const vec3& b) { return vec3(a.x - b.x, a.y - b.y, a.z - b.z); }
inline vec3 operator-(const vec3& a)                { return vec3(-a.x, -a.y, -a.z); }
inline vec3 operator*(const vec3& a, float s)       { return vec3(a.x * s, a.y * s, a.z * s); }
inline vec3 operator*(float s, const vec3& a)       { return a * s; }
inline vec3 operator/(const vec3& a, float s)       { return vec3(a.x / s, a.y / s, a.z / s); }
inline float dot(const vec3& a, const vec3& b)      { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline vec3 cross(const vec3& a, const vec3& b) {
    return vec3(a.y * b.z - a.z * b.y,
                a.z * b.x - a.x * b.z,
                a.x * b.y - a.y * b.x);
}
inline float lengthSq(const vec3& a) { return dot(a, a); }
inline float length(const vec3& a)   { return mhSqrt(lengthSq(a)); }
inline vec3 normalize(const vec3& a) {
    float l = length(a);
    return (l > 1e-20f) ? (a / l) : vec3(0.0f, 0.0f, 0.0f);
}
inline vec3 lerp(const vec3& a, const vec3& b, float t) { return a + (b - a) * t; }

// vec4 ops (Euclidean R4)
inline vec4 operator+(const vec4& a, const vec4& b) { return vec4(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w); }
inline vec4 operator-(const vec4& a, const vec4& b) { return vec4(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w); }
inline vec4 operator-(const vec4& a)                { return vec4(-a.x, -a.y, -a.z, -a.w); }
inline vec4 operator*(const vec4& a, float s)       { return vec4(a.x * s, a.y * s, a.z * s, a.w * s); }
inline vec4 operator*(float s, const vec4& a)       { return a * s; }
inline vec4 operator/(const vec4& a, float s)       { return vec4(a.x / s, a.y / s, a.z / s, a.w / s); }
inline float dot(const vec4& a, const vec4& b)      { return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w; }
inline float lengthSq(const vec4& a) { return dot(a, a); }
inline float length(const vec4& a)   { return mhSqrt(lengthSq(a)); }
inline vec4 normalize(const vec4& a) {
    float l = length(a);
    return (l > 1e-20f) ? (a / l) : vec4(0.0f, 0.0f, 0.0f, 0.0f);
}

// ---- 4x4 matrix, column-major (m[col*4 + row]) ----
// MSL-safe subset only: identity, multiply, apply. (Inverse is host-only, in Mobius.cpp.)
struct mat4 {
    float m[16];
    mat4() { for (int i = 0; i < 16; ++i) m[i] = 0.0f; }
};

inline mat4 mat4Identity() {
    mat4 r;
    r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1.0f;
    return r;
}

inline mat4 mat4Mul(const mat4& a, const mat4& b) {
    mat4 r;
    for (int c = 0; c < 4; ++c)
        for (int row = 0; row < 4; ++row) {
            float s = 0.0f;
            for (int k = 0; k < 4; ++k) s += a.m[k * 4 + row] * b.m[c * 4 + k];
            r.m[c * 4 + row] = s;
        }
    return r;
}

inline vec4 mat4Apply(const mat4& a, const vec4& v) {
    return vec4(a.m[0] * v.x + a.m[4] * v.y + a.m[8] * v.z + a.m[12] * v.w,
                a.m[1] * v.x + a.m[5] * v.y + a.m[9] * v.z + a.m[13] * v.w,
                a.m[2] * v.x + a.m[6] * v.y + a.m[10] * v.z + a.m[14] * v.w,
                a.m[3] * v.x + a.m[7] * v.y + a.m[11] * v.z + a.m[15] * v.w);
}

} // namespace geo
