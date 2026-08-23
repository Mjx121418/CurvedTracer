#include <metal_stdlib>
using namespace metal;

constant int PACKET_MAGIC         = 0x4E545243;
constant int CONTRACT_VERSION     = 7;
constant int PACKET_HEADER_SIZE   = 128;
constant int OBJECT_SIZE          = 32;

constant int MODEL_H3             = 0;
constant int MODEL_S3             = 1;
constant int OBJECT_OPAQUE_SPHERE = 0;
constant int OBJECT_MIRROR_SPHERE = 1;

constant int FOG_DISABLED          = 0;
constant int FOG_COMPACT           = 1;
constant int FOG_EXPONENTIAL       = 2;

constant int MAX_BOUNCES          = 64;
constant int MAX_LIGHTS           = 16;

constant float EPS                = 1e-5f;
constant float SELF_HIT_EPS       = 1e-4f;
constant float SHADOW_HIT_EPS     = 5e-4f;
constant float INF                = 1e30f;
constant float PI                 = 3.14159265358979323846f;

struct PacketMeta {
    int magic;
    int contractVersion;
    int objectSize;
    int packetHeaderSize;
};

struct Camera {
    float4 right;
    float4 up;
    float4 fwd;
    float fovTan;
    float aspect;
    float chartRadius;
    float chartRadiusHalfAngle;
};

struct RenderControls {
    int maxBounces;
    int modelKind;
    float falloffK;
    float ambient;
    float bounceAttenuation;

    // CONTRACT v7 keeps these at the former pad0/pad1/pad2 offsets.
    // fogMode: 0 = disabled, 1 = compact smoothstep, 2 = exponential.
    // compact mode uses fogStartFraction in [0,1).
    // exponential mode uses fogDensity in inverse intrinsic-distance units.
    float fogMode;
    float fogStartFraction;
    float fogDensity;
};

struct Counts {
    int objectCount;
    int materialCount;
    int lightCount;
    int pad0;
};

struct PacketHeader {
    PacketMeta meta;
    Camera camera;
    RenderControls controls;
    Counts counts;
};

struct SceneObject {
    packed_float3 a;
    float b;
    float c;
    int kind;
    int colorIdx;
    int pad0;
};

struct PointLight {
    packed_float3 position;
    float positionW; // Signed fourth coordinate for S3; ignored for H3.
    packed_float3 color;
    float intensity;
};

struct Material {
    float4 color;
    float4 specular;
};

// Unified ambient surface: <n,X>_kappa = h.
struct AmbientSurface {
    float4 n;
    float h;
};

struct Roots {
    int count;
    float r0;
    float r1;
};

struct Hit {
    bool valid;
    int objectIndex;
    // tan(distance/2) in S3; tanh(distance/2) in H3.
    float halfAngle;
    float intrinsicDistance;
    float4 ambientPoint;
    float4 ambientNormal;
};

struct HitFrame {
    bool valid;
    float4x4 sceneTransform;
    float3 normal;
    float3 view;
};

struct LightSample {
    bool valid;
    float3 direction;
    float halfAngle;
    float areaRadiusSquared;
};

struct DirectLighting {
    float3 diffuse;
    float3 specular;
};

struct ReflectionStep {
    bool valid;
    float4x4 chartChange;
    float3 rayDirection;
};

float modelKappa(int modelKind) {
    return modelKind == MODEL_S3 ? 1.0f : -1.0f;
}

// --------------------------------------------------------------------------
// CONTRACT v9: authored-atlas traversal. The v7 kernel later in this file
// remains intact. Forward declarations keep both paths independent.
// --------------------------------------------------------------------------
float intrinsicDistanceFromHalfAngle(float halfAngle, float kappa);
AmbientSurface decodeAmbientSurface(SceneObject obj, int modelKind);
Roots solveQuadratic(float a, float b, float c);
float4 liftPointMetric(float3 x, float w, float kappa);
float ambientDot(float4 a, float4 b, float kappa);
float4x4 identity4();
float4x4 movePointToOrigin(float4 point, float kappa);
int decodeFogMode(float encodedMode);
float fogVisibility(float distance, float chartRadius, int fogMode,
                    float fogStartFraction, float fogDensity,
                    float exponentialBoundary);
constant int ATLAS_PACKET_MAGIC = 0x41545243;
constant int ATLAS_CONTRACT_VERSION = 9;
constant int ATLAS_HEADER_SIZE = 192;
constant int MAX_ATLAS_CHARTS = 256;
constant int MAX_ATLAS_PORTALS = 1024;
constant int MAX_ATLAS_HOPS = 128;
constant int MAX_LIGHT_ROUTE_DEPTH = 4;
constant bool ATLAS_SHADOWS_ENABLED = false;

struct AtlasCameraGPU {
    float4 position;
    float4 right;
    float4 up;
    float4 fwd;
    float fovTan;
    float aspect;
    float maxTraceDistance;
    float maxTraceHalfAngle;
    int chartId;
    int pad0;
    int pad1;
    int pad2;
};

struct AtlasControlsGPU {
    RenderControls shading;
    int maxChartHops;
    int maxLightHops;
    int maxLightStates;
    int pad0;
};

struct AtlasCountsGPU {
    int chartCount;
    int portalCount;
    int objectCount;
    int materialCount;
    int lightCount;
    int pad0;
    int pad1;
    int pad2;
};

struct AtlasHeaderGPU {
    PacketMeta meta;
    AtlasCameraGPU camera;
    AtlasControlsGPU controls;
    AtlasCountsGPU counts;
};

struct AtlasChartGPU {
    float angularRadius;
    float intrinsicRadius;
    int firstPortal;
    int portalCount;
    int firstObject;
    int objectCount;
    int firstLight;
    int lightCount;
};

struct AtlasPortalGPU {
    float4x4 toNeighbor;
    packed_float3 a;
    float b;
    float c;
    int neighborChart;
    int reversePortal;
    int interiorSign;
};

struct AtlasEvent {
    bool valid;
    bool portal;
    int index;
    float distance;
    float4 point;
    float4 tangent;
    float4 normal;
};

struct AtlasSurfaceRoot {
    bool valid;
    float halfAngle;
};

float atlasHalfAngle(float distance, float kappa) {
    return kappa > 0.0f ? tan(0.5f * distance) : tanh(0.5f * distance);
}

AtlasSurfaceRoot atlasNearestSurfaceRoot(AmbientSurface surface,
                                         float3 rayDirection,
                                         float maximumHalfAngle,
                                         float minimumHalfAngle,
                                         float kappa) {
    AtlasSurfaceRoot nearest = {false, INF};

    // The ray starts at e4. This is the same stable quadratic used by the
    // legacy flattened tracer after every reflection.
    float positionProjection = kappa * surface.n.w;
    float tangentProjection = dot(surface.n.xyz, rayDirection);
    float quadraticA = -kappa * (positionProjection + surface.h);
    float quadraticB = 2.0f * tangentProjection;
    float quadraticC = positionProjection - surface.h;
    Roots roots = solveQuadratic(quadraticA, quadraticB, quadraticC);

    for (int i = 0; i < roots.count; ++i) {
        float halfAngle = i == 0 ? roots.r0 : roots.r1;
        if (!isfinite(halfAngle) ||
            halfAngle <= minimumHalfAngle ||
            halfAngle >= maximumHalfAngle ||
            halfAngle >= nearest.halfAngle) {
            continue;
        }

        float halfAngleSquared = halfAngle * halfAngle;
        float denominator = 1.0f + kappa * halfAngleSquared;
        if (denominator <= EPS)
            continue;

        nearest.valid = true;
        nearest.halfAngle = halfAngle;
    }

    return nearest;
}

float atlasSurfaceTangentProjection(AmbientSurface surface,
                                    float3 rayDirection,
                                    float halfAngle,
                                    float kappa) {
    float halfAngleSquared = halfAngle * halfAngle;
    float inverseDenominator = 1.0f
                             / (1.0f + kappa * halfAngleSquared);
    float sine = 2.0f * halfAngle * inverseDenominator;
    float cosine = (1.0f - kappa * halfAngleSquared)
                 * inverseDenominator;
    return cosine * dot(surface.n.xyz, rayDirection)
         - sine * surface.n.w;
}

AtlasEvent atlasMaterializeSurfaceEvent(AmbientSurface surface,
                                        float3 rayDirection,
                                        float halfAngle,
                                        float kappa,
                                        bool isPortal,
                                        int index) {
    AtlasEvent event;
    event.valid = false;
    event.portal = isPortal;
    event.index = index;
    event.distance = INF;

    float halfAngleSquared = halfAngle * halfAngle;
    float denominator = 1.0f + kappa * halfAngleSquared;
    if (denominator <= EPS)
        return event;

    float sine = 2.0f * halfAngle / denominator;
    float cosine = (1.0f - kappa * halfAngleSquared) / denominator;
    float4 hitPoint = float4(sine * rayDirection, cosine);
    float4 hitTangent = float4(cosine * rayDirection,
                               -kappa * sine);
    event.distance = intrinsicDistanceFromHalfAngle(halfAngle, kappa);
    event.point = hitPoint;
    event.tangent = hitTangent;

    // Portal traversal needs the point and tangent, but never the normal.
    if (isPortal) {
        event.valid = true;
        event.normal = float4(0.0f);
        return event;
    }

    float4 hitNormal = surface.n - kappa * surface.h * hitPoint;
    float normalSquared = ambientDot(hitNormal, hitNormal, kappa);
    if (normalSquared <= EPS * EPS)
        return event;

    event.valid = true;
    event.normal = hitNormal * rsqrt(normalSquared);
    return event;
}

AmbientSurface atlasPortalSurface(AtlasPortalGPU portal, int modelKind) {
    SceneObject face;
    face.a = portal.a;
    face.b = portal.b;
    face.c = portal.c;
    face.kind = 0;
    face.colorIdx = 0;
    face.pad0 = 0;
    return decodeAmbientSurface(face, modelKind);
}

AtlasEvent atlasNearest(float3 rayDirection,
                        float4x4 chartToRay,
                        int chartId,
                        float remainingDistance,
                        float minimumObjectDistance,
                        int modelKind,
                        device const AtlasChartGPU* charts,
                        device const AtlasPortalGPU* portals,
                        device const SceneObject* objects) {
    float kappa = modelKappa(modelKind);
    AtlasEvent nearest;
    nearest.valid = false;
    nearest.portal = false;
    nearest.index = -1;
    nearest.distance = INF;
    float nearestHalfAngle = INF;
    AmbientSurface nearestSurface;

    float maximumHalfAngle = atlasHalfAngle(remainingDistance, kappa);
    float minimumObjectHalfAngle = atlasHalfAngle(minimumObjectDistance,
                                                  kappa);

    AtlasChartGPU chart = charts[chartId];
    for (int i = 0; i < chart.objectCount; ++i) {
        int objectIndex = chart.firstObject + i;
        AmbientSurface surface = decodeAmbientSurface(objects[objectIndex],
                                                       modelKind);
        surface.n = chartToRay * surface.n;
        AtlasSurfaceRoot root = atlasNearestSurfaceRoot(
            surface,
            rayDirection,
            maximumHalfAngle,
            minimumObjectHalfAngle,
            kappa);
        if (root.valid && root.halfAngle < nearestHalfAngle) {
            nearest.valid = true;
            nearest.index = objectIndex;
            nearest.portal = false;
            nearestHalfAngle = root.halfAngle;
            nearestSurface = surface;
        }
    }

    for (int i = 0; i < chart.portalCount; ++i) {
        int portalIndex = chart.firstPortal + i;
        AtlasPortalGPU portal = portals[portalIndex];
        AmbientSurface surface = atlasPortalSurface(portal, modelKind);
        surface.n = chartToRay * surface.n;
        float modelOrientation = modelKind == MODEL_S3 ? 1.0f : -1.0f;
        AtlasSurfaceRoot root = atlasNearestSurfaceRoot(
            surface,
            rayDirection,
            maximumHalfAngle,
            0.0f,
            kappa);
        if (!root.valid)
            continue;

        float crossingDirection = modelOrientation
                                * float(portal.interiorSign)
                                * atlasSurfaceTangentProjection(
                                    surface,
                                    rayDirection,
                                    root.halfAngle,
                                    kappa);
        if (crossingDirection <= EPS)
            continue;

        float halfAngleTolerance = nearest.valid
            ? 0.5f
              * (1.0f + kappa * nearestHalfAngle * nearestHalfAngle)
              * EPS
            : 0.0f;
        bool isCloser = !nearest.valid
                     || root.halfAngle
                        < nearestHalfAngle - halfAngleTolerance;
        bool winsTie = nearest.valid
                    && fabs(root.halfAngle - nearestHalfAngle)
                       <= halfAngleTolerance
                    && (!nearest.portal || portalIndex < nearest.index);
        if (isCloser || winsTie) {
            nearest.valid = true;
            nearest.index = portalIndex;
            nearest.portal = true;
            nearestHalfAngle = root.halfAngle;
            nearestSurface = surface;
        }
    }

    if (!nearest.valid)
        return nearest;

    return atlasMaterializeSurfaceEvent(nearestSurface,
                                        rayDirection,
                                        nearestHalfAngle,
                                        kappa,
                                        nearest.portal,
                                        nearest.index);
}

float4 atlasInverseIsometryPoint(float4x4 transform,
                                 float4 point,
                                 float kappa) {
    // For S3 this is transpose(transform). For H3 it is
    // G * transpose(transform) * G, where G = diag(1, 1, 1, -1).
    float4 metricPoint = float4(point.xyz, kappa * point.w);
    float4 inversePoint = transpose(transform) * metricPoint;
    inversePoint.w *= kappa;
    return inversePoint;
}

bool atlasAdvancePortal(thread float3& rayDirection,
                        thread float4x4& chartToRay,
                        thread int& chartId,
                        AtlasEvent event,
                        int maxHops,
                        thread int& portalHops,
                        device const AtlasChartGPU* charts,
                        device const AtlasPortalGPU* portals,
                        float kappa,
                        thread uint& errorBits) {
    if (portalHops >= maxHops) {
        errorBits |= 2u;
        return false;
    }
    ++portalHops;

    AtlasPortalGPU portal = portals[event.index];
    AtlasPortalGPU reversePortal = portals[portal.reversePortal];
    float4x4 recenter = movePointToOrigin(event.point, kappa);
    float4 recenteredTangent = recenter * event.tangent;
    float directionSquared = dot(recenteredTangent.xyz,
                                 recenteredTangent.xyz);
    float4x4 nextChartToRay = recenter
                            * chartToRay
                            * reversePortal.toNeighbor;
    if (!all(isfinite(recenteredTangent)) ||
        !all(isfinite(nextChartToRay[0])) ||
        !all(isfinite(nextChartToRay[1])) ||
        !all(isfinite(nextChartToRay[2])) ||
        !all(isfinite(nextChartToRay[3])) ||
        directionSquared <= EPS * EPS) {
        errorBits |= 16u;
        return false;
    }

    rayDirection = recenteredTangent.xyz * rsqrt(directionSquared);
    chartToRay = nextChartToRay;
    chartId = portal.neighborChart;

    // Outward-displaced portal collars overlap near domain edges and
    // vertices. A face pairing puts the origin inside its reverse face, but
    // it can put it beyond another face. Resolve those additional crossings
    // immediately: they change only the chart representative, not the ray's
    // accumulated geometric distance.
    int modelKind = kappa > 0.0f ? MODEL_S3 : MODEL_H3;
    float modelOrientation = modelKind == MODEL_S3 ? 1.0f : -1.0f;
    float4 localOrigin = atlasInverseIsometryPoint(
        chartToRay,
        float4(0.0f, 0.0f, 0.0f, 1.0f),
        kappa);
    if (!all(isfinite(localOrigin))) {
        errorBits |= 16u;
        return false;
    }

    while (true) {
        AtlasChartGPU chart = charts[chartId];
        int selectedPortal = -1;
        float strongestViolation = 0.0f;

        for (int i = 0; i < chart.portalCount; ++i) {
            int portalIndex = chart.firstPortal + i;
            AtlasPortalGPU candidate = portals[portalIndex];
            AmbientSurface surface = atlasPortalSurface(candidate,
                                                        modelKind);
            float violation = modelOrientation
                            * float(candidate.interiorSign)
                            * (ambientDot(surface.n, localOrigin, kappa)
                               - surface.h);
            float tangentNormalSquared = ambientDot(surface.n,
                                                     surface.n,
                                                     kappa)
                                       - kappa * surface.h * surface.h;
            float normalizedViolation = violation
                                      / sqrt(max(abs(tangentNormalSquared),
                                                 EPS * EPS));
            if (normalizedViolation > EPS &&
                normalizedViolation > strongestViolation) {
                selectedPortal = portalIndex;
                strongestViolation = normalizedViolation;
            }
        }

        if (selectedPortal < 0)
            return true;
        if (portalHops >= maxHops) {
            errorBits |= 2u;
            return false;
        }
        ++portalHops;

        AtlasPortalGPU extraPortal = portals[selectedPortal];
        AtlasPortalGPU extraReverse = portals[extraPortal.reversePortal];
        nextChartToRay = chartToRay * extraReverse.toNeighbor;
        if (!all(isfinite(nextChartToRay[0])) ||
            !all(isfinite(nextChartToRay[1])) ||
            !all(isfinite(nextChartToRay[2])) ||
            !all(isfinite(nextChartToRay[3]))) {
            errorBits |= 16u;
            return false;
        }
        float4 nextLocalOrigin = extraPortal.toNeighbor * localOrigin;
        if (!all(isfinite(nextLocalOrigin))) {
            errorBits |= 16u;
            return false;
        }
        localOrigin = nextLocalOrigin;
        chartToRay = nextChartToRay;
        chartId = extraPortal.neighborChart;
    }
}

bool atlasOccluded(float3 rayDirection,
                   float4x4 chartToRay,
                   int chartId,
                   float distance,
                   int maxHops,
                   int modelKind,
                   device const AtlasChartGPU* charts,
                   device const AtlasPortalGPU* portals,
                   device const SceneObject* objects,
                   thread uint& errorBits) {
    float kappa = modelKappa(modelKind);
    float remainingDistance = distance;
    int portalHops = 0;

    while (true) {
        AtlasEvent event = atlasNearest(rayDirection,
                                        chartToRay,
                                        chartId,
                                        remainingDistance,
                                        SHADOW_HIT_EPS,
                                        modelKind,
                                        charts,
                                        portals,
                                        objects);
        if (!event.valid)
            return false;
        if (!event.portal)
            return true;

        remainingDistance -= event.distance;
        if (!atlasAdvancePortal(rayDirection,
                                chartToRay,
                                chartId,
                                event,
                                maxHops,
                                portalHops,
                                charts,
                                portals,
                                kappa,
                                errorBits)) {
            return true;
        }
    }
}

bool atlasLightVector(float4 point,
                      float4 lightPoint,
                      float kappa,
                      thread float& distance,
                      thread float4& direction) {
    float cosine = kappa > 0.0f
        ? clamp(ambientDot(point, lightPoint, kappa), -1.0f, 1.0f)
        : max(1.0f, -ambientDot(point, lightPoint, kappa));
    distance = kappa > 0.0f ? acos(cosine) : acosh(cosine);
    float sine = kappa > 0.0f ? sin(distance) : sinh(distance);
    if (sine <= EPS)
        return false;

    direction = (lightPoint - cosine * point) / sine;
    return all(isfinite(direction));
}

DirectLighting atlasLighting(float4x4 hitChartToRay,
                             float3 incoming,
                             float3 normal,
                             int startChart,
                             float horizon,
                             float falloffK,
                             int modelKind,
                             int maxHops,
                             int maxLightHops,
                             int maxLightStates,
                             device const AtlasChartGPU* charts,
                             device const AtlasPortalGPU* portals,
                             device const SceneObject* objects,
                             device const PointLight* lights,
                             thread uint& errorBits) {
    DirectLighting result;
    result.diffuse = float3(0.0f);
    result.specular = float3(0.0f);
    float kappa = modelKappa(modelKind);

    // Iterative depth-first traversal avoids recursion in Metal. Every matrix
    // maps points from the chart at this depth back into the hit's chart.
    float4x4 chartToStart[MAX_LIGHT_ROUTE_DEPTH + 1];
    int chartStack[MAX_LIGHT_ROUTE_DEPTH + 1];
    int nextPortal[MAX_LIGHT_ROUTE_DEPTH + 1];
    int incomingReverse[MAX_LIGHT_ROUTE_DEPTH + 1];

    chartToStart[0] = identity4();
    chartStack[0] = startChart;
    nextPortal[0] = 0;
    incomingReverse[0] = -1;

    int depth = 0;
    int stateCount = 1;
    while (depth >= 0) {
        AtlasChartGPU chart = charts[chartStack[depth]];
        if (nextPortal[depth] == 0) {
            for (int i = 0; i < chart.lightCount; ++i) {
                PointLight light = lights[chart.firstLight + i];
                float4 localLight = liftPointMetric(float3(light.position),
                                                    light.positionW,
                                                    kappa);
                float4 lightPoint = hitChartToRay
                                  * chartToStart[depth]
                                  * localLight;
                float lightDistance;
                float4 ambientLightDirection;
                if (!atlasLightVector(float4(0, 0, 0, 1),
                                      lightPoint,
                                      kappa,
                                      lightDistance,
                                      ambientLightDirection) ||
                    lightDistance >= horizon) {
                    continue;
                }
                float directionSquared = dot(ambientLightDirection.xyz,
                                             ambientLightDirection.xyz);
                if (directionSquared <= EPS * EPS)
                    continue;
                float3 lightDirection = ambientLightDirection.xyz
                                      * rsqrt(directionSquared);

                if (ATLAS_SHADOWS_ENABLED &&
                    atlasOccluded(lightDirection,
                                  hitChartToRay,
                                  startChart,
                                  lightDistance,
                                  maxHops,
                                  modelKind,
                                  charts,
                                  portals,
                                  objects,
                                  errorBits)) {
                    continue;
                }

                float normalLight = max(dot(normal, lightDirection), 0.0f);
                if (normalLight <= 0.0f)
                    continue;

                float radialSine = kappa > 0.0f
                    ? sin(lightDistance)
                    : sinh(lightDistance);
                float attenuation = 1.0f
                    / (1.0f + max(falloffK, 0.0f)
                       * radialSine * radialSine);
                float3 lightColor = float3(light.color.x,
                                           light.color.y,
                                           light.color.z);
                float3 irradiance = lightColor
                                  * light.intensity
                                  * attenuation;
                result.diffuse += irradiance * normalLight;

                float3 viewDirection = -incoming;
                float3 halfway = viewDirection + lightDirection;
                float halfwaySquared = dot(halfway, halfway);
                if (halfwaySquared > EPS) {
                    halfway *= rsqrt(halfwaySquared);
                    float specularLobe = pow(max(dot(normal, halfway),
                                                 0.0f),
                                             32.0f);
                    result.specular += irradiance
                                     * specularLobe
                                     * normalLight;
                }
            }
        }

        if (depth >= maxLightHops ||
            nextPortal[depth] >= chart.portalCount) {
            --depth;
            continue;
        }

        int portalIndex = chart.firstPortal + nextPortal[depth]++;
        if (portalIndex == incomingReverse[depth])
            continue;
        if (stateCount++ >= maxLightStates) {
            errorBits |= 4u;
            break;
        }

        AtlasPortalGPU portal = portals[portalIndex];
        int nextDepth = depth + 1;
        chartStack[nextDepth] = portal.neighborChart;
        nextPortal[nextDepth] = 0;
        incomingReverse[nextDepth] = portal.reversePortal;
        chartToStart[nextDepth] = chartToStart[depth]
                                * portals[portal.reversePortal].toNeighbor;
        depth = nextDepth;
    }

    return result;
}

kernel void raytraceAtlas(device const uchar* packet [[buffer(0)]],
                          device atomic_uint* status [[buffer(1)]],
                          texture2d<float, access::write> output [[texture(0)]],
                          uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height())
        return;

    device const AtlasHeaderGPU* header =
        reinterpret_cast<device const AtlasHeaderGPU*>(packet);
    uint errors = 0;

    if (header->meta.magic != ATLAS_PACKET_MAGIC ||
        header->meta.contractVersion != ATLAS_CONTRACT_VERSION ||
        header->meta.packetHeaderSize != ATLAS_HEADER_SIZE) {
        errors |= 1u;
    }

    int chartCount = header->counts.chartCount;
    int portalCount = header->counts.portalCount;
    int objectCount = header->counts.objectCount;
    int materialCount = header->counts.materialCount;
    int lightCount = header->counts.lightCount;
    if (chartCount <= 0 || chartCount > MAX_ATLAS_CHARTS ||
        portalCount < 0 || portalCount > MAX_ATLAS_PORTALS ||
        objectCount < 0 || objectCount > 4096 ||
        materialCount <= 0 || materialCount > 256 ||
        lightCount < 0 || lightCount > 16) {
        errors |= 1u;
    }

    if (header->camera.chartId < 0 ||
        header->camera.chartId >= chartCount ||
        header->controls.maxChartHops <= 0 ||
        header->controls.maxChartHops > MAX_ATLAS_HOPS ||
        header->controls.maxLightHops < 0 ||
        header->controls.maxLightHops > MAX_LIGHT_ROUTE_DEPTH ||
        header->controls.maxLightStates <= 0 ||
        header->controls.maxLightStates > 256) {
        errors |= 1u;
    }

    if (errors != 0) {
        atomic_fetch_or_explicit(status, errors, memory_order_relaxed);
        output.write(float4(1, 0, 1, 1), pixel);
        return;
    }

    uint offset = ATLAS_HEADER_SIZE;
    device const AtlasChartGPU* charts =
        reinterpret_cast<device const AtlasChartGPU*>(packet + offset);
    offset += uint(chartCount) * uint(sizeof(AtlasChartGPU));
    device const AtlasPortalGPU* portals =
        reinterpret_cast<device const AtlasPortalGPU*>(packet + offset);
    offset += uint(portalCount) * uint(sizeof(AtlasPortalGPU));
    device const SceneObject* objects =
        reinterpret_cast<device const SceneObject*>(packet + offset);
    offset += uint(objectCount) * uint(sizeof(SceneObject));
    device const Material* materials =
        reinterpret_cast<device const Material*>(packet + offset);
    offset += uint(materialCount) * uint(sizeof(Material));
    device const PointLight* lights =
        reinterpret_cast<device const PointLight*>(packet + offset);

    float2 uv = (float2(pixel) + 0.5f)
              / float2(output.get_width(), output.get_height());
    float2 screen = 2.0f * uv - 1.0f;
    screen.y = -screen.y;
    float renderAspect = float(output.get_width())
                       / float(output.get_height());

    float kappa = modelKappa(header->controls.shading.modelKind);
    float4 cameraTangent = header->camera.fwd
                         + screen.x
                           * renderAspect
                           * header->camera.fovTan
                           * header->camera.right
                         + screen.y
                           * header->camera.fovTan
                           * header->camera.up;
    float4x4 chartToRay = movePointToOrigin(header->camera.position,
                                            kappa);
    float4 recenteredTangent = chartToRay * cameraTangent;
    float directionSquared = dot(recenteredTangent.xyz,
                                 recenteredTangent.xyz);
    if (!isfinite(directionSquared) || directionSquared <= EPS * EPS) {
        atomic_fetch_or_explicit(status, 16u, memory_order_relaxed);
        output.write(float4(1, 0, 1, 1), pixel);
        return;
    }
    float3 rayDirection = recenteredTangent.xyz * rsqrt(directionSquared);

    int chartId = header->camera.chartId;
    float remainingDistance = header->camera.maxTraceDistance;
    float pathDistance = 0.0f;
    float3 throughput = float3(1.0f);
    float3 radiance = float3(0.0f);

    int fogMode = decodeFogMode(header->controls.shading.fogMode);
    float fogDensity = max(header->controls.shading.fogDensity, 0.0f);
    float pathVisibility = 1.0f;
    float exponentialBoundary =
        fogMode == FOG_EXPONENTIAL &&
        fogDensity * header->camera.maxTraceDistance >= 1e-3f
            ? exp(-fogDensity * header->camera.maxTraceDistance)
            : 0.0f;
    float3 fogColor = float3(header->controls.shading.ambient);

    int portalHops = 0;
    int maxBounces = clamp(header->controls.shading.maxBounces,
                           0,
                           MAX_BOUNCES);
    for (int bounce = 0; bounce <= maxBounces;) {
        AtlasEvent event = atlasNearest(
            rayDirection,
            chartToRay,
            chartId,
            remainingDistance,
            0.5f * SELF_HIT_EPS,
            header->controls.shading.modelKind,
            charts,
            portals,
            objects);
        if (!event.valid) {
            radiance += throughput * fogColor;
            break;
        }

        remainingDistance -= event.distance;
        pathDistance += event.distance;
        float nextVisibility = fogVisibility(
            pathDistance,
            header->camera.maxTraceDistance,
            fogMode,
            header->controls.shading.fogStartFraction,
            fogDensity,
            exponentialBoundary);
        float segmentVisibility = pathVisibility > EPS
            ? clamp(nextVisibility / pathVisibility, 0.0f, 1.0f)
            : 0.0f;
        radiance += throughput * fogColor * (1.0f - segmentVisibility);
        throughput *= segmentVisibility;
        pathVisibility = nextVisibility;
        if (pathVisibility <= EPS)
            break;

        if (event.portal) {
            if (!atlasAdvancePortal(rayDirection,
                                    chartToRay,
                                    chartId,
                                    event,
                                    header->controls.maxChartHops,
                                    portalHops,
                                    charts,
                                    portals,
                                    kappa,
                                    errors)) {
                break;
            }
            continue;
        }

        SceneObject object = objects[event.index];
        if (object.colorIdx < 0 || object.colorIdx >= materialCount) {
            errors |= 16u;
            break;
        }
        Material material = materials[object.colorIdx];

        if (object.kind == OBJECT_OPAQUE_SPHERE) {
            float4x4 recenter = movePointToOrigin(event.point, kappa);
            float4x4 hitChartToRay = recenter * chartToRay;
            float3 hitIncoming = (recenter * event.tangent).xyz;
            float3 shadingNormal = (recenter * event.normal).xyz;
            float incomingSquared = dot(hitIncoming, hitIncoming);
            float normalSquared = dot(shadingNormal, shadingNormal);
            if (incomingSquared <= EPS * EPS || normalSquared <= EPS * EPS) {
                errors |= 16u;
                break;
            }
            hitIncoming *= rsqrt(incomingSquared);
            shadingNormal *= rsqrt(normalSquared);
            if (dot(shadingNormal, -hitIncoming) < 0.0f)
                shadingNormal = -shadingNormal;

            DirectLighting direct = atlasLighting(
                hitChartToRay,
                hitIncoming,
                shadingNormal,
                chartId,
                header->camera.maxTraceDistance,
                header->controls.shading.falloffK,
                header->controls.shading.modelKind,
                header->controls.maxChartHops,
                header->controls.maxLightHops,
                header->controls.maxLightStates,
                charts,
                portals,
                objects,
                lights,
                errors);
            radiance += throughput
                      * (material.color.rgb
                         * (header->controls.shading.ambient
                            + direct.diffuse)
                         + material.specular.rgb
                           * material.specular.a
                           * direct.specular);
            break;
        }

        if (object.kind == OBJECT_MIRROR_SPHERE && bounce < maxBounces) {
            throughput *= material.specular.rgb
                        * material.specular.a
                        * header->controls.shading.bounceAttenuation;
            float4 reflectedTangent = event.tangent
                                    - 2.0f
                                      * ambientDot(event.tangent,
                                                   event.normal,
                                                   kappa)
                                      * event.normal;
            float4x4 recenter = movePointToOrigin(event.point, kappa);
            float3 recenteredReflection = (recenter
                                           * reflectedTangent).xyz;
            float reflectionSquared = dot(recenteredReflection,
                                          recenteredReflection);
            if (reflectionSquared <= EPS * EPS) {
                errors |= 16u;
                break;
            }
            rayDirection = recenteredReflection * rsqrt(reflectionSquared);
            chartToRay = recenter * chartToRay;
            ++bounce;
            continue;
        }

        radiance += throughput * fogColor;
        break;
    }

    if (errors != 0) {
        atomic_fetch_or_explicit(status, errors, memory_order_relaxed);
        radiance = float3(1, 0, 1);
    }

    output.write(float4(clamp(radiance, 0.0f, 1.0f), 1.0f), pixel);
}

float ambientDot(float4 a, float4 b, float kappa) {
    return dot(a.xyz, b.xyz) + kappa * a.w * b.w;
}

float4x4 identity4() {
    return float4x4(float4(1, 0, 0, 0),
                    float4(0, 1, 0, 0),
                    float4(0, 0, 1, 0),
                    float4(0, 0, 0, 1));
}

int decodeFogMode(float encodedMode) {
    int mode = int(floor(encodedMode + 0.5f));
    return clamp(mode, FOG_DISABLED, FOG_EXPONENTIAL);
}

// View-path transmittance from the camera to an intrinsic path distance.
// Both enabled modes have compact support at chartRadius. Exponential mode is
// normalized so that T(0)=1 and T(chartRadius)=0 instead of leaving a hard
// discontinuity at the camera-chart boundary.
float fogVisibility(float distance,
                    float chartRadius,
                    int fogMode,
                    float fogStartFraction,
                    float fogDensity,
                    float exponentialBoundary) {
    if (distance >= chartRadius)
        return 0.0f;

    if (distance <= 0.0f || fogMode == FOG_DISABLED)
        return 1.0f;

    if (fogMode == FOG_COMPACT) {
        float startFraction = clamp(fogStartFraction,
                                    0.0f,
                                    1.0f - EPS);
        float fadeStart = startFraction * chartRadius;
        return 1.0f - smoothstep(fadeStart,
                                 chartRadius,
                                 distance);
    }

    // Truncated, normalized exponential:
    //
    //   T(d) = (exp(-sigma d) - exp(-sigma R))
    //          / (1 - exp(-sigma R)).
    //
    // Its sigma -> 0 limit is the linear fade 1-d/R.
    float density = max(fogDensity, 0.0f);
    float opticalDepth = density * chartRadius;
    if (opticalDepth < 1e-3f)
        return clamp(1.0f - distance / chartRadius,
                     0.0f,
                     1.0f);

    float atDistance = exp(-density * distance);
    return clamp((atDistance - exponentialBoundary)
                 / max(1.0f - exponentialBoundary, EPS),
                 0.0f,
                 1.0f);
}

float intrinsicDistanceFromHalfAngle(float halfAngle,
                                     float kappa) {
    return kappa > 0.0f
        ? 2.0f * atan(halfAngle)
        : 2.0f * atanh(clamp(halfAngle,
                             0.0f,
                             1.0f - EPS));
}

// Generalized tangent subtraction:
// tan((R-s)/2) in S3 and tanh((R-s)/2) in H3.
float subtractHalfAngles(float total,
                         float segment,
                         float kappa) {
    float denominator = 1.0f + kappa * total * segment;
    return max(0.0f,
               (total - segment) / max(denominator, EPS));
}

float4 liftPointS3(float3 x, float w) {
    return float4(x, w);
}

// Compact H3 coordinate x=tanh(d)L -> hyperboloid point.
float4 liftPointH3(float3 x) {
    float compactW = sqrt(max(0.0f, 1.0f - dot(x, x)));
    float inverseW = 1.0f / max(compactW, EPS);
    return float4(x * inverseW, inverseW);
}

float4 liftPointMetric(float3 x, float w, float kappa) {
    return kappa > 0.0f ? liftPointS3(x, w) : liftPointH3(x);
}

// Unit tangent of the current radial geodesic at the hit.
float4 rayTangentAtHit(Hit hit,
                       float3 rayDirection,
                       float kappa) {
    float radialComponent = dot(hit.ambientPoint.xyz, rayDirection);

    // S3: (cos(s)d,-sin(s)); H3: (cosh(s)d,sinh(s)).
    return float4(hit.ambientPoint.w * rayDirection,
                  -kappa * radialComponent);
}

AmbientSurface decodeAmbientSurface(SceneObject obj,
                                    int modelKind) {
    if (modelKind == MODEL_S3) {
        AmbientSurface surface;
        surface.n = float4(obj.a.x,
                           obj.a.y,
                           obj.a.z,
                           obj.b);
        surface.h = obj.c;
        return surface;
    }

    // In the H3 compact disk x=tanh(d)L, w=sqrt(1-|x|^2),
    //
    //   a.x+bw=c
    //
    // lifts directly to <(-a,-c),X>_L=b on the hyperboloid.
    AmbientSurface surface;
    surface.n = float4(-obj.a.x,
                       -obj.a.y,
                       -obj.a.z,
                       -obj.c);
    surface.h = obj.b;
    return surface;
}

AmbientSurface transformedAmbientSurface(SceneObject obj,
                                          float4x4 transform,
                                          int modelKind) {
    AmbientSurface surface = decodeAmbientSurface(obj, modelKind);
    surface.n = transform * surface.n;
    return surface;
}

Roots solveQuadratic(float a, float b, float c) {
    Roots roots = {0, 0.0f, 0.0f};

    if (fabs(a) < EPS) {
        if (fabs(b) >= EPS) {
            roots.count = 1;
            roots.r0 = -c / b;
        }
        return roots;
    }

    float discriminant = b * b - 4.0f * a * c;
    if (discriminant < -EPS)
        return roots;

    float rootDiscriminant = sqrt(max(discriminant, 0.0f));
    if (rootDiscriminant < EPS) {
        roots.count = 1;
        roots.r0 = -b / (2.0f * a);
        return roots;
    }

    float q = -0.5f * (b + copysign(rootDiscriminant, b));
    if (fabs(q) < EPS) {
        roots.count = 1;
        roots.r0 = -b / (2.0f * a);
        return roots;
    }

    roots.count = 2;
    roots.r0 = q / a;
    roots.r1 = c / q;
    return roots;
}

Hit emptyHit() {
    Hit hit;
    hit.valid = false;
    hit.objectIndex = -1;
    hit.halfAngle = INF;
    hit.intrinsicDistance = 0.0f;
    hit.ambientPoint = float4(0, 0, 0, 1);
    hit.ambientNormal = float4(0.0f);
    return hit;
}

Hit findNearestHit(float3 rayDirection,
                   float4x4 transform,
                   float halfAngleLimit,
                   float minimumHalfAngle,
                   int modelKind,
                   device const SceneObject* objects,
                   int objectCount) {
    Hit nearest = emptyHit();
    float kappa = modelKappa(modelKind);

    for (int i = 0; i < objectCount; ++i) {
        SceneObject obj = objects[i];

        AmbientSurface surface = transformedAmbientSurface(
            obj,
            transform,
            modelKind);

        // Along X(s)=(S_kappa(s)d,C_kappa(s)), let
        // u=tan(s/2) in S3 and u=tanh(s/2) in H3. Then
        //
        //   S_kappa=2u/(1+kappa*u^2),
        //   C_kappa=(1-kappa*u^2)/(1+kappa*u^2).
        //
        // Substitution into <n,X>_kappa=h gives one quadratic in u
        // for both geometries.
        float alpha = dot(surface.n.xyz, rayDirection);
        float beta = kappa * surface.n.w;
        float A = -kappa * (beta + surface.h);
        float B = 2.0f * alpha;
        float C = beta - surface.h;
        Roots roots = solveQuadratic(A, B, C);

        for (int rootIndex = 0; rootIndex < roots.count; ++rootIndex) {
            float u = rootIndex == 0 ? roots.r0 : roots.r1;
            if (!isfinite(u) ||
                u <= minimumHalfAngle ||
                u >= halfAngleLimit - EPS ||
                u >= nearest.halfAngle)
                continue;

            float u2 = u * u;
            float denominator = 1.0f + kappa * u2;
            if (denominator <= EPS)
                continue;

            float generalizedSin = 2.0f * u / denominator;
            float generalizedCos = (1.0f - kappa * u2)
                                 / denominator;
            float4 X = float4(generalizedSin * rayDirection,
                              generalizedCos);

            float lhs = ambientDot(surface.n, X, kappa);
            float equationScale = 1.0f
                                + fabs(surface.h)
                                + fabs(alpha * generalizedSin)
                                + fabs(beta * generalizedCos);
            if (fabs(lhs - surface.h) > 1e-3f * equationScale)
                continue;

            // Tangent projection of n. This is n-hX in S3 and n+hX
            // in H3 because <X,X>_kappa=kappa.
            float4 N = surface.n - kappa * surface.h * X;
            float normal2 = ambientDot(N, N, kappa);
            if (normal2 < EPS * EPS)
                continue;

            nearest.valid = true;
            nearest.objectIndex = i;
            nearest.halfAngle = u;
            nearest.ambientPoint = X;
            nearest.ambientNormal = N * rsqrt(normal2);
        }
    }

    if (nearest.valid) {
        nearest.intrinsicDistance = intrinsicDistanceFromHalfAngle(
            nearest.halfAngle,
            kappa);
    }

    return nearest;
}

// Stable SO(4) rotation sending P=(u,w) to e4.
float4x4 movePointToOriginS3(float4 P) {
    float3 u = P.xyz;
    float w = P.w;
    float r2 = dot(u, u);

    if (r2 < EPS * EPS) {
        if (w >= 0.0f)
            return identity4();

        // At the antipode, choose one orientation-preserving pi rotation.
        return float4x4(float4(-1, 0, 0, 0),
                        float4( 0, 1, 0, 0),
                        float4( 0, 0, 1, 0),
                        float4( 0, 0, 0,-1));
    }

    float3 axis = u * rsqrt(r2);
    float3 c0 = float3(1,0,0) + (w - 1.0f) * axis * axis.x;
    float3 c1 = float3(0,1,0) + (w - 1.0f) * axis * axis.y;
    float3 c2 = float3(0,0,1) + (w - 1.0f) * axis * axis.z;

    return float4x4(float4(c0, u.x),
                    float4(c1, u.y),
                    float4(c2, u.z),
                    float4(-u, w));
}

// Lorentz boost sending a future-pointing unit hyperboloid point to e4.
float4x4 movePointToOriginH3(float4 P) {
    float3 u = P.xyz;
    float w = P.w;
    float scale = 1.0f / max(1.0f + w, EPS);
    float3 c0 = float3(1,0,0) + scale * u * u.x;
    float3 c1 = float3(0,1,0) + scale * u * u.y;
    float3 c2 = float3(0,0,1) + scale * u * u.z;

    return float4x4(float4(c0, -u.x),
                    float4(c1, -u.y),
                    float4(c2, -u.z),
                    float4(-u, w));
}

float4x4 movePointToOrigin(float4 P, float kappa) {
    return kappa > 0.0f
        ? movePointToOriginS3(P)
        : movePointToOriginH3(P);
}

ReflectionStep makeReflectionStep(Hit hit,
                                  float3 incomingRayDirection,
                                  float kappa) {
    ReflectionStep result;
    result.valid = false;
    result.chartChange = identity4();
    result.rayDirection = float3(0.0f);

    float4x4 B = movePointToOrigin(hit.ambientPoint, kappa);
    float3 D = (B * rayTangentAtHit(hit,
                                    incomingRayDirection,
                                    kappa)).xyz;
    float3 N = (B * hit.ambientNormal).xyz;
    float d2 = dot(D, D);
    float n2 = dot(N, N);
    if (d2 < EPS * EPS || n2 < EPS * EPS)
        return result;

    D *= rsqrt(d2);
    N *= rsqrt(n2);

    // At e4 the tangent metric is Euclidean for both models.
    result.valid = true;
    result.chartChange = B;
    result.rayDirection = normalize(reflect(D, N));
    return result;
}

HitFrame makeHitFrame(Hit hit,
                      float3 incomingRayDirection,
                      float4x4 transform,
                      float kappa) {
    HitFrame frame;
    frame.valid = false;
    frame.sceneTransform = transform;
    frame.normal = float3(0.0f);
    frame.view = float3(0.0f);

    float4x4 B = movePointToOrigin(hit.ambientPoint, kappa);
    float3 N = (B * hit.ambientNormal).xyz;
    float3 V = -(B * rayTangentAtHit(hit,
                                     incomingRayDirection,
                                     kappa)).xyz;
    float normal2 = dot(N, N);
    float view2 = dot(V, V);
    if (normal2 < EPS * EPS || view2 < EPS * EPS)
        return frame;

    N *= rsqrt(normal2);
    V *= rsqrt(view2);
    if (dot(N, V) < 0.0f)
        N = -N;

    frame.valid = true;
    frame.sceneTransform = B * transform;
    frame.normal = N;
    frame.view = V;
    return frame;
}

LightSample samplePointLight(PointLight light,
                             float4x4 hitSceneTransform,
                             float chartRadiusHalfAngle,
                             float kappa) {
    LightSample sample;
    sample.valid = false;
    sample.direction = float3(0.0f);
    sample.halfAngle = 0.0f;
    sample.areaRadiusSquared = 0.0f;

    float3 position = float3(light.position.x,
                             light.position.y,
                             light.position.z);
    float4 Q = hitSceneTransform
             * liftPointMetric(position, light.positionW, kappa);
    float areaRadius2 = dot(Q.xyz, Q.xyz);
    if (areaRadius2 < EPS * EPS)
        return sample;

    float areaRadius = sqrt(areaRadius2);
    float halfAngleDenominator = 1.0f + Q.w;
    if (halfAngleDenominator <= EPS)
        return sample;

    // S/(1+C) is tan(d/2) in S3 and tanh(d/2) in H3.
    float halfAngle = areaRadius / halfAngleDenominator;
    float minimumHalfAngle = 0.5f * SHADOW_HIT_EPS;
    if (halfAngle <= minimumHalfAngle ||
        halfAngle >= chartRadiusHalfAngle - EPS)
        return sample;

    sample.valid = true;
    sample.direction = Q.xyz / areaRadius;
    sample.halfAngle = halfAngle;
    sample.areaRadiusSquared = areaRadius2;
    return sample;
}

bool isShadowed(LightSample light,
                float4x4 hitSceneTransform,
                int modelKind,
                device const SceneObject* objects,
                int objectCount) {
    float minimumHalfAngle = 0.5f * SHADOW_HIT_EPS;
    Hit blocker = findNearestHit(light.direction,
                                 hitSceneTransform,
                                 light.halfAngle,
                                 minimumHalfAngle,
                                 modelKind,
                                 objects,
                                 objectCount);
    return blocker.valid
        && blocker.halfAngle
            < light.halfAngle - minimumHalfAngle;
}

DirectLighting computeDirectLighting(Hit hit,
                                     float3 incomingRayDirection,
                                     float kappa,
                                     float4x4 transform,
                                     float chartRadiusHalfAngle,
                                     float falloffK,
                                     int modelKind,
                                     device const SceneObject* objects,
                                     int objectCount,
                                     device const PointLight* lights,
                                     int lightCount) {
    DirectLighting result;
    result.diffuse = float3(0.0f);
    result.specular = float3(0.0f);

    HitFrame frame = makeHitFrame(hit,
                                  incomingRayDirection,
                                  transform,
                                  kappa);
    if (!frame.valid)
        return result;

    const float shininess = 32.0f;
    const float phongNormalization =
        (shininess + 2.0f) / (2.0f * PI);

    for (int i = 0; i < lightCount; ++i) {
        LightSample light = samplePointLight(lights[i],
                                             frame.sceneTransform,
                                             chartRadiusHalfAngle,
                                             kappa);
        if (!light.valid)
            continue;

        float NoL = max(dot(frame.normal, light.direction), 0.0f);
        if (NoL <= 0.0f)
            continue;

        /*if (isShadowed(light,
                       frame.sceneTransform,
                       modelKind,
                       objects,
                       objectCount))
            continue;*/

        float attenuation = 1.0f /
            (1.0f + max(falloffK, 0.0f)
                    * light.areaRadiusSquared);
        float3 lightColor = float3(lights[i].color.x,
                                   lights[i].color.y,
                                   lights[i].color.z);
        float3 irradiance = lightColor
                          * lights[i].intensity
                          * attenuation;

        result.diffuse += irradiance * NoL;

        float3 H = frame.view + light.direction;
        float half2 = dot(H, H);
        if (half2 > EPS * EPS) {
            H *= rsqrt(half2);
            float NoH = max(dot(frame.normal, H), 0.0f);
            float specularLobe = phongNormalization
                               * pow(NoH, shininess)
                               * NoL;
            result.specular += irradiance * specularLobe;
        }
    }

    return result;
}

kernel void raytrace(device const uchar* packet [[buffer(0)]],
                     texture2d<float, access::write> output [[texture(0)]],
                     uint2 pixel [[thread_position_in_grid]]) {
    uint width = output.get_width();
    uint height = output.get_height();
    if (pixel.x >= width || pixel.y >= height)
        return;

    device const PacketHeader* header =
        reinterpret_cast<device const PacketHeader*>(packet);

    if (header->meta.magic != PACKET_MAGIC ||
        header->meta.contractVersion != CONTRACT_VERSION ||
        header->meta.objectSize != OBJECT_SIZE ||
        header->meta.packetHeaderSize != PACKET_HEADER_SIZE) {
        output.write(float4(1,0,1,1), pixel);
        return;
    }

    int modelKind = header->controls.modelKind;
    if (modelKind != MODEL_H3 && modelKind != MODEL_S3) {
        output.write(float4(1,1,0,1), pixel);
        return;
    }

    int objectCount = header->counts.objectCount;
    int materialCount = header->counts.materialCount;
    int lightCount = header->counts.lightCount;
    if (objectCount < 0 || objectCount > 4096 ||
        materialCount < 0 || materialCount > 256 ||
        lightCount < 0 || lightCount > MAX_LIGHTS) {
        output.write(float4(1,0,1,1), pixel);
        return;
    }

    device const SceneObject* objects =
        reinterpret_cast<device const SceneObject*>(
            packet + PACKET_HEADER_SIZE);
    uint materialOffset = PACKET_HEADER_SIZE
                        + uint(objectCount) * OBJECT_SIZE;
    device const Material* materials =
        reinterpret_cast<device const Material*>(
            packet + materialOffset);
    uint lightOffset = materialOffset + uint(materialCount) * 32;
    device const PointLight* lights =
        reinterpret_cast<device const PointLight*>(
            packet + lightOffset);

    float2 uv = (float2(pixel) + 0.5f) / float2(width, height);
    float2 screen = 2.0f * uv - 1.0f;
    screen.y = -screen.y;
    float renderAspect = float(width) / float(height);

    float3 rayDirection = normalize(
        header->camera.fwd.xyz
        + screen.x
            * renderAspect
            * header->camera.fovTan
            * header->camera.right.xyz
        + screen.y
            * header->camera.fovTan
            * header->camera.up.xyz);

    float kappa = modelKappa(modelKind);
    float chartRadius = header->camera.chartRadius;
    float chartRadiusHalfAngle =
        header->camera.chartRadiusHalfAngle;

    // S3 uses tan(R/2), with 0<R<pi. H3 uses tanh(R/2), with R>0.
    bool invalidRadius = !isfinite(chartRadius)
                      || !isfinite(chartRadiusHalfAngle)
                      || chartRadius <= EPS
                      || chartRadiusHalfAngle <= EPS;
    if (modelKind == MODEL_S3)
        invalidRadius = invalidRadius || chartRadius >= PI - EPS;
    else
        invalidRadius = invalidRadius
                     || chartRadiusHalfAngle >= 1.0f - EPS;

    if (invalidRadius) {
        output.write(float4(0,1,1,1), pixel);
        return;
    }

    int fogMode = decodeFogMode(header->controls.fogMode);
    float fogStartFraction = header->controls.fogStartFraction;
    float fogDensity = header->controls.fogDensity;
    float3 fogColor = float3(header->controls.ambient);
    float exponentialBoundary = 0.0f;
    if (fogMode == FOG_EXPONENTIAL &&
        max(fogDensity, 0.0f) * chartRadius >= 1e-3f) {
        exponentialBoundary = exp(-max(fogDensity, 0.0f)
                                  * chartRadius);
    }

    float4x4 transform = identity4();
    float3 throughput = float3(1.0f);
    float3 radiance = float3(0.0f);
    float pathDistance = 0.0f;
    float pathVisibility = 1.0f;
    float remainingHalfAngle = chartRadiusHalfAngle;
    float minimumHalfAngle = 0.5f * SELF_HIT_EPS;
    int maxBounces = clamp(header->controls.maxBounces,
                           0,
                           MAX_BOUNCES);

    for (int bounce = 0; bounce <= maxBounces; ++bounce) {
        if (remainingHalfAngle <= minimumHalfAngle) {
            radiance += throughput * fogColor;
            break;
        }

        Hit hit = findNearestHit(rayDirection,
                                 transform,
                                 remainingHalfAngle,
                                 minimumHalfAngle,
                                 modelKind,
                                 objects,
                                 objectCount);

        if (!hit.valid) {
            // With no hit before the horizon, the rest of the path terminates
            // in the chart-boundary fog/background.
            radiance += throughput * fogColor;
            break;
        }

        remainingHalfAngle = subtractHalfAngles(
            remainingHalfAngle,
            hit.halfAngle,
            kappa);
        pathDistance += hit.intrinsicDistance;

        float nextVisibility = fogVisibility(
            pathDistance,
            chartRadius,
            fogMode,
            fogStartFraction,
            fogDensity,
            exponentialBoundary);

        float segmentVisibility = pathVisibility > EPS
            ? nextVisibility / pathVisibility
            : 0.0f;
        segmentVisibility = clamp(segmentVisibility, 0.0f, 1.0f);

        // Integrate the homogeneous background contribution before applying
        // the material at this hit. This keeps the ordering correct across
        // lossy mirrors as well as ideal ones.
        radiance += throughput
                  * fogColor
                  * (1.0f - segmentVisibility);
        throughput *= segmentVisibility;
        pathVisibility = nextVisibility;

        if (pathVisibility <= EPS) {
            break;
        }

        SceneObject obj = objects[hit.objectIndex];
        if (obj.colorIdx < 0 || obj.colorIdx >= materialCount) {
            radiance = float3(1,0,1);
            break;
        }

        Material material = materials[obj.colorIdx];

        if (obj.kind == OBJECT_OPAQUE_SPHERE) {
            DirectLighting direct = computeDirectLighting(
                hit,
                rayDirection,
                kappa,
                transform,
                chartRadiusHalfAngle,
                header->controls.falloffK,
                modelKind,
                objects,
                objectCount,
                lights,
                lightCount);

            radiance += throughput * (
                material.color.rgb
                    * (header->controls.ambient + direct.diffuse)
                + material.specular.rgb
                    * material.specular.a
                    * direct.specular);
            break;
        }

        if (obj.kind == OBJECT_MIRROR_SPHERE) {
            if (bounce == maxBounces) {
                radiance += throughput
                          * float3(header->controls.ambient);
                break;
            }

            throughput *= material.specular.rgb
                        * material.specular.a
                        * header->controls.bounceAttenuation;

            ReflectionStep reflection = makeReflectionStep(
                hit,
                rayDirection,
                kappa);

            if (!reflection.valid) {
                radiance = float3(1,0,1);
                break;
            }

            transform = reflection.chartChange * transform;
            rayDirection = reflection.rayDirection;
            continue;
        }

        radiance = float3(1,0,1);
        break;
    }

    output.write(float4(clamp(radiance,
                              float3(0.0f),
                              float3(1.0f)),
                        1.0f),
                 pixel);
}
