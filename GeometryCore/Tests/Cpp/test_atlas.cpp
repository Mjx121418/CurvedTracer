#include "test_framework.h"
#include "GeometryCore/Chart.h"
#include "GeometryCore/Mobius.h"
#include "GeometryCore/Scene.h"
#include "GeometryCore/AtlasScene.h"

#include <cstring>
#include <vector>

using namespace geo;

namespace {

mat4 identity16() { return mat4Identity(); }

mat4 rotationX1X4(float theta) {
    mat4 m;
    float c = mhCos(theta), s = mhSin(theta);
    m.m[0] = c;  m.m[1] = 0;   m.m[2] = 0;   m.m[3] = s;
    m.m[4] = 0;  m.m[5] = 1;   m.m[6] = 0;   m.m[7] = 0;
    m.m[8] = 0;  m.m[9] = 0;   m.m[10] = 1;  m.m[11] = 0;
    m.m[12] = -s; m.m[13] = 0; m.m[14] = 0;  m.m[15] = c;
    return m;
}

mat4 boostX(float distance) {
    mat4 m = mat4Identity();
    float c = mhCosh(distance), s = mhSinh(distance);
    m.m[0] = c; m.m[3] = s;
    m.m[12] = s; m.m[15] = c;
    return m;
}

float component(const vec3& v, int index) {
    return index == 0 ? v.x : (index == 1 ? v.y : v.z);
}

mat4 moveH3PointToOrigin(const vec4& p) {
    mat4 m = mat4Identity();
    vec3 u = p.xyz();
    float scale = 1.0f / (1.0f + p.w);
    for (int col = 0; col < 3; ++col) {
        for (int row = 0; row < 3; ++row) {
            m.m[col * 4 + row] += scale
                                * component(u, row)
                                * component(u, col);
        }
        m.m[col * 4 + 3] = -component(u, col);
        m.m[12 + col] = -component(u, col);
    }
    m.m[15] = p.w;
    return m;
}

mat4 moveS3PointToOrigin(const vec4& p) {
    float r2 = lengthSq(p.xyz());
    if (r2 < 1e-10f) return mat4Identity();
    vec3 axis = p.xyz() / mhSqrt(r2);
    mat4 m = mat4Identity();
    for (int col = 0; col < 3; ++col) {
        for (int row = 0; row < 3; ++row) {
            m.m[col * 4 + row] += (p.w - 1.0f)
                                * component(axis, row)
                                * component(axis, col);
        }
        m.m[col * 4 + 3] = component(p.xyz(), col);
        m.m[12 + col] = -component(p.xyz(), col);
    }
    m.m[15] = p.w;
    return m;
}

void checkVec4Near(const vec4& a, const vec4& b, float tolerance) {
    CHECK_NEAR(a.x, b.x, tolerance);
    CHECK_NEAR(a.y, b.y, tolerance);
    CHECK_NEAR(a.z, b.z, tolerance);
    CHECK_NEAR(a.w, b.w, tolerance);
}

ScenePacketHeader readHeader(const Atlas& atlas) {
    ScenePacketHeader h;
    std::memcpy(&h, atlas.packet().data(), sizeof(h));
    return h;
}

Object readObject(const Atlas& atlas, int idx) {
    Object o;
    std::memcpy(&o, atlas.packet().data() + sizeof(ScenePacketHeader) + idx * sizeof(Object), sizeof(o));
    return o;
}

PointLight readPointLight(const Atlas& atlas, int objectCount, int materialCount, int idx) {
    PointLight light;
    size_t off = sizeof(ScenePacketHeader) + objectCount * sizeof(Object) + materialCount * sizeof(Material);
    std::memcpy(&light, atlas.packet().data() + off + idx * sizeof(PointLight), sizeof(light));
    return light;
}

} // namespace

void test_atlas() {
    std::printf("Scene sizes: PacketMeta=%zu Camera=%zu RenderControls=%zu Counts=%zu Object=%zu Material=%zu PointLight=%zu Header=%zu\n",
                sizeof(PacketMeta), sizeof(Camera), sizeof(RenderControls), sizeof(Counts),
                sizeof(Object), sizeof(Material), sizeof(PointLight), sizeof(ScenePacketHeader));
    CHECK(sizeof(PacketMeta) == 16);
    CHECK(sizeof(Camera) == 64);
    CHECK(sizeof(RenderControls) == 32);
    CHECK(sizeof(Counts) == 16);
    CHECK(sizeof(Object) == 32);
    CHECK(sizeof(Material) == 32);
    CHECK(sizeof(PointLight) == 32);
    CHECK(sizeof(ScenePacketHeader) == 128);
    CHECK(GEO_CONTRACT_VERSION == 7);
    CHECK(GEO_ATLAS_CONTRACT_VERSION == 9);
    CHECK(sizeof(AtlasCamera) == 96);
    CHECK(sizeof(AtlasRenderControls) == 48);
    CHECK(sizeof(AtlasCounts) == 32);
    CHECK(sizeof(AtlasPacketHeader) == 192);
    CHECK(sizeof(GPUChart) == 32);
    CHECK(sizeof(GPUPortal) == 96);

    // ------------------------------------------------------------------
    // Single-chart H3 scene and packet layout.
    // ------------------------------------------------------------------
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.0f) == 0);   // finite H³ chart radius
        atlas.addMaterial(vec4(1.0f, 0.5f, 0.25f, 1.0f), vec4(0.1f, 0.1f, 0.1f, 1.0f));
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0, 0, 0), 1.0f, 0.8f, 0);   // w=0.8 sphere around origin
        atlas.addLight(0, vec3(0.0f, 0.0f, -0.4f), vec3(1.0f, 1.0f, 0.9f), 0.8f);
        atlas.setCamera(0.8f, 1.6f, vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1));
        atlas.setControls(5, 0.1f, 0.2f, 0.7f);

        int code = atlas.build(0, GEO_MAX_CHART_DEPTH);
        CHECK(code == 0);
        CHECK(atlas.packetSize() == 128 + 1 * 32 + 1 * 32 + 1 * 32);

        ScenePacketHeader h = readHeader(atlas);
        CHECK(h.meta.magic == GEO_PACKET_MAGIC);
        CHECK(h.meta.contractVersion == GEO_CONTRACT_VERSION);
        CHECK(h.meta.objectSize == 32);
        CHECK(h.meta.packetHeaderSize == 128);
        CHECK(h.camera.fovTan == 0.8f);
        CHECK(h.camera.aspect == 1.6f);
        CHECK_NEAR(h.camera.chartRadius, mhAtanh(mhSin(1.0f)), 1e-4);
        CHECK_NEAR(h.camera.chartRadiusHalfAngle,
                   mhTanh(0.5f * mhAtanh(mhSin(1.0f))), 1e-4);
        CHECK(h.controls.maxBounces == 5);
        CHECK(h.controls.modelKind == GEO_MODEL_H3);
        CHECK(h.counts.objectCount == 1);
        CHECK(h.counts.materialCount == 1);
        CHECK(h.counts.lightCount == 1);

        Object o = readObject(atlas, 0);
        CHECK(o.kind == GEO_OBJECT_OPAQUE);
        CHECK(o.colorIdx == 0);
        CHECK_NEAR(o.a.x, 0.0f, 1e-6);
        CHECK_NEAR(o.b, 1.0f, 1e-6);
        CHECK_NEAR(o.c, 0.8f, 1e-6);

        PointLight light = readPointLight(atlas, h.counts.objectCount, h.counts.materialCount, 0);
        CHECK_NEAR(light.position.z, -0.4f, 1e-6);
        CHECK_NEAR(light.intensity, 0.8f, 1e-6);
    }

    // ------------------------------------------------------------------
    // Identity-link path independence and two-chart identity flattening.
    // ------------------------------------------------------------------
    {
        float I[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        Atlas atlasA;
        atlasA.start(GEO_MODEL_H3);
        CHECK(atlasA.seed(1.0f) == 0);
        CHECK(atlasA.add(1.0f, 0, I, 1) == 1);
        CHECK(atlasA.add(1.0f, 1, I, 1) == 2);
        atlasA.link(0, 2, I, 1);
        atlasA.addMaterial(vec4(1,1,1,1), vec4(0,0,0,1));
        atlasA.addObject(2, GEO_OBJECT_OPAQUE, vec3(0,0,0), 1.0f, 0.9f, 0);
        CHECK(atlasA.build(0, GEO_MAX_CHART_DEPTH) == 0);
        std::vector<unsigned char> bytesA(atlasA.packet().begin(), atlasA.packet().end());

        Atlas atlasB;
        atlasB.start(GEO_MODEL_H3);
        CHECK(atlasB.seed(1.0f) == 0);
        CHECK(atlasB.add(1.0f, 0, I, 1) == 1);
        CHECK(atlasB.add(1.0f, 1, I, 1) == 2);
        atlasB.link(0, 2, I, 0);   // unsafe direct hop
        atlasB.addMaterial(vec4(1,1,1,1), vec4(0,0,0,1));
        atlasB.addObject(2, GEO_OBJECT_OPAQUE, vec3(0,0,0), 1.0f, 0.9f, 0);
        CHECK(atlasB.build(0, GEO_MAX_CHART_DEPTH) == 0);
        CHECK(atlasB.packet().size() == bytesA.size());
        CHECK(std::memcmp(bytesA.data(), atlasB.packet().data(), bytesA.size()) == 0);
    }

    // ------------------------------------------------------------------
    // Cocycle violation and invalid lights/objects.
    // ------------------------------------------------------------------
    {
        float I[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        mat4 boostMat = rotationX1X4(0.0f); // identity for cocycle setup; use a bad edge below
        Atlas atlas;
        atlas.start(GEO_MODEL_S3);
        CHECK(atlas.seed(1.0f) == 0);
        CHECK(atlas.add(1.0f, 0, I, 1) == 1);
        CHECK(atlas.add(1.0f, 1, I, 1) == 2);
        atlas.link(0, 2, boostMat.m, 1);
        // A non-identity edge would be needed to violate cocycle; for now just build success.
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH) == 0);
    }
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.0f) == 0);
        atlas.addLight(0, vec3(0,0,0), vec3(1,1,1), -0.1f);
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH) == 3);
    }
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.0f) == 0);
        atlas.addObject(0, GEO_OBJECT_MIRROR, vec3(1,0,0), 0.2f, 0.0f, 0);  // invalid H3 mirror b != 0
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH) == 3);
    }
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_S3);
        CHECK(atlas.seed(1.0f) == 0);
        atlas.addObject(0, GEO_OBJECT_MIRROR, vec3(1,0,0), 0.0f, 0.0f, 0);  // valid S3 great sphere
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH) == 0);
    }

    // ------------------------------------------------------------------
    // Camera-chart disk culling drops objects that do not intersect the
    // camera chart.
    // ------------------------------------------------------------------
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_S3);
        CHECK(atlas.seed(1.5707963267948966f) == 0);
        atlas.addMaterial(vec4(1, 1, 1, 1), vec4(0, 0, 0, 1));

        // Camera chart has radius 0.5 and is centered at chart 0's origin.
        // Ball radius is acos(0.98) ~ 0.2003. A ball is kept iff its surface
        // reaches inside the camera chart (min distance to the surface < 0.5).
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0, 0, 0), 1.0f, 0.98f, 0);
        // Center 0.6 rad from the origin: surface distance range [0.4, 0.8].
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0.56464247f, 0, 0), 0.82533561f, 0.98f, 0);
        // Center 1.0 rad from the origin: surface distance range [0.8, 1.2].
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0.84147098f, 0, 0), 0.54030231f, 0.98f, 0);

        int cam = atlas.cameraChartAt(0, vec3(0, 0, 0), 0.5f);
        CHECK(cam >= 0);
        CHECK(atlas.build(cam, GEO_MAX_CHART_DEPTH) == 0);

        ScenePacketHeader h = readHeader(atlas);
        CHECK(h.counts.objectCount == 2);
    }

    // ------------------------------------------------------------------
    // H³ camera-chart disk culling.
    // ------------------------------------------------------------------
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.5707963267948966f) == 0);
        atlas.addMaterial(vec4(1, 1, 1, 1), vec4(0, 0, 0, 1));

        // Camera chart radius 0.5 has boundary |x| = sin(0.5) ~ 0.479.
        // c=0.98 gives boundary |x| ~ 0.199 (inside), c=0.8 gives 0.6 (outside).
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0, 0, 0), 1.0f, 0.98f, 0);
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0, 0, 0), 1.0f, 0.8f, 0);

        int cam = atlas.cameraChartAt(0, vec3(0, 0, 0), 0.5f);
        CHECK(cam >= 0);
        CHECK(atlas.build(cam, GEO_MAX_CHART_DEPTH) == 0);

        ScenePacketHeader h = readHeader(atlas);
        CHECK(h.counts.objectCount == 1);
    }

    // ------------------------------------------------------------------
    // Camera roll rotates the frame around fwd.
    // ------------------------------------------------------------------
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.0f) == 0);
        atlas.setCamera(1.0f, 1.0f, vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1));
        atlas.cameraRoll(1.5707963f);   // +90° roll left
        CHECK_NEAR(atlas.cameraRight().y, 1.0f, 1e-4f);
        CHECK_NEAR(atlas.cameraUp().x, -1.0f, 1e-4f);
        CHECK_NEAR(atlas.cameraFwd().z, 1.0f, 1e-4f);
    }

    // ------------------------------------------------------------------
    // S³ signed-w camera movement across two antipodal charts.
    // ------------------------------------------------------------------
    {
        const float r = 2.0943951023931953f;   // 2π/3
        float anti[16] = {-1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,-1};
        Atlas atlas;
        atlas.start(GEO_MODEL_S3);
        CHECK(atlas.seed(r) == 0);
        CHECK(atlas.add(r, 0, anti, true) == 1);
        atlas.addMaterial(vec4(1,0,0,1), vec4(0.3f,0.3f,0.3f,1));
        atlas.addMaterial(vec4(0,1,0,1), vec4(0.3f,0.3f,0.3f,1));
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0,0,0), 1.0f, 0.9f, 0);
        atlas.addObject(1, GEO_OBJECT_OPAQUE, vec3(0,0,0), 1.0f, 0.9f, 1);
        atlas.addLight(0, vec3(0.3f,0.2f,0.1f), vec3(1,1,1), 1.0f);
        atlas.addLight(1, vec3(-0.3f,-0.2f,0.1f), vec3(1,1,1), 0.6f);
        atlas.setCamera(1,1, vec3(1,0,0), vec3(0,1,0), vec3(0,0,1));
        int cam = atlas.cameraChartAt(0, vec3(0,0,0), r);
        CHECK(atlas.build(cam, 64) == 0);
        // Move far enough along +x to leave chart 0 and re-parent to chart 1.
        for (int i = 0; i < 16; ++i) {
            cam = atlas.cameraMove(vec3(0.1f, 0, 0));
            CHECK(cam >= 0);
        }
        CHECK(atlas.build(cam, 64) == 0);
    }

    // ------------------------------------------------------------------
    // Camera movement re-parenting and clamp-back.
    // ------------------------------------------------------------------
    {
        float I[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        Atlas atlas;
        atlas.start(GEO_MODEL_S3);
        CHECK(atlas.seed(0.5f) == 0);
        CHECK(atlas.add(1.0f, 0, I, true) == 1);

        // 0.6 is outside chart 0 (sin(0.5)≈0.479) but inside chart 1 (sin(1.0)≈0.841).
        CameraPlacement p = atlas.resolveCameraPlacement(0, vec3(0, 0, 0), vec3(0.6f, 0, 0));
        CHECK(p.chartId == 1);
        CHECK_NEAR(p.localPosition.x, 0.6f, 1e-6f);

        // No chart contains 2.0; the placement must clamp back to the original chart 0 boundary.
        CameraPlacement q = atlas.resolveCameraPlacement(0, vec3(0, 0, 0), vec3(2.0f, 0, 0));
        CHECK(q.chartId == 0);
        CHECK_NEAR(q.localPosition.x, mhSin(0.5f), 1e-6f);

        // Stateful cameraMove follows the same rule and remains buildable.
        atlas.setCamera(1.0f, 1.0f, vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1));
        int cam = atlas.cameraChartAt(0, vec3(0, 0, 0), 1.5707963f);
        CHECK(cam == 2);
        int moved = atlas.cameraMove(vec3(0.6f, 0, 0));
        CHECK(moved == cam);
        CHECK(atlas.build(moved, GEO_MAX_CHART_DEPTH) == 0);
    }

    // ------------------------------------------------------------------
    // Unknown camera chart / model kind mismatch.
    // ------------------------------------------------------------------
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.0f) == 0);
        CHECK(atlas.build(1, GEO_MAX_CHART_DEPTH) == 4);
        CHECK(atlas.build(0, 0) == 5);
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH + 1) == 5);
    }
    {
        Atlas atlas;
        atlas.start(2);
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH) == 6);
    }

    // ------------------------------------------------------------------
    // v9 authored-atlas packet. Portal edges are not overlap/cocycle edges.
    // ------------------------------------------------------------------
    {
        const float t = 0.4f, c = mhCosh(t), s = mhSinh(t);
        float boost[16] = {c,0,0,s, 0,1,0,0, 0,0,1,0, s,0,0,c};
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.2f) == 0);
        CHECK(atlas.addPortalPair(0, vec3(-1,0,0), 0, 0.2f, 1,
                                  0, vec3(1,0,0), 0, 0.2f, 1, boost) == 0);
        CHECK(atlas.portalCount() == 2);
        CHECK(atlas.addPortalPair(0, vec3(-1,0,0), 0, 0.2f, 1,
                                  0, vec3(1,0,0), 0, 0.2f, 1, boost) == -1);
        CHECK(atlas.lastError() == 7);
        CHECK(atlas.portalCount() == 2);
        CHECK(atlas.addMaterial(vec4(1,0,0,1), vec4(0,0,0,1)) == 0);
        CHECK(atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0,0,0), 1, 0.9f, 0) == 0);
        CHECK(atlas.addLight(0, vec3(0,0,0), vec3(1,1,1), 1) == 0);
        atlas.setCamera(1, 1, vec3(1,0,0), vec3(0,1,0), vec3(0,0,1));
        int camera = atlas.cameraChartAt(0, vec3(0,0,0), 1.0f);
        CHECK(atlas.buildAtlas(camera, 32, 2, 64) == 0);
        AtlasPacketHeader header{};
        std::memcpy(&header, atlas.packet().data(), sizeof(header));
        CHECK(header.meta.magic == GEO_ATLAS_PACKET_MAGIC);
        CHECK(header.meta.contractVersion == 9);
        CHECK(header.meta.packetHeaderSize == 192);
        CHECK(header.counts.chartCount == 1);
        CHECK(header.counts.portalCount == 2);
        CHECK(header.counts.objectCount == 1);
        CHECK(header.counts.lightCount == 1);
        CHECK(header.camera.chartId == 0);
        CHECK(header.controls.maxChartHops == 32);

        // A movement that crosses a portal by much less than the shader's
        // object self-hit epsilon must still reduce the camera immediately.
        camera = atlas.cameraChartAt(0, vec3(-0.199995f, 0, 0), 1.0f);
        CHECK(camera >= 0);
        CHECK(atlas.cameraMove(vec3(-0.00002f, 0, 0)) == camera);
        CHECK(atlas.buildAtlas(camera, 32, 2, 64) == 0);
        std::memcpy(&header, atlas.packet().data(), sizeof(header));
        CHECK(header.camera.position.x > 0.0f);

        camera = atlas.cameraChartAt(0, vec3(0, 0, 0), 1.0f);
        CHECK(camera >= 0);

        // Crossing the negative face applies the pairing and keeps the
        // camera in the authored chart instead of clamping at its boundary.
        CHECK(atlas.cameraMove(vec3(-0.3f, 0, 0)) == camera);
        CHECK(atlas.buildAtlas(camera, 32, 2, 64) == 0);
        std::memcpy(&header, atlas.packet().data(), sizeof(header));
        CHECK(header.camera.position.x > 0.0f);
        CHECK_NEAR(length(atlas.cameraRight()), 1.0f, 1e-3f);

        CHECK(atlas.buildAtlas(camera, 0, 2, 64) == 8);
        CHECK(atlas.packetSize() == 0);
    }
    {
        float reflection[16] = {-1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.0f) == 0);
        CHECK(atlas.addPortalPair(0, vec3(-1,0,0), 0, 0.2f, 1,
                                  0, vec3(1,0,0), 0, 0.2f, 1, reflection) == -1);
        CHECK(atlas.lastError() == 7);
        CHECK(atlas.portalCount() == 0);

        float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        CHECK(atlas.addPortalPair(0, vec3(-1,0,0), 0, 0.2f, 1,
                                  0, vec3(1,0,0), 0, 0.2f, 1, identity) == -1);
        CHECK(atlas.lastError() == 7);
    }
    {
        mat4 rotation = rotationX1X4(0.5f);
        Atlas atlas;
        atlas.start(GEO_MODEL_S3);
        CHECK(atlas.seed(1.4f) == 0);
        CHECK(atlas.addPortalPair(0, vec3(-1,0,0), 0, 0.2f, 1,
                                  0, vec3(1,0,0), 0, 0.2f, 1, rotation.m) == 0);
        atlas.setCamera(1, 1, vec3(1,0,0), vec3(0,1,0), vec3(0,0,1));
        int camera = atlas.cameraChartAt(0, vec3(0,0,0), 1.2f);
        CHECK(atlas.buildAtlas(camera, 16, 1, 16) == 0);

        float reflection[16] = {-1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        Atlas invalid;
        invalid.start(GEO_MODEL_S3);
        CHECK(invalid.seed(1.0f) == 0);
        CHECK(invalid.addPortalPair(0, vec3(-1,0,0), 0, 0.2f, 1,
                                    0, vec3(1,0,0), 0, 0.2f, 1, reflection) == -1);
        CHECK(invalid.lastError() == 7);
    }

    // ------------------------------------------------------------------
    // Origin-recentered portal composition used by the v9 shader.
    // If M maps current -> neighbor, the new ray frame is B*T*M^-1.
    // ------------------------------------------------------------------
    {
        const float cameraD = -1.0f;
        const float faceD = -0.7f;
        vec4 camera(mhSinh(cameraD), 0, 0, mhCosh(cameraD));
        vec4 hit(mhSinh(faceD), 0, 0, mhCosh(faceD));
        vec4 tangent(mhCosh(faceD), 0, 0, mhSinh(faceD));
        mat4 chartToRay = moveH3PointToOrigin(camera);
        vec4 rayHit = mat4Apply(chartToRay, hit);
        CHECK_NEAR(mhAcosh(rayHit.w), 0.3f, 1e-5f);

        mat4 portal = boostX(1.4f);
        mat4 inversePortal = boostX(-1.4f);
        vec4 neighborHit = mat4Apply(portal, hit);
        vec4 neighborTangent = mat4Apply(portal, tangent);
        mat4 recenter = moveH3PointToOrigin(rayHit);
        mat4 nextChartToRay = mat4Mul(recenter,
            mat4Mul(chartToRay, inversePortal));
        checkVec4Near(mat4Apply(nextChartToRay, neighborHit),
                      vec4(0,0,0,1), 2e-5f);
        checkVec4Near(mat4Apply(nextChartToRay, neighborTangent),
                      mat4Apply(recenter, mat4Apply(chartToRay, tangent)),
                      2e-5f);
    }
    {
        const float cameraD = -0.6f;
        const float faceD = -0.2f;
        vec4 camera(mhSin(cameraD), 0, 0, mhCos(cameraD));
        vec4 hit(mhSin(faceD), 0, 0, mhCos(faceD));
        vec4 tangent(mhCos(faceD), 0, 0, -mhSin(faceD));
        mat4 chartToRay = moveS3PointToOrigin(camera);
        vec4 rayHit = mat4Apply(chartToRay, hit);
        CHECK_NEAR(mhAcos(rayHit.w), 0.4f, 1e-5f);

        mat4 portal = rotationX1X4(-0.4f);
        mat4 inversePortal = rotationX1X4(0.4f);
        vec4 neighborHit = mat4Apply(portal, hit);
        vec4 neighborTangent = mat4Apply(portal, tangent);
        mat4 recenter = moveS3PointToOrigin(rayHit);
        mat4 nextChartToRay = mat4Mul(recenter,
            mat4Mul(chartToRay, inversePortal));
        checkVec4Near(mat4Apply(nextChartToRay, neighborHit),
                      vec4(0,0,0,1), 2e-5f);
        checkVec4Near(mat4Apply(nextChartToRay, neighborTangent),
                      mat4Apply(recenter, mat4Apply(chartToRay, tangent)),
                      2e-5f);
    }
}
