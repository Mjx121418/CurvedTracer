#include "test_framework.h"
#include "GeometryCore/Hyperboloid.h"
#include "GeometryCore/Sphere3.h"

using namespace geo;

void test_stereo() {
    // ---- H3: ball <-> model round trips ----
    vec4 o = H3::ballToModel(vec3(0, 0, 0));
    CHECK_NEAR(o.x, 0, 1e-6);
    CHECK_NEAR(o.y, 0, 1e-6);
    CHECK_NEAR(o.z, 0, 1e-6);
    CHECK_NEAR(o.w, 1, 1e-6);
    CHECK(H3::onModel(o));

    vec3 b(0.3f, -0.2f, 0.4f);
    vec4 x = H3::ballToModel(b);
    CHECK(H3::onModel(x));
    vec3 b2 = H3::modelToBall(x);
    CHECK_NEAR(b2.x, b.x, 1e-5);
    CHECK_NEAR(b2.y, b.y, 1e-5);
    CHECK_NEAR(b2.z, b.z, 1e-5);

    // distance: ball radius r <-> hyperbolic distance 2 atanh(r)
    float d = 1.0f;
    float r = mhTanh(d * 0.5f);              // = 0.4621...
    vec4 pc = H3::ballToModel(vec3(r, 0, 0));
    CHECK_NEAR(H3::distance(o, pc), d, 1e-5);

    // reflection across plane x=0 (normal e1): (a,b,c,w) -> (-a,b,c,w); preserves mdot
    vec4 n(1, 0, 0, 0);
    vec4 p(0.7f, 0.2f, -0.3f, 1.3f);
    vec4 pr = H3::reflect(n, p);
    CHECK_NEAR(pr.x, -p.x, 1e-5);
    CHECK_NEAR(pr.y, p.y, 1e-5);
    CHECK_NEAR(pr.z, p.z, 1e-5);
    CHECK_NEAR(pr.w, p.w, 1e-5);
    CHECK_NEAR(mdot(pr, pr), mdot(p, p), 1e-4);

    // geodesic through the origin is a straight line in the chart
    vec4 g = H3::exp(0.5f, o, vec4(1, 0, 0, 0));
    vec3 gb = H3::modelToBall(g);
    CHECK_NEAR(gb.x, mhTanh(0.25f), 1e-5);
    CHECK_NEAR(gb.y, 0, 1e-5);
    CHECK_NEAR(gb.z, 0, 1e-5);

    // ---- S3: chart <-> model round trips ----
    vec4 so = S3::chartToModel(vec3(0, 0, 0));
    CHECK_NEAR(so.x, 0, 1e-6);
    CHECK_NEAR(so.y, 0, 1e-6);
    CHECK_NEAR(so.z, 0, 1e-6);
    CHECK_NEAR(so.w, -1, 1e-6);
    CHECK(S3::onModel(so));

    vec3 sy(0.5f, -0.3f, 0.8f);
    vec4 sx = S3::chartToModel(sy);
    CHECK(S3::onModel(sx));
    vec3 sy2 = S3::modelToChart(sx);
    CHECK_NEAR(sy2.x, sy.x, 1e-5);
    CHECK_NEAR(sy2.y, sy.y, 1e-5);
    CHECK_NEAR(sy2.z, sy.z, 1e-5);

    // distance: chart point at |y|=1 is angular pi/2 from the south pole
    CHECK_NEAR(S3::distance(so, S3::chartToModel(vec3(1, 0, 0))), 1.5707963f, 1e-5);

    // reflection across great sphere {x.w=0} (normal e4): (a,b,c,d) -> (a,b,c,-d)
    vec4 sn(0, 0, 0, 1);
    vec4 sp(0.2f, -0.5f, 0.7f, 0.4f);
    vec4 spr = S3::reflect(sn, sp);
    CHECK_NEAR(spr.x, sp.x, 1e-5);
    CHECK_NEAR(spr.y, sp.y, 1e-5);
    CHECK_NEAR(spr.z, sp.z, 1e-5);
    CHECK_NEAR(spr.w, -sp.w, 1e-5);
    CHECK_NEAR(dot(spr, spr), dot(sp, sp), 1e-4);
}
