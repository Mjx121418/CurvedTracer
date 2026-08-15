#include "test_framework.h"
#include "GeometryCore/Intersect.h"

using namespace geo;

void test_intersect() {
    // ---- raySphere: straight ray from origin ----
    // Hit at t = 1.5 and 2.5; nearest is 1.5.
    float t = raySphere(vec3(0, 0, 0), vec3(1, 0, 0), vec3(2, 0, 0), 0.5f, 0.0f);
    CHECK_NEAR(t, 1.5f, 1e-5);

    // tMin excludes the near root.
    t = raySphere(vec3(0, 0, 0), vec3(1, 0, 0), vec3(2, 0, 0), 0.5f, 1.6f);
    CHECK_NEAR(t, 2.5f, 1e-5);

    // Miss: perpendicular distance from the ray to the center exceeds radius.
    t = raySphere(vec3(0, 0, 0), vec3(1, 0, 0), vec3(2, 1, 0), 0.5f, 0.0f);
    CHECK_NEAR(t, -1.0f, 1e-6);

    // Tangent: discriminant == 0, single root at t = 2.
    t = raySphere(vec3(0, 0, 0), vec3(1, 0, 0), vec3(2, 2, 0), 2.0f, 0.0f);
    CHECK_NEAR(t, 2.0f, 1e-4);

    // Sphere behind the ray: both roots negative.
    t = raySphere(vec3(0, 0, 0), vec3(1, 0, 0), vec3(-2, 0, 0), 0.5f, 0.0f);
    CHECK_NEAR(t, -1.0f, 1e-6);

    // Non-normalized direction is still handled (a = |d|^2 is taken into account).
    t = raySphere(vec3(0, 0, 0), vec3(2, 0, 0), vec3(4, 0, 0), 1.0f, 0.0f);
    CHECK_NEAR(t, 1.5f, 1e-5);   // p(t)=2t*e1, reaches |x|=1? wait sphere center 4 radius 1 -> t=1.5,2.5

    // ---- rayPlane: ray from origin ----
    t = rayPlane(vec3(1, 0, 0), vec3(1, 0, 0), 2.0f);
    CHECK_NEAR(t, 2.0f, 1e-5);

    t = rayPlane(vec3(0, 1, 0), vec3(1, 0, 0), 0.0f);   // parallel to plane through origin
    CHECK_NEAR(t, -1.0f, 1e-6);

    // ---- invertSphere: sphere -> sphere ----
    {
        vec3 c; float r; bool op = false;
        // Invert a sphere at (3,0,0), radius 1 across the unit mirror at origin.
        invertSphere(vec3(0, 0, 0), 1.0f, vec3(3, 0, 0), 1.0f, c, r, op);
        CHECK(!op);
        // d=(3,0,0), D=9-1=8, k=1 -> center = (3/8,0,0), radius = 1/8.
        CHECK_NEAR(c.x, 3.0f / 8.0f, 1e-5);
        CHECK_NEAR(c.y, 0.0f, 1e-5);
        CHECK_NEAR(c.z, 0.0f, 1e-5);
        CHECK_NEAR(r, 1.0f / 8.0f, 1e-5);
    }

    // ---- invertSphere: D == 0 -> plane ----
    {
        vec3 c; float r; bool op = false;
        // Sphere centered at (2,0,0) radius 2 passes through the mirror center.
        invertSphere(vec3(0, 0, 0), 1.0f, vec3(2, 0, 0), 2.0f, c, r, op);
        CHECK(op);
        CHECK_NEAR(c.x, 1.0f, 1e-5);       // unit normal (1,0,0)
        CHECK_NEAR(c.y, 0.0f, 1e-5);
        CHECK_NEAR(c.z, 0.0f, 1e-5);
        CHECK_NEAR(r, 0.25f, 1e-5);        // n·(x - m) = k/(2|d|) => offset 1/4
    }

    // ---- reflectPlane ----
    {
        vec3 d = normalize(vec3(1, 1, 0));
        vec3 n(1, 0, 0);
        vec3 r = reflectPlane(d, n);
        CHECK_NEAR(r.x, -d.x, 1e-6);
        CHECK_NEAR(r.y, d.y, 1e-6);
        CHECK_NEAR(r.z, d.z, 1e-6);
    }
}
