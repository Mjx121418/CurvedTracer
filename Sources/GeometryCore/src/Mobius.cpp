#include "GeometryCore/Mobius.h"
#include "GeometryCore/Hyperboloid.h"
#include "GeometryCore/Sphere3.h"

#include <cmath>

namespace geo {

namespace {

// Gauss-Jordan 4x4 inverse. Returns identity on (near-)singular input.
mat4 mat4Inverse(const mat4& a) {
    float aug[4][8];
    for (int r = 0; r < 4; ++r) {
        for (int c = 0; c < 4; ++c) aug[r][c] = a.m[c * 4 + r];
        for (int c = 0; c < 4; ++c) aug[r][4 + c] = (r == c) ? 1.0f : 0.0f;
    }
    for (int col = 0; col < 4; ++col) {
        int piv = col;
        for (int r = col + 1; r < 4; ++r)
            if (mhAbs(aug[r][col]) > mhAbs(aug[piv][col])) piv = r;
        if (mhAbs(aug[piv][col]) < 1e-12f) return mat4Identity();
        if (piv != col)
            for (int c = 0; c < 8; ++c) {
                float t = aug[piv][c]; aug[piv][c] = aug[col][c]; aug[col][c] = t;
            }
        float d = aug[col][col];
        for (int c = 0; c < 8; ++c) aug[col][c] /= d;
        for (int r = 0; r < 4; ++r) {
            if (r == col) continue;
            float f = aug[r][col];
            if (f != 0.0f)
                for (int c = 0; c < 8; ++c) aug[r][c] -= f * aug[col][c];
        }
    }
    mat4 r;
    for (int rr = 0; rr < 4; ++rr)
        for (int cc = 0; cc < 4; ++cc) r.m[cc * 4 + rr] = aug[rr][4 + cc];
    return r;
}

// 3x3 linear solve (A row-major). Returns false if singular.
bool solve3x3(const float A[9], const float b[3], float x[3]) {
    float m[3][4];
    for (int r = 0; r < 3; ++r) {
        for (int c = 0; c < 3; ++c) m[r][c] = A[r * 3 + c];
        m[r][3] = b[r];
    }
    for (int col = 0; col < 3; ++col) {
        int piv = col;
        for (int r = col + 1; r < 3; ++r)
            if (std::fabs(m[r][col]) > std::fabs(m[piv][col])) piv = r;
        if (std::fabs(m[piv][col]) < 1e-12f) return false;
        if (piv != col)
            for (int c = 0; c < 4; ++c) { float t = m[piv][c]; m[piv][c] = m[col][c]; m[col][c] = t; }
        float d = m[col][col];
        for (int c = 0; c < 4; ++c) m[col][c] /= d;
        for (int r = 0; r < 3; ++r) {
            if (r == col) continue;
            float f = m[r][col];
            if (f != 0.0f)
                for (int c = 0; c < 4; ++c) m[r][c] -= f * m[col][c];
        }
    }
    x[0] = m[0][3]; x[1] = m[1][3]; x[2] = m[2][3];
    return true;
}

} // namespace

vec3 Mobius::apply(const vec3& b) const {
    if (kind == ModelKind::H3) {
        vec4 x = H3::ballToModel(b);
        vec4 y = mat4Apply(m, x);
        return H3::modelToBall(y);
    }
    vec4 x = S3::chartToModel(b);
    vec4 y = mat4Apply(m, x);
    return S3::modelToChart(y);
}

Mobius Mobius::compose(const Mobius& other) const {
    Mobius r;
    r.kind = kind;
    r.m = mat4Mul(m, other.m);
    return r;
}

Mobius Mobius::inverse() const {
    Mobius r;
    r.kind = kind;
    r.m = mat4Inverse(m);
    return r;
}

namespace {
// Plane through three points p0,p1,p2: normal + signed offset. Returns false if collinear.
bool planeFrom3(const vec3& p0, const vec3& p1, const vec3& p2, vec3& n, float& off) {
    vec3 nn = cross(p1 - p0, p2 - p0);
    float l = length(nn);
    if (l < 1e-9f) return false;
    nn = nn / l;
    n = nn; off = dot(nn, p0);
    return true;
}
} // namespace

void Mobius::applySphere(const vec3& c, float r, vec3& oc, float& orr, bool& op) const {
    const vec3 e1(1, 0, 0), e2(0, 1, 0), e3(0, 0, 1);
    vec3 src[4] = { c + e1 * r, c - e1 * r, c + e2 * r, c + e3 * r };

    vec3 fin[4];
    int nfinite = 0;
    for (int i = 0; i < 4; ++i) {
        vec3 p = apply(src[i]);
        if (std::isfinite(p.x) && std::isfinite(p.y) && std::isfinite(p.z)) {
            fin[nfinite++] = p;
        }
    }

    if (nfinite == 4) {
        // Try a circumsphere through the four image points.
        vec3 a = fin[1] - fin[0], b = fin[2] - fin[0], d = fin[3] - fin[0];
        float A[9] = { a.x, a.y, a.z, b.x, b.y, b.z, d.x, d.y, d.z };
        float y[3] = { 0.5f * dot(a, a), 0.5f * dot(b, b), 0.5f * dot(d, d) };
        float x[3];
        if (solve3x3(A, y, x)) {
            vec3 center = fin[0] + vec3(x[0], x[1], x[2]);
            float radius = length(center - fin[0]);
            if (radius < 1e6f) { oc = center; orr = radius; op = false; return; }
        }
        // Coplanar: image is a plane.
        if (planeFrom3(fin[0], fin[1], fin[2], oc, orr)) { op = true; return; }
    } else if (nfinite == 3) {
        // One sample landed at infinity: the sphere passed through the projection point.
        if (planeFrom3(fin[0], fin[1], fin[2], oc, orr)) { op = true; return; }
    }

    // Degenerate fallback.
    oc = vec3(0, 0, 0); orr = 0.0f; op = false;
}

} // namespace geo
