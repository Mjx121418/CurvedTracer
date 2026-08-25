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

static uint photoRandomState(uint2 pixel, uint width, uint sampleIndex) {
    uint pixelIndex = pixel.y * width + pixel.x;
    return photoHash(
        pixelIndex ^ photoHash(sampleIndex ^ 0x9e3779b9u) ^ 0x68bc21ebu);
}

static float photoRandom(thread uint &state) {
    state = photoHash(state);
    return photoUnitFloat(state);
}

static float2 photoSubpixelOffset(thread uint &state) {
    return float2(
        photoRandom(state),
        photoRandom(state));
}

static float4 photoAmbientAxis(int index) {
    if (index == 0)
        return float4(1, 0, 0, 0);
    if (index == 1)
        return float4(0, 1, 0, 0);
    if (index == 2)
        return float4(0, 0, 1, 0);
    return float4(0, 0, 0, 1);
}

static float4 photoProjectToTangent(float4 vector, float4 point) {
    if (SPACE_FORM == MODEL_R3)
        return float4(vector.xyz, 0);
    return vector - kappa() * mdot(vector, point) * point;
}

static bool photoCanonicalNormal(
    float4 point,
    float4 normal,
    thread float4 &canonicalNormal
) {
    canonicalNormal = tangentNormalize(
        photoProjectToTangent(normal, point));
    return all(isfinite(canonicalNormal)) &&
    mdot(canonicalNormal, canonicalNormal) > 0.5f;
}

static bool photoTangentFrame(
    float4 point,
    float4 normal,
    thread float4 &first,
    thread float4 &second
) {
    float bestFirstNorm = 0.0f;
    first = float4(0);
    int candidateCount = SPACE_FORM == MODEL_R3 ? 3 : 4;
    for (int axis = 0; axis < candidateCount; ++axis) {
        float4 candidate = photoProjectToTangent(
            photoAmbientAxis(axis), point);
        candidate -= mdot(candidate, normal) * normal;
        float candidateNorm = mdot(candidate, candidate);
        if (isfinite(candidateNorm) && candidateNorm > bestFirstNorm) {
            bestFirstNorm = candidateNorm;
            first = candidate;
        }
    }
    if (bestFirstNorm <= EPS * EPS)
        return false;
    first *= rsqrt(bestFirstNorm);

    float bestSecondNorm = 0.0f;
    second = float4(0);
    for (int axis = 0; axis < candidateCount; ++axis) {
        float4 candidate = photoProjectToTangent(
            photoAmbientAxis(axis), point);
        candidate -= mdot(candidate, normal) * normal;
        candidate -= mdot(candidate, first) * first;
        float candidateNorm = mdot(candidate, candidate);
        if (isfinite(candidateNorm) && candidateNorm > bestSecondNorm) {
            bestSecondNorm = candidateNorm;
            second = candidate;
        }
    }
    if (bestSecondNorm <= EPS * EPS)
        return false;
    second *= rsqrt(bestSecondNorm);
    return all(isfinite(first)) && all(isfinite(second)) &&
    mdot(first, first) > 0.5f && mdot(second, second) > 0.5f;
}

static bool photoCosineHemisphere(
    float4 point,
    float4 normal,
    thread uint &randomState,
    thread float4 &direction
) {
    float4 first, second;
    if (!photoTangentFrame(point, normal, first, second))
        return false;
    float radialSample = photoRandom(randomState);
    float azimuthSample = photoRandom(randomState);
    float radius = sqrt(radialSample);
    float azimuth = TWO_PI * azimuthSample;
    direction = tangentNormalize(
        radius * cos(azimuth) * first +
        radius * sin(azimuth) * second +
        sqrt(max(1.0f - radialSample, 0.0f)) * normal);
    return all(isfinite(direction)) && mdot(direction, direction) > 0.5f;
}

static float3 photoDirectLambertian(
    Event hit,
    float4 normal,
    MaterialGPU material,
    int chartId,
    device const HeaderGPU *h,
    device const ChartGPU *charts,
    device const PortalGPU *portals,
    device const ObjectGPU *objects,
    device const QuadricGPU *quadrics,
    device const PrimitiveClipGPU *clips,
    device const LightGPU *lights,
    thread TraceResult &result
) {
    const float inversePi = 0.31830988618f;
    float3 direct = 0;
    int chartStack[5], nextPortal[5], incoming[5];
    float4x4 toStart[5];
    chartStack[0] = chartId;
    nextPortal[0] = -1;
    incoming[0] = -1;
    toStart[0] = float4x4(1);
    int depth = 0, stateCount = 1;
    while (depth >= 0) {
        ChartGPU chart = charts[chartStack[depth]];
        if (nextPortal[depth] < 0) {
            for (int local = 0; local < chart.lightCount; ++local) {
                LightGPU light = lights[chart.firstLight + local];
                float4 lightPosition = toStart[depth] * light.position;
                float distanceToLight = intrinsicDistance(
                    hit.point, lightPosition);
                if (!isfinite(distanceToLight) || distanceToLight < EPS)
                    continue;

                float4 lightDirection = directionTo(
                    hit.point, lightPosition, distanceToLight);
                float cosine = clamp(
                    mdot(normal, lightDirection), 0.0f, 1.0f);
                if (cosine <= 0.0f)
                    continue;

                RayState shadowRay;
                shadowRay.point = hit.point;
                shadowRay.tangent = lightDirection;
                shadowRay.chartId = chartId;
                VisibilityResult visibility = traceAny(
                    shadowRay, distanceToLight - SELF_EPS,
                    h->controls.maxChartHops, charts, portals, objects,
                    quadrics, clips);
                result.errorBits |= visibility.errorBits;
                result.portalHops += visibility.portalHops;
                result.compoundPortalHops += visibility.compoundPortalHops;
                result.portalTests += visibility.portalTests;
                result.hitHopLimit =
                result.hitHopLimit || visibility.hitHopLimit;
                if (visibility.blocked)
                    continue;

                float area = max(areaRadius(distanceToLight), 1e-3f);
                float attenuation = light.intensity /
                (1.0f + h->controls.falloffK * area * area);
                direct +=
                float3(light.color) * attenuation * cosine * inversePi;
            }
            nextPortal[depth] = 0;
        }
        if (!ENABLE_PORTALS || depth >= h->controls.maxLightHops ||
            nextPortal[depth] >= chart.portalCount) {
            --depth;
            continue;
        }
        int portalIndex = chart.firstPortal + nextPortal[depth]++;
        if (portalIndex == incoming[depth])
            continue;
        if (stateCount++ >= h->controls.maxLightStates) {
            result.errorBits |= 16u;
            break;
        }
        PortalGPU portal = portals[portalIndex];
        int child = depth + 1;
        chartStack[child] = portal.neighborChart;
        nextPortal[child] = -1;
        incoming[child] = portal.reversePortal;
        toStart[child] =
        toStart[depth] * portals[portal.reversePortal].toNeighbor;
        depth = child;
    }
    return clamp(material.color.rgb, 0.0f, 1.0f) * direct;
}

static TraceResult traceLambertianSample(
    device const HeaderGPU *h,
    device const ChartGPU *charts,
    device const PortalGPU *portals,
    device const ObjectGPU *objects,
    device const QuadricGPU *quadrics,
    device const PrimitiveClipGPU *clips,
    device const MaterialGPU *materials,
    device const LightGPU *lights,
    float2 samplePosition,
    uint2 renderSize,
    thread uint &randomState
) {
    TraceResult result{};
    RayState ray;
    if (!makeCameraRay(h, samplePosition, renderSize, ray)) {
        result.errorBits = 4u;
        result.radiance = float3(1, 0, 1);
        return result;
    }

    float3 radiance = 0;
    float3 throughput = 1;
    int maxBounces = clamp(h->controls.maxBounces, 0, 64);
    for (int depth = 0; depth <= maxBounces; ++depth) {
        SurfaceTraceResult surface = traceToSurface(
            ray, h->camera.maxTraceDistance, h->controls.maxChartHops,
            charts, portals, objects, quadrics, clips);
        result.errorBits |= surface.errorBits;
        result.portalHops += surface.portalHops;
        result.compoundPortalHops += surface.compoundPortalHops;
        result.portalTests += surface.portalTests;
        result.hitHopLimit = result.hitHopLimit || surface.hitHopLimit;
        if (!surface.hit)
            break;

        Event hit = surface.event;
        ObjectGPU object = objects[hit.index];
        if (object.colorIdx < 0 ||
            object.colorIdx >= h->counts.materialCount) {
            result.errorBits |= 1u;
            radiance = float3(1, 0, 1);
            break;
        }
        RayState canonicalHit;
        canonicalHit.point = hit.point;
        canonicalHit.tangent = hit.tangent;
        canonicalHit.chartId = surface.chartId;
        if (!canonicalizeRayState(
                canonicalHit.point, canonicalHit.tangent)) {
            result.errorBits |= 4u;
            break;
        }
        hit.point = canonicalHit.point;
        hit.tangent = canonicalHit.tangent;
        hit.normal = objectNormal(object, hit.point, quadrics);
        MaterialGPU material = materials[object.colorIdx];
        float4 normal;
        if (!photoCanonicalNormal(hit.point, hit.normal, normal)) {
            result.errorBits |= 32u;
            break;
        }
        if (mdot(normal, -hit.tangent) < 0.0f)
            normal = -normal;

        if (object.responseKind == RESPONSE_MIRROR) {
            if (depth == maxBounces)
                break;
            float opacity = clamp(material.specular.a, 0.0f, 1.0f);
            throughput *= clamp(material.specular.rgb * opacity, 0.0f, 1.0f);
            ray.point = hit.point;
            ray.tangent = tangentNormalize(
                hit.tangent - 2.0f * mdot(hit.tangent, normal) * normal);
            ray.chartId = surface.chartId;
        } else if (object.responseKind == RESPONSE_OPAQUE) {
            radiance += throughput * photoDirectLambertian(
                hit, normal, material, surface.chartId, h, charts, portals,
                objects, quadrics, clips, lights, result);
            if (depth == maxBounces)
                break;
            throughput *= clamp(material.color.rgb, 0.0f, 1.0f);
            ray.point = hit.point;
            if (!photoCosineHemisphere(
                    hit.point, normal, randomState, ray.tangent)) {
                result.errorBits |= 4u;
                break;
            }
            ray.chartId = surface.chartId;
        } else {
            break;
        }

        if (max(max(throughput.r, throughput.g), throughput.b) <= EPS)
            break;
        if (!canonicalizeRayState(ray.point, ray.tangent)) {
            result.errorBits |= 4u;
            break;
        }
    }

    result.radiance = radiance;
    return result;
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
    uint randomState = photoRandomState(
        pixel, output.get_width(), frame.sampleIndex);
    float2 offset = photoSubpixelOffset(randomState);
    device const ChartGPU *charts = packetCharts(packet);
    device const PortalGPU *portals = packetPortals(packet, h);
    device const ObjectGPU *objects = packetObjects(packet, h);
    device const QuadricGPU *quadrics = packetQuadrics(packet, h);
    device const PrimitiveClipGPU *clips = packetClips(packet, h);
    device const MaterialGPU *materials = packetMaterials(packet, h);
    device const LightGPU *lights = packetLights(packet, h);
    TraceResult result = traceLambertianSample(
        h, charts, portals, objects, quadrics, clips, materials, lights,
        float2(pixel) + offset,
        uint2(output.get_width(), output.get_height()), randomState);

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
