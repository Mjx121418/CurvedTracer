#ifndef CURVED_TRACER_TRACE_LIGHTING_METAL
#define CURVED_TRACER_TRACE_LIGHTING_METAL

// Direct lighting, portal-light traversal, and fog.

#include "TraceBSDF.metal"
#include "TraceIntersection.metal"

static float3 shade(Event hit, MaterialGPU material, int chartId,
             float4 view, device const ChartGPU *charts,
             device const PortalGPU *portals,
             device const ObjectGPU *objects,
             device const QuadricGPU *quadrics,
             device const PrimitiveClipGPU *clips,
             device const LightGPU *lights,
             float ambient, float falloff, int maxLightHops, int maxLightStates,
             int maxPortalHops, bool enableShadows,
             thread uint &errorBits, thread uint &portalHops,
             thread uint &compoundPortalHops, thread uint &portalTests,
             thread bool &hitHopLimit) {
    float4 normal;
    if (!bsdfCanonicalNormal(hit.point, hit.normal, normal)) {
        errorBits |= 32u;
        return float3(0);
    }
    bool frontFace = mdot(normal, view) >= 0.0f;
    if (!frontFace)
        normal = -normal;
    int bsdfModel = resolveBSDFModel(material);
    float3 radiance = bsdfModel == BSDF_MODEL_GGX_DIELECTRIC
    ? float3(0)
    : clamp(material.baseColor.rgb, 0.0f, 1.0f) * float3(ambient);
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
                float nd = clamp(mdot(normal, ld), 0.0f, 1.0f);
                if (nd <= 0.0f)
                    continue;
                if (enableShadows) {
                    RayState shadowRay;
                    shadowRay.point = hit.point;
                    shadowRay.tangent = ld;
                    shadowRay.chartId = chartId;
                    VisibilityResult visibility = traceAny(
                        shadowRay, d - SELF_EPS, maxPortalHops, charts,
                        portals, objects, quadrics, clips);
                    errorBits |= visibility.errorBits;
                    portalHops += visibility.portalHops;
                    compoundPortalHops += visibility.compoundPortalHops;
                    portalTests += visibility.portalTests;
                    hitHopLimit = hitHopLimit || visibility.hitHopLimit;
                    if (visibility.blocked)
                        continue;
                }
                float ar = max(areaRadius(d), 1e-3f);
                float attenuation;
                if (l.kind == LIGHT_POINT) {
                    attenuation =
                    l.intensity / (1 + falloff * ar * ar);
                } else if (l.kind == LIGHT_SPHERE && l.radius > 0.0f) {
                    float emitterRadius = areaRadius(l.radius);
                    attenuation = l.intensity * emitterRadius * emitterRadius /
                    (ar * ar);
                    // The center approximation stores exitant Lambertian
                    // radiance; convert it back to irradiance for evaluateBSDF.
                    attenuation *= 0.5f * TWO_PI;
                } else {
                    errorBits |= 1u;
                    continue;
                }
                float3 irradiance = float3(l.color) * attenuation;
                BSDFEvaluation evaluation = evaluateBSDF(
                    material, normal, frontFace, view, ld);
                radiance += irradiance * evaluation.value * nd;
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
        // The reverse record identifies the edge back to the parent and owns
        // the inverse map from child-local coordinates to parent coordinates.
        incoming[child] = portal.reversePortal;
        toStart[child] = toStart[depth] * portals[portal.reversePortal].toNeighbor;
        depth = child;
    }
    return radiance;
}

static float fogVisibility(float distance, float horizon, int mode,
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


#endif
