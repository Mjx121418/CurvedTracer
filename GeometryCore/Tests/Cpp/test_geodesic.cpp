#include "GeometryCore/Geodesic.h"
#include "GeometryCore/Isometry.h"
#include "test_framework.h"

#include <cmath>

using namespace geo;

namespace {

float modelDot(const vec4 &a, const vec4 &b, int model) {
  return model == GEO_MODEL_H3
             ? a.x * b.x + a.y * b.y + a.z * b.z - a.w * b.w
             : dot(a, b);
}

void checkVectorNear(const vec4 &a, const vec4 &b, float tolerance) {
  CHECK_NEAR(a.x, b.x, tolerance);
  CHECK_NEAR(a.y, b.y, tolerance);
  CHECK_NEAR(a.z, b.z, tolerance);
  CHECK_NEAR(a.w, b.w, tolerance);
}

Isometry testIsometry(int model) {
  Isometry isometry;
  isometry.kind = static_cast<ModelKind>(model);
  isometry.m = mat4Identity();
  float angle = 0.31f;
  float c = std::cos(angle), s = std::sin(angle);
  if (model == GEO_MODEL_S3) {
    isometry.m.m[0] = c;
    isometry.m.m[3] = -s;
    isometry.m.m[12] = s;
    isometry.m.m[15] = c;
  } else if (model == GEO_MODEL_H3) {
    c = std::cosh(angle);
    s = std::sinh(angle);
    isometry.m.m[0] = c;
    isometry.m.m[3] = s;
    isometry.m.m[12] = s;
    isometry.m.m[15] = c;
  } else {
    isometry.m.m[0] = c;
    isometry.m.m[1] = s;
    isometry.m.m[4] = -s;
    isometry.m.m[5] = c;
    isometry.m.m[12] = 0.2f;
    isometry.m.m[13] = -0.1f;
    isometry.m.m[14] = 0.3f;
  }
  return isometry;
}

} // namespace

void test_geodesic() {
  for (int model = GEO_MODEL_H3; model <= GEO_MODEL_R3; ++model) {
    Geodesic radial(vec4(0, 0, 0, 1),
                    normalize(vec4(0.6f, -0.3f, 0.2f, 0)));
    CHECK(canonicalizeGeodesic(radial, model));
    CHECK(advanceGeodesic(radial, 0.43f, model));

    // Choose a direction unrelated to the radial direction, then project it
    // into the tangent space at this deliberately off-origin point.
    Geodesic geodesic(radial.point, vec4(-0.2f, 0.7f, 0.4f, 0.3f));
    CHECK(canonicalizeGeodesic(geodesic, model));
    if (model != GEO_MODEL_R3)
      CHECK_NEAR(modelDot(geodesic.point, geodesic.tangent, model), 0, 2e-5);
    CHECK_NEAR(modelDot(geodesic.tangent, geodesic.tangent, model), 1,
               2e-5);
    if (model == GEO_MODEL_S3)
      CHECK_NEAR(modelDot(geodesic.point, geodesic.point, model), 1, 2e-5);
    else if (model == GEO_MODEL_H3) {
      CHECK_NEAR(modelDot(geodesic.point, geodesic.point, model), -1, 2e-5);
      CHECK(geodesic.point.w > 0);
    } else {
      CHECK_NEAR(geodesic.point.w, 1, 1e-6);
      CHECK_NEAR(geodesic.tangent.w, 0, 1e-6);
    }

    Geodesic oneStep = geodesic, twoSteps = geodesic;
    CHECK(advanceGeodesic(oneStep, 0.37f, model));
    CHECK(advanceGeodesic(twoSteps, 0.11f, model));
    CHECK(advanceGeodesic(twoSteps, 0.26f, model));
    checkVectorNear(oneStep.point, twoSteps.point, 3e-5f);
    checkVectorNear(oneStep.tangent, twoSteps.tangent, 3e-5f);

    float epsilon = 1e-3f;
    vec4 before = geodesicPointAt(geodesic, 0.23f - epsilon, model);
    vec4 after = geodesicPointAt(geodesic, 0.23f + epsilon, model);
    vec4 derivative = (after - before) / (2 * epsilon);
    vec4 expectedTangent = geodesicTangentAt(geodesic, 0.23f, model);
    checkVectorNear(derivative, expectedTangent, 3e-4f);

    Isometry isometry = testIsometry(model);
    CHECK(isometry.validate());
    Geodesic transformed(isometry.applyPoint(geodesic.point),
                         isometry.applyTangent(geodesic.tangent));
    CHECK(canonicalizeGeodesic(transformed, model));
    vec4 transformedAfter = geodesicPointAt(transformed, 0.29f, model);
    vec4 afterTransformed =
        isometry.applyPoint(geodesicPointAt(geodesic, 0.29f, model));
    checkVectorNear(transformedAfter, afterTransformed, 3e-5f);
  }

  Geodesic invalid(vec4(0, 0, 0, 1), vec4());
  CHECK(!canonicalizeGeodesic(invalid, GEO_MODEL_S3));
  CHECK(!advanceGeodesic(invalid, 0.1f, GEO_MODEL_S3));
}
