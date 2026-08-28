#ifndef CURVED_TRACER_TRACE_PATH_METAL
#define CURVED_TRACER_TRACE_PATH_METAL

// Deterministic path tracing.

#include "TraceLighting.metal"
#include "TracePacket.metal"

static TraceResult traceDeterministicSample(
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
    bool enableShadows
) {
    TraceResult result{};

    RayState cameraRay;
    if (!makeCameraRay(h, samplePosition, renderSize, cameraRay)) {
        result.errorBits = 4;
        result.radiance = float3(1, 0, 1);
        return result;
    }
    float4 p = cameraRay.point;
    float4 v = cameraRay.tangent;
    int chartId = cameraRay.chartId;
    float remaining = h->camera.maxTraceDistance, path = 0;
    float3 throughput = 1, radiance = 0;
    int hops = 0;
    uint error = 0, secondaryPortalHops = 0, compoundPortalHops = 0;
    uint portalTests = 0;
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
                               charts, portals, quadrics, clips, error,
                               compoundPortalHops, portalTests, hitHopLimit))
                break;
            continue;
        }
        ObjectGPU o = objects[e.index];
        if (o.colorIdx < 0 || o.colorIdx >= h->counts.materialCount) {
            radiance = float3(1, 0, 1);
            break;
        }
        MaterialGPU m = materials[o.colorIdx];
        int bsdfModel = resolveBSDFModel(m);
        if (!isSupportedBSDFModel(bsdfModel)) {
            error |= 1u;
            break;
        }
        radiance += throughput * materialEmission(m);
        if (bsdfModel == BSDF_MODEL_LAMBERTIAN ||
            bsdfModel == BSDF_MODEL_GGX_CONDUCTOR ||
            bsdfModel == BSDF_MODEL_GGX_OPAQUE_DIELECTRIC) {
            radiance +=
            throughput * shade(e, m, chartId, -e.tangent, charts, portals,
                               objects, quadrics, clips, lights,
                               h->controls.ambient, h->controls.falloffK,
                               clamp(h->controls.maxLightHops, 0, 4),
                               clamp(h->controls.maxLightStates, 1, 256),
                               h->controls.maxChartHops, enableShadows, error,
                               secondaryPortalHops, compoundPortalHops,
                               portalTests, hitHopLimit);
            break;
        }
        if (bsdfModel == BSDF_MODEL_GGX_DIELECTRIC) {
            radiance +=
            throughput * shade(e, m, chartId, -e.tangent, charts, portals,
                               objects, quadrics, clips, lights,
                               h->controls.ambient, h->controls.falloffK,
                               clamp(h->controls.maxLightHops, 0, 4),
                               clamp(h->controls.maxLightStates, 1, 256),
                               h->controls.maxChartHops, enableShadows, error,
                               secondaryPortalHops, compoundPortalHops,
                               portalTests, hitHopLimit);
        }
        if (bounce == maxBounces) {
            break;
        }
        float4 normal;
        if (!bsdfCanonicalNormal(e.point, e.normal, normal)) {
            error |= 32u;
            break;
        }
        bool frontFace = mdot(normal, -e.tangent) >= 0.0f;
        if (!frontFace)
            normal = -normal;
        float dielectricChoice =
        (bsdfModel == BSDF_MODEL_DELTA_DIELECTRIC ||
         bsdfModel == BSDF_MODEL_GGX_DIELECTRIC) ? 0.5f : 0.0f;
        MaterialGPU continuationMaterial = m;
        if (bsdfModel == BSDF_MODEL_GGX_DIELECTRIC)
            continuationMaterial.roughness = 0.0f;
        BSDFSample bsdf = sampleBSDF(
            continuationMaterial, e.point, e.tangent, normal, frontFace,
            float3(0, 0, dielectricChoice));
        if (!bsdf.valid) {
            error |= 4u;
            break;
        }
        float deterministicLobeWeight =
        (bsdfModel == BSDF_MODEL_DELTA_DIELECTRIC ||
         bsdfModel == BSDF_MODEL_GGX_DIELECTRIC) ? bsdf.pdf : 1.0f;
        throughput *= bsdf.weight * deterministicLobeWeight;
        v = bsdf.direction;
        p = e.point;
        if (!canonicalizeRayState(p, v)) {
            error |= 4u;
            break;
        }
        ++bounce;
    }
    result.radiance = radiance;
    result.errorBits = error;
    result.portalHops = uint(hops) + secondaryPortalHops;
    result.compoundPortalHops = compoundPortalHops;
    result.portalTests = portalTests;
    result.hitHopLimit = hitHopLimit;
    return result;
}


#endif
