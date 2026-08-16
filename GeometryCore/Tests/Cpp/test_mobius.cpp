#include "test_framework.h"
#include "GeometryCore/Mobius.h"

using namespace geo;

namespace {
// Lorentz boost along x with rapidity rho (column-major).
mat4 lorentzBoostX(float rho) {
    mat4 m;
    float ch = mhCosh(rho), sh = mhSinh(rho);
    m.m[0] = ch;  m.m[1] = 0;   m.m[2] = 0;   m.m[3] = sh;   // col 0
    m.m[4] = 0;   m.m[5] = 1;   m.m[6] = 0;   m.m[7] = 0;    // col 1
    m.m[8] = 0;   m.m[9] = 0;   m.m[10] = 1;  m.m[11] = 0;   // col 2
    m.m[12] = sh; m.m[13] = 0;  m.m[14] = 0;  m.m[15] = ch;  // col 3
    return m;
}

// Rotation in the (x1, x4) plane by angle theta, acting on R4 (column-major).
mat4 rotationX1X4(float theta) {
    mat4 m;
    float c = mhCos(theta), s = mhSin(theta);
    m.m[0] = c;  m.m[1] = 0;   m.m[2] = 0;   m.m[3] = s;    // col 0
    m.m[4] = 0;  m.m[5] = 1;   m.m[6] = 0;   m.m[7] = 0;    // col 1
    m.m[8] = 0;  m.m[9] = 0;   m.m[10] = 1;  m.m[11] = 0;   // col 2
    m.m[12] = -s; m.m[13] = 0; m.m[14] = 0;  m.m[15] = c;   // col 3
    return m;
}
} // namespace

void test_mobius() {
    // ---- H3: identity ----
    Mobius id;
    id.kind = ModelKind::H3;
    vec3 b(0.2f, -0.1f, 0.3f);
    vec3 bi = id.apply(b);
    CHECK_NEAR(bi.x, b.x, 1e-6);
    CHECK_NEAR(bi.y, b.y, 1e-6);
    CHECK_NEAR(bi.z, b.z, 1e-6);

    // ---- H3: boost moves origin to tanh(rho/2) on +x ----
    Mobius boost;
    boost.kind = ModelKind::H3;
    boost.m = lorentzBoostX(1.0f);
    vec3 o = boost.apply(vec3(0, 0, 0));
    CHECK_NEAR(o.x, mhTanh(0.5f), 1e-5);
    CHECK_NEAR(o.y, 0, 1e-5);
    CHECK_NEAR(o.z, 0, 1e-5);

    // inverse returns origin
    Mobius binv = boost.inverse();
    vec3 back = binv.apply(o);
    CHECK_NEAR(back.x, 0, 1e-5);
    CHECK_NEAR(back.y, 0, 1e-5);
    CHECK_NEAR(back.z, 0, 1e-5);

    // compose(boost, boost.inverse()) == identity on a random point
    Mobius comp = boost.compose(binv);
    vec3 p(0.35f, 0.1f, -0.2f);
    vec3 q = comp.apply(p);
    CHECK_NEAR(q.x, p.x, 1e-4);
    CHECK_NEAR(q.y, p.y, 1e-4);
    CHECK_NEAR(q.z, p.z, 1e-4);

    // ---- H3: applySphere keeps sphere-ness; image points lie on image sphere ----
    {
        vec3 oc; float orr; bool op = false;
        boost.applySphere(vec3(0, 0, 0), 0.2f, oc, orr, op);
        CHECK(!op);
        CHECK(orr > 0.0f);
        // a point on the source sphere maps onto the image sphere
        vec3 src = vec3(0.2f, 0, 0);
        vec3 img = boost.apply(src);
        CHECK_NEAR(length(img - oc), orr, 1e-3);
        // image stays inside the unit ball
        CHECK(length(oc) + orr < 1.0f);
    }

    // ---- S3: identity ----
    Mobius sid;
    sid.kind = ModelKind::S3;
    vec3 sb(0.5f, -0.3f, 0.8f);
    vec3 sbi = sid.apply(sb);
    CHECK_NEAR(sbi.x, sb.x, 1e-6);
    CHECK_NEAR(sbi.y, sb.y, 1e-6);
    CHECK_NEAR(sbi.z, sb.z, 1e-6);

    // ---- S3: rotation by pi/2 moves chart origin to (1,0,0) ----
    Mobius rot;
    rot.kind = ModelKind::S3;
    rot.m = rotationX1X4(1.5707963f);
    vec3 ro = rot.apply(vec3(0, 0, 0));
    CHECK_NEAR(ro.x, 1.0f, 1e-4);
    CHECK_NEAR(ro.y, 0.0f, 1e-4);
    CHECK_NEAR(ro.z, 0.0f, 1e-4);

    // inverse returns origin
    vec3 rback = rot.inverse().apply(ro);
    CHECK_NEAR(rback.x, 0, 1e-4);
    CHECK_NEAR(rback.y, 0, 1e-4);
    CHECK_NEAR(rback.z, 0, 1e-4);

    // ---- S3: sphere NOT through the projection preimage stays a sphere ----
    {
        vec3 oc; float orr; bool op = false;
        rot.applySphere(vec3(0, 0, 0), 0.3f, oc, orr, op);
        CHECK(!op);
        CHECK(orr > 0.0f);
    }
    // ---- S3: sphere passing THROUGH the projection preimage (1,0,0) maps to a plane ----
    {
        vec3 oc; float orr; bool op = false;
        // unit sphere centered at origin: (1,0,0) lies on it -> maps to plane x=0
        rot.applySphere(vec3(0, 0, 0), 1.0f, oc, orr, op);
        CHECK(op);
        CHECK_NEAR(oc.x, 1.0f, 1e-3);
        CHECK_NEAR(oc.y, 0.0f, 1e-3);
        CHECK_NEAR(oc.z, 0.0f, 1e-3);
        CHECK_NEAR(orr, 0.0f, 1e-3);
    }

    // ---- v4 disk-chart applyChartPoint and applySurface smoke tests ----
    {
        Mobius diskId;
        diskId.kind = ModelKind::H3;
        vec3 dp(0.2f, -0.1f, 0.3f);
        vec3 dq = diskId.applyChartPoint(dp);
        CHECK_NEAR(dq.x, dp.x, 1e-5);
        CHECK_NEAR(dq.y, dp.y, 1e-5);
        CHECK_NEAR(dq.z, dp.z, 1e-5);

        Mobius diskRot;
        diskRot.kind = ModelKind::S3;
        diskRot.m = rotationX1X4(1.5707963f);
        vec3 ro = diskRot.applyChartPoint(vec3(0, 0, 0));
        CHECK_NEAR(ro.x, -1.0f, 1e-4);
        CHECK_NEAR(ro.y, 0.0f, 1e-4);
        CHECK_NEAR(ro.z, 0.0f, 1e-4);

        vec3 oa; float ob; float oc;
        diskRot.applySurface(vec3(1,0,0), 0.0f, 0.0f, oa, ob, oc);
        CHECK_NEAR(oa.x, 0.0f, 1e-3);
        CHECK_NEAR(ob, 1.0f, 1e-3);
        CHECK_NEAR(oc, 0.0f, 1e-3);
    }

    // ---- applyPlane: H3 plane through origin -> sphere or plane ----
    {
        vec3 oc; float orr; bool op = false;
        // Boost along x; the plane x=0 maps to the sphere orthogonal to the
        // boundary with center coth(rho) and radius csch(rho) on the x-axis.
        Mobius hboost;
        hboost.kind = ModelKind::H3;
        hboost.m = lorentzBoostX(0.5f);
        hboost.applyPlane(vec3(1, 0, 0), 0.0f, oc, orr, op);
        CHECK(!op);
        float expectedC = 1.0f / mhTanh(0.5f);    // coth
        float expectedR = 1.0f / mhSinh(0.5f);    // csch
        CHECK_NEAR(oc.x, expectedC, 1e-3);
        CHECK_NEAR(oc.y, 0.0f, 1e-3);
        CHECK_NEAR(oc.z, 0.0f, 1e-3);
        CHECK_NEAR(orr, expectedR, 1e-3);

        // Plane y=0 is invariant under the x-boost and stays a plane through 0.
        hboost.applyPlane(vec3(0, 1, 0), 0.0f, oc, orr, op);
        CHECK(op);
        CHECK_NEAR(mhAbs(oc.y), 1.0f, 1e-3);
        CHECK_NEAR(orr, 0.0f, 1e-3);

        // S3 rotation by pi in (x,w) leaves model plane x=0 invariant.
        Mobius rotPi;
        rotPi.kind = ModelKind::S3;
        rotPi.m = rotationX1X4(3.14159265f);
        vec3 soc; float sorr; bool sop = false;
        rotPi.applyPlane(vec3(1, 0, 0), 0.0f, soc, sorr, sop);
        CHECK(sop);
        CHECK_NEAR(mhAbs(soc.x), 1.0f, 1e-3);
        CHECK_NEAR(sorr, 0.0f, 1e-3);
    }
}
