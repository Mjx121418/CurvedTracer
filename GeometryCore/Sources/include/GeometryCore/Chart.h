#pragma once
#include "GeometryCore/AtlasScene.h"
#include "GeometryCore/Geodesic.h"
#include "GeometryCore/Isometry.h"
#include "GeometryCore/Scene.h"
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#ifndef SWIFT_RETURNS_INDEPENDENT_VALUE
#if defined(__has_attribute) && __has_attribute(swift_attr)
#define SWIFT_RETURNS_INDEPENDENT_VALUE                                        \
  __attribute__((swift_attr("import_unsafe")))
#else
#define SWIFT_RETURNS_INDEPENDENT_VALUE
#endif
#endif

namespace geo {

inline std::string geometryCoreName() { return "Geometry Core v16"; }

struct ChartObject {
  int chartId = -1;
  int equationKind = GEO_EQUATION_LINEAR;
  vec4 geometry;
  float parameter = 0.0f;
  mat4 quadric;
  int colorIdx = 0;
  std::vector<int> clipIds;
};

struct ChartClip {
  vec4 normal;
  float offset = 0.0f;
  int kind = GEO_CLIP_LINEAR;
  int keepPositive = 0;
  mat4 quadric;
};

struct ChartLight {
  int chartId = -1;
  vec4 position;
  vec3 color;
  float intensity = 1.0f;
  float radius = 0.0f;
  int kind = GEO_LIGHT_POINT;
};

struct CameraPlacement {
  int chartId = -1;
  vec4 localPosition;
};

struct ChartEdge {
  int neighborId = -1;
  Isometry toNeighbor;
  bool safe = true;
};

struct Chart {
  int id = -1;
  std::vector<ChartEdge> edges;
  std::vector<int> objectIds;
  std::vector<int> lightIds;
  std::vector<int> portalIds;
};

struct ChartPortal {
  int chartId = -1;
  int neighborId = -1;
  int equationKind = GEO_EQUATION_LINEAR;
  vec4 normal;
  float offset = 0.0f;
  mat4 quadric;
  std::vector<int> clipIds;
  // Camera and ray crossings use toNeighbor directly. The reverse index is
  // retained only for bounded GPU light-lift traversal, which needs the
  // incoming portal and the inverse coordinate map without inverting a matrix.
  int reversePortal = -1;
  Isometry toNeighbor;
};

class Atlas {
public:
  Atlas();
  void begin(int modelKind);
  void start(int modelKind) { begin(modelKind); }

  int seed();
  int addChart(int fromChart, const float m[16], bool safe);
  void linkCharts(int a, int b, const float m_ab[16], bool safe);
  int add(int from, const float m[16], bool safe) {
    return addChart(from, m, safe);
  }
  void link(int a, int b, const float m[16], bool safe) {
    linkCharts(a, b, m, safe);
  }

  vec4 pointFromOriginTangent(const vec3 &tangent) const;
  float intrinsicDistance(const vec4 &a, const vec4 &b) const;

  int addBall(int chart, const vec4 &center, float intrinsicRadius,
              int material);
  int addBallSurface(int chart, const vec4 &center, float intrinsicRadius,
                     int material);
  int addLinearSurface(int chart, const vec4 &normal, float offset,
                       int material);
  int addPlane(int chart, const vec3 &outwardDirection, float signedDistance,
               int material);
  int addQuadric(int chart, const float coefficients[16], int material);
  int addCliffordTorus(int chart, int material);
  int addObjectClip(int object, const vec4 &normal, float offset);
  int addObjectClipPlane(int object, const vec3 &outwardDirection,
                         float signedDistance);
  int addObjectClipQuadric(int object, const float coefficients[16],
                           bool keepPositive);
  int addLight(int chart, const vec4 &position, const vec3 &color,
               float intensity);
  int addSphericalAreaLight(int chart, const vec4 &center,
                            float intrinsicRadius, const vec3 &color,
                            float emittedRadiance);
  int addPortalPair(int chartA, const vec3 &outwardA, float faceDistanceA,
                    int chartB, const vec3 &outwardB, float faceDistanceB,
                    const float pairingAB[16]);
  int addPortalPairWithCollar(
      int chartA, const vec3 &outwardA, float faceDistanceA, int chartB,
      const vec3 &outwardB, float faceDistanceB, const float pairingAB[16],
      float triggerCollar);
  int addGeodesicBallPortal(int exteriorChart, int interiorChart,
                            const vec4 &interiorCenter, float radius,
                            const float exteriorToInterior[16],
                            float triggerCollar);
  int addCappedTubePortal(int exteriorChart, int interiorChart,
                          const vec3 &axis, float radius,
                          float lowerAxialDistance,
                          float upperAxialDistance,
                          const float exteriorToInterior[16],
                          float triggerCollar);
  int addMaterial(const vec4 &baseColor, float roughness, float metallic,
                  float ior, float transmission, const vec3 &emission);

  void setCamera(float fovTan, float aspect, const vec3 &right, const vec3 &up,
                 const vec3 &fwd);
  void setControls(int maxBounces, float falloffK, float ambient);
  void setControls(int maxBounces, float falloffK, float ambient, float fogMode,
                   float fogStartFraction, float fogDensity);
  void cameraRotate(const vec3 &axis, float radians);
  void cameraRoll(float radians);
  vec3 cameraRight() const { return cameraRight_; }
  vec3 cameraUp() const { return cameraUp_; }
  vec3 cameraFwd() const { return cameraFwd_; }

  CameraPlacement resolveCameraPlacement(int startChart, const vec4 &startLocal,
                                         const vec3 &movement) const;
  int cameraChartAt(int chart, const vec4 &position, float viewDistance);
  int cameraMove(const vec3 &movement);
  int cameraChartId() const { return cameraChartId_; }

  int build(int cameraChart, int maxChartDepth);
  int buildAtlas(int cameraChart, int maxChartHops, int maxLightHops,
                 int maxLightStates);
  int portalCount() const { return int(portals_.size()); }
  const std::vector<uint8_t> &packet() const { return packet_; }
  std::vector<uint8_t> packetBytes() const { return packet_; }
  const void *packetData() const SWIFT_RETURNS_INDEPENDENT_VALUE {
    return packet_.data();
  }
  std::size_t packetSize() const { return packet_.size(); }
  int lastError() const { return lastError_; }
  int modelKind() const { return modelKind_; }

private:
  int modelKind_ = GEO_MODEL_H3;
  std::vector<Chart> charts_;
  std::vector<ChartObject> objects_;
  std::vector<ChartClip> clips_;
  std::vector<ChartLight> lights_;
  std::vector<ChartPortal> portals_;
  std::vector<Material> materials_;
  int cameraChartId_ = -1;
  vec4 cameraPosition_ = vec4(0, 0, 0, 1);
  float cameraViewDistance_ = 1.0f;
  vec3 cameraRight_ = vec3(1, 0, 0);
  vec3 cameraUp_ = vec3(0, 1, 0);
  vec3 cameraFwd_ = vec3(0, 0, 1);
  float fovTan_ = 1.0f;
  float aspect_ = 1.0f;
  int maxBounces_ = 4;
  float falloffK_ = 0.0f;
  float ambient_ = 0.0f;
  float fogMode_ = 0.0f;
  float fogStartFraction_ = 0.0f;
  float fogDensity_ = 0.0f;
  std::vector<uint8_t> packet_;
  int lastError_ = 0;

  bool validModelKind() const;
  bool validChartId(int id) const {
    return id >= 0 && id < int(charts_.size());
  }
  bool validGeodesicRadius(float radius) const;
  bool validSignedDistance(float distance) const;
  bool validPortalDistance(float distance) const;
  bool validViewDistance(float distance) const;
  ModelKind kind() const { return static_cast<ModelKind>(modelKind_); }
  Isometry isometryFrom(const float m[16]) const;
  bool canonicalizePoint(const vec4 &in, vec4 &out) const;
  vec4 planeNormal(const vec3 &outward, float distance) const;
  bool normalizedLinearForm(const vec4 &normal, float offset,
                            vec4 &normalized, float &normalizedOffset) const;
  bool normalizedQuadric(const float coefficients[16], mat4 &normalized) const;
  bool insideClip(const ChartClip &clip, const vec4 &point) const;
  bool insidePortalClips(const ChartPortal &portal,
                         const vec4 &point) const;
  float portalRoot(const ChartPortal &portal, const Geodesic &geodesic,
                   float maximum) const;
  bool moveThroughPortals(int &chart, Geodesic &geodesic, float distance,
                          vec4 *right, vec4 *up, vec4 *forward) const;
  Isometry movePointToOrigin(const vec4 &p) const;
  vec4 parallelTransportAlong(const Geodesic &geodesic, float distance,
                              const vec4 &tangent) const;
  void reset();
  void setError(int e) { lastError_ = e; }
  void upsertEdge(int a, int b, const Isometry &m, bool safe);
  int chartTransformsTo(int camera, std::vector<Isometry> &transforms) const;
  bool validateScene() const;
  int emit(bool flatten, int cameraChart, int maxChartDepth, int maxChartHops,
           int maxLightHops, int maxLightStates);
};

} // namespace geo
