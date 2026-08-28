#ifndef CURVED_TRACER_TRACE_INTERSECTION_METAL
#define CURVED_TRACER_TRACE_INTERSECTION_METAL

// Object, portal, and visibility intersections.

#include "TraceMath.metal"

static int roots(float a, float b, float c, thread float &r0, thread float &r1) {
    if (abs(a) < EPS) {
        if (abs(b) < EPS)
            return 0;
        r0 = -c / b;
        r1 = r0;
        return 1;
    }
    float disc = b * b - 4 * a * c;
    float discTolerance = EPS * (1 + abs(b * b) + abs(4 * a * c));
    if (disc < -discTolerance)
        return 0;
    float s = sqrt(max(disc, 0.0f));
    float q = -.5f * (b + copysign(s, b));
    r0 = q / a;
    r1 = abs(q) > EPS ? c / q : r0;
    if (r0 > r1) {
        float t = r0;
        r0 = r1;
        r1 = t;
    }
    return disc <= discTolerance ? 1 : 2;
}

static void insertCandidate(float distance, float minimum, float maximum,
                     thread float &first, thread float &second,
                     thread int &count) {
    if (!isfinite(distance) || distance < minimum || distance > maximum)
        return;
    if (count > 0 && abs(distance - first) <= EPS)
        return;
    if (count == 0 || distance < first) {
        second = first;
        first = distance;
        count = min(count + 1, 2);
    } else if (count == 1 || distance < second) {
        second = distance;
        count = 2;
    }
}

static int curvedCandidates(float A, float B, float level, float minimum,
                     float maximum, thread float &first,
                     thread float &second) {
    float r0, r1;
    int rootsFound = roots(-kappa() * (A + level), 2 * B, A - level,
                           r0, r1);
    int count = 0;
    first = second = INF;
    if (rootsFound > 0 && r0 >= 0)
        insertCandidate(distanceFromU(r0), minimum, maximum,
                        first, second, count);
    if (rootsFound > 1 && r1 >= 0)
        insertCandidate(distanceFromU(r1), minimum, maximum,
                        first, second, count);
    return count;
}

static float quadricValue(float4x4 q, float4 first, float4 second) {
    return dot(first, q * second);
}

static int quadricCandidates(float4x4 q, float4 p, float4 v, float minimum,
                      float maximum, thread float &first,
                      thread float &second) {
    float A = quadricValue(q, p, p);
    float B = quadricValue(q, p, v);
    float D = quadricValue(q, v, v);
    first = second = INF;
    int count = 0;
    if (SPACE_FORM == MODEL_R3) {
        float r0, r1;
        int rootsFound = roots(D, 2 * B, A, r0, r1);
        if (rootsFound > 0)
            insertCandidate(r0, minimum, maximum, first, second, count);
        if (rootsFound > 1)
            insertCandidate(r1, minimum, maximum, first, second, count);
        return count;
    }
    if (SPACE_FORM == MODEL_H3) {
        float mean = 0.5f * (A + D);
        float r0, r1;
        int rootsFound = roots(mean + B, A - D, mean - B, r0, r1);
        if (rootsFound > 0 && r0 >= 1)
            insertCandidate(0.5f * log(r0), minimum, maximum,
                            first, second, count);
        if (rootsFound > 1 && r1 >= 1)
            insertCandidate(0.5f * log(r1), minimum, maximum,
                            first, second, count);
        return count;
    }

    float constantPart = 0.5f * (A + D);
    float cosinePart = 0.5f * (A - D);
    float amplitude = length(float2(cosinePart, B));
    if (amplitude <= EPS || abs(constantPart) > amplitude + EPS)
        return 0;
    float target = clamp(-constantPart / amplitude, -1.0f, 1.0f);
    float phase = atan2(B, cosinePart);
    float alpha = acos(target);
    for (int branch = 0; branch < 2; ++branch) {
        float theta = phase + (branch == 0 ? alpha : -alpha);
        theta -= floor(theta / TWO_PI) * TWO_PI;
        insertCandidate(0.5f * theta, minimum, maximum,
                        first, second, count);
    }
    return count;
}

static float4 objectNormal(ObjectGPU o, float4 hit,
                    device const QuadricGPU *quadrics) {
    if (o.equationKind == EQUATION_R3_SPHERE)
        return float4(normalize(hit.xyz - o.geometry.xyz), 0);
    if (o.equationKind == EQUATION_LINEAR) {
        if (SPACE_FORM == MODEL_R3)
            return float4(normalize(o.geometry.xyz), 0);
        return tangentNormalize(
            o.geometry - kappa() * mdot(o.geometry, hit) * hit);
    }
    float4 covector = quadrics[o.quadricIndex].coefficients * hit;
    float4 gradient = SPACE_FORM == MODEL_H3
    ? float4(covector.xyz, -covector.w) : covector;
    if (SPACE_FORM == MODEL_R3)
        return float4(normalize(gradient.xyz), 0);
    return tangentNormalize(gradient - kappa() * mdot(gradient, hit) * hit);
}

static bool insideClip(PrimitiveClipGPU clip, float4 point,
                       device const QuadricGPU *quadrics) {
    if (clip.kind == CLIP_LINEAR) {
        float scale = 1 + length(clip.geometry) + abs(clip.parameter);
        return mdot(clip.geometry, point) <= clip.parameter + 4 * EPS * scale;
    }
    if (clip.kind == CLIP_QUADRIC && clip.pad0 >= 0) {
        float4 qPoint = quadrics[clip.pad0].coefficients * point;
        float value = dot(point, qPoint);
        if (!isfinite(value) || any(!isfinite(qPoint)))
            return false;
        float scale = 1.0f + abs(point.x * qPoint.x) +
                      abs(point.y * qPoint.y) + abs(point.z * qPoint.z) +
                      abs(point.w * qPoint.w);
        float tolerance = 8.0f * EPS * scale;
        return clip.pad1 != 0 ? value >= -tolerance : value <= tolerance;
    }
    return false;
}

static float objectRoot(ObjectGPU o, float4 p, float4 v, float minimum,
                 float maximum, device const QuadricGPU *quadrics,
                 device const PrimitiveClipGPU *clips,
                 thread uint &errorBits) {
    float first = INF, second = INF;
    int count = 0;
    if (o.equationKind == EQUATION_R3_SPHERE) {
        float3 delta = p.xyz - o.geometry.xyz;
        float r0, r1;
        count = roots(dot(v.xyz, v.xyz), 2 * dot(delta, v.xyz),
                      dot(delta, delta) - o.parameter * o.parameter, r0, r1);
        int accepted = 0;
        first = second = INF;
        if (count > 0)
            insertCandidate(r0, minimum, maximum, first, second, accepted);
        if (count > 1)
            insertCandidate(r1, minimum, maximum, first, second, accepted);
        count = accepted;
    } else if (o.equationKind == EQUATION_LINEAR) {
        if (SPACE_FORM == MODEL_R3) {
            float denominator = dot(o.geometry.xyz, v.xyz);
            if (abs(denominator) >= EPS) {
                count = 0;
                insertCandidate(
                    (o.parameter - dot(o.geometry.xyz, p.xyz)) / denominator,
                    minimum, maximum, first, second, count);
            }
        } else {
            count = curvedCandidates(mdot(o.geometry, p), mdot(o.geometry, v),
                                     o.parameter, minimum, maximum,
                                     first, second);
        }
    } else if (o.equationKind == EQUATION_QUADRIC && o.quadricIndex >= 0) {
        count = quadricCandidates(quadrics[o.quadricIndex].coefficients, p, v,
                                  minimum, maximum, first, second);
    }

    for (int candidate = 0; candidate < count; ++candidate) {
        float distance = candidate == 0 ? first : second;
        float4 point = rayPoint(p, v, distance);
        bool accepted = true;
        for (int local = 0; local < o.clipCount; ++local)
            accepted = accepted &&
                       insideClip(clips[o.firstClip + local], point, quadrics);
        if (!accepted)
            continue;
        float4 normal = objectNormal(o, point, quadrics);
        if (all(isfinite(normal)) && mdot(normal, normal) > 0.5f)
            return distance;
        errorBits |= 32u;
    }
    return INF;
}
static float4 portalNormal(PortalGPU portal, float4 hit,
                    device const QuadricGPU *quadrics) {
    float4 normal;
    if (portal.equationKind == EQUATION_LINEAR) {
        normal = portal.geometry;
    } else {
        float4 covector = quadrics[portal.quadricIndex].coefficients * hit;
        normal = SPACE_FORM == MODEL_H3
        ? float4(covector.xyz, -covector.w) : covector;
    }
    if (SPACE_FORM == MODEL_R3)
        return float4(normalize(normal.xyz), 0);
    return tangentNormalize(normal - kappa() * mdot(normal, hit) * hit);
}

static bool insidePortalClips(PortalGPU portal, float4 point,
                       device const QuadricGPU *quadrics,
                       device const PrimitiveClipGPU *clips) {
    for (int local = 0; local < portal.clipCount; ++local)
        if (!insideClip(clips[portal.firstClip + local], point, quadrics))
            return false;
    return true;
}

static float portalRoot(PortalGPU portal, float4 p, float4 v, float minimum,
                 float maximum, device const QuadricGPU *quadrics,
                 device const PrimitiveClipGPU *clips,
                 thread uint &errorBits) {
    float first = INF, second = INF;
    int count = 0;
    if (portal.equationKind == EQUATION_LINEAR) {
        if (SPACE_FORM == MODEL_R3) {
            float denominator = dot(portal.geometry.xyz, v.xyz);
            if (abs(denominator) >= EPS)
                insertCandidate(
                    (portal.parameter - dot(portal.geometry.xyz, p.xyz)) /
                    denominator, minimum, maximum, first, second, count);
        } else {
            count = curvedCandidates(mdot(portal.geometry, p),
                                     mdot(portal.geometry, v),
                                     portal.parameter, minimum, maximum,
                                     first, second);
        }
    } else if (portal.equationKind == EQUATION_QUADRIC &&
               portal.quadricIndex >= 0) {
        count = quadricCandidates(
            quadrics[portal.quadricIndex].coefficients, p, v,
            minimum, maximum, first, second);
    }

    for (int candidate = 0; candidate < count; ++candidate) {
        float distance = candidate == 0 ? first : second;
        float4 point = rayPoint(p, v, distance);
        if (!insidePortalClips(portal, point, quadrics, clips))
            continue;
        float4 normal = portalNormal(portal, point, quadrics);
        if (all(isfinite(normal)) && mdot(normal, normal) > 0.5f) {
            if (mdot(normal, rayTangent(p, v, distance)) > EPS)
                return distance;
            continue;
        }
        errorBits |= 32u;
    }
    return INF;
}

static Event nearestEvent(float4 p, float4 v, int chartId, float maximum,
                   float objectMinimum, device const ChartGPU *charts,
                   device const PortalGPU *portals,
                   device const ObjectGPU *objects,
                   device const QuadricGPU *quadrics,
                   device const PrimitiveClipGPU *clips,
                   thread uint &portalTests, thread uint &errorBits) {
    Event e{};
    e.valid = false;
    e.distance = maximum + 1;
    ChartGPU chart = charts[chartId];
    // A chart is a coordinate state, not an intrinsic ball. The ray remains
    // in that state until it reaches an explicit portal; the camera's view
    // distance is the only implicit traversal horizon.
    float localMaximum = maximum;
    for (int local = 0; local < chart.objectCount; ++local) {
        int i = chart.firstObject + local;
        float d = objectRoot(objects[i], p, v, objectMinimum, localMaximum,
                             quadrics, clips, errorBits);
        if (d < e.distance) {
            e.valid = true;
            e.portal = false;
            e.index = i;
            e.distance = d;
        }
    }
    if (ENABLE_PORTALS) {
        portalTests += uint(chart.portalCount);
        for (int local = 0; local < chart.portalCount; ++local) {
            int i = chart.firstPortal + local;
            // Portal crossings are directional transitions, not reflective
            // surfaces. Accept a zero-distance outward crossing so a camera on or
            // immediately inside a face cannot fall into an untraceable dead band.
            float d = portalRoot(portals[i], p, v, 0.0f, localMaximum,
                                 quadrics, clips, errorBits);
            if (d < e.distance) {
                e.valid = true;
                e.portal = true;
                e.index = i;
                e.distance = d;
            }
        }
    }
    if (e.valid) {
        e.point = rayPoint(p, v, e.distance);
        e.tangent = tangentNormalize(rayTangent(p, v, e.distance));
        e.normal = e.portal ? portalNormal(portals[e.index], e.point, quadrics)
        : objectNormal(objects[e.index], e.point, quadrics);
    }
    return e;
}

static float normalizedPortalViolation(PortalGPU portal, float4 point,
                                device const QuadricGPU *quadrics) {
    if (portal.equationKind == EQUATION_LINEAR) {
        float violation = mdot(portal.geometry, point) - portal.parameter;
        float normalSquared = mdot(portal.geometry, portal.geometry) -
        kappa() * portal.parameter * portal.parameter;
        return violation / sqrt(max(abs(normalSquared), EPS * EPS));
    }
    float4x4 q = quadrics[portal.quadricIndex].coefficients;
    float4 qPoint = q * point;
    float violation = dot(point, qPoint);
    float4 gradient = SPACE_FORM == MODEL_H3
    ? float4(qPoint.xyz, -qPoint.w) : qPoint;
    if (SPACE_FORM != MODEL_R3)
        gradient -= kappa() * mdot(gradient, point) * point;
    float gradientLength = sqrt(max(mdot(gradient, gradient), EPS * EPS));
    return violation / (2 * gradientLength);
}

static bool applyPortalPairing(int portalIndex, thread float4 &point,
                        thread float4 &tangent, thread int &chartId,
                        thread int &portalHops, int maxPortalHops,
                        device const PortalGPU *portals,
                        thread uint &errorBits, thread bool &hitHopLimit) {
    if (portalHops >= maxPortalHops) {
        errorBits |= 8u;
        hitHopLimit = true;
        return false;
    }

    PortalGPU portal = portals[portalIndex];
    point = portal.toNeighbor * point;
    tangent = portal.toNeighbor * tangent;
    chartId = portal.neighborChart;
    ++portalHops;

    if (!canonicalizeRayState(point, tangent)) {
        errorBits |= 4u;
        return false;
    }
    return true;
}

static bool advancePortal(Event event, thread float4 &point, thread float4 &tangent,
                   thread int &chartId, thread int &portalHops,
                   int maxPortalHops, device const ChartGPU *charts,
                   device const PortalGPU *portals,
                   device const QuadricGPU *quadrics,
                   device const PrimitiveClipGPU *clips,
                   thread uint &errorBits,
                   thread uint &compoundPortalHops,
                   thread uint &portalTests, thread bool &hitHopLimit) {
    point = event.point;
    tangent = event.tangent;
    if (!applyPortalPairing(event.index, point, tangent, chartId, portalHops,
                            maxPortalHops, portals, errorBits, hitHopLimit))
        return false;

    // Outward-displaced collars overlap near edges and vertices. A pairing
    // places the ray inside its reverse face, but it may place it outside one
    // or more adjacent faces. Reduce those violations immediately without
    // consuming geometric path distance.
    while (true) {
        ChartGPU chart = charts[chartId];
        int selectedPortal = -1;
        float strongestViolation = 4.0f * EPS;
        portalTests += uint(chart.portalCount);

        for (int local = 0; local < chart.portalCount; ++local) {
            int candidateIndex = chart.firstPortal + local;
            if (!insidePortalClips(portals[candidateIndex], point,
                                   quadrics, clips))
                continue;
            float violation =
            normalizedPortalViolation(portals[candidateIndex], point,
                                      quadrics);
            if (violation > strongestViolation) {
                selectedPortal = candidateIndex;
                strongestViolation = violation;
            }
        }

        if (selectedPortal < 0)
            return true;
        if (!applyPortalPairing(selectedPortal, point, tangent, chartId, portalHops,
                                maxPortalHops, portals, errorBits, hitHopLimit))
            return false;
        ++compoundPortalHops;
    }
}

static SurfaceTraceResult traceToSurface(
    RayState ray,
    float maximumDistance,
    int maxPortalHops,
    device const ChartGPU *charts,
    device const PortalGPU *portals,
    device const ObjectGPU *objects,
    device const QuadricGPU *quadrics,
    device const PrimitiveClipGPU *clips
) {
    SurfaceTraceResult result{};
    float remaining = max(maximumDistance, 0.0f);
    int hops = 0;
    result.chartId = ray.chartId;

    if (!canonicalizeRayState(ray.point, ray.tangent)) {
        result.errorBits = 4u;
        return result;
    }

    while (remaining > SELF_EPS) {
        Event event = nearestEvent(
            ray.point, ray.tangent, ray.chartId, remaining, SELF_EPS,
            charts, portals, objects, quadrics, clips, result.portalTests,
            result.errorBits);
        if (!event.valid)
            break;

        remaining -= event.distance;
        result.distance += event.distance;
        if (!event.portal) {
            result.hit = true;
            result.event = event;
            break;
        }

        if (!advancePortal(
                event, ray.point, ray.tangent, ray.chartId, hops,
                maxPortalHops, charts, portals, quadrics, clips,
                result.errorBits,
                result.compoundPortalHops, result.portalTests,
                result.hitHopLimit))
            break;
    }

    result.chartId = ray.chartId;
    result.portalHops = uint(hops);
    return result;
}

static VisibilityResult traceAny(
    RayState ray,
    float maximumDistance,
    int maxPortalHops,
    device const ChartGPU *charts,
    device const PortalGPU *portals,
    device const ObjectGPU *objects,
    device const QuadricGPU *quadrics,
    device const PrimitiveClipGPU *clips
) {
    SurfaceTraceResult surface = traceToSurface(
        ray, maximumDistance, maxPortalHops, charts, portals, objects,
        quadrics, clips);
    VisibilityResult result{};
    // Incomplete visibility queries are conservatively occluded so exhausted
    // portal budgets or invalid rays cannot leak direct light into the image.
    result.blocked = surface.hit || surface.errorBits != 0u;
    result.errorBits = surface.errorBits;
    result.portalHops = surface.portalHops;
    result.compoundPortalHops = surface.compoundPortalHops;
    result.portalTests = surface.portalTests;
    result.hitHopLimit = surface.hitHopLimit;
    return result;
}

static void recordTraceStats(device TraceStatsGPU *stats, uint portalHops,
                      uint compoundPortalHops, uint portalTests,
                      bool hitHopLimit, uint laneInSIMDGroup,
                      uint simdGroupIndex, uint threadIndex,
                      uint simdGroupCount, threadgroup uint *rayPartials,
                      threadgroup uint *hopPartials,
                      threadgroup uint *compoundPartials,
                      threadgroup uint *maximumPartials,
                      threadgroup uint *limitedPartials,
                      threadgroup uint *testPartials) {
    uint rays = simd_sum(1u);
    uint hops = simd_sum(portalHops);
    uint compound = simd_sum(compoundPortalHops);
    uint maximum = simd_max(portalHops);
    uint limited = simd_sum(hitHopLimit ? 1u : 0u);
    uint tests = simd_sum(portalTests);
    if (laneInSIMDGroup == 0) {
        rayPartials[simdGroupIndex] = rays;
        hopPartials[simdGroupIndex] = hops;
        compoundPartials[simdGroupIndex] = compound;
        maximumPartials[simdGroupIndex] = maximum;
        limitedPartials[simdGroupIndex] = limited;
        testPartials[simdGroupIndex] = tests;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (threadIndex != 0)
        return;

    rays = hops = compound = maximum = limited = tests = 0;
    for (uint group = 0; group < simdGroupCount; ++group) {
        rays += rayPartials[group];
        hops += hopPartials[group];
        compound += compoundPartials[group];
        maximum = max(maximum, maximumPartials[group]);
        limited += limitedPartials[group];
        tests += testPartials[group];
    }
    atomic_fetch_add_explicit(&stats->rayCount, rays, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->totalPortalHops, hops,
                              memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->compoundPortalHops, compound,
                              memory_order_relaxed);
    atomic_fetch_max_explicit(&stats->maximumPortalHops, maximum,
                              memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->hopLimitRays, limited,
                              memory_order_relaxed);
    atomic_fetch_add_explicit(&stats->totalPortalTests, tests,
                              memory_order_relaxed);
}

static float intrinsicDistance(float4 a, float4 b) {
    if (SPACE_FORM == MODEL_S3)
        return acos(clamp(dot(a, b), -1.0f, 1.0f));
    if (SPACE_FORM == MODEL_H3)
        return acosh(max(-mdot(a, b), 1.0f));
    return length(a.xyz - b.xyz);
}
static float4 directionTo(float4 from, float4 to, float d) {
    if (SPACE_FORM == MODEL_R3)
        return float4(normalize(to.xyz - from.xyz), 0);
    float q = mdot(to, from);
    return tangentNormalize(to - kappa() * q * from);
}


#endif
