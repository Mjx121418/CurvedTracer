#ifndef CURVED_TRACER_TRACE_TYPES_METAL
#define CURVED_TRACER_TRACE_TYPES_METAL

// GPU packet types, constants, and shared diagnostics.

#include <metal_stdlib>
using namespace metal;

constant int SPACE_FORM [[function_constant(0)]]; // 0 H³, 1 S³, 2 R³
constant bool ENABLE_PORTALS [[function_constant(1)]];

constant int PACKET_MAGIC = 0x41545243, CONTRACT_VERSION = 16,
HEADER_SIZE = 192, OBJECT_SIZE = 48, MAX_QUADRICS = 4096;
constant int MODEL_H3 = 0, MODEL_S3 = 1, MODEL_R3 = 2;
constant int EQUATION_LINEAR = 0, EQUATION_R3_SPHERE = 1, EQUATION_QUADRIC = 2;
constant int BSDF_EVENT_NONE = 0, BSDF_EVENT_DIFFUSE = 1,
BSDF_EVENT_SPECULAR_REFLECTION = 2, BSDF_EVENT_SPECULAR_TRANSMISSION = 3,
BSDF_EVENT_GLOSSY_REFLECTION = 4, BSDF_EVENT_GLOSSY_TRANSMISSION = 5;
constant int BSDF_MODEL_INVALID = 0, BSDF_MODEL_LAMBERTIAN = 1,
BSDF_MODEL_DELTA_REFLECTION = 2, BSDF_MODEL_DELTA_DIELECTRIC = 3,
BSDF_MODEL_GGX_CONDUCTOR = 4, BSDF_MODEL_GGX_DIELECTRIC = 5,
BSDF_MODEL_GGX_OPAQUE_DIELECTRIC = 6, BSDF_MODEL_UNSUPPORTED = 7;
constant int LIGHT_POINT = 0, LIGHT_SPHERE = 1;
constant int CLIP_LINEAR = 0, CLIP_QUADRIC = 2;
constant int FOG_DISABLED = 0, FOG_COMPACT = 1, FOG_EXPONENTIAL = 2;
constant uint DIAGNOSTIC_INVALID_RAY_STATE = 4u;
constant uint PHOTO_DIAGNOSTIC_INVALID_BSDF_SAMPLE = 128u;
constant uint PHOTO_DIAGNOSTIC_INVALID_EMITTER_SAMPLE = 256u;
constant float EPS = 1e-5f, SELF_EPS = 1e-4f, INF = 1e30f,
TWO_PI = 6.28318530718f;

static float3 toneMapRadiance(float3 radiance, float exposure) {
    float3 exposed = max(radiance, 0.0f) * max(exposure, 0.0f);
    return exposed / (1.0f + exposed);
}

struct PacketMeta {
    int magic, contractVersion, objectSize, packetHeaderSize;
};
struct CameraGPU {
    float4 position, right, up, fwd;
    float fovTan, aspect, maxTraceDistance, reservedFloat0;
    int chartId, pad0, pad1, pad2;
};
struct ControlsGPU {
    int maxBounces, modelKind;
    float falloffK, ambient, padFloat0, fogMode, fogStartFraction,
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
    // Reserved version-15 fields retained to preserve the 32-byte layout.
    float reserved0, reserved1;
    int firstPortal, portalCount, firstObject, objectCount, firstLight,
    lightCount;
};
struct PortalGPU {
    float4x4 toNeighbor;
    float4 geometry;
    float parameter;
    int equationKind, firstClip, clipCount, quadricIndex;
    int neighborChart, reversePortal, pad0;
};
struct ObjectGPU {
    float4 geometry;
    float parameter;
    int equationKind, colorIdx, firstClip, clipCount, quadricIndex, pad0, pad1;
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
    float4 baseColor;
    packed_float3 emission;
    float roughness;
    float metallic;
    float ior;
    float transmission;
    float pad0;
};

static float3 materialEmission(MaterialGPU material) {
    return max(float3(material.emission), 0.0f);
}

struct LightGPU {
    float4 position;
    packed_float3 color;
    float intensity;
    float radius;
    int kind;
    int pad0;
    int pad1;
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

struct RayState {
    float4 point;
    float4 tangent;
    int chartId;
};

struct VisibilityResult {
    bool blocked;
    uint errorBits;
    uint portalHops;
    uint compoundPortalHops;
    uint portalTests;
    bool hitHopLimit;
};

struct SurfaceTraceResult {
    bool hit;
    Event event;
    int chartId;
    float distance;
    uint errorBits;
    uint portalHops;
    uint compoundPortalHops;
    uint portalTests;
    bool hitHopLimit;
};

struct BSDFEvaluation {
    float3 value;
    float pdf;
    int valid;
};

struct BSDFSample {
    float4 direction;
    float3 weight;
    float pdf;
    int eventType;
    int delta;
    int valid;
};


#endif
