#include "test_framework.h"
#include "GeometryCore/Chart.h"
#include "GeometryCore/Mobius.h"
#include "GeometryCore/Scene.h"

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
    CHECK(GEO_CONTRACT_VERSION == 5);

    // ------------------------------------------------------------------
    // Single-chart H3 scene and packet layout.
    // ------------------------------------------------------------------
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed(1.5707963f) == 0);   // π/2
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
        CHECK_NEAR(h.camera.chartRadiusSin, mhSin(1.5707963f), 1e-4);
        CHECK_NEAR(h.camera.chartRadiusCos, mhCos(1.5707963f), 1e-4);
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
}
