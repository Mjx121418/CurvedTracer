#include "TraceShared.metalh"

kernel void raytrace(device const uchar *packet [[buffer(0)]],
                     device TraceStatsGPU *stats [[buffer(1)]],
                     texture2d<float, access::write> output [[texture(0)]],
                     uint2 pixel [[thread_position_in_grid]],
                     uint laneInSIMDGroup [[thread_index_in_simdgroup]],
                     uint simdGroupIndex [[simdgroup_index_in_threadgroup]],
                     uint threadIndex [[thread_index_in_threadgroup]],
                     uint2 threadsPerGroup [[threads_per_threadgroup]],
                     uint threadsPerSIMDGroup [[threads_per_simdgroup]]) {
    threadgroup uint rayPartials[32];
    threadgroup uint hopPartials[32];
    threadgroup uint compoundPartials[32];
    threadgroup uint maximumPartials[32];
    threadgroup uint limitedPartials[32];
    threadgroup uint testPartials[32];
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height())
        return;

    uint error = validatePacket(packet);
    if (error) {
        atomic_fetch_or_explicit(&stats->errorBits, error, memory_order_relaxed);
        output.write(float4(1, 0, 1, 1), pixel);
        return;
    }

    device const HeaderGPU *h = packetHeader(packet);
    TraceResult result = traceDeterministicSample(
        h,
        packetCharts(packet),
        packetPortals(packet, h),
        packetObjects(packet, h),
        packetQuadrics(packet, h),
        packetClips(packet, h),
        packetMaterials(packet, h),
        packetLights(packet, h),
        float2(pixel) + 0.5f,
        uint2(output.get_width(), output.get_height()),
        false);

    if (result.errorBits)
        atomic_fetch_or_explicit(
            &stats->errorBits, result.errorBits, memory_order_relaxed);
    uint threadsInGroup = threadsPerGroup.x * threadsPerGroup.y;
    uint simdGroupCount =
    (threadsInGroup + threadsPerSIMDGroup - 1) / threadsPerSIMDGroup;
    recordTraceStats(
        stats, result.portalHops, result.compoundPortalHops,
        result.portalTests, result.hitHopLimit, laneInSIMDGroup,
        simdGroupIndex, threadIndex, simdGroupCount, rayPartials,
        hopPartials, compoundPartials, maximumPartials, limitedPartials,
        testPartials);
    output.write(float4(clamp(result.radiance, 0.0f, 1.0f), 1), pixel);
}

struct PhotoFrameGPU {
    uint sampleIndex;
    float exposure;
    uint pad1;
    uint pad2;
};

static uint photoHash(uint input) {
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static float photoUnitFloat(uint bits) {
    return float(bits >> 8u) * (1.0f / 16777216.0f);
}

static float2 photoSubpixelOffset(uint2 pixel, uint width, uint sampleIndex) {
    uint pixelIndex = pixel.y * width + pixel.x;
    uint seed = pixelIndex ^ (sampleIndex * 2246822519u);
    return float2(
        photoUnitFloat(photoHash(seed ^ 0x68bc21ebu)),
        photoUnitFloat(photoHash(seed ^ 0x02e5be93u)));
}

kernel void photoTrace(
    device const uchar *packet [[buffer(0)]],
    device TraceStatsGPU *stats [[buffer(1)]],
    constant PhotoFrameGPU &frame [[buffer(2)]],
    texture2d<float, access::write> output [[texture(0)]],
    texture2d<float, access::read_write> accumulation [[texture(1)]],
    uint2 pixel [[thread_position_in_grid]],
    uint laneInSIMDGroup [[thread_index_in_simdgroup]],
    uint simdGroupIndex [[simdgroup_index_in_threadgroup]],
    uint threadIndex [[thread_index_in_threadgroup]],
    uint2 threadsPerGroup [[threads_per_threadgroup]],
    uint threadsPerSIMDGroup [[threads_per_simdgroup]]
) {
    threadgroup uint rayPartials[32];
    threadgroup uint hopPartials[32];
    threadgroup uint compoundPartials[32];
    threadgroup uint maximumPartials[32];
    threadgroup uint limitedPartials[32];
    threadgroup uint testPartials[32];
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height())
        return;

    uint error = validatePacket(packet);
    if (output.get_width() != accumulation.get_width() ||
        output.get_height() != accumulation.get_height())
        error |= 1u;
    if (error) {
        atomic_fetch_or_explicit(&stats->errorBits, error, memory_order_relaxed);
        output.write(float4(1, 0, 1, 1), pixel);
        return;
    }

    device const HeaderGPU *h = packetHeader(packet);
    float2 offset = photoSubpixelOffset(
        pixel, output.get_width(), frame.sampleIndex);
    TraceResult result = traceDeterministicSample(
        h,
        packetCharts(packet),
        packetPortals(packet, h),
        packetObjects(packet, h),
        packetQuadrics(packet, h),
        packetClips(packet, h),
        packetMaterials(packet, h),
        packetLights(packet, h),
        float2(pixel) + offset,
        uint2(output.get_width(), output.get_height()),
        true);

    float3 sample = result.radiance;
    if (!all(isfinite(sample))) {
        result.errorBits |= 64u;
        sample = float3(1, 0, 1);
    }
    sample = max(sample, 0.0f);
    float3 sum = frame.sampleIndex == 0
    ? sample
    : accumulation.read(pixel).rgb + sample;
    accumulation.write(float4(sum, 1), pixel);

    float3 average = sum / float(frame.sampleIndex + 1u);
    float3 exposed = average * max(frame.exposure, 0.0f);
    float3 mapped = exposed / (1.0f + exposed);
    output.write(float4(mapped, 1), pixel);

    if (result.errorBits)
        atomic_fetch_or_explicit(
            &stats->errorBits, result.errorBits, memory_order_relaxed);
    uint threadsInGroup = threadsPerGroup.x * threadsPerGroup.y;
    uint simdGroupCount =
    (threadsInGroup + threadsPerSIMDGroup - 1) / threadsPerSIMDGroup;
    recordTraceStats(
        stats, result.portalHops, result.compoundPortalHops,
        result.portalTests, result.hitHopLimit, laneInSIMDGroup,
        simdGroupIndex, threadIndex, simdGroupCount, rayPartials,
        hopPartials, compoundPartials, maximumPartials, limitedPartials,
        testPartials);
}
