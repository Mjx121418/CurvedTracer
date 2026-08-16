#include "GeometryCore/Mobius.h"
#include "GeometryCore/Disk.h"
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

vec3 Mobius::applyChartPoint(const vec3& b) const {
    if (kind == ModelKind::H3) {
        vec3 p = disk::toPoincare(b);
        vec4 x = H3::ballToModel(p);
        vec4 y = mat4Apply(m, x);
        vec3 p2 = H3::modelToBall(y);
        return disk::fromPoincare(p2);
    }
    vec4 X = disk::toAmbient(b);
    vec4 Y = mat4Apply(m, X);
    return disk::fromAmbient(Y);
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

namespace {

void makeOrthonormalBasis(const vec3& n, vec3& u, vec3& v) {
    vec3 helper = (mhAbs(n.x) < 0.9f) ? vec3(1, 0, 0) : vec3(0, 1, 0);
    u = normalize(cross(n, helper));
    v = cross(n, u);
}

// Four points on an H3 sphere, chosen strictly inside the unit ball.  This is
// needed for H3 mirror spheres: their Euclidean center lies outside the ball
// and axis-aligned samples such as c +/- e_i*r would leave the Poincare ball
// (where H3::ballToModel is undefined).  The inside portion is the spherical
// cap looking toward the origin; its angular half-width gives beta < 1/r.
void sampleH3SphereInside(const vec3& c, float r, vec3 src[4]) {
    float clen = length(c);
    if (clen < 1e-12f) {
        const vec3 e1(1, 0, 0), e2(0, 1, 0), e3(0, 0, 1);
        src[0] = c + e1 * r;
        src[1] = c - e1 * r;
        src[2] = c + e2 * r;
        src[3] = c + e3 * r;
        return;
    }
    vec3 n = c / clen;
    vec3 u, v;
    makeOrthonormalBasis(n, u, v);
    float beta = 0.75f / r;
    vec3 w0 = -n;
    vec3 w1 = normalize(-n + u * beta);
    vec3 w2 = normalize(-n + v * beta);
    vec3 w3 = normalize(-n - u * beta);   // opposite of w1: stays inside the cap
    src[0] = c + w0 * r;
    src[1] = c + w1 * r;
    src[2] = c + w2 * r;
    src[3] = c + w3 * r;
}

} // namespace

// Common sample-and-fit used by applySphere and applyPlane.  Four source points
// on the primitive are pushed through the Mobius map; the image is fitted with a
// Euclidean sphere, or a plane when one sample lands at infinity / points are
// coplanar.
void Mobius::fitTransformedPrimitive(const vec3 src[4],
                                     vec3& oc, float& orr, bool& op) const {
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
        // Coplanar (or nearly coplanar): image is a plane.
        if (planeFrom3(fin[0], fin[1], fin[2], oc, orr)) { op = true; return; }
    } else if (nfinite == 3) {
        // One sample landed at infinity: the primitive passed through the projection point.
        if (planeFrom3(fin[0], fin[1], fin[2], oc, orr)) { op = true; return; }
    }

    // Degenerate fallback: finite and harmless (avoids NaN crossing the seam).
    oc = vec3(0, 0, 0);
    orr = 0.0f;
    op = false;
}

void Mobius::applySphere(const vec3& c, float r, vec3& oc, float& orr, bool& op) const {
    vec3 src[4];
    if (kind == ModelKind::H3 && length(c) + r >= 1.0f) {
        // H3 mirror sphere (center outside the unit ball): sample the cap that
        // lies inside the Poincare ball, where the chart map is defined.
        sampleH3SphereInside(c, r, src);
    } else {
        const vec3 e1(1, 0, 0), e2(0, 1, 0), e3(0, 0, 1);
        src[0] = c + e1 * r;
        src[1] = c - e1 * r;
        src[2] = c + e2 * r;
        src[3] = c + e3 * r;
    }
    fitTransformedPrimitive(src, oc, orr, op);
}

void Mobius::applyPlane(const vec3& normal, float offset,
                        vec3& oc, float& orr, bool& op) const {
    // Build four points in the plane: p0 (closest to the origin) plus a small
    // asymmetric set.  H3 chart points must stay strictly inside the unit ball,
    // so the set is shrunk there (valid mirror planes pass through the origin).
    vec3 n = normalize(normal);
    vec3 u, v;
    makeOrthonormalBasis(n, u, v);
    // Four points in the plane, deliberately NOT concyclic: three on one line
    // plus one off it.  A Mobius map sends concyclic source points to coplanar
    // image points, which would make the sphere fit degenerate.
    // For H3 the points must stay strictly inside the unit ball; valid mirror
    // planes pass through the origin, so 0.45 / 0.9 is safely inside.
    float s = (kind == ModelKind::H3) ? 0.45f : 1.0f;
    vec3 p0 = n * offset;
    vec3 src[4] = { p0, p0 + u * s, p0 + v * s, p0 + u * (2.0f * s) };
    fitTransformedPrimitive(src, oc, orr, op);
}

void Mobius::applySurface(const vec3& a, float b, float c,
                          vec3& outA, float& outB, float& outC) const {
    if (kind == ModelKind::S3) {
        // Direct O(4) ambient transform:
        //     A·X = c,  Y = M X  =>  A' = M A,  c' = c.
        vec4 A(a.x, a.y, a.z, b);
        vec4 Ap = mat4Apply(m, A);
        outA = Ap.xyz();
        outB = Ap.w;
        outC = c;
        return;
    }

    // H3: disk surface -> Poincare sphere/plane -> old apply -> disk surface.
    float Acoef = b + c;
    vec3 Bcoef = a * -2.0f;
    float Ccoef = c - b;

    vec3 pc;
    float pr = 0.0f;
    bool pp = false;

    if (mhAbs(Acoef) < 1e-7f) {
        // Poincare plane: Bcoef·p + Ccoef = 0  =>  n·p = offset.
        float lenB = length(Bcoef);
        if (lenB < 1e-12f) {
            outA = a; outB = b; outC = c;
            return;
        }
        vec3 n = Bcoef / lenB;
        float off = -Ccoef / lenB;
        applyPlane(n, off, pc, pr, pp);
    } else {
        vec3 center = a * (1.0f / Acoef);
        float radiusSq = (lengthSq(a) + b * b - c * c) / (Acoef * Acoef);
        if (radiusSq < 0.0f) radiusSq = 0.0f;
        applySphere(center, mhSqrt(radiusSq), pc, pr, pp);
    }

    // Convert transformed Poincare sphere/plane back to disk coefficients.
    float A2;
    vec3 B2;
    float C2;
    if (pp) {
        A2 = 0.0f;
        B2 = pc * 2.0f;
        C2 = -2.0f * pr;
    } else {
        A2 = 1.0f;
        B2 = pc * -2.0f;
        C2 = lengthSq(pc) - pr * pr;
    }

    outA = B2 * -0.5f;
    outB = (A2 - C2) * 0.5f;
    outC = (A2 + C2) * 0.5f;
}

} // namespace geo
