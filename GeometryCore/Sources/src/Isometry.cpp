#include "GeometryCore/Isometry.h"
#include <cmath>

namespace geo {
namespace {

float det4(const mat4& m) {
    double a[4][4];
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c)
            a[r][c] = m.m[c * 4 + r];
    double d = 1.0;
    for (int c = 0; c < 4; ++c) {
        int p = c;
        for (int r = c + 1; r < 4; ++r)
            if (std::fabs(a[r][c]) > std::fabs(a[p][c]))
                p = r;
        if (std::fabs(a[p][c]) < 1e-12)
            return 0.0f;
        if (p != c) {
            for (int k = 0; k < 4; ++k) {
                double t = a[p][k];
                a[p][k] = a[c][k];
                a[c][k] = t;
            }
            d = -d;
        }
        d *= a[c][c];
        for (int r = c + 1; r < 4; ++r) {
            double q = a[r][c] / a[c][c];
            for (int k = c + 1; k < 4; ++k)
                a[r][k] -= q * a[c][k];
        }
    }
    return float(d);
}

float metric(int i, ModelKind kind) { return kind == ModelKind::H3 && i == 3 ? -1.0f : 1.0f; }

bool finiteMatrix(const mat4& m) {
    for (float x : m.m)
        if (!std::isfinite(x))
            return false;
    return true;
}

} // namespace

vec4 Isometry::applyPoint(const vec4& point) const { return mat4Apply(m, point); }
vec4 Isometry::applyTangent(const vec4& tangent) const { return mat4Apply(m, tangent); }

Isometry Isometry::compose(const Isometry& other) const {
    Isometry out;
    out.kind = kind;
    out.m = kind == other.kind ? mat4Mul(m, other.m) : mat4Identity();
    return out;
}

Isometry Isometry::inverse() const {
    Isometry out;
    out.kind = kind;
    if (kind == ModelKind::R3) {
        out.m = mat4Identity();
        for (int r = 0; r < 3; ++r)
            for (int c = 0; c < 3; ++c)
                out.m.m[c * 4 + r] = m.m[r * 4 + c];
        vec3 t(m.m[12], m.m[13], m.m[14]);
        vec3 ti(-(out.m.m[0] * t.x + out.m.m[4] * t.y + out.m.m[8] * t.z),
                -(out.m.m[1] * t.x + out.m.m[5] * t.y + out.m.m[9] * t.z),
                -(out.m.m[2] * t.x + out.m.m[6] * t.y + out.m.m[10] * t.z));
        out.m.m[12] = ti.x;
        out.m.m[13] = ti.y;
        out.m.m[14] = ti.z;
        return out;
    }
    // M^-1 = G M^T G for both Euclidean SO(4) and Lorentz SO(3,1).
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c)
            out.m.m[c * 4 + r] = metric(r, kind) * m.m[r * 4 + c] * metric(c, kind);
    return out;
}

bool Isometry::validate(float tol) const {
    if (!finiteMatrix(m) || !std::isfinite(tol) || tol <= 0.0f)
        return false;
    if (kind != ModelKind::H3 && kind != ModelKind::S3 && kind != ModelKind::R3)
        return false;
    if (det4(m) <= 0.0f || std::fabs(det4(m) - 1.0f) > tol * 20.0f)
        return false;
    if (kind == ModelKind::R3) {
        if (std::fabs(m.m[3]) > tol || std::fabs(m.m[7]) > tol || std::fabs(m.m[11]) > tol ||
            std::fabs(m.m[15] - 1.0f) > tol)
            return false;
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j) {
                float s = 0;
                for (int k = 0; k < 3; ++k)
                    s += m.m[i * 4 + k] * m.m[j * 4 + k];
                if (std::fabs(s - (i == j ? 1.0f : 0.0f)) > tol * 4)
                    return false;
            }
        return true;
    }
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j) {
            float s = 0;
            for (int k = 0; k < 4; ++k)
                s += m.m[i * 4 + k] * metric(k, kind) * m.m[j * 4 + k];
            float want = i == j ? metric(i, kind) : 0.0f;
            if (std::fabs(s - want) > tol * 8)
                return false;
        }
    if (kind == ModelKind::H3 && applyPoint(vec4(0, 0, 0, 1)).w <= 0.0f)
        return false;
    return true;
}

} // namespace geo
