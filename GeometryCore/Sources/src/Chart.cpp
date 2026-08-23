#include "GeometryCore/Chart.h"
#include "GeometryCore/Disk.h"
#include "GeometryCore/Hyperboloid.h"
#include "GeometryCore/Sphere3.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace geo {

namespace {

constexpr float kObjectEps = 1e-3f;
constexpr float kPlaneOffsetEps = 1e-4f;
constexpr float kCameraRadius = 1.5707963267948966f;  // π/2
constexpr float kCameraInsideFactor = 0.98f;          // chart contains a point iff |x| < sin(r)·this

bool finiteVec(const vec3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

bool finiteFloat(float x) { return std::isfinite(x); }

float determinant4(const mat4& m) {
    double a[4][4];
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) a[r][c] = m.m[c * 4 + r];
    double det = 1.0;
    for (int c = 0; c < 4; ++c) {
        int p = c;
        for (int r = c + 1; r < 4; ++r)
            if (std::fabs(a[r][c]) > std::fabs(a[p][c])) p = r;
        if (std::fabs(a[p][c]) < 1e-10) return 0.0f;
        if (p != c) { for (int k = c; k < 4; ++k) std::swap(a[p][k], a[c][k]); det = -det; }
        det *= a[c][c];
        for (int r = c + 1; r < 4; ++r) {
            double f = a[r][c] / a[c][c];
            for (int k = c + 1; k < 4; ++k) a[r][k] -= f * a[c][k];
        }
    }
    return static_cast<float>(det);
}

// Ambient transvection sending P to (0,0,0,1).
// kappa = +1 for S3 O(4); kappa = -1 for H3 Lorentz in the hyperboloid model.
mat4 movePointToOrigin(const vec4& P, float kappa) {
    vec3 u = P.xyz();
    float w = P.w;
    float denominator = mhMax(1.0f + w, 1e-6f);
    float scale = -kappa / denominator;

    vec3 c0 = vec3(1, 0, 0) + u * (scale * u.x);
    vec3 c1 = vec3(0, 1, 0) + u * (scale * u.y);
    vec3 c2 = vec3(0, 0, 1) + u * (scale * u.z);

    mat4 B;
    B.m[0] = c0.x; B.m[1] = c0.y; B.m[2] = c0.z; B.m[3] = kappa * u.x;
    B.m[4] = c1.x; B.m[5] = c1.y; B.m[6] = c1.z; B.m[7] = kappa * u.y;
    B.m[8] = c2.x; B.m[9] = c2.y; B.m[10] = c2.z; B.m[11] = kappa * u.z;
    B.m[12] = -u.x; B.m[13] = -u.y; B.m[14] = -u.z; B.m[15] = w;
    return B;
}

// Does the hyperplane section a·x + b·w = c intersect the camera chart disk?
//
// In disk-chart coordinates the camera chart is the spherical cap
//     X = (x, w),  |X| = 1,  w >= cos(radius)
// for both models (H³ has the additional w > 0, but radius <= π/2 makes
// cos(radius) >= 0 anyway). The object surface is n·X = c with n = (a,b).
// The maximum/minimum of n·X over this cap is either the unconstrained
// sphere extremum ±|n| (when that point lies in the cap) or the boundary
// value b·cos(radius) ± |a|·sin(radius). If c lies outside that interval the
// surface has no point inside the camera chart and can be culled.
bool surfaceIntersectsChartDisk(const vec3& a, float b, float c,
                                float cosR, float sinR) {
    float n2 = lengthSq(a) + b * b;
    if (n2 < 1e-12f) return true;   // degenerate normal: keep conservatively
    float nLen = mhSqrt(n2);
    float aLen = length(a);

    float maxVal;
    if (b / nLen >= cosR) {
        maxVal = nLen;              // unconstrained max n/nLen is inside the cap
    } else {
        maxVal = b * cosR + aLen * sinR;   // max on the cap boundary
    }

    float minVal;
    if (-b / nLen >= cosR) {
        minVal = -nLen;             // unconstrained min -n/nLen is inside the cap
    } else {
        minVal = b * cosR - aLen * sinR;   // min on the cap boundary
    }

    const float eps = 1e-4f;
    return c >= minVal - eps && c <= maxVal + eps;
}

} // namespace

Atlas::Atlas() { resetToDefaults(); }

void Atlas::resetToDefaults() {
    modelKind_ = GEO_MODEL_H3;
    charts_.clear();
    objects_.clear();
    lights_.clear();
    portals_.clear();
    materials_.clear();
    cameraRight_ = vec3(1, 0, 0);
    cameraUp_ = vec3(0, 1, 0);
    cameraFwd_ = vec3(0, 0, 1);
    fovTan_ = 1.0f;
    aspect_ = 1.0f;
    maxBounces_ = 4;
    falloffK_ = 0.0f;
    ambient_ = 0.0f;
    bounceAttenuation_ = 1.0f;
    fogMode_ = 0.0f;
    fogStartFraction_ = 0.0f;
    fogDensity_ = 0.0f;
    packet_.clear();
    lastError_ = 0;
    capacityExceeded_ = false;
    cameraChartId_ = -1;
    cameraChartFrom_ = 0;
    cameraPosition_ = vec3(0, 0, 0);
    cameraPositionW_ = 1.0f;
    cameraChartTransition_ = Mobius();
}

void Atlas::begin(int modelKind) {
    resetToDefaults();
    if (modelKind == GEO_MODEL_H3 || modelKind == GEO_MODEL_S3) {
        modelKind_ = modelKind;
        lastError_ = 0;
    } else {
        modelKind_ = -1;   // invalid marker; build/seed/add will report code 6
        lastError_ = 6;
    }
}

bool Atlas::validChartRadius(float r) const {
    if (!std::isfinite(r)) return false;
    if (modelKind_ == GEO_MODEL_H3) {
        return r > 0.0f && r <= 1.5707963267948966f + 1e-4f;  // π/2 + eps
    }
    return r > 0.0f && r < 3.141592653589793f - 1e-4f;          // π - eps
}

int Atlas::seed(float radius) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!charts_.empty()) { setError(5); return -1; }   // anchorless seed is unique
    if (!validChartRadius(radius)) { setError(3); return -1; }
    Chart c;
    c.id = 0;
    c.radius = radius;
    charts_.push_back(c);
    setError(0);
    return 0;
}

Mobius Atlas::identityMobius() const {
    Mobius m;
    m.kind = (modelKind_ == GEO_MODEL_S3) ? ModelKind::S3 : ModelKind::H3;
    m.m = mat4Identity();
    return m;
}

Mobius Atlas::mobiusFromMatrix(const float m[16]) const {
    Mobius r;
    r.kind = (modelKind_ == GEO_MODEL_S3) ? ModelKind::S3 : ModelKind::H3;
    for (int i = 0; i < 16; ++i) r.m.m[i] = m[i];
    return r;
}

void Atlas::upsertEdge(int a, int b, const Mobius& m_ab, bool safe) {
    for (auto& e : charts_[a].edges) {
        if (e.neighborId == b) {
            e.toNeighbor = m_ab;
            e.safe = safe;
            return;
        }
    }
    ChartEdge e;
    e.neighborId = b;
    e.toNeighbor = m_ab;
    e.safe = safe;
    charts_[a].edges.push_back(e);
}

int Atlas::addChart(float radius, int fromChart, const float m[16], bool safe) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!validChartId(fromChart)) { setError(4); return -1; }
    if (!validChartRadius(radius)) { setError(3); return -1; }
    if (!m) { setError(3); return -1; }
    for (int i = 0; i < 16; ++i) {
        if (!std::isfinite(m[i])) { setError(3); return -1; }
    }

    Mobius mFrom = mobiusFromMatrix(m);
    Mobius mBack = mFrom.inverse();

    Chart c;
    c.id = static_cast<int>(charts_.size());
    c.radius = radius;
    charts_.push_back(c);
    int newId = c.id;

    upsertEdge(fromChart, newId, mFrom, safe);
    upsertEdge(newId, fromChart, mBack, safe);
    setError(0);
    return newId;
}

void Atlas::linkCharts(int a, int b, const float m_ab[16], bool safe) {
    clearPacket();
    if (!validModelKind()) { setError(6); return; }
    if (!validChartId(a) || !validChartId(b)) { setError(4); return; }
    if (a == b) { setError(3); return; }
    if (!m_ab) { setError(3); return; }
    for (int i = 0; i < 16; ++i) {
        if (!std::isfinite(m_ab[i])) { setError(3); return; }
    }

    Mobius m = mobiusFromMatrix(m_ab);
    upsertEdge(a, b, m, safe);
    upsertEdge(b, a, m.inverse(), safe);
    setError(0);
}

bool Atlas::validPortalIsometry(const Mobius& m) const {
    float det = determinant4(m.m);
    if (!finiteFloat(det) || mhAbs(det - 1.0f) > 5e-3f) return false;
    const float tol = 2e-3f;
    for (int c = 0; c < 4; ++c) for (int d = 0; d < 4; ++d) {
        float v = 0.0f;
        for (int r = 0; r < 4; ++r) {
            float sign = (modelKind_ == GEO_MODEL_H3 && r == 3) ? -1.0f : 1.0f;
            v += sign * m.m.m[c * 4 + r] * m.m.m[d * 4 + r];
        }
        float want = c == d ? ((modelKind_ == GEO_MODEL_H3 && c == 3) ? -1.0f : 1.0f) : 0.0f;
        if (mhAbs(v - want) > tol) return false;
    }
    return modelKind_ != GEO_MODEL_H3 || mat4Apply(m.m, vec4(0,0,0,1)).w > 0.0f;
}

int Atlas::addPortalPair(int chartA, const vec3& aA, float bA, float cA, int interiorSignA,
                         int chartB, const vec3& aB, float bB, float cB, int interiorSignB,
                         const float m_ab[16]) {
    clearPacket();
    if (!validChartId(chartA) || !validChartId(chartB) || !m_ab ||
        !finiteVec(aA) || !finiteVec(aB) || !finiteFloat(bA) || !finiteFloat(cA) ||
        !finiteFloat(bB) || !finiteFloat(cB) ||
        (interiorSignA != -1 && interiorSignA != 1) ||
        (interiorSignB != -1 && interiorSignB != 1)) {
        setError(7); return -1;
    }
    if (static_cast<int>(portals_.size()) + 2 > GEO_MAX_PORTALS) {
        setError(8); return -1;
    }
    Mobius ab = mobiusFromMatrix(m_ab);
    if (!validPortalIsometry(ab)) { setError(7); return -1; }
    if (chartA == chartB && mobiusClose(ab, identityMobius(), 1e-5f)) {
        setError(7); return -1;
    }
    if (lengthSq(aA) + bA*bA < 1e-10f || lengthSq(aB) + bB*bB < 1e-10f) {
        setError(7); return -1;
    }
    for (const auto& existing : portals_) {
        if (existing.chartId == chartA && existing.neighborId == chartB &&
            length(existing.a - aA) < 1e-5f && mhAbs(existing.b - bA) < 1e-5f &&
            mhAbs(existing.c - cA) < 1e-5f && existing.interiorSign == interiorSignA &&
            mobiusClose(existing.toNeighbor, ab, 1e-5f)) {
            setError(7); return -1;
        }
    }
    int first = static_cast<int>(portals_.size());
    ChartPortal p, q;
    p.chartId=chartA; p.neighborId=chartB; p.a=aA; p.b=bA; p.c=cA;
    p.interiorSign=interiorSignA; p.reversePortal=first+1; p.toNeighbor=ab;
    q.chartId=chartB; q.neighborId=chartA; q.a=aB; q.b=bB; q.c=cB;
    q.interiorSign=interiorSignB; q.reversePortal=first; q.toNeighbor=ab.inverse();
    portals_.push_back(p); portals_.push_back(q);
    setError(0);
    return first;
}

int Atlas::addObject(int chartId, int kind, const vec3& a, float b, float c, int colorIdx) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (static_cast<int>(objects_.size()) >= GEO_MAX_OBJECTS) { capacityExceeded_ = true; setError(5); return -1; }

    // Store objects even if they are invalid; Atlas::build is the single
    // validation point and must return the CONTRACT error code.
    ChartObject o;
    o.chartId = chartId;
    o.kind = kind;
    o.a = a;
    o.b = b;
    o.c = c;
    o.colorIdx = colorIdx;
    int objId = static_cast<int>(objects_.size());
    objects_.push_back(o);
    if (validChartId(chartId)) {
        charts_[chartId].objectIds.push_back(objId);
    }
    setError(0);
    return objId;
}

int Atlas::addMaterial(const vec4& color, const vec4& specular) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!finiteVec(vec3(color.x, color.y, color.z)) || !finiteFloat(color.w) ||
        !finiteVec(vec3(specular.x, specular.y, specular.z)) || !finiteFloat(specular.w)) { setError(3); return -1; }
    if (static_cast<int>(materials_.size()) >= GEO_MAX_MATERIALS) { capacityExceeded_ = true; setError(5); return -1; }
    Material mat;
    mat.color = color;
    mat.specular = specular;
    int idx = static_cast<int>(materials_.size());
    materials_.push_back(mat);
    setError(0);
    return idx;
}

int Atlas::addLight(int chartId, const vec3& position, const vec3& color, float intensity) {
    // Derive the augmented w coordinate of the disk chart. For S³ it is signed
    // (callers that need w < 0 use the 5-argument overload); for H³ it is
    // always +sqrt(1-|x|²).
    float positionW = mhSqrt(mhMax(0.0f, 1.0f - lengthSq(position)));
    return addLight(chartId, position, positionW, color, intensity);
}

int Atlas::addLight(int chartId, const vec3& position, float positionW,
                    const vec3& color, float intensity) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (static_cast<int>(lights_.size()) >= GEO_MAX_LIGHTS) { capacityExceeded_ = true; setError(5); return -1; }

    // Store lights even if they are invalid; Atlas::build is the single
    // validation point and must return the CONTRACT error code.
    ChartLight light;
    light.chartId = chartId;
    light.position = position;
    light.positionW = positionW;
    light.color = color;
    light.intensity = intensity;
    int lightId = static_cast<int>(lights_.size());
    lights_.push_back(light);
    if (validChartId(chartId)) {
        charts_[chartId].lightIds.push_back(lightId);
    }
    setError(0);
    return lightId;
}

void Atlas::setCamera(float fovTan, float aspect, const vec3& right, const vec3& up, const vec3& fwd) {
    clearPacket();
    if (!finiteFloat(fovTan) || !finiteFloat(aspect) ||
        !finiteVec(right) || !finiteVec(up) || !finiteVec(fwd)) {
        setError(3);
        return;
    }
    cameraRight_ = right;
    cameraUp_ = up;
    cameraFwd_ = fwd;
    fovTan_ = fovTan;
    aspect_ = aspect;
    setError(0);
}

void Atlas::setControls(int maxBounces, float falloffK, float ambient, float bounceAttenuation) {
    setControls(maxBounces, falloffK, ambient, bounceAttenuation, 0.0f, 0.0f, 0.0f);
}

void Atlas::setControls(int maxBounces, float falloffK, float ambient, float bounceAttenuation,
                        float fogMode, float fogStartFraction, float fogDensity) {
    clearPacket();
    if (maxBounces < 0 || !finiteFloat(falloffK) || !finiteFloat(ambient) ||
        !finiteFloat(bounceAttenuation) || !finiteFloat(fogMode) ||
        !finiteFloat(fogStartFraction) || !finiteFloat(fogDensity)) {
        setError(3);
        return;
    }
    maxBounces_ = maxBounces;
    falloffK_ = falloffK;
    ambient_ = ambient;
    bounceAttenuation_ = bounceAttenuation;
    fogMode_ = fogMode;
    fogStartFraction_ = fogStartFraction;
    fogDensity_ = fogDensity;
    setError(0);
}

void Atlas::cameraRotate(const vec3& axis, float deltaRadians) {
    clearPacket();
    if (!finiteVec(axis) || !finiteFloat(deltaRadians)) {
        setError(3);
        return;
    }
    float axisLenSq = lengthSq(axis);
    if (axisLenSq < 1e-12f) {
        setError(3);
        return;
    }

    vec3 n = axis * mhSqrt(1.0f / axisLenSq);
    float c = mhCos(deltaRadians);
    float s = mhSin(deltaRadians);
    float oneMinusC = 1.0f - c;

    auto rotateVector = [&](const vec3& v) {
        return v * c
             + cross(n, v) * s
             + n * (dot(n, v) * oneMinusC);
    };

    cameraRight_ = normalize(rotateVector(cameraRight_));
    cameraUp_ = normalize(rotateVector(cameraUp_));
    cameraFwd_ = normalize(rotateVector(cameraFwd_));
    setError(0);
}

void Atlas::cameraRoll(float deltaRadians) {
    cameraRotate(cameraFwd_, deltaRadians);
}

int Atlas::validateObjectBasics(const ChartObject& o, int materialCount) const {
    if (!validChartId(o.chartId)) return 3;
    if (o.kind < GEO_OBJECT_OPAQUE || o.kind > GEO_OBJECT_MIRROR) return 3;
    if (!finiteVec(o.a) || !finiteFloat(o.b) || !finiteFloat(o.c)) return 3;
    if (o.colorIdx < 0 || o.colorIdx >= materialCount) return 3;
    return 0;
}

int Atlas::validateObjectModel(const ChartObject& o) const {
    float radius = charts_[o.chartId].radius;

    if (o.kind == GEO_OBJECT_MIRROR) {
        if (modelKind_ == GEO_MODEL_H3) {
            // H3 mirror: hyperbolic hyperplane orthogonal to the ideal equator.
            if (mhAbs(o.b) > kObjectEps) return 3;
            if (mhAbs(length(o.a) - 1.0f) > kObjectEps) return 3;
            if (mhAbs(o.c) >= mhSin(radius) - 1e-4f) return 3;
        } else {
            // S3 mirror: great sphere.
            if (mhAbs(o.c) > kObjectEps) return 3;
            if (mhAbs(mhSqrt(lengthSq(o.a) + o.b * o.b) - 1.0f) > kObjectEps) return 3;
        }
        return 0;
    }

    // OPAQUE: a small sphere inside the chart disk. The common v4 OPAQUE is
    // a geodesic ball around the origin: a=0, b=1, c=w0.
    if (o.c <= mhCos(radius) + 1e-4f) return 3;   // boundary must be inside the disk
    if (o.c >= 1.0f - 1e-4f) return 3;            // boundary must have positive radius
    return 0;
}

int Atlas::validateLight(const ChartLight& light) const {
    if (!validChartId(light.chartId)) return 3;
    if (!finiteVec(light.position) || !finiteFloat(light.positionW) ||
        !finiteVec(light.color) || !finiteFloat(light.intensity)) return 3;
    if (light.intensity < 0.0f) return 3;
    float radius = charts_[light.chartId].radius;

    // Unified augmented disk-chart coordinate: (x,w) with |x|² + w² = 1.
    // The chart contains the point iff w > cos(r), for both H³ and S³.
    float ambientNorm2 = lengthSq(light.position) + light.positionW * light.positionW;
    if (mhAbs(ambientNorm2 - 1.0f) > 1e-3f) return 3;
    if (light.positionW <= mhCos(radius) + 1e-4f) return 3;
    return 0;
}

std::vector<Atlas::UEdge> Atlas::buildUndirectedEdges() const {
    std::vector<UEdge> uedges;
    int n = static_cast<int>(charts_.size());
    for (int i = 0; i < n; ++i) {
        for (const auto& e : charts_[i].edges) {
            int j = e.neighborId;
            if (j < 0 || j >= n) continue;      // invalid edges are caught in build
            if (i < j) {
                UEdge u;
                u.a = i; u.b = j; u.ab = e.toNeighbor;
                uedges.push_back(u);
            } else if (i > j) {
                // Only add if the smaller-index side did not already add it.
                bool found = false;
                for (const auto& u : uedges) {
                    if (u.a == j && u.b == i) { found = true; break; }
                }
                if (!found) {
                    UEdge u;
                    u.a = j; u.b = i; u.ab = e.toNeighbor.inverse();
                    uedges.push_back(u);
                }
            }
        }
    }
    return uedges;
}

bool Atlas::chartTransition(int from, int to, Mobius& out) const {
    if (!validChartId(from) || !validChartId(to)) return false;
    if (from == to) {
        out = identityMobius();
        return true;
    }

    const int n = static_cast<int>(charts_.size());
    std::vector<UEdge> uedges = buildUndirectedEdges();

    std::vector<int> depth(n, -1);
    std::vector<Mobius> path(n);
    std::vector<int> queue;
    queue.reserve(n);

    depth[from] = 0;
    path[from] = identityMobius();
    queue.push_back(from);

    for (size_t qi = 0; qi < queue.size(); ++qi) {
        int u = queue[qi];
        for (const auto& ue : uedges) {
            int v = -1;
            if (ue.a == u) v = ue.b;
            else if (ue.b == u) v = ue.a;
            if (v < 0 || depth[v] != -1) continue;

            Mobius t_uv = edgeTransition(u, v, ue);
            path[v] = t_uv.compose(path[u]);
            depth[v] = depth[u] + 1;
            if (v == to) {
                out = path[v];
                return true;
            }
            queue.push_back(v);
        }
    }
    return false;
}

Mobius Atlas::edgeTransition(int from, int to, const UEdge& e) {
    if (from == e.a && to == e.b) return e.ab;
    return e.ab.inverse();
}

bool Atlas::mobiusClose(const Mobius& a, const Mobius& b, float tol) const {
    if (a.kind != b.kind) return false;
    Mobius diff = a.compose(b.inverse());   // identity iff a == b

    mat4 I = mat4Identity();
    for (int i = 0; i < 16; ++i) {
        if (mhAbs(diff.m.m[i] - I.m[i]) > tol) return false;
    }

    // Sample a few finite chart points.  Matrix closeness is necessary, but a
    // sample check catches the S3 projection-point / NaN edge cases.
    const vec3 samples[] = {
        vec3(0.0f, 0.0f, 0.0f),
        vec3(0.2f, 0.0f, 0.0f),
        vec3(0.0f, 0.3f, 0.0f),
        vec3(0.0f, 0.0f, 0.1f),
        vec3(-0.1f, 0.2f, 0.05f),
    };
    for (const auto& s : samples) {
        vec3 p = diff.applyChartPoint(s);
        if (!finiteVec(p)) return false;
        if (length(p - s) > tol) return false;
    }
    return true;
}

CameraPlacement Atlas::resolveCameraPlacement(int startChart, const vec3& startLocal, const vec3& movement) const {
    // Thin compatibility wrapper over the unified augmented-coordinate resolver.
    vec3 candidate = startLocal + movement;
    float positionW = mhSqrt(mhMax(0.0f, 1.0f - lengthSq(candidate)));
    return resolveCameraPlacementAugmented(startChart, vec4(candidate, positionW));
}

CameraPlacement Atlas::resolveCameraPlacementAugmented(int startChart, const vec4& candidateAugmented) const {
    CameraPlacement placement;
    placement.chartId = startChart;
    placement.localPosition = candidateAugmented.xyz();
    placement.localPositionW = candidateAugmented.w;

    if (!validModelKind() || !validChartId(startChart)) {
        return placement;
    }
    if (!finiteVec(candidateAugmented.xyz()) || !finiteFloat(candidateAugmented.w)) {
        placement.localPosition = vec3(0, 0, 0);
        placement.localPositionW = 1.0f;
        return placement;
    }

    const int n = static_cast<int>(charts_.size());
    std::vector<UEdge> uedges = buildUndirectedEdges();

    // BFS from startChart, computing T_{start -> x} for every chart.
    std::vector<int> depth(n, -1);
    std::vector<Mobius> path(n);
    std::vector<int> queue;
    queue.reserve(n);
    depth[startChart] = 0;
    path[startChart] = identityMobius();
    queue.push_back(startChart);

    for (size_t qi = 0; qi < queue.size(); ++qi) {
        int u = queue[qi];
        for (const auto& ue : uedges) {
            int v = -1;
            if (ue.a == u) v = ue.b;
            else if (ue.b == u) v = ue.a;
            if (v < 0 || depth[v] != -1) continue;

            Mobius t_uv = edgeTransition(u, v, ue);
            path[v] = t_uv.compose(path[u]);
            depth[v] = depth[u] + 1;
            queue.push_back(v);
        }
    }

    int bestInsideChart = -1;
    vec3 bestLocal;
    float bestW = -2.0f;

    for (int x = 0; x < n; ++x) {
        if (depth[x] < 0) continue;
        if (x == cameraChartId_) continue;   // the special camera chart is not a re-parenting target

        vec4 local = path[x].applyChartPointAugmented(candidateAugmented);
        if (!finiteVec(local.xyz()) || !finiteFloat(local.w)) continue;

        // Unified disk-chart containment: w > cos(radius) for both H³ and S³.
        float radius = charts_[x].radius;
        if (local.w > mhCos(radius) + 1e-4f) {
            if (bestInsideChart < 0 || local.w > bestW) {
                bestInsideChart = x;
                bestLocal = local.xyz();
                bestW = local.w;
            }
        }
    }

    if (bestInsideChart >= 0) {
        placement.chartId = bestInsideChart;
        placement.localPosition = bestLocal;
        placement.localPositionW = bestW;
    } else {
        // Clamp back to the original chart's geodesic boundary, along the same
        // radial direction from the original chart's origin.
        placement.chartId = startChart;
        float radius = charts_[startChart].radius;
        float sinR = mhSin(radius);
        float cosR = mhCos(radius);
        vec3 dir = candidateAugmented.xyz();
        float norm = length(dir);
        if (norm > 1e-6f) {
            dir = dir / norm;
            placement.localPosition = dir * sinR;
            placement.localPositionW = cosR;
        } else {
            // Degenerate: keep the original origin.
            placement.localPosition = vec3(0, 0, 0);
            placement.localPositionW = 1.0f;
        }
    }

    return placement;
}

int Atlas::cameraChartAt(int fromChart, const vec3& positionInFromChart, float radius) {
    float positionW = mhSqrt(mhMax(0.0f, 1.0f - lengthSq(positionInFromChart)));
    return cameraChartAt(fromChart, positionInFromChart, positionW, radius);
}

int Atlas::cameraChartAt(int fromChart, const vec3& positionInFromChart, float positionW,
                         float radius) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!validChartId(fromChart)) { setError(4); return -1; }
    if (!validChartRadius(radius)) { setError(3); return -1; }
    if (!finiteVec(positionInFromChart) || !finiteFloat(positionW)) { setError(3); return -1; }

    Mobius T;
    T.kind = (modelKind_ == GEO_MODEL_S3) ? ModelKind::S3 : ModelKind::H3;

    if (modelKind_ == GEO_MODEL_S3) {
        // Augmented orthographic chart coordinate: the anchor position is the
        // ambient unit vector (x, w) in the source chart.
        vec4 P(positionInFromChart, positionW);
        T.m = movePointToOrigin(P, 1.0f);
    } else {
        vec3 poincare = disk::toPoincare(positionInFromChart);
        vec4 P = H3::ballToModel(poincare);
        T.m = movePointToOrigin(P, -1.0f);
    }

    // Reuse a single special camera chart so the chart list does not grow per
    // frame. Remove the previous camera-chart links, then re-link at the new
    // anchor.
    if (cameraChartId_ >= 0 && validChartId(cameraChartId_) && validChartId(cameraChartFrom_)) {
        charts_[cameraChartFrom_].edges.erase(
            std::remove_if(charts_[cameraChartFrom_].edges.begin(),
                           charts_[cameraChartFrom_].edges.end(),
                           [&](const ChartEdge& e) { return e.neighborId == cameraChartId_; }),
            charts_[cameraChartFrom_].edges.end());
        charts_[cameraChartId_].edges.erase(
            std::remove_if(charts_[cameraChartId_].edges.begin(),
                           charts_[cameraChartId_].edges.end(),
                           [&](const ChartEdge& e) { return e.neighborId == cameraChartFrom_; }),
            charts_[cameraChartId_].edges.end());
    }

    if (cameraChartId_ < 0) {
        Chart c;
        c.id = static_cast<int>(charts_.size());
        c.radius = radius;
        charts_.push_back(c);
        cameraChartId_ = c.id;
    } else {
        charts_[cameraChartId_].radius = radius;
    }

    cameraChartFrom_ = fromChart;
    cameraChartTransition_ = T;
    cameraPosition_ = positionInFromChart;
    cameraPositionW_ = positionW;
    upsertEdge(fromChart, cameraChartId_, T, true);
    upsertEdge(cameraChartId_, fromChart, T.inverse(), true);

    setError(0);
    return cameraChartId_;
}

int Atlas::cameraMove(const vec3& movement) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!finiteVec(movement)) { setError(3); return -1; }

    if (cameraChartId_ < 0) {
        // Initialize the camera chart at the current (base-chart) position.
        // The camera-chart radius is fixed at π/2 until a scene explicitly
        // creates the camera chart with a different radius.
        return cameraChartAt(cameraChartFrom_, cameraPosition_, cameraPositionW_,
                             1.5707963267948966f);
    }

    // Save the current local camera orientation and parent-chart relation.
    vec3 oldRight = cameraRight_;
    vec3 oldUp = cameraUp_;
    vec3 oldFwd = cameraFwd_;
    const int oldParent = cameraChartFrom_;
    const vec3 oldPosition = cameraPosition_;
    const float oldPositionW = cameraPositionW_;
    Mobius oldToBase = cameraChartTransition_.inverse();

    // Build the augmented camera-chart point reached by `movement`.
    vec4 movedCam;
    if (modelKind_ == GEO_MODEL_S3) {
        float moveLen = length(movement);
        if (moveLen < 1e-9f) {
            movedCam = vec4(0, 0, 0, 1);
        } else {
            vec3 dir = movement / moveLen;
            movedCam = vec4(mhSin(moveLen) * dir, mhCos(moveLen));
        }
    } else {
        movedCam = vec4(movement, mhSqrt(mhMax(0.0f, 1.0f - lengthSq(movement))));
    }

    // Express the result in the old parent chart and re-parent.
    vec4 movedParent = oldToBase.applyChartPointAugmented(movedCam);
    CameraPlacement placement;
    Mobius portalTransition = identityMobius();
    bool crossedPortal = false;
    if (!portals_.empty()) {
        int current = oldParent;
        vec4 point = movedParent;
        for (int hop = 0; hop < 16; ++hop) {
            int selected = -1; float worst = 1e-6f;
            for (size_t i = 0; i < portals_.size(); ++i) {
                const auto& p = portals_[i]; if (p.chartId != current) continue;
                float violation = p.interiorSign * (dot(p.a, point.xyz()) + p.b*point.w - p.c);
                if (violation > worst) { worst = violation; selected = static_cast<int>(i); }
            }
            if (selected < 0) break;
            const auto& p = portals_[selected];
            point = p.toNeighbor.applyChartPointAugmented(point);
            portalTransition = p.toNeighbor.compose(portalTransition);
            current = p.neighborId; crossedPortal = true;
            if (hop == 15) { setError(8); return -1; }
        }
        placement.chartId=current; placement.localPosition=point.xyz(); placement.localPositionW=point.w;
    } else {
        placement = resolveCameraPlacementAugmented(oldParent, movedParent);
    }

    // Transition from the old parent chart to the new parent chart, needed to
    // parallel-transport the camera frame into the re-anchored camera chart.
    Mobius parentToNew;
    if (crossedPortal) {
        parentToNew = portalTransition;
    } else if (placement.chartId == oldParent) {
        parentToNew = identityMobius();
    } else if (!chartTransition(oldParent, placement.chartId, parentToNew)) {
        setError(4);   // should not happen: resolveCameraPlacementAugmented only returns reachable charts
        return -1;
    }

    // The camera chart radius is fixed. Re-parenting changes only the anchor
    // chart and position, not the camera chart's own culling radius.
    float newRadius = charts_[cameraChartId_].radius;
    int id = cameraChartAt(placement.chartId, placement.localPosition,
                           placement.localPositionW, newRadius);
    if (id < 0) return id;   // preserve cameraChartAt's error

    // Push the previous camera-chart orientation into the new camera chart:
    // old camera chart -> old parent -> new parent -> new camera chart.
    Mobius oldToNew = cameraChartTransition_.compose(parentToNew.compose(oldToBase));
    const float eps = 1e-3f;
    auto pushDirection = [&](const vec3& dir) {
        float len = length(dir);
        if (len < 1e-9f) return dir;
        vec3 u = dir / len;
        float w = mhSqrt(mhMax(0.0f, 1.0f - eps * eps));
        vec4 base = oldToNew.applyChartPointAugmented(vec4(0, 0, 0, 1));
        vec4 moved = oldToNew.applyChartPointAugmented(vec4(u * eps, w));
        vec3 local = moved.xyz() - base.xyz();
        float l = length(local);
        if (l > 1e-9f) return local / l;
        return dir;
    };

    cameraRight_ = pushDirection(oldRight);
    cameraUp_ = pushDirection(oldUp);
    cameraFwd_ = pushDirection(oldFwd);

    setError(0);
    return id;
}

int Atlas::build(int cameraChart, int maxChartDepth) {
    packet_.clear();
    if (!validModelKind()) { setError(6); return 6; }
    if (!validChartId(cameraChart)) { setError(4); return 4; }
    if (maxChartDepth <= 0 || maxChartDepth > GEO_MAX_CHART_DEPTH) { setError(5); return 5; }
    if (capacityExceeded_) { setError(5); return 5; }

    const int n = static_cast<int>(charts_.size());
    const int objectCount = static_cast<int>(objects_.size());
    if (objectCount > GEO_MAX_OBJECTS) { setError(5); return 5; }

    const int authoredMaterialCount = static_cast<int>(materials_.size());
    if (authoredMaterialCount > GEO_MAX_MATERIALS) { setError(5); return 5; }
    const int materialCount = authoredMaterialCount > 0 ? authoredMaterialCount : 1;   // default white

    const int lightCount = static_cast<int>(lights_.size());
    if (lightCount > GEO_MAX_LIGHTS) { setError(5); return 5; }

    // ---- object validation (authoring chart coordinates) ----
    for (const auto& o : objects_) {
        int code = validateObjectBasics(o, materialCount);
        if (code != 0) { setError(code); return code; }
        code = validateObjectModel(o);
        if (code != 0) { setError(code); return code; }
    }

    // ---- light validation (authoring chart coordinates) ----
    for (const auto& light : lights_) {
        int code = validateLight(light);
        if (code != 0) { setError(code); return code; }
    }

    // ---- build the undirected overlap graph ----
    std::vector<UEdge> uedges = buildUndirectedEdges();
    // Reject charts referenced by missing/invalid edge endpoints.
    for (int i = 0; i < n; ++i) {
        for (const auto& e : charts_[i].edges) {
            if (e.neighborId < 0 || e.neighborId >= n) { setError(3); return 3; }
        }
    }

    // ---- BFS over ALL edges from the camera chart ----
    std::vector<int> depth(n, -1);
    std::vector<Mobius> path(n);
    std::vector<int> parent(n, -1);
    std::vector<int> parentEdge(n, -1);
    std::vector<int> queue;
    queue.reserve(n);

    depth[cameraChart] = 0;
    path[cameraChart] = identityMobius();
    parent[cameraChart] = -2;
    queue.push_back(cameraChart);

    for (size_t qi = 0; qi < queue.size(); ++qi) {
        int u = queue[qi];
        for (size_t ei = 0; ei < uedges.size(); ++ei) {
            const UEdge& ue = uedges[ei];
            int v = -1;
            if (ue.a == u) v = ue.b;
            else if (ue.b == u) v = ue.a;
            if (v < 0 || depth[v] != -1) continue;

            Mobius t_uv = edgeTransition(u, v, ue);
            path[v] = t_uv.compose(path[u]);
            depth[v] = depth[u] + 1;
            parent[v] = u;
            parentEdge[v] = static_cast<int>(ei);
            queue.push_back(v);
        }
    }

    for (int i = 0; i < n; ++i) {
        if (depth[i] < 0) { setError(1); return 1; }   // island chart (or disconnected component)
        if (depth[i] > maxChartDepth) { setError(5); return 5; }
    }

    // ---- cocycle check on non-tree edges ----
    std::vector<bool> inTree(uedges.size(), false);
    for (int i = 0; i < n; ++i) {
        if (i != cameraChart && parentEdge[i] >= 0) inTree[parentEdge[i]] = true;
    }

    for (size_t ei = 0; ei < uedges.size(); ++ei) {
        if (inTree[ei]) continue;
        const UEdge& ue = uedges[ei];
        Mobius tTree_uv = path[ue.b].compose(path[ue.a].inverse());  // ue.a -> ue.b via tree
        if (!mobiusClose(ue.ab, tTree_uv, 1e-3f)) { setError(2); return 2; }
    }

    // ---- flattening BFS that prefers safe hops ----
    std::vector<int> safeDepth(n, -1);
    std::vector<Mobius> safePath(n);
    std::vector<int> safeQueue;
    safeQueue.reserve(n);
    safeDepth[cameraChart] = 0;
    safePath[cameraChart] = identityMobius();
    safeQueue.push_back(cameraChart);

    for (size_t qi = 0; qi < safeQueue.size(); ++qi) {
        int u = safeQueue[qi];
        for (const auto& e : charts_[u].edges) {
            int v = e.neighborId;
            if (!e.safe || safeDepth[v] != -1) continue;
            safePath[v] = e.toNeighbor.compose(safePath[u]);
            safeDepth[v] = safeDepth[u] + 1;
            safeQueue.push_back(v);
        }
    }

    // Choose a path per chart: shortest safe path when available and within the
    // depth bound; otherwise fall back to the all-edge BFS path.
    std::vector<Mobius> flattenPath(n);
    for (int i = 0; i < n; ++i) {
        if (safeDepth[i] >= 0 && safeDepth[i] <= maxChartDepth) {
            flattenPath[i] = safePath[i];
        } else if (depth[i] >= 0 && depth[i] <= maxChartDepth) {
            flattenPath[i] = path[i];
        } else {
            setError(5);
            return 5;
        }
    }

    // ---- transform objects into the camera chart ----
    struct FlatObject {
        int kind;
        vec3 a;
        float b;
        float c;
        int colorIdx;
    };
    std::vector<FlatObject> flat;
    flat.reserve(objectCount);

    const float cameraRadius = charts_[cameraChart].radius;
    // H³ disk charts live on the upper hemisphere (w > 0); clamp tiny
    // floating-point cos(π/2) values back to the actual cap boundary.
    const float cameraCosR = (modelKind_ == GEO_MODEL_H3)
        ? mhMax(0.0f, mhCos(cameraRadius))
        : mhCos(cameraRadius);
    const float cameraSinR = mhSin(cameraRadius);

    auto isIdentity = [](const Mobius& m) {
        mat4 I = mat4Identity();
        for (int i = 0; i < 16; ++i) {
            if (m.m.m[i] != I.m[i]) return false;
        }
        return true;
    };

    for (int x = 0; x < n; ++x) {
        if (charts_[x].objectIds.empty()) continue;
        Mobius toCam = (x == cameraChart) ? identityMobius() : flattenPath[x].inverse();
        const bool copyDirect = (x == cameraChart) || isIdentity(toCam);
        for (int objId : charts_[x].objectIds) {
            if (objId < 0 || objId >= objectCount) { setError(3); return 3; }
            const ChartObject& o = objects_[objId];

            vec3 fa = o.a;
            float fb = o.b;
            float fc = o.c;

            if (!copyDirect) {
                toCam.applySurface(o.a, o.b, o.c, fa, fb, fc);
                if (!finiteVec(fa) || !finiteFloat(fb) || !finiteFloat(fc)) { setError(3); return 3; }
            }

            // Camera-chart disk culling: keep only objects whose surface has at
            // least one point inside the camera chart. The GPU already discards
            // hits at t >= chartRadius; this avoids emitting objects that can
            // never contribute to the frame.
            if (!surfaceIntersectsChartDisk(fa, fb, fc, cameraCosR, cameraSinR)) {
                continue;
            }

            flat.push_back({o.kind, fa, fb, fc, o.colorIdx});
        }
    }

    // ---- transform lights into the camera chart ----
    struct FlatLight {
        vec3 position;
        float positionW;
        vec3 color;
        float intensity;
    };
    std::vector<FlatLight> flatLights;
    flatLights.reserve(lightCount);

    for (int x = 0; x < n; ++x) {
        if (charts_[x].lightIds.empty()) continue;
        Mobius toCam = (x == cameraChart) ? identityMobius() : flattenPath[x].inverse();
        const bool copyDirect = (x == cameraChart) || isIdentity(toCam);
        for (int lightId : charts_[x].lightIds) {
            if (lightId < 0 || lightId >= lightCount) { setError(3); return 3; }
            const ChartLight& light = lights_[lightId];
            vec3 lp = light.position;
            float lpW = light.positionW;
            if (!copyDirect) {
                vec4 Q = toCam.applyChartPointAugmented(
                    vec4(light.position, light.positionW));
                lp = Q.xyz();
                lpW = Q.w;
                if (!finiteVec(lp) || !finiteFloat(lpW)) { setError(3); return 3; }
            }
            flatLights.push_back({lp, lpW, light.color, light.intensity});
        }
    }

    std::sort(flatLights.begin(), flatLights.end(), [](const FlatLight& a, const FlatLight& b) {
        if (a.position.x != b.position.x) return a.position.x < b.position.x;
        if (a.position.y != b.position.y) return a.position.y < b.position.y;
        if (a.position.z != b.position.z) return a.position.z < b.position.z;
        if (a.positionW != b.positionW) return a.positionW < b.positionW;
        if (a.color.x != b.color.x) return a.color.x < b.color.x;
        if (a.color.y != b.color.y) return a.color.y < b.color.y;
        if (a.color.z != b.color.z) return a.color.z < b.color.z;
        return a.intensity < b.intensity;
    });

    const int flatLightCount = static_cast<int>(flatLights.size());
    if (flatLightCount > GEO_MAX_LIGHTS) { setError(5); return 5; }

    // Canonical object order so the packet is deterministic and independent of
    // authoring order / BFS traversal order.
    std::sort(flat.begin(), flat.end(), [](const FlatObject& a, const FlatObject& b) {
        if (a.kind != b.kind) return a.kind < b.kind;
        if (a.colorIdx != b.colorIdx) return a.colorIdx < b.colorIdx;
        if (a.a.x != b.a.x) return a.a.x < b.a.x;
        if (a.a.y != b.a.y) return a.a.y < b.a.y;
        if (a.a.z != b.a.z) return a.a.z < b.a.z;
        if (a.b != b.b) return a.b < b.b;
        return a.c < b.c;
    });

    const int flatCount = static_cast<int>(flat.size());
    if (flatCount > GEO_MAX_OBJECTS) { setError(5); return 5; }

    // ---- emit ScenePacket bytes ----
    const size_t headerSize = sizeof(ScenePacketHeader);
    const size_t totalSize = headerSize + sizeof(Object) * flatCount + sizeof(Material) * materialCount + sizeof(PointLight) * flatLightCount;
    packet_.assign(totalSize, 0);

    ScenePacketHeader hdr{};
    hdr.meta.magic = GEO_PACKET_MAGIC;
    hdr.meta.contractVersion = GEO_CONTRACT_VERSION;
    hdr.meta.objectSize = static_cast<int>(sizeof(Object));
    hdr.meta.packetHeaderSize = static_cast<int>(headerSize);
    hdr.camera.right = cameraRight_;
    hdr.camera.padRight = 0.0f;
    hdr.camera.up = cameraUp_;
    hdr.camera.padUp = 0.0f;
    hdr.camera.fwd = cameraFwd_;
    hdr.camera.padFwd = 0.0f;
    hdr.camera.fovTan = fovTan_;
    hdr.camera.aspect = aspect_;
    float cameraChartRadius = charts_[cameraChart].radius;
    if (modelKind_ == GEO_MODEL_H3) {
        // H³ charts store the angular radius r whose compact disk boundary is
        // |x| = sin(r). The intrinsic geodesic radius is R = atanh(sin(r)).
        float compactBoundary = mhSin(cameraChartRadius);
        float intrinsicRadius = mhAtanh(compactBoundary);
        hdr.camera.chartRadius = intrinsicRadius;
        hdr.camera.chartRadiusHalfAngle = mhTanh(0.5f * intrinsicRadius);
    } else {
        hdr.camera.chartRadius = cameraChartRadius;
        hdr.camera.chartRadiusHalfAngle =
            mhSin(0.5f * cameraChartRadius) / mhCos(0.5f * cameraChartRadius);
    }
    hdr.controls.maxBounces = maxBounces_;
    hdr.controls.modelKind = modelKind_;
    hdr.controls.falloffK = falloffK_;
    hdr.controls.ambient = ambient_;
    hdr.controls.bounceAttenuation = bounceAttenuation_;
    hdr.controls.fogMode = fogMode_;
    hdr.controls.fogStartFraction = fogStartFraction_;
    hdr.controls.fogDensity = fogDensity_;
    hdr.counts.objectCount = flatCount;
    hdr.counts.materialCount = materialCount;
    hdr.counts.lightCount = flatLightCount;
    hdr.counts.pad0 = 0;

    std::memcpy(packet_.data(), &hdr, headerSize);
    size_t off = headerSize;

    for (const auto& f : flat) {
        Object obj{};
        obj.a = f.a;
        obj.b = f.b;
        obj.c = f.c;
        obj.kind = f.kind;
        obj.colorIdx = f.colorIdx;
        obj.pad0 = 0;
        std::memcpy(packet_.data() + off, &obj, sizeof(obj));
        off += sizeof(obj);
    }

    for (int i = 0; i < materialCount; ++i) {
        Material mat;
        if (i < authoredMaterialCount) {
            mat = materials_[i];
        } else {
            mat.color = vec4(1.0f, 1.0f, 1.0f, 1.0f);   // default white
            mat.specular = vec4(0.0f, 0.0f, 0.0f, 1.0f);
        }
        std::memcpy(packet_.data() + off, &mat, sizeof(mat));
        off += sizeof(mat);
    }

    for (const auto& light : flatLights) {
        PointLight outLight{};
        outLight.position = light.position;
        outLight.positionW = light.positionW;
        outLight.color = light.color;
        outLight.intensity = light.intensity;
        std::memcpy(packet_.data() + off, &outLight, sizeof(outLight));
        off += sizeof(outLight);
    }

    setError(0);
    return 0;
}

int Atlas::buildAtlas(int cameraChart, int maxChartHops, int maxLightHops, int maxLightStates) {
    packet_.clear();
    if (!validModelKind()) { setError(6); return 6; }
    if (!validChartId(cameraChart)) { setError(4); return 4; }
    if (capacityExceeded_) { setError(5); return 5; }
    if (maxChartHops <= 0 || maxChartHops > 128 || maxLightHops < 0 || maxLightHops > 4 ||
        maxLightStates <= 0 || maxLightStates > 256) { setError(8); return 8; }

    const int chartCount = static_cast<int>(charts_.size());
    const int materialCount = materials_.empty() ? 1 : static_cast<int>(materials_.size());
    if (static_cast<int>(objects_.size()) > GEO_MAX_OBJECTS ||
        static_cast<int>(materials_.size()) > GEO_MAX_MATERIALS ||
        static_cast<int>(lights_.size()) > GEO_MAX_LIGHTS) { setError(5); return 5; }
    for (const auto& object : objects_) {
        int code = validateObjectBasics(object, materialCount);
        if (code == 0) code = validateObjectModel(object);
        if (code != 0) { setError(code); return code; }
    }
    for (const auto& light : lights_) {
        int code = validateLight(light);
        if (code != 0) { setError(code); return code; }
    }

    // Validate only ordinary overlap connectivity and cocycles. Portal loops
    // intentionally carry quotient holonomy and are not part of this graph.
    std::vector<UEdge> overlapEdges = buildUndirectedEdges();
    for (const auto& chart : charts_) for (const auto& edge : chart.edges) {
        if (edge.neighborId < 0 || edge.neighborId >= chartCount) { setError(3); return 3; }
    }
    std::vector<int> depth(chartCount, -1), parentEdge(chartCount, -1), queue;
    std::vector<Mobius> path(chartCount);
    depth[cameraChart] = 0; path[cameraChart] = identityMobius(); queue.push_back(cameraChart);
    for (size_t qi = 0; qi < queue.size(); ++qi) {
        int from = queue[qi];
        for (size_t ei = 0; ei < overlapEdges.size(); ++ei) {
            const UEdge& edge = overlapEdges[ei];
            int to = edge.a == from ? edge.b : (edge.b == from ? edge.a : -1);
            if (to < 0 || depth[to] >= 0) continue;
            path[to] = edgeTransition(from, to, edge).compose(path[from]);
            depth[to] = depth[from] + 1; parentEdge[to] = static_cast<int>(ei); queue.push_back(to);
        }
    }
    for (int chart = 0; chart < chartCount; ++chart) {
        if (depth[chart] < 0) { setError(1); return 1; }
        if (depth[chart] > GEO_MAX_CHART_DEPTH) { setError(5); return 5; }
    }
    std::vector<bool> treeEdge(overlapEdges.size(), false);
    for (int chart = 0; chart < chartCount; ++chart)
        if (chart != cameraChart && parentEdge[chart] >= 0) treeEdge[parentEdge[chart]] = true;
    for (size_t ei = 0; ei < overlapEdges.size(); ++ei) {
        if (treeEdge[ei]) continue;
        const UEdge& edge = overlapEdges[ei];
        Mobius treeTransition = path[edge.b].compose(path[edge.a].inverse());
        if (!mobiusClose(edge.ab, treeTransition, 1e-3f)) { setError(2); return 2; }
    }

    std::vector<int> authoredCharts;
    std::vector<int> chartRemap(charts_.size(), -1);
    for (int chart = 0; chart < static_cast<int>(charts_.size()); ++chart) {
        if (chart == cameraChartId_) continue; // special camera chart is host-only
        chartRemap[chart] = static_cast<int>(authoredCharts.size());
        authoredCharts.push_back(chart);
    }
    int baseChartCount = static_cast<int>(authoredCharts.size());
    if (baseChartCount <= 0 || baseChartCount > GEO_MAX_CHARTS ||
        static_cast<int>(portals_.size()) > GEO_MAX_PORTALS) { setError(8); return 8; }

    int parent = (cameraChart == cameraChartId_) ? cameraChartFrom_ : cameraChart;
    if (parent < 0 || parent >= static_cast<int>(chartRemap.size()) || chartRemap[parent] < 0) {
        setError(4); return 4;
    }

    std::vector<GPUChart> gpuCharts(baseChartCount);
    std::vector<GPUPortal> gpuPortals;
    std::vector<int> portalRemap(portals_.size(), -1);
    std::vector<Object> gpuObjects;
    std::vector<PointLight> gpuLights;

    for (int gpuChart = 0; gpuChart < baseChartCount; ++gpuChart) {
        int chart = authoredCharts[gpuChart];
        GPUChart gc{};
        gc.angularRadius = charts_[chart].radius;
        gc.intrinsicRadius = modelKind_ == GEO_MODEL_H3
            ? mhAtanh(mhMin(0.999999f, mhSin(charts_[chart].radius)))
            : charts_[chart].radius;
        gc.firstPortal = static_cast<int>(gpuPortals.size());
        for (size_t pi = 0; pi < portals_.size(); ++pi) if (portals_[pi].chartId == chart) {
            portalRemap[pi] = static_cast<int>(gpuPortals.size());
            GPUPortal gp{};
            gp.toNeighbor = portals_[pi].toNeighbor.m;
            gp.a = portals_[pi].a; gp.b = portals_[pi].b; gp.c = portals_[pi].c;
            int neighbor = portals_[pi].neighborId;
            if (neighbor < 0 || neighbor >= static_cast<int>(chartRemap.size()) || chartRemap[neighbor] < 0) {
                setError(7); return 7;
            }
            gp.neighborChart = chartRemap[neighbor];
            gp.reversePortal = portals_[pi].reversePortal; // remapped below
            gp.interiorSign = portals_[pi].interiorSign;
            gpuPortals.push_back(gp);
        }
        gc.portalCount = static_cast<int>(gpuPortals.size()) - gc.firstPortal;
        gc.firstObject = static_cast<int>(gpuObjects.size());
        for (int objectId : charts_[chart].objectIds) {
            const ChartObject& in = objects_[objectId];
            Object out{}; out.a=in.a; out.b=in.b; out.c=in.c;
            out.kind=in.kind; out.colorIdx=in.colorIdx;
            gpuObjects.push_back(out);
        }
        gc.objectCount = static_cast<int>(gpuObjects.size()) - gc.firstObject;
        gc.firstLight = static_cast<int>(gpuLights.size());
        for (int lightId : charts_[chart].lightIds) {
            const ChartLight& in = lights_[lightId];
            PointLight out{}; out.position=in.position; out.positionW=in.positionW;
            out.color=in.color; out.intensity=in.intensity;
            gpuLights.push_back(out);
        }
        gc.lightCount = static_cast<int>(gpuLights.size()) - gc.firstLight;
        gpuCharts[gpuChart] = gc;
    }
    for (size_t old = 0; old < portals_.size(); ++old) {
        int mapped = portalRemap[old];
        int reverse = portals_[old].reversePortal;
        if (mapped < 0 || reverse < 0 || reverse >= static_cast<int>(portalRemap.size()) ||
            portalRemap[reverse] < 0) { setError(7); return 7; }
        gpuPortals[mapped].reversePortal = portalRemap[reverse];
    }

    AtlasPacketHeader hdr{};
    hdr.meta.magic = GEO_ATLAS_PACKET_MAGIC;
    hdr.meta.contractVersion = GEO_ATLAS_CONTRACT_VERSION;
    hdr.meta.objectSize = sizeof(Object);
    hdr.meta.packetHeaderSize = sizeof(AtlasPacketHeader);
    hdr.camera.chartId = chartRemap[parent];
    hdr.camera.fovTan = fovTan_; hdr.camera.aspect = aspect_;
    float horizonAngle = charts_[cameraChart].radius;
    hdr.camera.maxTraceDistance = modelKind_ == GEO_MODEL_H3
        ? mhAtanh(mhMin(0.999999f, mhSin(horizonAngle))) : horizonAngle;
    hdr.camera.maxTraceHalfAngle = modelKind_ == GEO_MODEL_H3
        ? mhTanh(0.5f * hdr.camera.maxTraceDistance)
        : mhSin(0.5f*horizonAngle)/mhCos(0.5f*horizonAngle);

    Mobius cameraToParent = identityMobius();
    vec4 P(0,0,0,1);
    if (cameraChart == cameraChartId_) {
        cameraToParent = cameraChartTransition_.inverse();
        P = modelKind_ == GEO_MODEL_S3
            ? vec4(cameraPosition_, cameraPositionW_)
            : mat4Apply(cameraToParent.m, vec4(0,0,0,1));
    }
    hdr.camera.position = P;
    hdr.camera.right = mat4Apply(cameraToParent.m, vec4(cameraRight_,0));
    hdr.camera.up = mat4Apply(cameraToParent.m, vec4(cameraUp_,0));
    hdr.camera.fwd = mat4Apply(cameraToParent.m, vec4(cameraFwd_,0));
    hdr.controls.shading.maxBounces=maxBounces_; hdr.controls.shading.modelKind=modelKind_;
    hdr.controls.shading.falloffK=falloffK_; hdr.controls.shading.ambient=ambient_;
    hdr.controls.shading.bounceAttenuation=bounceAttenuation_;
    hdr.controls.shading.fogMode=fogMode_; hdr.controls.shading.fogStartFraction=fogStartFraction_;
    hdr.controls.shading.fogDensity=fogDensity_;
    hdr.controls.maxChartHops=maxChartHops; hdr.controls.maxLightHops=maxLightHops;
    hdr.controls.maxLightStates=maxLightStates;
    hdr.counts.chartCount=baseChartCount; hdr.counts.portalCount=gpuPortals.size();
    hdr.counts.objectCount=gpuObjects.size(); hdr.counts.materialCount=materials_.empty()?1:materials_.size();
    hdr.counts.lightCount=gpuLights.size();

    size_t total=sizeof(hdr)+gpuCharts.size()*sizeof(GPUChart)+gpuPortals.size()*sizeof(GPUPortal)+
        gpuObjects.size()*sizeof(Object)+hdr.counts.materialCount*sizeof(Material)+gpuLights.size()*sizeof(PointLight);
    packet_.assign(total,0); size_t off=0;
    auto append=[&](const void* p,size_t bytes){std::memcpy(packet_.data()+off,p,bytes);off+=bytes;};
    append(&hdr,sizeof(hdr)); append(gpuCharts.data(),gpuCharts.size()*sizeof(GPUChart));
    append(gpuPortals.data(),gpuPortals.size()*sizeof(GPUPortal));
    append(gpuObjects.data(),gpuObjects.size()*sizeof(Object));
    if (materials_.empty()) { Material m{};m.color=vec4(1,1,1,1);m.specular=vec4(0,0,0,1);append(&m,sizeof(m)); }
    else append(materials_.data(),materials_.size()*sizeof(Material));
    append(gpuLights.data(),gpuLights.size()*sizeof(PointLight));
    setError(0); return 0;
}

} // namespace geo
