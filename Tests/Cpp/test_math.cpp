#include "test_framework.h"
#include "GeometryCore/Math.h"

using namespace geo;

void test_math() {
    // vec3 basics
    vec3 a(1, 2, 3), b(4, 5, 6);
    vec3 s = a + b;
    CHECK_NEAR(s.x, 5, 1e-6);
    CHECK_NEAR(s.y, 7, 1e-6);
    CHECK_NEAR(s.z, 9, 1e-6);

    CHECK_NEAR(dot(a, b), 32, 1e-6);

    vec3 e1(1, 0, 0), e2(0, 1, 0);
    vec3 c = cross(e1, e2);
    CHECK_NEAR(c.x, 0, 1e-6);
    CHECK_NEAR(c.y, 0, 1e-6);
    CHECK_NEAR(c.z, 1, 1e-6);

    vec3 n = normalize(vec3(3, 0, 4));
    CHECK_NEAR(length(n), 1.0, 1e-6);
    CHECK_NEAR(n.x, 0.6, 1e-6);
    CHECK_NEAR(n.z, 0.8, 1e-6);

    // vec4 basics
    vec4 v(1, 2, 3, 4), w(5, 6, 7, 8);
    CHECK_NEAR(dot(v, w), 70, 1e-6);

    // mat4 identity
    mat4 I = mat4Identity();
    vec4 p(1, -2, 3, 4);
    vec4 q = mat4Apply(I, p);
    CHECK_NEAR(q.x, p.x, 1e-6);
    CHECK_NEAR(q.y, p.y, 1e-6);
    CHECK_NEAR(q.z, p.z, 1e-6);
    CHECK_NEAR(q.w, p.w, 1e-6);

    // mat4Mul by identity
    mat4 R;
    R.m[0] = 0;  R.m[1] = 1;  R.m[2] = 0;  R.m[3] = 0;   // 90deg rotation in x-y plane
    R.m[4] = -1; R.m[5] = 0;  R.m[6] = 0;  R.m[7] = 0;
    R.m[8] = 0;  R.m[9] = 0;  R.m[10] = 1; R.m[11] = 0;
    R.m[12] = 0; R.m[13] = 0; R.m[14] = 0; R.m[15] = 1;

    vec4 e1v(1, 0, 0, 0);
    vec4 r = mat4Apply(R, e1v);
    CHECK_NEAR(r.x, 0, 1e-6);
    CHECK_NEAR(r.y, 1, 1e-6);

    mat4 I2 = mat4Mul(R, mat4Identity());
    CHECK_NEAR(I2.m[0], R.m[0], 1e-6);
    CHECK_NEAR(I2.m[15], R.m[15], 1e-6);
}
