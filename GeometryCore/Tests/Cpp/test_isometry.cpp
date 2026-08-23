#include "GeometryCore/Isometry.h"
#include "test_framework.h"
using namespace geo;

static Isometry rotation(ModelKind kind, float a) {
    Isometry m;
    m.kind = kind;
    m.m = mat4Identity();
    m.m.m[0] = cos(a);
    m.m.m[1] = sin(a);
    m.m.m[4] = -sin(a);
    m.m.m[5] = cos(a);
    return m;
}

void test_isometry() {
    for (ModelKind k : {ModelKind::S3, ModelKind::H3, ModelKind::R3}) {
        Isometry m = rotation(k, 0.4f);
        CHECK(m.validate());
        Isometry id = m.compose(m.inverse());
        CHECK(id.validate());
        vec4 p = k == ModelKind::R3 ? vec4(1, 2, 3, 1) : vec4(0, 0, 0, 1);
        vec4 q = m.inverse().applyPoint(m.applyPoint(p));
        CHECK_NEAR(q.x, p.x, 1e-5);
        CHECK_NEAR(q.w, p.w, 1e-5);
    }
    Isometry reflection;
    reflection.kind = ModelKind::S3;
    reflection.m = mat4Identity();
    reflection.m.m[0] = -1;
    CHECK(!reflection.validate());
    Isometry scale;
    scale.kind = ModelKind::R3;
    scale.m = mat4Identity();
    scale.m.m[0] = 2;
    CHECK(!scale.validate());
    Isometry badRow;
    badRow.kind = ModelKind::R3;
    badRow.m = mat4Identity();
    badRow.m.m[3] = 1;
    CHECK(!badRow.validate());
    Isometry past;
    past.kind = ModelKind::H3;
    past.m = mat4Identity();
    past.m.m[10] = -1;
    past.m.m[15] = -1;
    CHECK(!past.validate());
    Isometry translation;
    translation.kind = ModelKind::R3;
    translation.m = mat4Identity();
    translation.m.m[12] = 2;
    translation.m.m[13] = -3;
    CHECK(translation.validate());
    vec4 point = translation.applyPoint(vec4(1, 1, 1, 1)),
         tangent = translation.applyTangent(vec4(1, 1, 1, 0));
    CHECK_NEAR(point.x, 3, 1e-6);
    CHECK_NEAR(point.y, -2, 1e-6);
    CHECK_NEAR(tangent.x, 1, 1e-6);
    CHECK_NEAR(tangent.y, 1, 1e-6);
    Isometry boost;
    boost.kind = ModelKind::H3;
    boost.m = mat4Identity();
    float c = cosh(.7f), s = sinh(.7f);
    boost.m.m[0] = c;
    boost.m.m[3] = s;
    boost.m.m[12] = s;
    boost.m.m[15] = c;
    CHECK(boost.validate());
    vec4 future = boost.applyPoint(vec4(0, 0, 0, 1));
    CHECK(future.w > 0);
    CHECK_NEAR(future.x, s, 1e-5);
}
