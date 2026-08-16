#pragma once
// Host-only intrinsic chart atlas (CONTRACT.md §3).  Uses std containers freely;
// this header is never included by Metal shaders.
#include "GeometryCore/Mobius.h"
#include "GeometryCore/Scene.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// Swift C++ interop annotation for pointer-returning helper methods.
#ifndef SWIFT_RETURNS_INDEPENDENT_VALUE
#if defined(__has_attribute)
#if __has_attribute(swift_attr)
#define SWIFT_RETURNS_INDEPENDENT_VALUE __attribute__((swift_attr("import_unsafe")))
#else
#define SWIFT_RETURNS_INDEPENDENT_VALUE
#endif
#else
#define SWIFT_RETURNS_INDEPENDENT_VALUE
#endif
#endif

namespace geo {

// Temporary Xcode integration smoke-test helper.
inline std::string geometryCoreName() { return "Geometry Core"; }

struct ChartObject {
    int chartId = -1;
    int kind = GEO_OBJECT_OPAQUE;      // GEO_OBJECT_OPAQUE / GEO_OBJECT_MIRROR
    vec3 a;                            // hyperplane normal part
    float b = 0.0f;                    // hyperplane w coefficient
    float c = 0.0f;                    // hyperplane right-hand side
    int colorIdx = 0;
};

struct ChartLight {
    int chartId = -1;
    vec3 position;                     // chart-space point light position
    vec3 color;                        // linear light color
    float intensity = 1.0f;
};

struct ChartEdge {
    int neighborId = -1;
    Mobius toNeighbor;                 // maps a point from this chart to neighbor chart
    bool safe = true;                  // one hop keeps float32 distortion bounded
};

struct Chart {
    int id = -1;
    float radius = 1.0f;               // geodesic disk radius, radians
    std::vector<ChartEdge> edges;
    std::vector<int> objectIds;
    std::vector<int> lightIds;
};

class Atlas {
public:
    Atlas();

    void begin(int modelKind);         // 0 = H3, 1 = S3; resets the atlas
    // Swift C++ interop treats a method named `begin` as a C++ iterator and
    // hides it; `start` is the Swift-visible alias for begin.
    void start(int modelKind) { begin(modelKind); }
    int seed(float radius);            // anchorless base chart; returns 0
    int addChart(float radius, int fromChart, const float m[16], bool safe);   // returns new chart id
    void linkCharts(int a, int b, const float m_ab[16], bool safe);

    // Shorter aliases.
    int add(float radius, int fromChart, const float m[16], bool safe) { return addChart(radius, fromChart, m, safe); }
    void link(int a, int b, const float m_ab[16], bool safe) { linkCharts(a, b, m_ab, safe); }
    int addObject(int chartId, int kind, const vec3& a, float b, float c, int colorIdx);
    int addMaterial(const vec4& color);
    int addLight(int chartId, const vec3& position, const vec3& color, float intensity);
    void setCamera(float fovTan, float aspect, const vec3& right, const vec3& up, const vec3& fwd);
    void setControls(int maxBounces, float falloffK, float ambient, float bounceAttenuation);

    // Rotate the camera frame around an arbitrary chart-space axis by
    // deltaRadians. The camera remains at the chart origin; this only changes
    // the right/up/fwd orientation used by the next build().
    void cameraRotate(const vec3& axis, float deltaRadians);

    // Validate and flatten.  Returns 0, or CONTRACT.md §6 error code:
    // 1 island chart, 2 cocycle violation, 3 invalid object, 4 unknown camera chart,
    // 5 capacity exceeded, 6 model/kind mismatch.
    int build(int cameraChart, int maxChartDepth);

    const std::vector<uint8_t>& packet() const { return packet_; }
    // Swift-friendly packet access: Swift C++ interop hides methods returning
    // interior pointers or references unless annotated, and can import
    // std::vector by value.
    std::vector<uint8_t> packetBytes() const { return packet_; }
    const void* packetData() const SWIFT_RETURNS_INDEPENDENT_VALUE { return packet_.data(); }
    std::size_t packetSize() const { return packet_.size(); }
    int lastError() const { return lastError_; }
    int modelKind() const { return modelKind_; }

private:
    int modelKind_ = GEO_MODEL_H3;
    std::vector<Chart> charts_;
    std::vector<ChartObject> objects_;
    std::vector<ChartLight> lights_;
    std::vector<vec4> materials_;
    vec3 cameraRight_ = vec3(1, 0, 0);
    vec3 cameraUp_ = vec3(0, 1, 0);
    vec3 cameraFwd_ = vec3(0, 0, 1);
    float fovTan_ = 1.0f;
    float aspect_ = 1.0f;
    int maxBounces_ = 4;
    float falloffK_ = 0.0f;
    float ambient_ = 0.0f;
    float bounceAttenuation_ = 1.0f;
    std::vector<uint8_t> packet_;
    int lastError_ = 0;
    bool capacityExceeded_ = false;

    void setError(int code) { lastError_ = code; }
    void clearPacket() { packet_.clear(); }
    void resetToDefaults();

    bool validChartId(int id) const { return id >= 0 && id < static_cast<int>(charts_.size()); }
    bool validModelKind() const { return modelKind_ == GEO_MODEL_H3 || modelKind_ == GEO_MODEL_S3; }
    bool validChartRadius(float r) const;
    Mobius identityMobius() const;
    Mobius mobiusFromMatrix(const float m[16]) const;

    void upsertEdge(int a, int b, const Mobius& m_ab, bool safe);
    int validateObjectBasics(const ChartObject& o, int materialCount) const;
    int validateObjectModel(const ChartObject& o) const;
    int validateLight(const ChartLight& light) const;

    struct UEdge {
        int a;
        int b;
        Mobius ab;   // maps a -> b, always a < b
    };
    std::vector<UEdge> buildUndirectedEdges() const;
    static Mobius edgeTransition(int from, int to, const UEdge& e);
    bool mobiusClose(const Mobius& a, const Mobius& b, float tol) const;
};

} // namespace geo
