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

} // namespace

Atlas::Atlas() { resetToDefaults(); }

void Atlas::resetToDefaults() {
    modelKind_ = GEO_MODEL_H3;
    charts_.clear();
    objects_.clear();
    lights_.clear();
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
    packet_.clear();
    lastError_ = 0;
    capacityExceeded_ = false;
    cameraChartId_ = -1;
    cameraChartFrom_ = 0;
    cameraPosition_ = vec3(0, 0, 0);
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
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (static_cast<int>(lights_.size()) >= GEO_MAX_LIGHTS) { capacityExceeded_ = true; setError(5); return -1; }

    // Store lights even if they are invalid; Atlas::build is the single
    // validation point and must return the CONTRACT error code.
    ChartLight light;
    light.chartId = chartId;
    light.position = position;
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
    clearPacket();
    if (maxBounces < 0 || !finiteFloat(falloffK) || !finiteFloat(ambient) || !finiteFloat(bounceAttenuation)) {
        setError(3);
        return;
    }
    maxBounces_ = maxBounces;
    falloffK_ = falloffK;
    ambient_ = ambient;
    bounceAttenuation_ = bounceAttenuation;
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
    if (!finiteVec(light.position) || !finiteVec(light.color) || !finiteFloat(light.intensity)) return 3;
    if (light.intensity < 0.0f) return 3;
    float radius = charts_[light.chartId].radius;
    if (length(light.position) >= mhSin(radius) - 1e-4f) return 3;
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
    CameraPlacement placement;
    placement.chartId = startChart;
    placement.localPosition = startLocal + movement;

    if (!validModelKind() || !validChartId(startChart)) {
        return placement;
    }

    vec3 candidate = startLocal + movement;
    if (!finiteVec(candidate)) {
        placement.chartId = startChart;
        placement.localPosition = startLocal;
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
    vec3 bestInsideLocal;
    float bestInsideNorm = 1e30f;

    for (int x = 0; x < n; ++x) {
        if (depth[x] < 0) continue;
        // The special camera chart is not a re-parenting target.
        if (x == cameraChartId_) continue;

        vec3 local = path[x].applyChartPoint(candidate);
        if (!finiteVec(local)) continue;

        float norm = length(local);
        float limit = mhSin(charts_[x].radius);

        if (norm < limit * kCameraInsideFactor) {
            if (bestInsideChart < 0 || norm < bestInsideNorm) {
                bestInsideChart = x;
                bestInsideLocal = local;
                bestInsideNorm = norm;
            }
        }
    }

    if (bestInsideChart >= 0) {
        placement.chartId = bestInsideChart;
        placement.localPosition = bestInsideLocal;
    } else {
        // No existing chart can realize the candidate point. Clamp it back
        // onto the original chart's disk boundary (no 0.95/0.98 safety factor,
        // which caused the camera position to jump inward).
        placement.chartId = startChart;
        float limit = mhSin(charts_[startChart].radius);
        float norm = length(candidate);
        if (norm > limit && norm > 1e-6f) {
            placement.localPosition = candidate * (limit / norm);
        } else {
            placement.localPosition = candidate;
        }
    }

    return placement;
}

int Atlas::cameraChartAt(int fromChart, const vec3& positionInFromChart, float radius) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!validChartId(fromChart)) { setError(4); return -1; }
    if (!validChartRadius(radius)) { setError(3); return -1; }
    if (!finiteVec(positionInFromChart)) { setError(3); return -1; }

    Mobius T;
    T.kind = (modelKind_ == GEO_MODEL_S3) ? ModelKind::S3 : ModelKind::H3;

    if (modelKind_ == GEO_MODEL_S3) {
        vec4 P = disk::toAmbient(positionInFromChart);
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
        return cameraChartAt(cameraChartFrom_, cameraPosition_, kCameraRadius);
    }

    // Save the current local camera orientation and parent-chart relation.
    vec3 oldRight = cameraRight_;
    vec3 oldUp = cameraUp_;
    vec3 oldFwd = cameraFwd_;
    const int oldParent = cameraChartFrom_;
    const vec3 oldPosition = cameraPosition_;
    Mobius oldToBase = cameraChartTransition_.inverse();

    // Express the local camera-chart movement in the parent chart coordinates.
    vec3 baseMoved = oldToBase.applyChartPoint(movement);

    CameraPlacement placement;
    if (!finiteVec(baseMoved)) {
        // The movement cannot be realized (for example H3 |movement| == 1
        // lands on the disk-chart boundary). Clamp back to the original chart
        // at the previous valid position.
        placement.chartId = oldParent;
        placement.localPosition = oldPosition;
    } else {
        vec3 baseDelta = baseMoved - oldPosition;
        placement = resolveCameraPlacement(oldParent, oldPosition, baseDelta);
    }

    // Transition from the old parent chart to the new parent chart, needed to
    // parallel-transport the camera frame into the re-anchored camera chart.
    Mobius parentToNew;
    if (placement.chartId == oldParent) {
        parentToNew = identityMobius();
    } else if (!chartTransition(oldParent, placement.chartId, parentToNew)) {
        setError(4);   // should not happen: resolveCameraPlacement only returns reachable charts
        return -1;
    }

    int id = cameraChartAt(placement.chartId, placement.localPosition, kCameraRadius);
    if (id < 0) return id;   // preserve cameraChartAt's error

    // Push the previous camera-chart orientation into the new camera chart:
    // old camera chart -> old parent -> new parent -> new camera chart.
    Mobius oldToNew = cameraChartTransition_.compose(parentToNew.compose(oldToBase));
    const float eps = 1e-3f;
    auto pushDirection = [&](const vec3& dir) {
        vec3 base = oldToNew.applyChartPoint(vec3(0, 0, 0));
        vec3 moved = oldToNew.applyChartPoint(dir * eps);
        vec3 local = moved - base;
        float len = length(local);
        if (len > 1e-9f) return local / len;
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

            flat.push_back({o.kind, fa, fb, fc, o.colorIdx});
        }
    }

    // ---- transform lights into the camera chart ----
    struct FlatLight {
        vec3 position;
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
            if (!copyDirect) {
                lp = toCam.applyChartPoint(light.position);
                if (!finiteVec(lp)) { setError(3); return 3; }
            }
            flatLights.push_back({lp, light.color, light.intensity});
        }
    }

    std::sort(flatLights.begin(), flatLights.end(), [](const FlatLight& a, const FlatLight& b) {
        if (a.position.x != b.position.x) return a.position.x < b.position.x;
        if (a.position.y != b.position.y) return a.position.y < b.position.y;
        if (a.position.z != b.position.z) return a.position.z < b.position.z;
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
    hdr.camera.chartRadiusSin = mhSin(charts_[cameraChart].radius);
    hdr.camera.chartRadiusCos = mhCos(charts_[cameraChart].radius);
    hdr.controls.maxBounces = maxBounces_;
    hdr.controls.modelKind = modelKind_;
    hdr.controls.falloffK = falloffK_;
    hdr.controls.ambient = ambient_;
    hdr.controls.bounceAttenuation = bounceAttenuation_;
    hdr.controls.pad0 = 0.0f;
    hdr.controls.pad1 = 0.0f;
    hdr.controls.pad2 = 0.0f;
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
        outLight.pad0 = 0.0f;
        outLight.color = light.color;
        outLight.intensity = light.intensity;
        std::memcpy(packet_.data() + off, &outLight, sizeof(outLight));
        off += sizeof(outLight);
    }

    setError(0);
    return 0;
}

} // namespace geo
