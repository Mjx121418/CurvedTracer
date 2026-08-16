#include "GeometryCore/Chart.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace geo {

namespace {

constexpr float kObjectEps = 1e-3f;
constexpr float kPlaneOffsetEps = 1e-4f;

bool finiteVec(const vec3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

bool finiteFloat(float x) { return std::isfinite(x); }

} // namespace

Atlas::Atlas() { resetToDefaults(); }

void Atlas::resetToDefaults() {
    modelKind_ = GEO_MODEL_H3;
    charts_.clear();
    objects_.clear();
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

int Atlas::seed() {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!charts_.empty()) { setError(5); return -1; }   // anchorless seed is unique
    Chart c;
    c.id = 0;
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

int Atlas::addChart(int fromChart, const float m[16], bool safe) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!validChartId(fromChart)) { setError(4); return -1; }
    if (!m) { setError(3); return -1; }
    for (int i = 0; i < 16; ++i) {
        if (!std::isfinite(m[i])) { setError(3); return -1; }
    }

    Mobius mFrom = mobiusFromMatrix(m);
    Mobius mBack = mFrom.inverse();

    Chart c;
    c.id = static_cast<int>(charts_.size());
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

int Atlas::addObject(int chartId, int kind, const vec3& center, float radiusOrOffset, int colorIdx) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (static_cast<int>(objects_.size()) >= GEO_MAX_OBJECTS) { capacityExceeded_ = true; setError(5); return -1; }

    // Store objects even if they are invalid; Atlas::build is the single
    // validation point and must return the CONTRACT error code.
    ChartObject o;
    o.chartId = chartId;
    o.kind = kind;
    o.center = center;
    o.radiusOrOffset = radiusOrOffset;
    o.colorIdx = colorIdx;
    int objId = static_cast<int>(objects_.size());
    objects_.push_back(o);
    if (validChartId(chartId)) {
        charts_[chartId].objectIds.push_back(objId);
    }
    setError(0);
    return objId;
}

int Atlas::addMaterial(const vec4& color) {
    clearPacket();
    if (!validModelKind()) { setError(6); return -1; }
    if (!finiteVec(vec3(color.x, color.y, color.z)) || !finiteFloat(color.w)) { setError(3); return -1; }
    if (static_cast<int>(materials_.size()) >= GEO_MAX_MATERIALS) { capacityExceeded_ = true; setError(5); return -1; }
    int idx = static_cast<int>(materials_.size());
    materials_.push_back(color);
    setError(0);
    return idx;
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

int Atlas::validateObjectBasics(const ChartObject& o, int materialCount) const {
    if (!validChartId(o.chartId)) return 3;
    if (o.kind < GEO_OBJECT_OPAQUE || o.kind > GEO_OBJECT_PLANE) return 3;
    if (!finiteVec(o.center) || !finiteFloat(o.radiusOrOffset)) return 3;
    if (o.kind != GEO_OBJECT_PLANE && o.radiusOrOffset <= 0.0f) return 3;
    if (o.colorIdx < 0 || o.colorIdx >= materialCount) return 3;
    return 0;
}

int Atlas::validateObjectModel(const ChartObject& o) const {
    if (o.kind == GEO_OBJECT_OPAQUE) {
        if (modelKind_ == GEO_MODEL_H3) {
            // OPAQUE spheres must stay strictly inside the unit ball.
            float r = o.radiusOrOffset;
            if (length(o.center) + r >= 1.0f) return 3;
        }
        return 0;
    }

    if (o.kind == GEO_OBJECT_MIRROR) {
        float r = o.radiusOrOffset;
        float c2 = lengthSq(o.center);
        if (modelKind_ == GEO_MODEL_H3) {
            // |center|^2 == radius^2 + 1
            float target = r * r + 1.0f;
            float tol = kObjectEps * mhMax(1.0f, target);
            if (mhAbs(c2 - target) > tol) return 3;
        } else {
            // |center|^2 == radius^2 - 1
            float target = r * r - 1.0f;
            float tol = kObjectEps * mhMax(1.0f, r * r);
            if (target < 0.0f || mhAbs(c2 - target) > tol) return 3;
        }
        return 0;
    }

    // GEO_OBJECT_PLANE: unit normal through the origin.
    float normalLen = length(o.center);
    if (mhAbs(normalLen - 1.0f) > kObjectEps) return 3;
    if (mhAbs(o.radiusOrOffset) > kPlaneOffsetEps) return 3;
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
        vec3 p = diff.apply(s);
        if (!finiteVec(p)) return false;
        if (length(p - s) > tol) return false;
    }
    return true;
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

    // ---- object validation (authoring chart coordinates) ----
    for (const auto& o : objects_) {
        int code = validateObjectBasics(o, materialCount);
        if (code != 0) { setError(code); return code; }
        code = validateObjectModel(o);
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
        vec3 center;
        float radiusOrOffset;
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

    auto validFlatPrimitive = [](bool op, const vec3& c, float r) {
        if (!finiteVec(c) || !finiteFloat(r)) return false;
        if (op) {
            if (mhAbs(length(c) - 1.0f) > 1e-3f) return false;
            if (mhAbs(r) > 1e-3f) return false;
        } else {
            if (r <= 0.0f) return false;
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

            if (copyDirect) {
                flat.push_back({o.kind, o.center, o.radiusOrOffset, o.colorIdx});
                continue;
            }

            vec3 oc;
            float orr = 0.0f;
            bool op = false;

            if (o.kind == GEO_OBJECT_PLANE) {
                toCam.applyPlane(o.center, o.radiusOrOffset, oc, orr, op);
                if (op) {
                    // A valid mirror plane stays a plane only when it passes
                    // through the camera-chart origin; clamp tiny drift to 0.
                    if (mhAbs(orr) <= 1e-3f) orr = 0.0f;
                    if (!validFlatPrimitive(true, oc, orr)) { setError(3); return 3; }
                    flat.push_back({GEO_OBJECT_PLANE, oc, orr, o.colorIdx});
                } else {
                    if (!validFlatPrimitive(false, oc, orr)) { setError(3); return 3; }
                    flat.push_back({GEO_OBJECT_MIRROR, oc, orr, o.colorIdx});
                }
            } else {
                toCam.applySphere(o.center, o.radiusOrOffset, oc, orr, op);
                if (op) {
                    if (o.kind == GEO_OBJECT_MIRROR) {
                        if (mhAbs(orr) <= 1e-3f) orr = 0.0f;
                        if (!validFlatPrimitive(true, oc, orr)) { setError(3); return 3; }
                        flat.push_back({GEO_OBJECT_PLANE, oc, orr, o.colorIdx});
                    } else {
                        // An OPAQUE sphere flattened to a plane would be an
                        // OPAQUE half-space, which the v2 packet cannot express.
                        setError(3);
                        return 3;
                    }
                } else {
                    if (!validFlatPrimitive(false, oc, orr)) { setError(3); return 3; }
                    flat.push_back({o.kind, oc, orr, o.colorIdx});
                }
            }
        }
    }

    // Canonical object order so the packet is deterministic and independent of
    // authoring order / BFS traversal order.
    std::sort(flat.begin(), flat.end(), [](const FlatObject& a, const FlatObject& b) {
        if (a.kind != b.kind) return a.kind < b.kind;
        if (a.colorIdx != b.colorIdx) return a.colorIdx < b.colorIdx;
        if (a.center.x != b.center.x) return a.center.x < b.center.x;
        if (a.center.y != b.center.y) return a.center.y < b.center.y;
        if (a.center.z != b.center.z) return a.center.z < b.center.z;
        return a.radiusOrOffset < b.radiusOrOffset;
    });

    const int flatCount = static_cast<int>(flat.size());
    if (flatCount > GEO_MAX_OBJECTS) { setError(5); return 5; }

    // ---- emit ScenePacket bytes ----
    const size_t headerSize = sizeof(ScenePacketHeader);
    const size_t totalSize = headerSize + sizeof(Object) * flatCount + sizeof(Material) * materialCount;
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
    hdr.camera.pad0 = 0.0f;
    hdr.camera.pad1 = 0.0f;
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
    hdr.counts.pad0 = 0;
    hdr.counts.pad1 = 0;

    std::memcpy(packet_.data(), &hdr, headerSize);
    size_t off = headerSize;

    for (const auto& f : flat) {
        Object obj{};
        obj.center = f.center;
        obj.radiusOrOffset = f.radiusOrOffset;
        obj.kind = f.kind;
        obj.colorIdx = f.colorIdx;
        obj.pad0 = 0;
        obj.pad1 = 0;
        std::memcpy(packet_.data() + off, &obj, sizeof(obj));
        off += sizeof(obj);
    }

    for (int i = 0; i < materialCount; ++i) {
        Material mat;
        if (i < authoredMaterialCount) mat.color = materials_[i];
        else mat.color = vec4(1.0f, 1.0f, 1.0f, 1.0f);   // default white
        std::memcpy(packet_.data() + off, &mat, sizeof(mat));
        off += sizeof(mat);
    }

    setError(0);
    return 0;
}

} // namespace geo
