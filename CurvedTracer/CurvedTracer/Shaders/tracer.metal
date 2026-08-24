#include <metal_stdlib>
using namespace metal;

constant int SPACE_FORM [[function_constant(0)]]; // 0 H³, 1 S³, 2 R³
constant bool ENABLE_PORTALS [[function_constant(1)]];

constant int PACKET_MAGIC = 0x41545243, CONTRACT_VERSION = 11,
HEADER_SIZE = 192, OBJECT_SIZE = 48;
constant int MODEL_H3 = 0, MODEL_S3 = 1, MODEL_R3 = 2;
constant int EQUATION_LINEAR = 0, EQUATION_R3_SPHERE = 1, EQUATION_QUADRIC = 2;
constant int RESPONSE_OPAQUE = 0, RESPONSE_MIRROR = 1;
constant int CLIP_LINEAR = 0, CLIP_BALL = 1;
constant int FOG_DISABLED = 0, FOG_COMPACT = 1, FOG_EXPONENTIAL = 2;
constant float EPS = 1e-5f, SELF_EPS = 1e-4f, INF = 1e30f,
TWO_PI = 6.28318530718f;

struct PacketMeta {
    int magic, contractVersion, objectSize, packetHeaderSize;
};
struct CameraGPU {
    float4 position, right, up, fwd;
    float fovTan, aspect, maxTraceDistance, maxTraceParameter;
    int chartId, pad0, pad1, pad2;
};
struct ControlsGPU {
    int maxBounces, modelKind;
    float falloffK, ambient, bounceAttenuation, fogMode, fogStartFraction,
    fogDensity;
    int maxChartHops, maxLightHops, maxLightStates, pad0;
};
struct CountsGPU {
    int chartCount, portalCount, objectCount, materialCount, lightCount,
    quadricCount, clipCount, pad0;
};
struct HeaderGPU {
    PacketMeta meta;
    CameraGPU camera;
    ControlsGPU controls;
    CountsGPU counts;
};
struct ChartGPU {
    float intrinsicRadius, tracingParameter;
    int firstPortal, portalCount, firstObject, objectCount, firstLight,
    lightCount;
};
struct PortalGPU {
    float4x4 toNeighbor;
    float4 normal;
    float offset;
    int neighborChart, reversePortal, pad0;
};
struct ObjectGPU {
    float4 geometry;
    float parameter;
    int equationKind, responseKind, colorIdx, firstClip, clipCount,
    quadricIndex, pad0;
};
struct QuadricGPU {
    float4x4 coefficients;
};
struct PrimitiveClipGPU {
    float4 geometry;
    float parameter;
    int kind, pad0, pad1;
};
struct MaterialGPU {
    float4 color, specular;
};
struct LightGPU {
    float4 position;
    packed_float3 color;
    float intensity;
};
struct TraceStatsGPU {
    atomic_uint errorBits;
    atomic_uint rayCount;
    atomic_uint totalPortalHops;
    atomic_uint compoundPortalHops;
    atomic_uint maximumPortalHops;
    atomic_uint hopLimitRays;
    atomic_uint totalPortalTests;
    atomic_uint reserved;
};

struct Event {
    bool valid;
    bool portal;
    int index;
    float distance;
    float4 point;
    float4 tangent;
    float4 normal;
};

float kappa() {
    return SPACE_FORM == MODEL_S3 ? 1.0f : SPACE_FORM == MODEL_H3 ? -1.0f : 0.0f;
}
float mdot(float4 a, float4 b) {
    return SPACE_FORM == MODEL_H3 ? dot(a.xyz, b.xyz) - a.w * b.w : dot(a, b);
}
float4 origin() { return float4(0, 0, 0, 1); }
float distanceFromU(float u) {
    if (SPACE_FORM == MODEL_S3)
        return 2 * atan(u);
    if (SPACE_FORM == MODEL_H3)
        return u < 1 ? log((1 + u) / (1 - u)) : INF;
    return 2 * u;
}
float areaRadius(float d) {
    return SPACE_FORM == MODEL_S3 ? sin(d) : SPACE_FORM == MODEL_H3 ? sinh(d) : d;
}
void radial(float d, thread float &C, thread float &S) {
    if (SPACE_FORM == MODEL_S3) {
        C = cos(d);
        S = sin(d);
    } else if (SPACE_FORM == MODEL_H3) {
        C = cosh(d);
        S = sinh(d);
    } else {
        C = 1;
        S = d;
    }
}
float4 rayPoint(float4 p, float4 v, float d) {
    float C, S;
    radial(d, C, S);
    return C * p + S * v;
}
float4 rayTangent(float4 p, float4 v, float d) {
    if (SPACE_FORM == MODEL_S3)
        return -sin(d) * p + cos(d) * v;
    if (SPACE_FORM == MODEL_H3)
        return sinh(d) * p + cosh(d) * v;
    return v;
}
float4 tangentNormalize(float4 v) {
    float q = max(mdot(v, v), 0.0f);
    return q > EPS * EPS ? v * rsqrt(q) : float4(0);
}

bool canonicalizeRayState(thread float4 &point, thread float4 &tangent) {
    if (SPACE_FORM == MODEL_R3) {
        point.w = 1.0f;
        tangent = float4(tangent.xyz, 0.0f);
    } else {
        float pointNorm = mdot(point, point);
        float expectedSign = kappa();
        if (!isfinite(pointNorm) || expectedSign * pointNorm <= EPS)
            return false;
        point *= rsqrt(expectedSign * pointNorm);
        if (SPACE_FORM == MODEL_H3 && point.w <= 0.0f)
            return false;
        tangent -= kappa() * mdot(tangent, point) * point;
    }

    tangent = tangentNormalize(tangent);
    return all(isfinite(point)) && all(isfinite(tangent)) &&
    mdot(tangent, tangent) > 0.5f;
}

int roots(float a, float b, float c, thread float &r0, thread float &r1) {
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

float curvedRoot(float A, float B, float q, float minimum, float maximum) {
    float r0, r1;
    int count = roots(-kappa() * (A + q), 2 * B, A - q, r0, r1);
    float best = INF;
    if (count > 0 && r0 >= 0) {
        float d = distanceFromU(r0);
        if (d >= minimum && d <= maximum)
            best = d;
    }
    if (count > 1 && r1 >= 0) {
        float d = distanceFromU(r1);
        if (d >= minimum && d <= maximum)
            best = min(best, d);
    }
    return best;
}

void insertCandidate(float distance, float minimum, float maximum,
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

int curvedCandidates(float A, float B, float level, float minimum,
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

float quadricValue(float4x4 q, float4 first, float4 second) {
    return dot(first, q * second);
}

int quadricCandidates(float4x4 q, float4 p, float4 v, float minimum,
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

float4 objectNormal(ObjectGPU o, float4 hit,
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

bool insideClip(PrimitiveClipGPU clip, float4 point) {
    if (clip.kind == CLIP_LINEAR) {
        float scale = 1 + length(clip.geometry) + abs(clip.parameter);
        return mdot(clip.geometry, point) <= clip.parameter + 4 * EPS * scale;
    }
    if (SPACE_FORM == MODEL_R3)
        return distance(point.xyz, clip.geometry.xyz) <= clip.parameter + 4 * EPS;
    return mdot(clip.geometry, point) >= clip.parameter - 4 * EPS;
}

float objectRoot(ObjectGPU o, float4 p, float4 v, float minimum,
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
            accepted = accepted && insideClip(clips[o.firstClip + local], point);
        if (!accepted)
            continue;
        float4 normal = objectNormal(o, point, quadrics);
        if (all(isfinite(normal)) && mdot(normal, normal) > 0.5f)
            return distance;
        errorBits |= 32u;
    }
    return INF;
}
float portalRoot(PortalGPU portal, float4 p, float4 v, float minimum,
                 float maximum) {
    if (SPACE_FORM == MODEL_R3) {
        float den = dot(portal.normal.xyz, v.xyz);
        if (abs(den) < EPS)
            return INF;
        float d = (portal.offset - dot(portal.normal.xyz, p.xyz)) / den;
        return den > 0 && d >= minimum && d <= maximum ? d : INF;
    }
    float A = mdot(portal.normal, p), B = mdot(portal.normal, v);
    float d = curvedRoot(A, B, portal.offset, minimum, maximum);
    if (d < INF && mdot(portal.normal, rayTangent(p, v, d)) <= 0)
        return INF;
    return d;
}

float4 portalNormal(PortalGPU o, float4 hit) {
    if (SPACE_FORM == MODEL_R3)
        return float4(normalize(o.normal.xyz), 0);
    float q = mdot(o.normal, hit);
    return tangentNormalize(o.normal - kappa() * q * hit);
}

Event nearestEvent(float4 p, float4 v, int chartId, float maximum,
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
    float chartExit = INF;
    if (SPACE_FORM == MODEL_R3) {
        float r0, r1;
        int count = roots(dot(v.xyz, v.xyz), 2 * dot(p.xyz, v.xyz),
                          dot(p.xyz, p.xyz) -
                          chart.intrinsicRadius * chart.intrinsicRadius,
                          r0, r1);
        if (count > 0 && r0 >= objectMinimum && r0 <= maximum)
            chartExit = r0;
        if (count > 1 && r1 >= objectMinimum && r1 <= maximum)
            chartExit = min(chartExit, r1);
    } else {
        float level = SPACE_FORM == MODEL_S3 ? cos(chart.intrinsicRadius)
        : -cosh(chart.intrinsicRadius);
        chartExit = curvedRoot(mdot(origin(), p), mdot(origin(), v), level,
                               objectMinimum, maximum);
    }
    float localMaximum = min(maximum, chartExit);
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
            float d = portalRoot(portals[i], p, v, 0.0f, localMaximum);
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
        e.normal = e.portal ? portalNormal(portals[e.index], e.point)
        : objectNormal(objects[e.index], e.point, quadrics);
    }
    return e;
}

float normalizedPortalViolation(PortalGPU portal, float4 point) {
    float violation = mdot(portal.normal, point) - portal.offset;
    float normalSquared = mdot(portal.normal, portal.normal) -
    kappa() * portal.offset * portal.offset;
    return violation / sqrt(max(abs(normalSquared), EPS * EPS));
}

bool applyPortalPairing(int portalIndex, thread float4 &point,
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

bool advancePortal(Event event, thread float4 &point, thread float4 &tangent,
                   thread int &chartId, thread int &portalHops,
                   int maxPortalHops, device const ChartGPU *charts,
                   device const PortalGPU *portals, thread uint &errorBits,
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
            float violation =
            normalizedPortalViolation(portals[candidateIndex], point);
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

void recordTraceStats(device TraceStatsGPU *stats, uint portalHops,
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

float intrinsicDistance(float4 a, float4 b) {
    if (SPACE_FORM == MODEL_S3)
        return acos(clamp(dot(a, b), -1.0f, 1.0f));
    if (SPACE_FORM == MODEL_H3)
        return acosh(max(-mdot(a, b), 1.0f));
    return length(a.xyz - b.xyz);
}
float4 directionTo(float4 from, float4 to, float d) {
    if (SPACE_FORM == MODEL_R3)
        return float4(normalize(to.xyz - from.xyz), 0);
    float q = mdot(to, from);
    return tangentNormalize(to - kappa() * q * from);
}

float3 shade(Event hit, ObjectGPU object, MaterialGPU material, int chartId,
             float4 view, device const ChartGPU *charts,
             device const PortalGPU *portals, device const LightGPU *lights,
             float ambient, float falloff, int maxLightHops, int maxLightStates,
             thread uint &errorBits) {
    float3 diffuse = float3(ambient), spec = float3(0);
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
                LightGPU l = lights[chart.firstLight + local];
                float4 lightPosition = toStart[depth] * l.position;
                float d = intrinsicDistance(hit.point, lightPosition);
                if (!isfinite(d) || d < EPS)
                    continue;
                float4 ld = directionTo(hit.point, lightPosition, d);
                float nd = max(mdot(hit.normal, ld), 0.0f);
                float ar = max(areaRadius(d), 1e-3f);
                float attenuation = l.intensity / (1 + falloff * ar * ar);
                float3 irradiance = float3(l.color) * attenuation;
                diffuse += irradiance * nd;
                float4 halfv = tangentNormalize(ld + view);
                spec +=
                irradiance * pow(max(mdot(hit.normal, halfv), 0.0f), 32.0f) * nd;
            }
            nextPortal[depth] = 0;
        }
        if (!ENABLE_PORTALS || depth >= maxLightHops ||
            nextPortal[depth] >= chart.portalCount) {
            --depth;
            continue;
        }
        int portalIndex = chart.firstPortal + nextPortal[depth]++;
        if (portalIndex == incoming[depth])
            continue;
        if (stateCount++ >= maxLightStates) {
            errorBits |= 16;
            break;
        }
        PortalGPU portal = portals[portalIndex];
        int child = depth + 1;
        chartStack[child] = portal.neighborChart;
        nextPortal[child] = -1;
        incoming[child] = portal.reversePortal;
        toStart[child] = toStart[depth] * portals[portal.reversePortal].toNeighbor;
        depth = child;
    }
    return material.color.rgb * diffuse +
    material.specular.rgb * material.specular.a * spec;
}

float fogVisibility(float distance, float horizon, int mode,
                    float startFraction, float density,
                    float exponentialBoundary) {
    if (distance >= horizon)
        return 0;
    if (distance <= 0 || mode == FOG_DISABLED)
        return 1;
    if (mode == FOG_COMPACT) {
        float start = clamp(startFraction, 0.0f, 0.999f) * horizon;
        float x = clamp((distance - start) / max(horizon - start, EPS), 0.0f, 1.0f);
        return 1 - x * x * (3 - 2 * x);
    }

    // Preserve the exponential profile while making it continuous with the
    // background at the finite tracing horizon:
    //   T(d) = (exp(-density*d) - exp(-density*horizon))
    //          / (1 - exp(-density*horizon)).
    density = max(density, 0.0f);
    if (density * horizon < 1e-3f)
        return clamp(1.0f - distance / horizon, 0.0f, 1.0f);
    float atDistance = exp(-density * distance);
    return clamp((atDistance - exponentialBoundary) /
                 max(1.0f - exponentialBoundary, EPS),
                 0.0f, 1.0f);
}

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
    if (h->counts.chartCount <= 0 || h->counts.chartCount > 256 ||
        h->counts.portalCount < 0 || h->counts.portalCount > 1024 ||
        h->counts.objectCount < 0 || h->counts.objectCount > 4096 ||
        h->counts.materialCount < 0 || h->counts.materialCount > 256 ||
        h->counts.lightCount < 0 || h->counts.lightCount > 16 ||
        h->counts.quadricCount < 0 || h->counts.quadricCount > 4096 ||
        h->counts.clipCount < 0 || h->counts.clipCount > 65536)
        error |= 1;
    if (h->camera.chartId < 0 || h->camera.chartId >= h->counts.chartCount ||
        h->controls.maxChartHops <= 0 || h->controls.maxChartHops > 128 ||
        h->controls.maxLightHops < 0 || h->controls.maxLightHops > 4 ||
        h->controls.maxLightStates <= 0 || h->controls.maxLightStates > 256)
        error |= 1;
    if (!ENABLE_PORTALS && h->counts.portalCount != 0)
        error |= 2;
    if (error) {
        atomic_fetch_or_explicit(&stats->errorBits, error, memory_order_relaxed);
        output.write(float4(1, 0, 1, 1), pixel);
        return;
    }
    uint offset = HEADER_SIZE;
    device const ChartGPU *charts =
    reinterpret_cast<device const ChartGPU *>(packet + offset);
    offset += h->counts.chartCount * sizeof(ChartGPU);
    device const PortalGPU *portals =
    reinterpret_cast<device const PortalGPU *>(packet + offset);
    offset += h->counts.portalCount * sizeof(PortalGPU);
    device const ObjectGPU *objects =
    reinterpret_cast<device const ObjectGPU *>(packet + offset);
    offset += h->counts.objectCount * sizeof(ObjectGPU);
    device const QuadricGPU *quadrics =
    reinterpret_cast<device const QuadricGPU *>(packet + offset);
    offset += h->counts.quadricCount * sizeof(QuadricGPU);
    device const PrimitiveClipGPU *clips =
    reinterpret_cast<device const PrimitiveClipGPU *>(packet + offset);
    offset += h->counts.clipCount * sizeof(PrimitiveClipGPU);
    device const MaterialGPU *materials =
    reinterpret_cast<device const MaterialGPU *>(packet + offset);
    offset += h->counts.materialCount * sizeof(MaterialGPU);
    device const LightGPU *lights =
    reinterpret_cast<device const LightGPU *>(packet + offset);

    float2 uv = (float2(pixel) + .5f) /
    float2(output.get_width(), output.get_height()),
    screen = 2 * uv - 1;
    screen.y = -screen.y;
    float renderAspect = float(output.get_width()) / float(output.get_height());
    float4 p = h->camera.position;
    float4 v = tangentNormalize(h->camera.fwd +
                                screen.x * renderAspect * h->camera.fovTan *
                                h->camera.right +
                                screen.y * h->camera.fovTan * h->camera.up);
    if (!canonicalizeRayState(p, v)) {
        atomic_fetch_or_explicit(&stats->errorBits, 4, memory_order_relaxed);
        output.write(float4(1, 0, 1, 1), pixel);
        return;
    }
    int chartId = h->camera.chartId;
    float remaining = h->camera.maxTraceDistance, path = 0;
    float3 throughput = 1, radiance = 0;
    int hops = 0;
    uint compoundPortalHops = 0, portalTests = 0;
    bool hitHopLimit = false;
    float pathVisibility = 1;
    int maxBounces = clamp(h->controls.maxBounces, 0, 64);
    int fogMode = clamp(int(floor(h->controls.fogMode + 0.5f)), FOG_DISABLED,
                        FOG_EXPONENTIAL);
    float density = max(h->controls.fogDensity, 0.0f);
    float exponentialBoundary =
    fogMode == FOG_EXPONENTIAL &&
    density * h->camera.maxTraceDistance >= 1e-3f
    ? exp(-density * h->camera.maxTraceDistance)
    : 0.0f;
    for (int bounce = 0; bounce <= maxBounces;) {
        Event e = nearestEvent(p, v, chartId, remaining, SELF_EPS, charts, portals,
                               objects, quadrics, clips, portalTests, error);
        if (!e.valid) {
            // The remaining transmitted light terminates in the homogeneous
            // fog color. Together with the segment contributions below, this
            // preserves a stable background while geometry converges toward it.
            radiance += throughput * float3(h->controls.ambient);
            break;
        }
        remaining -= e.distance;
        path += e.distance;
        float next = fogVisibility(path, h->camera.maxTraceDistance, fogMode,
                                   h->controls.fogStartFraction, density,
                                   exponentialBoundary);
        float segment = pathVisibility > EPS ? next / pathVisibility : 0;
        segment = clamp(segment, 0.0f, 1.0f);
        radiance += throughput * float3(h->controls.ambient) * (1 - segment);
        throughput *= segment;
        pathVisibility = next;
        if (pathVisibility <= EPS)
            break;
        if (e.portal) {
            if (!advancePortal(e, p, v, chartId, hops, h->controls.maxChartHops,
                               charts, portals, error, compoundPortalHops,
                               portalTests, hitHopLimit))
                break;
            continue;
        }
        ObjectGPU o = objects[e.index];
        if (o.colorIdx < 0 || o.colorIdx >= h->counts.materialCount) {
            radiance = float3(1, 0, 1);
            break;
        }
        MaterialGPU m = materials[o.colorIdx];
        if (o.responseKind == RESPONSE_OPAQUE) {
            radiance +=
            throughput * shade(e, o, m, chartId, -e.tangent, charts, portals,
                               lights, h->controls.ambient, h->controls.falloffK,
                               clamp(h->controls.maxLightHops, 0, 4),
                               clamp(h->controls.maxLightStates, 1, 256), error);
            break;
        }
        if (o.responseKind != RESPONSE_MIRROR)
            break;

        if (bounce == maxBounces) {
            radiance += throughput * m.color.rgb;
            break;
        }

        float reflectivity =
        clamp(m.specular.a * h->controls.bounceAttenuation, 0.0f, 1.0f);
        radiance += throughput * m.color.rgb * (1.0f - reflectivity);
        throughput *= m.specular.rgb * reflectivity;
        v = tangentNormalize(e.tangent - 2 * mdot(e.tangent, e.normal) * e.normal);
        p = e.point;
        ++bounce;
    }
    if (error)
        atomic_fetch_or_explicit(&stats->errorBits, error, memory_order_relaxed);
    uint threadsInGroup = threadsPerGroup.x * threadsPerGroup.y;
    uint simdGroupCount =
    (threadsInGroup + threadsPerSIMDGroup - 1) / threadsPerSIMDGroup;
    recordTraceStats(stats, uint(hops), compoundPortalHops, portalTests,
                     hitHopLimit, laneInSIMDGroup, simdGroupIndex, threadIndex,
                     simdGroupCount, rayPartials, hopPartials, compoundPartials,
                     maximumPartials, limitedPartials, testPartials);
    output.write(float4(clamp(radiance, 0.0f, 1.0f), 1), pixel);
}
