#include "test_framework.h"
#include "GeometryCore/Chart.h"
#include "GeometryCore/Mobius.h"
#include "GeometryCore/Scene.h"

#include <cstring>
#include <vector>

using namespace geo;

namespace {

mat4 lorentzBoostX(float rho) {
    mat4 m;
    float ch = mhCosh(rho), sh = mhSinh(rho);
    m.m[0] = ch;  m.m[1] = 0;   m.m[2] = 0;   m.m[3] = sh;
    m.m[4] = 0;   m.m[5] = 1;   m.m[6] = 0;   m.m[7] = 0;
    m.m[8] = 0;   m.m[9] = 0;   m.m[10] = 1;  m.m[11] = 0;
    m.m[12] = sh; m.m[13] = 0;  m.m[14] = 0;  m.m[15] = ch;
    return m;
}

mat4 rotationX1X4(float theta) {
    mat4 m;
    float c = mhCos(theta), s = mhSin(theta);
    m.m[0] = c;  m.m[1] = 0;   m.m[2] = 0;   m.m[3] = s;
    m.m[4] = 0;  m.m[5] = 1;   m.m[6] = 0;   m.m[7] = 0;
    m.m[8] = 0;  m.m[9] = 0;   m.m[10] = 1;  m.m[11] = 0;
    m.m[12] = -s; m.m[13] = 0; m.m[14] = 0;  m.m[15] = c;
    return m;
}

Mobius mobiusH3(const mat4& m) {
    Mobius r;
    r.kind = ModelKind::H3;
    r.m = m;
    return r;
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
    // ------------------------------------------------------------------
    // Scene packet sizes, printed for the Swift MemoryLayout check.
    // ------------------------------------------------------------------
    std::printf("Scene sizes: PacketMeta=%zu Camera=%zu RenderControls=%zu Counts=%zu Object=%zu Material=%zu PointLight=%zu Header=%zu\n",
                sizeof(PacketMeta), sizeof(Camera), sizeof(RenderControls), sizeof(Counts),
                sizeof(Object), sizeof(Material), sizeof(PointLight), sizeof(ScenePacketHeader));
    CHECK(sizeof(PacketMeta) == 16);
    CHECK(sizeof(Camera) == 64);
    CHECK(sizeof(RenderControls) == 32);
    CHECK(sizeof(Counts) == 16);
    CHECK(sizeof(Object) == 32);
    CHECK(sizeof(Material) == 16);
    CHECK(sizeof(PointLight) == 32);
    CHECK(sizeof(ScenePacketHeader) == 128);

    // ------------------------------------------------------------------
    // Single-chart H3 scene and byte layout.
    // ------------------------------------------------------------------
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed() == 0);
        float I[16] = {
            1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1
        };
        CHECK(atlas.add(0, I, 1) == 1);
        atlas.addMaterial(vec4(1.0f, 0.5f, 0.25f, 1.0f));
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0.2f, 0.0f, 0.0f), 0.3f, 0);
        atlas.addLight(0, vec3(0.0f, 0.0f, -0.4f), vec3(1.0f, 1.0f, 0.9f), 0.8f);
        atlas.setCamera(0.8f, 1.6f, vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1));
        atlas.setControls(5, 0.1f, 0.2f, 0.7f);

        int code = atlas.build(0, GEO_MAX_CHART_DEPTH);
        CHECK(code == 0);
        CHECK(atlas.packetSize() == 128 + 1 * 32 + 1 * 16 + 1 * 32);

        ScenePacketHeader h = readHeader(atlas);
        CHECK(h.meta.magic == GEO_PACKET_MAGIC);
        CHECK(h.meta.contractVersion == GEO_CONTRACT_VERSION);
        CHECK(h.meta.objectSize == 32);
        CHECK(h.meta.packetHeaderSize == 128);
        CHECK(h.camera.fovTan == 0.8f);
        CHECK(h.camera.aspect == 1.6f);
        CHECK(h.controls.maxBounces == 5);
        CHECK(h.controls.modelKind == GEO_MODEL_H3);
        CHECK(h.controls.falloffK == 0.1f);
        CHECK(h.controls.ambient == 0.2f);
        CHECK(h.controls.bounceAttenuation == 0.7f);
        CHECK(h.counts.objectCount == 1);
        CHECK(h.counts.materialCount == 1);
        CHECK(h.counts.lightCount == 1);

        Object o = readObject(atlas, 0);
        CHECK(o.kind == GEO_OBJECT_OPAQUE);
        CHECK(o.colorIdx == 0);
        CHECK_NEAR(o.center.x, 0.2f, 1e-6);
        CHECK_NEAR(o.center.y, 0.0f, 1e-6);
        CHECK_NEAR(o.center.z, 0.0f, 1e-6);
        CHECK_NEAR(o.radiusOrOffset, 0.3f, 1e-6);

        PointLight light = readPointLight(atlas, h.counts.objectCount, h.counts.materialCount, 0);
        CHECK_NEAR(light.position.x, 0.0f, 1e-6);
        CHECK_NEAR(light.position.y, 0.0f, 1e-6);
        CHECK_NEAR(light.position.z, -0.4f, 1e-6);
        CHECK_NEAR(light.color.x, 1.0f, 1e-6);
        CHECK_NEAR(light.color.y, 1.0f, 1e-6);
        CHECK_NEAR(light.color.z, 0.9f, 1e-6);
        CHECK_NEAR(light.intensity, 0.8f, 1e-6);
    }

    // ------------------------------------------------------------------
    // Two-chart scene flattens identically to direct camera-chart scene.
    // ------------------------------------------------------------------
    {
        const float rho = 0.7f;
        mat4 boostMat = lorentzBoostX(rho);
        Mobius boost = mobiusH3(boostMat);
        Mobius binv = boost.inverse();
        vec3 homeCenter(0.1f, -0.2f, 0.05f);
        float homeRadius = 0.15f;
        vec3 directCenter; float directRadius; bool directPlane = false;
        binv.applySphere(homeCenter, homeRadius, directCenter, directRadius, directPlane);
        CHECK(!directPlane);

        // Build the two-chart scene.
        Atlas twoAtlas;
        twoAtlas.start(GEO_MODEL_H3);
        CHECK(twoAtlas.seed() == 0);
        CHECK(twoAtlas.add(0, boostMat.m, 1) == 1);
        twoAtlas.addMaterial(vec4(1.0f, 1.0f, 1.0f, 1.0f));
        twoAtlas.addObject(1, GEO_OBJECT_OPAQUE, homeCenter, homeRadius, 0);
        CHECK(twoAtlas.build(0, GEO_MAX_CHART_DEPTH) == 0);
        CHECK(twoAtlas.packetSize() == 128 + 1 * 32 + 1 * 16);

        // Build the same scene directly in the camera chart.
        Atlas directAtlas;
        directAtlas.start(GEO_MODEL_H3);
        CHECK(directAtlas.seed() == 0);
        directAtlas.addMaterial(vec4(1.0f, 1.0f, 1.0f, 1.0f));
        directAtlas.addObject(0, GEO_OBJECT_OPAQUE, directCenter, directRadius, 0);
        CHECK(directAtlas.build(0, GEO_MAX_CHART_DEPTH) == 0);
        CHECK(directAtlas.packetSize() == twoAtlas.packetSize());

        // Byte compare the full packet (object order is canonical).
        CHECK(twoAtlas.packet().size() == directAtlas.packet().size());
        CHECK(std::memcmp(twoAtlas.packet().data(), directAtlas.packet().data(), twoAtlas.packet().size()) == 0);
    }

    // ------------------------------------------------------------------
    // Two-chart light flattens identically to direct camera-chart light.
    // ------------------------------------------------------------------
    {
        const float rho = 0.5f;
        mat4 boostMat = lorentzBoostX(rho);
        Mobius boost = mobiusH3(boostMat);
        Mobius binv = boost.inverse();
        vec3 homeLight(0.1f, -0.2f, 0.05f);
        vec3 directLight = binv.apply(homeLight);

        Atlas twoAtlas;
        twoAtlas.start(GEO_MODEL_H3);
        CHECK(twoAtlas.seed() == 0);
        CHECK(twoAtlas.add(0, boostMat.m, 1) == 1);
        twoAtlas.addMaterial(vec4(1.0f, 1.0f, 1.0f, 1.0f));
        twoAtlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0.0f, 0.0f, 0.1f), 0.05f, 0);
        twoAtlas.addLight(1, homeLight, vec3(1.0f, 0.9f, 0.8f), 0.7f);
        CHECK(twoAtlas.build(0, GEO_MAX_CHART_DEPTH) == 0);

        Atlas directAtlas;
        directAtlas.start(GEO_MODEL_H3);
        CHECK(directAtlas.seed() == 0);
        directAtlas.addMaterial(vec4(1.0f, 1.0f, 1.0f, 1.0f));
        directAtlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0.0f, 0.0f, 0.1f), 0.05f, 0);
        directAtlas.addLight(0, directLight, vec3(1.0f, 0.9f, 0.8f), 0.7f);
        CHECK(directAtlas.build(0, GEO_MAX_CHART_DEPTH) == 0);

        CHECK(twoAtlas.packet().size() == directAtlas.packet().size());
        CHECK(std::memcmp(twoAtlas.packet().data(), directAtlas.packet().data(), twoAtlas.packet().size()) == 0);
    }

    // ------------------------------------------------------------------
    // Flatten path independence: identity-matrix triangle, direct edge safe
    // vs unsafe (forces the longer safe path).
    // ------------------------------------------------------------------
    {
        float I[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};

        // Build with direct edge 0-2 safe -> shortest safe path is 0->2.
        Atlas atlasA;
        atlasA.start(GEO_MODEL_H3);
        CHECK(atlasA.seed() == 0);
        CHECK(atlasA.add(0, I, 1) == 1);
        CHECK(atlasA.add(1, I, 1) == 2);
        atlasA.link(0, 2, I, 1);
        atlasA.addMaterial(vec4(1.0f, 1.0f, 1.0f, 1.0f));
        atlasA.addObject(2, GEO_OBJECT_OPAQUE, vec3(0.1f, -0.2f, 0.05f), 0.15f, 0);
        CHECK(atlasA.build(0, GEO_MAX_CHART_DEPTH) == 0);
        std::vector<unsigned char> bytesA(atlasA.packet().begin(), atlasA.packet().end());

        // Rebuild with direct edge 0-2 unsafe -> safe path is 0->1->2.
        Atlas atlasB;
        atlasB.start(GEO_MODEL_H3);
        CHECK(atlasB.seed() == 0);
        CHECK(atlasB.add(0, I, 1) == 1);
        CHECK(atlasB.add(1, I, 1) == 2);
        atlasB.link(0, 2, I, 0);   // unsafe direct hop
        atlasB.addMaterial(vec4(1.0f, 1.0f, 1.0f, 1.0f));
        atlasB.addObject(2, GEO_OBJECT_OPAQUE, vec3(0.1f, -0.2f, 0.05f), 0.15f, 0);
        CHECK(atlasB.build(0, GEO_MAX_CHART_DEPTH) == 0);
        CHECK(atlasB.packet().size() == bytesA.size());
        CHECK(std::memcmp(bytesA.data(), atlasB.packet().data(), bytesA.size()) == 0);
    }

    // ------------------------------------------------------------------
    // Cocycle violation must be rejected.
    // ------------------------------------------------------------------
    {
        float I[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
        mat4 boostMat = lorentzBoostX(0.4f);

        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed() == 0);
        CHECK(atlas.add(0, I, 1) == 1);
        CHECK(atlas.add(1, I, 1) == 2);
        atlas.link(0, 2, boostMat.m, 1);   // inconsistent 0-2 edge
        int code = atlas.build(0, GEO_MAX_CHART_DEPTH);
        CHECK(code == 2);
        CHECK(atlas.lastError() == 2);
    }

    // ------------------------------------------------------------------
    // Invalid objects are rejected in authoring chart coordinates.
    // ------------------------------------------------------------------
    {
        // H3 OPAQUE sphere must be strictly inside the unit ball.
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed() == 0);
        atlas.addObject(0, GEO_OBJECT_OPAQUE, vec3(0.0f, 0.0f, 0.0f), 1.0f, 0);
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH) == 3);

        // H3 MIRROR sphere must satisfy |c|^2 == r^2 + 1.
        Atlas atlas2;
        atlas2.start(GEO_MODEL_H3);
        CHECK(atlas2.seed() == 0);
        atlas2.addObject(0, GEO_OBJECT_MIRROR, vec3(0.0f, 0.0f, 0.0f), 0.5f, 0);
        CHECK(atlas2.build(0, GEO_MAX_CHART_DEPTH) == 3);

        // H3 MIRROR plane offset must be ~0.
        Atlas atlas3;
        atlas3.start(GEO_MODEL_H3);
        CHECK(atlas3.seed() == 0);
        atlas3.addObject(0, GEO_OBJECT_PLANE, vec3(1.0f, 0.0f, 0.0f), 0.5f, 0);
        CHECK(atlas3.build(0, GEO_MAX_CHART_DEPTH) == 3);

        // Basic invalid object fields are also rejected by build.
        Atlas atlas4;
        atlas4.start(GEO_MODEL_H3);
        CHECK(atlas4.seed() == 0);
        atlas4.addObject(0, GEO_OBJECT_OPAQUE, vec3(0.0f, 0.0f, 0.0f), -0.5f, 0);   // negative radius
        CHECK(atlas4.build(0, GEO_MAX_CHART_DEPTH) == 3);

        // Invalid lights are rejected by build.
        Atlas atlas5;
        atlas5.start(GEO_MODEL_H3);
        CHECK(atlas5.seed() == 0);
        atlas5.addLight(0, vec3(0.0f, 0.0f, 0.0f), vec3(1.0f, 1.0f, 1.0f), -0.1f);  // negative intensity
        CHECK(atlas5.build(0, GEO_MAX_CHART_DEPTH) == 3);

        Atlas atlas6;
        atlas6.start(GEO_MODEL_H3);
        CHECK(atlas6.seed() == 0);
        atlas6.addLight(0, vec3(0.0f, 0.0f, 1.0f), vec3(1.0f, 1.0f, 1.0f), 1.0f);   // H3 light on/outside ball
        CHECK(atlas6.build(0, GEO_MAX_CHART_DEPTH) == 3);
    }

    // ------------------------------------------------------------------
    // S3 antipode chart: sphere near the projection point flattens without NaN.
    // ------------------------------------------------------------------
    {
        mat4 antipode = rotationX1X4(3.14159265f);

        Atlas atlas;
        atlas.start(GEO_MODEL_S3);
        CHECK(atlas.seed() == 0);
        CHECK(atlas.add(0, antipode.m, 1) == 1);
        atlas.addMaterial(vec4(1.0f, 1.0f, 1.0f, 1.0f));
        atlas.addObject(1, GEO_OBJECT_OPAQUE, vec3(0.0f, 0.0f, 0.0f), 0.2f, 0);
        int code = atlas.build(0, GEO_MAX_CHART_DEPTH);
        CHECK(code == 0);

        ScenePacketHeader h = readHeader(atlas);
        CHECK(h.counts.objectCount == 1);
        CHECK(h.controls.modelKind == GEO_MODEL_S3);
        Object o = readObject(atlas, 0);
        CHECK(o.kind == GEO_OBJECT_OPAQUE);
        CHECK(std::isfinite(o.center.x) && std::isfinite(o.center.y) && std::isfinite(o.center.z));
        CHECK(std::isfinite(o.radiusOrOffset));
        CHECK(o.radiusOrOffset > 0.0f);
    }

    // ------------------------------------------------------------------
    // Valid S3 mirror sphere and H3 mirror sphere are accepted.
    // ------------------------------------------------------------------
    {
        // S3: |c|^2 = r^2 - 1.  c=(2,0,0), r=sqrt(5).
        Atlas s3Atlas;
        s3Atlas.start(GEO_MODEL_S3);
        CHECK(s3Atlas.seed() == 0);
        float r = mhSqrt(5.0f);
        s3Atlas.addObject(0, GEO_OBJECT_MIRROR, vec3(2.0f, 0.0f, 0.0f), r, 0);
        CHECK(s3Atlas.build(0, GEO_MAX_CHART_DEPTH) == 0);

        // H3: |c|^2 = r^2 + 1.  c=(2,0,0), r=sqrt(3).
        Atlas h3Atlas;
        h3Atlas.start(GEO_MODEL_H3);
        CHECK(h3Atlas.seed() == 0);
        r = mhSqrt(3.0f);
        h3Atlas.addObject(0, GEO_OBJECT_MIRROR, vec3(2.0f, 0.0f, 0.0f), r, 0);
        CHECK(h3Atlas.build(0, GEO_MAX_CHART_DEPTH) == 0);
    }

    // ------------------------------------------------------------------
    // Unknown camera chart / model kind mismatch.
    // ------------------------------------------------------------------
    {
        Atlas atlas;
        atlas.start(GEO_MODEL_H3);
        CHECK(atlas.seed() == 0);
        CHECK(atlas.build(1, GEO_MAX_CHART_DEPTH) == 4);
        CHECK(atlas.build(0, 0) == 5);          // depth bound invalid
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH + 1) == 5);
    }
    {
        Atlas atlas;
        atlas.start(2);                          // invalid model kind
        CHECK(atlas.build(0, GEO_MAX_CHART_DEPTH) == 6);
    }
}
