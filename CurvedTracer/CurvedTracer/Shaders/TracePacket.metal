#ifndef CURVED_TRACER_TRACE_PACKET_METAL
#define CURVED_TRACER_TRACE_PACKET_METAL

// Packet validation, accessors, and camera rays.

#include "TraceMath.metal"

static uint validatePacket(device const uchar *packet) {
    device const HeaderGPU *h =
    reinterpret_cast<device const HeaderGPU *>(packet);
    uint error = 0;
    if (h->meta.magic != PACKET_MAGIC ||
        h->meta.contractVersion != CONTRACT_VERSION ||
        h->meta.objectSize != OBJECT_SIZE ||
        h->meta.packetHeaderSize != HEADER_SIZE)
        error |= 1;
    if (h->controls.modelKind != SPACE_FORM)
        error |= 2;
    bool countsValid =
    h->counts.chartCount > 0 && h->counts.chartCount <= 256 &&
    h->counts.portalCount >= 0 && h->counts.portalCount <= 1024 &&
    h->counts.objectCount >= 0 && h->counts.objectCount <= 4096 &&
    h->counts.materialCount >= 0 && h->counts.materialCount <= 256 &&
    h->counts.lightCount >= 0 && h->counts.lightCount <= 16 &&
    h->counts.quadricCount >= 0 && h->counts.quadricCount <= MAX_QUADRICS &&
    h->counts.clipCount >= 0 && h->counts.clipCount <= 65536;
    if (!countsValid)
        error |= 1;
    if (h->camera.chartId < 0 || h->camera.chartId >= h->counts.chartCount ||
        h->controls.maxChartHops <= 0 || h->controls.maxChartHops > 128 ||
        h->controls.maxLightHops < 0 || h->controls.maxLightHops > 4 ||
        h->controls.maxLightStates <= 0 || h->controls.maxLightStates > 256)
        error |= 1;
    if (!ENABLE_PORTALS && h->counts.portalCount != 0)
        error |= 2;
    return error;
}

static device const HeaderGPU *packetHeader(device const uchar *packet) {
    return reinterpret_cast<device const HeaderGPU *>(packet);
}

static device const ChartGPU *packetCharts(device const uchar *packet) {
    return reinterpret_cast<device const ChartGPU *>(packet + HEADER_SIZE);
}

static device const PortalGPU *packetPortals(device const uchar *packet,
                                      device const HeaderGPU *h) {
    uint offset = HEADER_SIZE + h->counts.chartCount * sizeof(ChartGPU);
    return reinterpret_cast<device const PortalGPU *>(packet + offset);
}

static device const ObjectGPU *packetObjects(device const uchar *packet,
                                      device const HeaderGPU *h) {
    uint offset = HEADER_SIZE + h->counts.chartCount * sizeof(ChartGPU) +
    h->counts.portalCount * sizeof(PortalGPU);
    return reinterpret_cast<device const ObjectGPU *>(packet + offset);
}

static device const QuadricGPU *packetQuadrics(device const uchar *packet,
                                        device const HeaderGPU *h) {
    uint offset = HEADER_SIZE + h->counts.chartCount * sizeof(ChartGPU) +
    h->counts.portalCount * sizeof(PortalGPU) +
    h->counts.objectCount * sizeof(ObjectGPU);
    return reinterpret_cast<device const QuadricGPU *>(packet + offset);
}

static device const PrimitiveClipGPU *packetClips(device const uchar *packet,
                                           device const HeaderGPU *h) {
    uint offset = HEADER_SIZE + h->counts.chartCount * sizeof(ChartGPU) +
    h->counts.portalCount * sizeof(PortalGPU) +
    h->counts.objectCount * sizeof(ObjectGPU) +
    h->counts.quadricCount * sizeof(QuadricGPU);
    return reinterpret_cast<device const PrimitiveClipGPU *>(packet + offset);
}

static device const MaterialGPU *packetMaterials(device const uchar *packet,
                                          device const HeaderGPU *h) {
    uint offset = HEADER_SIZE + h->counts.chartCount * sizeof(ChartGPU) +
    h->counts.portalCount * sizeof(PortalGPU) +
    h->counts.objectCount * sizeof(ObjectGPU) +
    h->counts.quadricCount * sizeof(QuadricGPU) +
    h->counts.clipCount * sizeof(PrimitiveClipGPU);
    return reinterpret_cast<device const MaterialGPU *>(packet + offset);
}

static device const LightGPU *packetLights(device const uchar *packet,
                                    device const HeaderGPU *h) {
    uint offset = HEADER_SIZE + h->counts.chartCount * sizeof(ChartGPU) +
    h->counts.portalCount * sizeof(PortalGPU) +
    h->counts.objectCount * sizeof(ObjectGPU) +
    h->counts.quadricCount * sizeof(QuadricGPU) +
    h->counts.clipCount * sizeof(PrimitiveClipGPU) +
    h->counts.materialCount * sizeof(MaterialGPU);
    return reinterpret_cast<device const LightGPU *>(packet + offset);
}

struct TraceResult {
    float3 radiance;
    uint errorBits;
    uint portalHops;
    uint compoundPortalHops;
    uint portalTests;
    bool hitHopLimit;
};

static bool makeCameraRay(
    device const HeaderGPU *h,
    float2 samplePosition,
    uint2 renderSize,
    thread RayState &ray
) {
    float2 uv = samplePosition / float2(renderSize);
    float2 screen = 2 * uv - 1;
    screen.y = -screen.y;
    float renderAspect = float(renderSize.x) / float(renderSize.y);
    ray.point = h->camera.position;
    ray.tangent = tangentNormalize(
        h->camera.fwd +
        screen.x * renderAspect * h->camera.fovTan * h->camera.right +
        screen.y * h->camera.fovTan * h->camera.up);
    ray.chartId = h->camera.chartId;
    return canonicalizeRayState(ray.point, ray.tangent);
}


#endif
