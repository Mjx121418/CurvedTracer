#pragma once
// Version-12 scene packet shared verbatim by C++ and Metal.
#include "GeometryCore/Math.h"

#define GEO_CONTRACT_VERSION 12
#define GEO_PACKET_MAGIC 0x41545243

#define GEO_MAX_OBJECTS 4096
#define GEO_MAX_MATERIALS 256
#define GEO_MAX_LIGHTS 16
#define GEO_MAX_CHARTS 256
#define GEO_MAX_PORTALS 1024
#define GEO_MAX_CHART_DEPTH 64
#define GEO_MAX_CLIPS 65536
#define GEO_MAX_CLIPS_PER_OBJECT 16

#define GEO_MODEL_H3 0
#define GEO_MODEL_S3 1
#define GEO_MODEL_R3 2

#define GEO_EQUATION_LINEAR 0
#define GEO_EQUATION_R3_SPHERE 1
#define GEO_EQUATION_QUADRIC 2

#define GEO_RESPONSE_OPAQUE 0
#define GEO_RESPONSE_MIRROR 1

#define GEO_LIGHT_POINT 0
#define GEO_LIGHT_SPHERE 1

// Source-compatibility aliases for the former shape/response constants.
#define GEO_OBJECT_OPAQUE GEO_RESPONSE_OPAQUE
#define GEO_OBJECT_MIRROR GEO_RESPONSE_MIRROR

#define GEO_CLIP_LINEAR 0
#define GEO_CLIP_BALL 1

namespace geo {

struct PacketMeta {
    int magic;
    int contractVersion;
    int objectSize;
    int packetHeaderSize;
};

struct Camera {
    vec4 position;
    vec4 right;
    vec4 up;
    vec4 fwd;
    float fovTan;
    float aspect;
    float maxTraceDistance;
    float maxTraceParameter;
    int chartId;
    int pad0;
    int pad1;
    int pad2;
};

struct RenderControls {
    int maxBounces;
    int modelKind;
    float falloffK;
    float ambient;
    float bounceAttenuation;
    float fogMode;
    float fogStartFraction;
    float fogDensity;
    int maxChartHops;
    int maxLightHops;
    int maxLightStates;
    int pad0;
};

struct Counts {
    int chartCount;
    int portalCount;
    int objectCount;
    int materialCount;
    int lightCount;
    int quadricCount;
    int clipCount;
    int pad0;
};

struct ScenePacketHeader {
    PacketMeta meta;
    Camera camera;
    RenderControls controls;
    Counts counts;
};

// LINEAR: geometry=ambient metric normal, parameter=offset.
// R3_SPHERE: geometry=center, parameter=radius.
// QUADRIC: quadricIndex selects P^T Q P = 0; geometry/parameter are unused.
struct Object {
    vec4 geometry;
    float parameter;
    int equationKind;
    int responseKind;
    int colorIdx;
    int firstClip;
    int clipCount;
    int quadricIndex;
    int pad0;
};

struct Quadric {
    mat4 coefficients;
};

// LINEAR retains metricDot(geometry, P) <= parameter.
// BALL retains the intrinsic ball encoded by geometry/parameter.
struct PrimitiveClip {
    vec4 geometry;
    float parameter;
    int kind;
    int pad0;
    int pad1;
};

struct Material {
    vec4 color;
    vec4 specular;
};

struct PointLight {
    vec4 position;
    vec3 color;
    float intensity;
    float radius;
    int kind;
    int pad0;
    int pad1;
};

#if !defined(__METAL_VERSION__)
static_assert(sizeof(int) == 4, "scene packet requires 32-bit int");
static_assert(sizeof(PacketMeta) == 16, "PacketMeta must be 16 bytes");
static_assert(sizeof(Camera) == 96, "Camera must be 96 bytes");
static_assert(sizeof(RenderControls) == 48, "RenderControls must be 48 bytes");
static_assert(sizeof(Counts) == 32, "Counts must be 32 bytes");
static_assert(sizeof(ScenePacketHeader) == 192, "ScenePacketHeader must be 192 bytes");
static_assert(sizeof(Object) == 48, "Object must be 48 bytes");
static_assert(sizeof(Quadric) == 64, "Quadric must be 64 bytes");
static_assert(sizeof(PrimitiveClip) == 32, "PrimitiveClip must be 32 bytes");
static_assert(sizeof(Material) == 32, "Material must be 32 bytes");
static_assert(sizeof(PointLight) == 48, "PointLight must be 48 bytes");
#endif

} // namespace geo
