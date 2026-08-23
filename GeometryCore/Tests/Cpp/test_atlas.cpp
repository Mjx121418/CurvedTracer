#include "GeometryCore/Chart.h"
#include "test_framework.h"
#include <cstring>
using namespace geo;

static void identity(float m[16]) {
  for (int i = 0; i < 16; ++i)
    m[i] = 0;
  m[0] = m[5] = m[10] = m[15] = 1;
}
static ScenePacketHeader header(const Atlas &a) {
  ScenePacketHeader h{};
  std::memcpy(&h, a.packet().data(), sizeof(h));
  return h;
}
static Object flatObject(const Atlas &a, int index) {
  Object o{};
  std::memcpy(&o,
              a.packet().data() + sizeof(ScenePacketHeader) + sizeof(GPUChart) +
                  index * sizeof(Object),
              sizeof(o));
  return o;
}
static GPUPortal atlasPortal(const Atlas &a, int index) {
  GPUPortal portal{};
  std::memcpy(&portal,
              a.packet().data() + sizeof(ScenePacketHeader) + sizeof(GPUChart) +
                  index * sizeof(GPUPortal),
              sizeof(portal));
  return portal;
}

void test_atlas() {
  CHECK(GEO_CONTRACT_VERSION == 10);
  CHECK(sizeof(ScenePacketHeader) == 192);
  CHECK(sizeof(Object) == 32);
  CHECK(sizeof(GPUPortal) == 96);
  for (int model = 0; model <= 2; ++model) {
    Atlas a;
    a.start(model);
    CHECK(a.seed(model == GEO_MODEL_S3 ? 2.0f : 3.0f) == 0);
    vec4 p = a.pointFromOriginTangent(vec3(.3f, -.2f, .1f));
    CHECK_NEAR(a.intrinsicDistance(vec4(0, 0, 0, 1), p), sqrt(.14f), 2e-4);
    CameraPlacement moved =
        a.resolveCameraPlacement(0, vec4(0, 0, 0, 1), vec3(.4f, 0, 0));
    CHECK(moved.chartId == 0);
    CHECK_NEAR(a.intrinsicDistance(vec4(0, 0, 0, 1), moved.localPosition), .4f,
               2e-4);
    CHECK(a.addMaterial(vec4(1, 0, 0, 1), vec4(.2f, .2f, .2f, 1)) == 0);
    CHECK(a.addBall(0, p, .2f, 0) == 0);
    CHECK(a.addMirrorPlane(0, vec3(0, 2, 0), .8f, 0) == 1);
    CHECK(a.addLight(0, a.pointFromOriginTangent(vec3(-.2f, 0, 0)),
                     vec3(1, 1, 1), 1) == 0);
    a.setCamera(.8f, 1.6f, vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1));
    CHECK(a.cameraChartAt(0, vec4(0, 0, 0, 1), 2.5f) == 0);
    CHECK(a.build(0, 64) == 0);
    auto h = header(a);
    CHECK(h.meta.magic == GEO_PACKET_MAGIC);
    CHECK(h.meta.contractVersion == 10);
    CHECK(h.meta.packetHeaderSize == 192);
    CHECK(h.controls.modelKind == model);
    CHECK(h.counts.chartCount == 1);
    CHECK(h.counts.portalCount == 0);
    CHECK(h.counts.objectCount == 2);
    Object ball = flatObject(a, 0), plane = flatObject(a, 1);
    CHECK(ball.kind == GEO_OBJECT_OPAQUE);
    CHECK(plane.kind == GEO_OBJECT_MIRROR);
    CHECK_NEAR(ball.parameter,
               model == GEO_MODEL_S3   ? cos(.2f)
               : model == GEO_MODEL_H3 ? -cosh(.2f)
                                       : .2f,
               2e-5);
    CHECK_NEAR(plane.geometry.y,
               model == GEO_MODEL_H3   ? cosh(.8f)
               : model == GEO_MODEL_S3 ? cos(.8f)
                                       : 1.0f,
               2e-5);
    CHECK_NEAR(plane.geometry.w,
               model == GEO_MODEL_H3   ? sinh(.8f)
               : model == GEO_MODEL_S3 ? -sin(.8f)
                                       : 0.0f,
               2e-5);
    CHECK_NEAR(plane.parameter, model == GEO_MODEL_R3 ? .8f : 0.0f, 2e-5);
    CHECK(a.buildAtlas(0, 32, 1, 16) == 0);
    h = header(a);
    CHECK(h.counts.chartCount == 1);
  }
  {
    Atlas a;
    a.start(GEO_MODEL_H3);
    CHECK(a.seed(4.0f) == 0);
    CHECK(a.pointFromOriginTangent(vec3(2, 0, 0)).w > 1);
  }
  {
    Atlas a;
    a.start(GEO_MODEL_H3);
    CHECK(a.seed(2) == 0);
    float m[16];
    identity(m);
    float c = cosh(1.2f), s = sinh(1.2f);
    m[0] = c;
    m[3] = s;
    m[12] = s;
    m[15] = c;
    CHECK(a.addPortalPair(0, vec3(-1, 0, 0), .6f, 0, vec3(1, 0, 0), .6f, m) >=
          0);
    CHECK(a.portalCount() == 2);
  }
  // Repeated forward steps follow the same geodesic as one combined step in
  // every model, even when the camera starts away from the chart origin.
  for (int model = GEO_MODEL_H3; model <= GEO_MODEL_R3; ++model) {
    auto configure = [model](Atlas &a) {
      a.start(model);
      CHECK(a.seed(model == GEO_MODEL_S3 ? 2.5f : 3.0f) == 0);
      a.setCamera(.8f, 1.6f, vec3(0, 0, 1), vec3(.6f, .8f, 0),
                  vec3(-.8f, .6f, 0));
      CHECK(a.cameraChartAt(0, a.pointFromOriginTangent(vec3(.35f, -.2f, .1f)),
                            2.0f) == 0);
    };

    Atlas singleStep, repeatedSteps;
    configure(singleStep);
    configure(repeatedSteps);
    CHECK(singleStep.cameraMove(singleStep.cameraFwd() * .4f) == 0);
    for (int step = 0; step < 40; ++step)
      CHECK(repeatedSteps.cameraMove(repeatedSteps.cameraFwd() * .01f) == 0);
    CHECK(singleStep.buildAtlas(0, 64, 1, 32) == 0);
    CHECK(repeatedSteps.buildAtlas(0, 64, 1, 32) == 0);
    auto one = header(singleStep), many = header(repeatedSteps);
    CHECK_NEAR(many.camera.position.x, one.camera.position.x, 2e-4);
    CHECK_NEAR(many.camera.position.y, one.camera.position.y, 2e-4);
    CHECK_NEAR(many.camera.position.z, one.camera.position.z, 2e-4);
    CHECK_NEAR(many.camera.position.w, one.camera.position.w, 2e-4);
    CHECK_NEAR(repeatedSteps.cameraFwd().x, singleStep.cameraFwd().x, 2e-4);
    CHECK_NEAR(repeatedSteps.cameraFwd().y, singleStep.cameraFwd().y, 2e-4);
    CHECK_NEAR(repeatedSteps.cameraFwd().z, singleStep.cameraFwd().z, 2e-4);
  }
  // Holding forward must agree with one geodesic step, including across an
  // H3 quotient face. This catches frame transport in a chart trivialization
  // instead of Levi-Civita parallel transport along the camera path.
  {
    auto configure = [](Atlas &a) {
      a.start(GEO_MODEL_H3);
      CHECK(a.seed(3) == 0);
      float boost[16];
      identity(boost);
      float c = cosh(1.2f), s = sinh(1.2f);
      boost[0] = c;
      boost[3] = s;
      boost[12] = s;
      boost[15] = c;
      CHECK(a.addPortalPair(0, vec3(-1, 0, 0), .6f, 0, vec3(1, 0, 0), .6f,
                            boost) >= 0);
      a.setCamera(.8f, 1.6f, vec3(0, 0, 1), vec3(.6f, .8f, 0),
                  vec3(-.8f, .6f, 0));
      CHECK(a.cameraChartAt(0, a.pointFromOriginTangent(vec3(-.59f, 0, 0)),
                            3) == 0);
    };

    Atlas singleStep, repeatedSteps;
    configure(singleStep);
    configure(repeatedSteps);
    CHECK(singleStep.cameraMove(singleStep.cameraFwd() * .5f) == 0);
    for (int step = 0; step < 50; ++step)
      CHECK(repeatedSteps.cameraMove(repeatedSteps.cameraFwd() * .01f) == 0);
    CHECK(singleStep.buildAtlas(0, 64, 1, 32) == 0);
    CHECK(repeatedSteps.buildAtlas(0, 64, 1, 32) == 0);
    auto one = header(singleStep), many = header(repeatedSteps);
    CHECK(one.camera.position.x > 0);
    CHECK_NEAR(many.camera.position.x, one.camera.position.x, 2e-4);
    CHECK_NEAR(many.camera.position.y, one.camera.position.y, 2e-4);
    CHECK_NEAR(many.camera.position.z, one.camera.position.z, 2e-4);
    CHECK_NEAR(many.camera.position.w, one.camera.position.w, 2e-4);
    CHECK_NEAR(repeatedSteps.cameraFwd().x, singleStep.cameraFwd().x, 2e-4);
    CHECK_NEAR(repeatedSteps.cameraFwd().y, singleStep.cameraFwd().y, 2e-4);
    CHECK_NEAR(repeatedSteps.cameraFwd().z, singleStep.cameraFwd().z, 2e-4);
  }
  {
    Atlas a;
    a.start(GEO_MODEL_S3);
    CHECK(a.seed(3.14159265f) < 0);
  }
  {
    Atlas a;
    a.start(GEO_MODEL_R3);
    CHECK(a.seed(2) == 0);
    CHECK(a.addMaterial(vec4(1, 1, 1, 1), vec4()) == 0);
    CHECK(a.addBall(0, vec4(1.9f, 0, 0, 1), .2f, 0) < 0);
    CHECK(a.addMirrorPlane(0, vec3(), 1, 0) < 0);
  }
  // One-chart Euclidean torus: six directed portals and translation closure.
  {
    Atlas a;
    a.start(GEO_MODEL_R3);
    CHECK(a.seed(2.0f) == 0);
    float tx[16], ty[16], tz[16];
    identity(tx);
    identity(ty);
    identity(tz);
    tx[12] = -2;
    ty[13] = -2;
    tz[14] = -2;
    CHECK(a.addPortalPair(0, vec3(1, 0, 0), 1, 0, vec3(-1, 0, 0), 1, tx) >= 0);
    CHECK(a.addPortalPair(0, vec3(0, 1, 0), 1, 0, vec3(0, -1, 0), 1, ty) >= 0);
    CHECK(a.addPortalPair(0, vec3(0, 0, 1), 1, 0, vec3(0, 0, -1), 1, tz) >= 0);
    CHECK(a.portalCount() == 6);
    CHECK(a.cameraChartAt(0, vec4(.99f, .99f, .99f, 1), 6) == 0);
    CHECK(a.cameraMove(vec3(.03f, .03f, .03f)) == 0);
    CHECK(a.buildAtlas(0, 64, 1, 32) == 0);
    auto h = header(a);
    CHECK(h.counts.portalCount == 6);
    CHECK_NEAR(atlasPortal(a, 0).offset, 1.01f, 1e-5);
    CHECK_NEAR(h.camera.position.x, -.98f, 3e-3);
    CHECK_NEAR(h.camera.position.y, -.98f, 3e-3);
    CHECK_NEAR(h.camera.position.z, -.98f, 3e-3);
  }
  // Camera reduction must not leave a point in the narrow interval outside a
  // portal but inside the general chart-containment tolerance.
  {
    Atlas a;
    a.start(GEO_MODEL_R3);
    CHECK(a.seed(2) == 0);
    float translation[16];
    identity(translation);
    translation[12] = -2;
    CHECK(a.addPortalPair(0, vec3(1, 0, 0), 1, 0, vec3(-1, 0, 0), 1,
                          translation) >= 0);
    vec4 start(1.0099f, 0, 0, 1);
    CameraPlacement resolved =
        a.resolveCameraPlacement(0, start, vec3(.0002f, 0, 0));
    CHECK_NEAR(resolved.localPosition.x, -.9899f, 2e-5);
    CHECK(a.cameraChartAt(0, start, 2) == 0);
    CHECK(a.cameraMove(vec3(.0002f, 0, 0)) == 0);
    CHECK(a.buildAtlas(0, 64, 1, 32) == 0);
    CHECK_NEAR(header(a).camera.position.x, -.9899f, 2e-5);
  }
  // Ordinary overlap cocycles remain checked; portal holonomy is not.
  {
    Atlas a;
    a.start(GEO_MODEL_R3);
    CHECK(a.seed(2) == 0);
    float I[16];
    identity(I);
    CHECK(a.add(2, 0, I, true) == 1);
    CHECK(a.add(2, 1, I, true) == 2);
    float t[16];
    identity(t);
    t[12] = 1;
    a.link(0, 2, t, true);
    CHECK(a.cameraChartAt(0, vec4(0, 0, 0, 1), 1) == 0);
    CHECK(a.build(0, 64) == 2);
  }
}
