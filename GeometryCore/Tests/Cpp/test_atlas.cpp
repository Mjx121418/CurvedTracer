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
static Quadric flatQuadric(const Atlas &a, int index) {
  ScenePacketHeader h = header(a);
  Quadric quadric{};
  std::memcpy(&quadric,
              a.packet().data() + sizeof(ScenePacketHeader) + sizeof(GPUChart) +
                  h.counts.objectCount * sizeof(Object) +
                  index * sizeof(Quadric),
              sizeof(quadric));
  return quadric;
}
static PrimitiveClip flatClip(const Atlas &a, int index) {
  ScenePacketHeader h = header(a);
  PrimitiveClip clip{};
  std::memcpy(&clip,
              a.packet().data() + sizeof(ScenePacketHeader) + sizeof(GPUChart) +
                  h.counts.objectCount * sizeof(Object) +
                  h.counts.quadricCount * sizeof(Quadric) +
                  index * sizeof(PrimitiveClip),
              sizeof(clip));
  return clip;
}

void test_atlas() {
  CHECK(GEO_CONTRACT_VERSION == 11);
  CHECK(sizeof(ScenePacketHeader) == 192);
  CHECK(sizeof(Object) == 48);
  CHECK(sizeof(Quadric) == 64);
  CHECK(sizeof(PrimitiveClip) == 32);
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
    CHECK(h.meta.contractVersion == 11);
    CHECK(h.meta.packetHeaderSize == 192);
    CHECK(h.controls.modelKind == model);
    CHECK(h.counts.chartCount == 1);
    CHECK(h.counts.portalCount == 0);
    CHECK(h.counts.objectCount == 2);
    Object ball = flatObject(a, 0), plane = flatObject(a, 1);
    CHECK(ball.responseKind == GEO_RESPONSE_OPAQUE);
    CHECK(plane.responseKind == GEO_RESPONSE_MIRROR);
    CHECK(ball.equationKind ==
          (model == GEO_MODEL_R3 ? GEO_EQUATION_R3_SPHERE
                                 : GEO_EQUATION_LINEAR));
    CHECK(plane.equationKind == GEO_EQUATION_LINEAR);
    CHECK_NEAR(ball.parameter,
               model == GEO_MODEL_S3   ? -cos(.2f)
               : model == GEO_MODEL_H3 ? cosh(.2f)
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
  // Linear sections, responses, quadrics, and clips are independent packet
  // concepts. Curved balls use the same linear equation family as planes.
  for (int model = GEO_MODEL_H3; model <= GEO_MODEL_R3; ++model) {
    Atlas a;
    a.start(model);
    CHECK(a.seed(model == GEO_MODEL_S3 ? 2.7f : 3.0f) == 0);
    CHECK(a.addMaterial(vec4(1, 1, 1, 1), vec4(.4f, .4f, .4f, 1)) == 0);
    int ball = a.addBallSurface(
        0, a.pointFromOriginTangent(vec3(.2f, 0, 0)), .25f, 0,
        GEO_RESPONSE_MIRROR);
    CHECK(ball == 0);
    CHECK(a.addObjectClipPlane(ball, vec3(1, 0, 0), .3f) == 0);
    CHECK(a.addPlane(0, vec3(0, 1, 0), .4f, 0, GEO_RESPONSE_OPAQUE) == 1);
    float q[16] = {};
    q[0] = 1;
    q[5] = 1.5f;
    q[10] = .75f;
    q[15] = -.2f;
    CHECK(a.addQuadric(0, q, 0, GEO_RESPONSE_OPAQUE) == 2);
    CHECK(a.cameraChartAt(0, vec4(0, 0, 0, 1), 2.5f) == 0);
    CHECK(a.build(0, 64) == 0);
    auto h = header(a);
    CHECK(h.counts.objectCount == 3);
    CHECK(h.counts.quadricCount == 1);
    CHECK(h.counts.clipCount == 3);
    Object encodedBall = flatObject(a, 0);
    CHECK(encodedBall.responseKind == GEO_RESPONSE_MIRROR);
    CHECK(encodedBall.equationKind ==
          (model == GEO_MODEL_R3 ? GEO_EQUATION_R3_SPHERE
                                 : GEO_EQUATION_LINEAR));
    CHECK(flatObject(a, 1).equationKind == GEO_EQUATION_LINEAR);
    CHECK(flatObject(a, 2).equationKind == GEO_EQUATION_QUADRIC);
    CHECK(flatObject(a, 2).quadricIndex == 0);
    CHECK_NEAR(flatQuadric(a, 0).coefficients.m[5], 1.5f / sqrt(3.8525f),
               2e-5);
    CHECK(flatClip(a, 0).kind == GEO_CLIP_LINEAR);
    CHECK(flatClip(a, 1).kind == GEO_CLIP_BALL);
  }
  {
    Atlas a;
    a.start(GEO_MODEL_S3);
    CHECK(a.seed(2.8f) == 0);
    CHECK(a.addMaterial(vec4(1, 1, 1, 1), vec4()) == 0);
    CHECK(a.addCliffordTorus(0, 0, GEO_RESPONSE_OPAQUE) == 0);
    float asymmetric[16] = {};
    asymmetric[1] = 1;
    CHECK(a.addQuadric(0, asymmetric, 0, GEO_RESPONSE_OPAQUE) < 0);
    int plane = a.addPlane(0, vec3(0, 0, 1), .3f, 0,
                           GEO_RESPONSE_OPAQUE);
    CHECK(plane == 1);
    for (int i = 0; i < GEO_MAX_CLIPS_PER_OBJECT; ++i)
      CHECK(a.addObjectClipPlane(plane, vec3(1, 0, 0), .5f) >= 0);
    CHECK(a.addObjectClipPlane(plane, vec3(1, 0, 0), .5f) < 0);
  }
  // Flattening develops both the quadric equation and its clipping half-spaces
  // into the camera chart. For x' = x - 2, the unit sphere becomes
  // (x' + 2)^2 + y^2 + z^2 - w^2 = 0.
  {
    Atlas a;
    a.start(GEO_MODEL_R3);
    CHECK(a.seed(3) == 0);
    float translation[16];
    identity(translation);
    translation[12] = 2;
    CHECK(a.addChart(3, 0, translation, true) == 1);
    CHECK(a.addMaterial(vec4(1, 1, 1, 1), vec4()) == 0);
    float sphere[16] = {};
    sphere[0] = sphere[5] = sphere[10] = 1;
    sphere[15] = -1;
    int object = a.addQuadric(1, sphere, 0, GEO_RESPONSE_OPAQUE);
    CHECK(object == 0);
    CHECK(a.addObjectClipPlane(object, vec3(1, 0, 0), .5f) == 0);
    CHECK(a.cameraChartAt(0, vec4(0, 0, 0, 1), 3) == 0);
    CHECK(a.build(0, 64) == 0);
    float norm = sqrt(20.0f);
    Quadric developed = flatQuadric(a, 0);
    CHECK_NEAR(developed.coefficients.m[0], 1 / norm, 2e-5);
    CHECK_NEAR(developed.coefficients.m[3], 2 / norm, 2e-5);
    CHECK_NEAR(developed.coefficients.m[12], 2 / norm, 2e-5);
    CHECK_NEAR(developed.coefficients.m[15], 3 / norm, 2e-5);
    CHECK_NEAR(flatClip(a, 0).parameter, -1.5f, 2e-5);
    CHECK(flatClip(a, 1).kind == GEO_CLIP_BALL);
    CHECK_NEAR(flatClip(a, 1).geometry.x, -2.0f, 2e-5);
  }
  // A near-symmetric API matrix is stored exactly symmetric, and normalization
  // remains stable for finite coefficients near the float range.
  {
    Atlas a;
    a.start(GEO_MODEL_R3);
    CHECK(a.seed(3) == 0);
    CHECK(a.addMaterial(vec4(1, 1, 1, 1), vec4()) == 0);
    float q[16] = {};
    q[0] = 1e30f;
    q[1] = 2e24f;
    q[4] = 2.000001e24f;
    CHECK(a.addQuadric(0, q, 0, GEO_RESPONSE_OPAQUE) == 0);
    float tiny[16] = {};
    tiny[0] = 1e-30f;
    CHECK(a.addQuadric(0, tiny, 0, GEO_RESPONSE_MIRROR) == 1);
    CHECK(a.cameraChartAt(0, vec4(0, 0, 0, 1), 3) == 0);
    CHECK(a.buildAtlas(0, 32, 1, 16) == 0);
    Quadric encoded = flatQuadric(a, 0);
    CHECK_NEAR(encoded.coefficients.m[1], encoded.coefficients.m[4], 1e-7);
    CHECK_NEAR(encoded.coefficients.m[0], 1.0f, 2e-5);
    CHECK_NEAR(flatQuadric(a, 1).coefficients.m[0], 1.0f, 2e-5);
    CHECK(flatObject(a, 1).responseKind == GEO_RESPONSE_MIRROR);
  }
  {
    Atlas a;
    a.start(GEO_MODEL_H3);
    CHECK(a.seed(3) == 0);
    CHECK(a.addMaterial(vec4(1, 1, 1, 1), vec4()) == 0);
    CHECK(a.addLinearSurface(0, vec4(1, 0, 0, 0), sinh(.4f), 0,
                             GEO_RESPONSE_OPAQUE) == 0);
    // A null Lorentz normal represents a horosphere.
    CHECK(a.addLinearSurface(0, vec4(1, 0, 0, 1), -.5f, 0,
                             GEO_RESPONSE_OPAQUE) == 1);
    CHECK(a.cameraChartAt(0, vec4(0, 0, 0, 1), 2.5f) == 0);
    CHECK(a.buildAtlas(0, 32, 1, 16) == 0);
    CHECK(header(a).counts.objectCount == 2);
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
  // Explicit trigger collars leave the default API unchanged and allow a
  // true-face transition for overlap-atlas experiments.
  {
    Atlas a;
    a.start(GEO_MODEL_R3);
    CHECK(a.seed(2) == 0);
    float translation[16];
    identity(translation);
    translation[12] = -2;
    CHECK(a.addPortalPairWithCollar(0, vec3(1, 0, 0), 1, 0,
                                    vec3(-1, 0, 0), 1, translation, 0) >= 0);
    CHECK(a.cameraChartAt(0, vec4(.99f, 0, 0, 1), 2) == 0);
    CHECK(a.cameraMove(vec3(.02f, 0, 0)) == 0);
    CHECK(a.buildAtlas(0, 64, 1, 32) == 0);
    CHECK_NEAR(atlasPortal(a, 0).offset, 1.0f, 1e-6);
    CHECK_NEAR(header(a).camera.position.x, -.99f, 2e-5);
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
