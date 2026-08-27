#include "ChartInternal.h"

#include <algorithm>
#include <cmath>
#include <queue>

// Validation and GPU packet emission.
namespace geo {
using namespace chart_detail;

int Atlas::chartTransformsTo(int camera, std::vector<Isometry> &out) const {
  out.resize(charts_.size());
  std::vector<char> seen(charts_.size(), 0);
  out[camera].kind = kind();
  out[camera].m = mat4Identity();
  seen[camera] = 1;
  std::queue<int> q;
  q.push(camera);
  while (!q.empty()) {
    int cur = q.front();
    q.pop();
    for (const auto &e : charts_[cur].edges) {
      Isometry neighborToCur = e.toNeighbor.inverse();
      Isometry candidate = out[cur].compose(neighborToCur);
      if (!seen[e.neighborId]) {
        out[e.neighborId] = candidate;
        seen[e.neighborId] = 1;
        q.push(e.neighborId);
      } else if (!matrixClose(out[e.neighborId].m, candidate.m))
        return 2;
    }
  }
  for (char s : seen)
    if (!s)
      return 1;
  return 0;
}

bool Atlas::validateScene() const {
  if (!validModelKind() || charts_.empty() ||
      objects_.size() > GEO_MAX_OBJECTS ||
      clips_.size() > GEO_MAX_CLIPS || materials_.size() > GEO_MAX_MATERIALS ||
      lights_.size() > GEO_MAX_LIGHTS)
    return false;
  for (const auto &o : objects_) {
    if (o.colorIdx < 0 || o.colorIdx >= int(materials_.size()) ||
        (o.equationKind != GEO_EQUATION_LINEAR &&
         o.equationKind != GEO_EQUATION_R3_SPHERE &&
         o.equationKind != GEO_EQUATION_QUADRIC) ||
        o.clipIds.size() > GEO_MAX_CLIPS_PER_OBJECT)
      return false;
    for (int clipId : o.clipIds)
      if (clipId < 0 || clipId >= int(clips_.size()))
        return false;
  }
  for (const auto &clip : clips_) {
    if (clip.kind == GEO_CLIP_LINEAR)
      continue;
    if (clip.kind != GEO_CLIP_QUADRIC ||
        (clip.keepPositive != 0 && clip.keepPositive != 1) ||
        !finite(clip.quadric) || matrixScale(clip.quadric) == 0)
      return false;
  }
  for (const auto &p : portals_)
    if (!p.toNeighbor.validate() || !validChartId(p.neighborId) ||
        p.reversePortal < 0 || p.reversePortal >= int(portals_.size()))
      return false;
  return true;
}

int Atlas::emit(bool flatten, int cameraChart, int depth, int hops,
                int lightHops, int lightStates) {
  packet_.clear();
  if (!validChartId(cameraChart)) {
    setError(4);
    return 4;
  }
  if (!validateScene()) {
    setError(3);
    return 3;
  }
  if (depth <= 0 || depth > GEO_MAX_CHART_DEPTH) {
    setError(5);
    return 5;
  }
  if (!flatten && (hops <= 0 || hops > 128 || lightHops < 0 || lightHops > 4 ||
                   lightStates <= 0 || lightStates > 256)) {
    setError(8);
    return 8;
  }
  if (!flatten) {
    std::vector<char> seen(charts_.size(), 0);
    std::queue<int> q;
    seen[cameraChart] = 1;
    q.push(cameraChart);
    while (!q.empty()) {
      int c = q.front();
      q.pop();
      for (const auto &e : charts_[c].edges)
        if (!seen[e.neighborId]) {
          seen[e.neighborId] = 1;
          q.push(e.neighborId);
        }
      for (int id : charts_[c].portalIds) {
        int n = portals_[id].neighborId;
        if (!seen[n]) {
          seen[n] = 1;
          q.push(n);
        }
      }
    }
    for (char s : seen)
      if (!s) {
        setError(1);
        return 1;
      }
  }
  std::vector<Isometry> toCamera;
  if (flatten) {
    int transitionError = chartTransformsTo(cameraChart, toCamera);
    if (transitionError) {
      setError(transitionError);
      return transitionError;
    }
  }
  std::vector<GPUChart> gpuCharts;
  std::vector<GPUPortal> gpuPortals;
  std::vector<Object> gpuObjects;
  std::vector<Quadric> gpuQuadrics;
  std::vector<PrimitiveClip> gpuClips;
  std::vector<PointLight> gpuLights;
  Isometry recenter = movePointToOrigin(cameraPosition_);
  Isometry localIdentity;
  localIdentity.kind = kind();
  localIdentity.m = mat4Identity();

  auto appendObject = [&](const ChartObject &o, const Isometry &transform,
                          bool developed) {
    Object x{};
    x.equationKind = o.equationKind;
    x.colorIdx = o.colorIdx;
    x.quadricIndex = -1;
    if (o.equationKind == GEO_EQUATION_LINEAR) {
      x.parameter = o.parameter;
      x.geometry = developed
                       ? transformPlane(transform, o.geometry, x.parameter,
                                        modelKind_)
                       : o.geometry;
    } else if (o.equationKind == GEO_EQUATION_R3_SPHERE) {
      x.geometry = developed ? transform.applyPoint(o.geometry) : o.geometry;
      x.parameter = o.parameter;
    } else {
      x.quadricIndex = int(gpuQuadrics.size());
      gpuQuadrics.push_back(
          Quadric{developed ? transformQuadric(transform, o.quadric)
                            : o.quadric});
    }

    x.firstClip = int(gpuClips.size());
    for (int clipId : o.clipIds) {
      const auto &clip = clips_[clipId];
      PrimitiveClip emitted{};
      emitted.kind = clip.kind;
      if (clip.kind == GEO_CLIP_QUADRIC) {
        emitted.pad0 = int(gpuQuadrics.size());
        emitted.pad1 = clip.keepPositive;
        gpuQuadrics.push_back(
            Quadric{developed ? transformQuadric(transform, clip.quadric)
                              : clip.quadric});
      } else {
        emitted.parameter = clip.offset;
        emitted.geometry = developed
                               ? transformPlane(transform, clip.normal,
                                                emitted.parameter, modelKind_)
                               : clip.normal;
      }
      gpuClips.push_back(emitted);
    }
    if (developed && o.needsChartBound) {
      PrimitiveClip bound{};
      bound.kind = GEO_CLIP_BALL;
      bound.geometry = transform.applyPoint(vec4(0, 0, 0, 1));
      float radius = charts_[o.chartId].radius;
      bound.parameter = modelKind_ == GEO_MODEL_S3 ? std::cos(radius)
                        : modelKind_ == GEO_MODEL_H3
                            ? -std::cosh(radius)
                            : radius;
      gpuClips.push_back(bound);
    }
    x.clipCount = int(gpuClips.size()) - x.firstClip;
    gpuObjects.push_back(x);
  };

  if (flatten) {
    GPUChart c{};
    c.intrinsicRadius = cameraViewDistance_;
    c.tracingParameter = tracingParameter(cameraViewDistance_);
    c.objectCount = int(objects_.size());
    c.lightCount = int(lights_.size());
    gpuCharts.push_back(c);
    for (const auto &o : objects_) {
      Isometry m = recenter.compose(toCamera[o.chartId]);
      appendObject(o, m, true);
    }
    for (const auto &l : lights_) {
      Isometry m = recenter.compose(toCamera[l.chartId]);
      gpuLights.push_back(
          PointLight{m.applyPoint(l.position), l.color, l.intensity,
                     l.radius, l.kind, 0, 0});
    }
  } else {
    std::vector<int> portalRemap(portals_.size(), -1);
    int nextPortal = 0;
    for (const auto &c : charts_)
      for (int id : c.portalIds)
        portalRemap[id] = nextPortal++;
    for (const auto &c : charts_) {
      GPUChart g{};
      g.intrinsicRadius = c.radius;
      g.tracingParameter = tracingParameter(c.radius);
      g.firstPortal = int(gpuPortals.size());
      g.portalCount = int(c.portalIds.size());
      g.firstObject = int(gpuObjects.size());
      g.objectCount = int(c.objectIds.size());
      g.firstLight = int(gpuLights.size());
      g.lightCount = int(c.lightIds.size());
      for (int id : c.portalIds) {
        const auto &p = portals_[id];
        GPUPortal x{};
        x.toNeighbor = p.toNeighbor.m;
        x.normal = p.normal;
        x.offset = p.offset;
        x.neighborChart = p.neighborId;
        x.reversePortal = portalRemap[p.reversePortal];
        gpuPortals.push_back(x);
      }
      for (int id : c.objectIds) {
        appendObject(objects_[id], localIdentity, false);
      }
      for (int id : c.lightIds) {
        const auto &l = lights_[id];
        gpuLights.push_back(PointLight{l.position, l.color, l.intensity,
                                       l.radius, l.kind, 0, 0});
      }
      gpuCharts.push_back(g);
    }
  }
  if (gpuQuadrics.size() > GEO_MAX_QUADRICS ||
      gpuClips.size() > GEO_MAX_CLIPS) {
    packet_.clear();
    setError(3);
    return 3;
  }
  ScenePacketHeader h{};
  h.meta = {GEO_PACKET_MAGIC, GEO_CONTRACT_VERSION, int(sizeof(Object)),
            int(sizeof(ScenePacketHeader))};
  h.camera.position = flatten ? vec4(0, 0, 0, 1) : cameraPosition_;
  h.camera.fovTan = fovTan_;
  h.camera.aspect = aspect_;
  h.camera.maxTraceDistance = cameraViewDistance_;
  h.camera.maxTraceParameter = tracingParameter(cameraViewDistance_);
  h.camera.chartId = flatten ? 0 : cameraChart;
  if (flatten) {
    h.camera.right = vec4(cameraRight_, 0);
    h.camera.up = vec4(cameraUp_, 0);
    h.camera.fwd = vec4(cameraFwd_, 0);
  } else {
    Isometry inv = recenter.inverse();
    h.camera.right = inv.applyTangent(vec4(cameraRight_, 0));
    h.camera.up = inv.applyTangent(vec4(cameraUp_, 0));
    h.camera.fwd = inv.applyTangent(vec4(cameraFwd_, 0));
  }
  h.controls = {maxBounces_,
                modelKind_,
                falloffK_,
                ambient_,
                0,
                fogMode_,
                fogStartFraction_,
                fogDensity_,
                flatten ? 1 : hops,
                flatten ? 0 : lightHops,
                flatten ? 1 : lightStates,
                0};
  h.counts = {int(gpuCharts.size()),
              int(gpuPortals.size()),
              int(gpuObjects.size()),
              int(materials_.size()),
              int(gpuLights.size()),
              int(gpuQuadrics.size()),
              int(gpuClips.size()),
              0};
  append(packet_, h);
  appendMany(packet_, gpuCharts);
  appendMany(packet_, gpuPortals);
  appendMany(packet_, gpuObjects);
  appendMany(packet_, gpuQuadrics);
  appendMany(packet_, gpuClips);
  appendMany(packet_, materials_);
  appendMany(packet_, gpuLights);
  setError(0);
  return 0;
}

int Atlas::build(int camera, int depth) {
  return emit(true, camera, depth, 1, 0, 1);
}
int Atlas::buildAtlas(int camera, int hops, int lightHops, int lightStates) {
  return emit(false, camera, GEO_MAX_CHART_DEPTH, hops, lightHops, lightStates);
}

} // namespace geo
