#pragma once
#include "GeometryCore/Scene.h"

#define GEO_ATLAS_CONTRACT_VERSION GEO_CONTRACT_VERSION
#define GEO_ATLAS_PACKET_MAGIC GEO_PACKET_MAGIC

namespace geo {

struct GPUChart {
    // Reserved version-15 fields retained to preserve the 32-byte layout.
    float reserved0;
    float reserved1;
    int firstPortal;
    int portalCount;
    int firstObject;
    int objectCount;
    int firstLight;
    int lightCount;
};

struct GPUPortal {
    mat4 toNeighbor;
    vec4 normal;
    float offset;
    int neighborChart;
    // Light-lift traversal uses this as both its parent back-edge and the
    // source of the neighbor-to-current inverse map. Primary rays do not.
    int reversePortal;
    int pad0;
};

using AtlasCamera = Camera;
using AtlasRenderControls = RenderControls;
using AtlasCounts = Counts;
using AtlasPacketHeader = ScenePacketHeader;

#if !defined(__METAL_VERSION__)
static_assert(sizeof(GPUChart) == 32, "GPUChart must be 32 bytes");
static_assert(sizeof(GPUPortal) == 96, "GPUPortal must be 96 bytes");
#endif

} // namespace geo
