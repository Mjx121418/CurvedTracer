#pragma once
#include "GeometryCore/Scene.h"

#define GEO_ATLAS_CONTRACT_VERSION 9
#define GEO_ATLAS_PACKET_MAGIC 0x41545243
#define GEO_MAX_CHARTS 256
#define GEO_MAX_PORTALS 1024

namespace geo {

// 96 bytes: camera is expressed directly in its authored chart.
struct AtlasCamera {
    vec4 position;
    vec4 right;
    vec4 up;
    vec4 fwd;
    float fovTan;
    float aspect;
    float maxTraceDistance;
    float maxTraceHalfAngle;
    int chartId;
    int pad0;
    int pad1;
    int pad2;
};

// 48 bytes.
struct AtlasRenderControls {
    RenderControls shading;
    int maxChartHops;
    int maxLightHops;
    int maxLightStates;
    int pad0;
};

// 32 bytes.
struct AtlasCounts {
    int chartCount;
    int portalCount;
    int objectCount;
    int materialCount;
    int lightCount;
    int pad0;
    int pad1;
    int pad2;
};

// 192 bytes.
struct AtlasPacketHeader {
    PacketMeta meta;
    AtlasCamera camera;
    AtlasRenderControls controls;
    AtlasCounts counts;
};

// 32 bytes. Arrays referenced here are grouped by authored chart.
struct GPUChart {
    float angularRadius;
    float intrinsicRadius;
    int firstPortal;
    int portalCount;
    int firstObject;
    int objectCount;
    int firstLight;
    int lightCount;
};

// 96 bytes. Face equation uses the same compact-chart coefficients as Object.
struct GPUPortal {
    mat4 toNeighbor;
    vec3 a;
    float b;
    float c;
    int neighborChart;
    int reversePortal;
    int interiorSign; // interiorSign * (a.x + b.w - c) <= 0
};

#if !defined(__METAL_VERSION__)
static_assert(sizeof(AtlasCamera) == 96, "AtlasCamera must be 96 bytes");
static_assert(sizeof(AtlasRenderControls) == 48, "AtlasRenderControls must be 48 bytes");
static_assert(sizeof(AtlasCounts) == 32, "AtlasCounts must be 32 bytes");
static_assert(sizeof(AtlasPacketHeader) == 192, "AtlasPacketHeader must be 192 bytes");
static_assert(sizeof(GPUChart) == 32, "GPUChart must be 32 bytes");
static_assert(sizeof(GPUPortal) == 96, "GPUPortal must be 96 bytes");
#endif

} // namespace geo
