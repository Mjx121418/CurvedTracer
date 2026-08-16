#include "test_framework.h"
#include "GeometryCore/Mobius.h"

using namespace geo;

namespace {

mat4 rotationX1X4(float theta) {
    mat4 m;
    float c = mhCos(theta), s = mhSin(theta);
    m.m[0] = c;  m.m[1] = 0;   m.m[2] = 0;   m.m[3] = s;
    m.m[4] = 0;  m.m[5] = 1;   m.m[6] = 0;   m.m[7] = 0;
    m.m[8] = 0;  m.m[9] = 0;   m.m[10] = 1;  m.m[11] = 0;
    m.m[12] = -s; m.m[13] = 0; m.m[14] = 0;  m.m[15] = c;
    return m;
}

} // namespace

void test_mobius() {
    // ---- v4 disk-chart identity ----
    {
        Mobius id;
        id.kind = ModelKind::H3;
        vec3 p(0.2f, -0.1f, 0.3f);
        vec3 q = id.applyChartPoint(p);
        CHECK_NEAR(q.x, p.x, 1e-5);
        CHECK_NEAR(q.y, p.y, 1e-5);
        CHECK_NEAR(q.z, p.z, 1e-5);
    }

    // ---- S3 disk-chart rotation by π/2 maps origin to (-1,0,0) ----
    {
        Mobius rot;
        rot.kind = ModelKind::S3;
        rot.m = rotationX1X4(1.5707963f);
        vec3 q = rot.applyChartPoint(vec3(0, 0, 0));
        CHECK_NEAR(q.x, -1.0f, 1e-4);
        CHECK_NEAR(q.y, 0.0f, 1e-4);
        CHECK_NEAR(q.z, 0.0f, 1e-4);
    }

    // ---- compose / inverse with v4 disk points ----
    {
        Mobius rot;
        rot.kind = ModelKind::S3;
        rot.m = rotationX1X4(1.5707963f);
        Mobius comp = rot.compose(rot.inverse());
        vec3 p(0.3f, 0.1f, -0.2f);
        vec3 q = comp.applyChartPoint(p);
        CHECK_NEAR(q.x, p.x, 1e-4);
        CHECK_NEAR(q.y, p.y, 1e-4);
        CHECK_NEAR(q.z, p.z, 1e-4);
    }

    // ---- S3 surface transform ----
    {
        Mobius rot;
        rot.kind = ModelKind::S3;
        rot.m = rotationX1X4(1.5707963f);
        vec3 a; float b; float c;
        rot.applySurface(vec3(1, 0, 0), 0.0f, 0.0f, a, b, c);
        CHECK_NEAR(a.x, 0.0f, 1e-3);
        CHECK_NEAR(a.y, 0.0f, 1e-3);
        CHECK_NEAR(a.z, 0.0f, 1e-3);
        CHECK_NEAR(b, 1.0f, 1e-3);
        CHECK_NEAR(c, 0.0f, 1e-3);
    }

    // ---- H3 identity surface transform ----
    {
        Mobius id;
        id.kind = ModelKind::H3;
        vec3 a; float b; float c;
        id.applySurface(vec3(0, 0, 1), 0.0f, 0.0f, a, b, c);
        CHECK_NEAR(a.x, 0.0f, 1e-4);
        CHECK_NEAR(a.y, 0.0f, 1e-4);
        CHECK_NEAR(a.z, 1.0f, 1e-4);
        CHECK_NEAR(b, 0.0f, 1e-4);
        CHECK_NEAR(c, 0.0f, 1e-4);
    }
}
