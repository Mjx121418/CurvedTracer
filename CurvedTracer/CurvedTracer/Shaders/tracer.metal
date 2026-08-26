#include "TraceShared.metalh"

struct FrameGPU {
    uint sampleIndex;
    float exposure;
    uint pad1;
    uint pad2;
};

kernel void raytrace(device const uchar *packet [[buffer(0)]],
                     device TraceStatsGPU *stats [[buffer(1)]],
                     constant FrameGPU &frame [[buffer(2)]],
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
    output.write(
        float4(toneMapRadiance(result.radiance, frame.exposure), 1), pixel);
}

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

static bool photoTangentBasis(
    float4 point,
    thread float4 &first,
    thread float4 &second,
    thread float4 &third
) {
    float bestNorm = 0.0f;
    third = float4(0);
    int candidateCount = SPACE_FORM == MODEL_R3 ? 3 : 4;
    for (int axis = 0; axis < candidateCount; ++axis) {
        float4 candidate = bsdfProjectToTangent(
            bsdfAmbientAxis(axis), point);
        float candidateNorm = mdot(candidate, candidate);
        if (isfinite(candidateNorm) && candidateNorm > bestNorm) {
            bestNorm = candidateNorm;
            third = candidate;
        }
    }
    if (bestNorm <= EPS * EPS)
        return false;
    third *= rsqrt(bestNorm);
    return bsdfTangentFrame(point, third, first, second);
}

static bool photoCanonicalPoint(thread float4 &point) {
    if (SPACE_FORM == MODEL_R3) {
        point.w = 1.0f;
        return all(isfinite(point));
    }
    float pointNorm = mdot(point, point);
    if (!isfinite(pointNorm) || kappa() * pointNorm <= EPS)
        return false;
    point *= rsqrt(kappa() * pointNorm);
    return all(isfinite(point)) &&
    (SPACE_FORM != MODEL_H3 || point.w > 0.0f);
}

static bool photoSampleSphericalEmitter(
    float4 center,
    float radius,
    thread uint &randomState,
    thread float4 &samplePoint,
    thread float4 &sampleNormal
) {
    if (!photoCanonicalPoint(center))
        return false;
    float4 first, second, third;
    if (!photoTangentBasis(center, first, second, third))
        return false;
    float z = 1.0f - 2.0f * photoRandom(randomState);
    float azimuth = TWO_PI * photoRandom(randomState);
    float radialPart = sqrt(max(1.0f - z * z, 0.0f));
    float4 radialDirection =
    radialPart * cos(azimuth) * first +
    radialPart * sin(azimuth) * second + z * third;
    float C, S;
    radial(radius, C, S);
    samplePoint = C * center + S * radialDirection;
    sampleNormal = -kappa() * S * center + C * radialDirection;
    return canonicalizeRayState(samplePoint, sampleNormal);
}

static float photoSphericalEmitterRoot(
    float4 center,
    float radius,
    float4 point,
    float4 tangent,
    float maximum,
    device const QuadricGPU *quadrics,
    device const PrimitiveClipGPU *clips,
    thread uint &errorBits
) {
    ObjectGPU emitter{};
    emitter.clipCount = 0;
    if (SPACE_FORM == MODEL_R3) {
        emitter.equationKind = EQUATION_R3_SPHERE;
        emitter.geometry = center;
        emitter.parameter = radius;
    } else {
        emitter.equationKind = EQUATION_LINEAR;
        emitter.geometry = -center;
        emitter.parameter = SPACE_FORM == MODEL_S3
        ? -cos(radius)
        : cosh(radius);
    }
    return objectRoot(
        emitter, point, tangent, SELF_EPS, maximum, quadrics, clips,
        errorBits);
}

static float photoPowerHeuristic(float firstPDF, float secondPDF) {
    if (!isfinite(firstPDF) || !isfinite(secondPDF) ||
        firstPDF < 0.0f || secondPDF < 0.0f)
        return 0.0f;
    float scale = max(firstPDF, secondPDF);
    if (scale <= 0.0f)
        return 0.0f;
    float first = firstPDF / scale;
    float second = secondPDF / scale;
    float firstSquared = first * first;
    float secondSquared = second * second;
    return firstSquared / max(firstSquared + secondSquared, EPS * EPS);
}

static float3 photoDirectLighting(
    Event hit,
    float4 normal,
    MaterialGPU material,
    int responseKind,
    int chartId,
    device const HeaderGPU *h,
    device const ChartGPU *charts,
    device const PortalGPU *portals,
    device const ObjectGPU *objects,
    device const QuadricGPU *quadrics,
    device const PrimitiveClipGPU *clips,
    device const LightGPU *lights,
    thread TraceResult &result,
    thread uint &randomState,
    bool hasBSDFSample,
    BSDFSample bsdfSample
) {
    float3 direct = 0;
    int chartStack[5], nextPortal[5], incoming[5];
    float4x4 toStart[5];
    chartStack[0] = chartId;
    nextPortal[0] = -1;
    incoming[0] = -1;
    toStart[0] = float4x4(1);
    int depth = 0, stateCount = 1;
    float nearestBSDFDistance = INF;
    LightGPU nearestBSDFLight{};
    float4 nearestBSDFCenter = float4(0);
    while (depth >= 0) {
        ChartGPU chart = charts[chartStack[depth]];
        if (nextPortal[depth] < 0) {
            for (int local = 0; local < chart.lightCount; ++local) {
                LightGPU light = lights[chart.firstLight + local];
                float4 lightCenter = toStart[depth] * light.position;
                float4 lightPosition = lightCenter;
                float4 lightNormal = float4(0);
                if (light.kind == LIGHT_SPHERE) {
                    if (light.radius <= 0.0f ||
                        !photoCanonicalPoint(lightCenter) ||
                        !photoSampleSphericalEmitter(
                            lightCenter, light.radius, randomState,
                            lightPosition, lightNormal)) {
                        result.errorBits |= 4u;
                        continue;
                    }
                    if (hasBSDFSample) {
                        float centerDistance = intrinsicDistance(
                            hit.point, lightCenter);
                        if (isfinite(centerDistance)) {
                            float maximum =
                            centerDistance + light.radius + SELF_EPS;
                            float emitterDistance = photoSphericalEmitterRoot(
                                lightCenter, light.radius, hit.point,
                                bsdfSample.direction, maximum, quadrics, clips,
                                result.errorBits);
                            if (emitterDistance < nearestBSDFDistance) {
                                nearestBSDFDistance = emitterDistance;
                                nearestBSDFLight = light;
                                nearestBSDFCenter = lightCenter;
                            }
                        }
                    }
                } else if (light.kind != LIGHT_POINT) {
                    result.errorBits |= 1u;
                    continue;
                }
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
                BSDFEvaluation evaluation = evaluateBSDF(
                    material, responseKind, normal, -hit.tangent,
                    lightDirection);
                if (!evaluation.valid || evaluation.pdf <= 0.0f)
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

                float propagationRadius =
                max(areaRadius(distanceToLight), 1e-3f);
                float attenuation;
                if (light.kind == LIGHT_POINT) {
                    attenuation = light.intensity /
                    (1.0f + h->controls.falloffK *
                     propagationRadius * propagationRadius);
                } else {
                    float4 directionFromLight = directionTo(
                        lightPosition, hit.point, distanceToLight);
                    float emitterCosine = clamp(
                        mdot(lightNormal, directionFromLight), 0.0f, 1.0f);
                    if (emitterCosine <= 0.0f)
                        continue;
                    float emitterRadius = areaRadius(light.radius);
                    float emitterArea =
                    2.0f * TWO_PI * emitterRadius * emitterRadius;
                    float lightPDF =
                    propagationRadius * propagationRadius /
                    max(emitterArea * emitterCosine, EPS);
                    float bsdfPDF = evaluation.pdf;
                    float misWeight = hasBSDFSample
                    ? photoPowerHeuristic(lightPDF, bsdfPDF)
                    : 1.0f;
                    attenuation = light.intensity * emitterCosine *
                    emitterArea * misWeight /
                    (propagationRadius * propagationRadius);
                }
                direct += float3(light.color) * attenuation *
                evaluation.value * cosine;
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
    if (hasBSDFSample && nearestBSDFDistance < INF) {
        float4 emitterPoint = rayPoint(
            hit.point, bsdfSample.direction, nearestBSDFDistance);
        float4 emitterNormal = directionTo(
            nearestBSDFCenter, emitterPoint, nearestBSDFLight.radius);
        float4 directionFromLight = directionTo(
            emitterPoint, hit.point, nearestBSDFDistance);
        float emitterCosine = clamp(
            mdot(emitterNormal, directionFromLight), 0.0f, 1.0f);
        float surfaceCosine = clamp(
            mdot(normal, bsdfSample.direction), 0.0f, 1.0f);
        if (emitterCosine > 0.0f && surfaceCosine > 0.0f) {
            RayState shadowRay;
            shadowRay.point = hit.point;
            shadowRay.tangent = bsdfSample.direction;
            shadowRay.chartId = chartId;
            VisibilityResult visibility = traceAny(
                shadowRay, nearestBSDFDistance - SELF_EPS,
                h->controls.maxChartHops, charts, portals, objects,
                quadrics, clips);
            result.errorBits |= visibility.errorBits;
            result.portalHops += visibility.portalHops;
            result.compoundPortalHops += visibility.compoundPortalHops;
            result.portalTests += visibility.portalTests;
            result.hitHopLimit =
            result.hitHopLimit || visibility.hitHopLimit;
            if (!visibility.blocked) {
                float propagationRadius =
                max(areaRadius(nearestBSDFDistance), 1e-3f);
                float emitterRadius = areaRadius(nearestBSDFLight.radius);
                float emitterArea =
                2.0f * TWO_PI * emitterRadius * emitterRadius;
                float lightPDF =
                propagationRadius * propagationRadius /
                max(emitterArea * emitterCosine, EPS);
                float bsdfPDF = bsdfSample.pdf;
                float misWeight =
                photoPowerHeuristic(bsdfPDF, lightPDF);
                direct += float3(nearestBSDFLight.color) *
                nearestBSDFLight.intensity * misWeight * bsdfSample.weight;
            }
        }
    }
    return direct;
}

static TraceResult tracePathSample(
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
        if (!bsdfCanonicalNormal(hit.point, hit.normal, normal)) {
            result.errorBits |= 32u;
            break;
        }
        if (mdot(normal, -hit.tangent) < 0.0f)
            normal = -normal;

        int bsdfModel = resolveBSDFModel(material, object.responseKind);
        if (bsdfModel != BSDF_MODEL_LAMBERTIAN &&
            bsdfModel != BSDF_MODEL_DELTA_REFLECTION) {
            result.errorBits |= 1u;
            break;
        }

        bool hasBSDFSample = depth < maxBounces;
        BSDFSample bsdfSample{};
        if (hasBSDFSample) {
            float2 randomSample = bsdfModel == BSDF_MODEL_LAMBERTIAN
            ? float2(photoRandom(randomState), photoRandom(randomState))
            : float2(0);
            bsdfSample = sampleBSDF(
                material, object.responseKind, hit.point, hit.tangent,
                normal, randomSample);
            if (!bsdfSample.valid) {
                result.errorBits |= 4u;
                break;
            }
        }

        if (bsdfModel == BSDF_MODEL_LAMBERTIAN) {
            radiance += throughput * photoDirectLighting(
                hit, normal, material, object.responseKind, surface.chartId, h,
                charts, portals, objects, quadrics, clips, lights, result,
                randomState, hasBSDFSample, bsdfSample);
        }
        if (!hasBSDFSample)
            break;

        throughput *= bsdfSample.weight;
        ray.point = hit.point;
        ray.tangent = bsdfSample.direction;
        ray.chartId = surface.chartId;

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
    constant FrameGPU &frame [[buffer(2)]],
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
    TraceResult result = tracePathSample(
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
    output.write(
        float4(toneMapRadiance(average, frame.exposure), 1), pixel);

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
