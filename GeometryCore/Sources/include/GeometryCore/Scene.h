#pragma once
// Version-10 scene packet shared verbatim by C++ and Metal.
#include "GeometryCore/Math.h"

#define GEO_CONTRACT_VERSION 10
#define GEO_PACKET_MAGIC 0x41545243

#define GEO_MAX_OBJECTS 4096
#define GEO_MAX_MATERIALS 256
#define GEO_MAX_LIGHTS 16
#define GEO_MAX_CHARTS 256
#define GEO_MAX_PORTALS 1024
#define GEO_MAX_CHART_DEPTH 64

#define GEO_MODEL_H3 0
#define GEO_MODEL_S3 1
#define GEO_MODEL_R3 2

#define GEO_OBJECT_OPAQUE 0
#define GEO_OBJECT_MIRROR 1

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
    int pad0;
    int pad1;
    int pad2;
};

struct ScenePacketHeader {
    PacketMeta meta;
    Camera camera;
    RenderControls controls;
    Counts counts;
};

// Ball: geometry=center, parameter=cos(r), -cosh(r), or r.
// Mirror: geometry=ambient outward normal, parameter=plane offset.
struct Object {
    vec4 geometry;
    float parameter;
    int kind;
    int colorIdx;
    int pad0;
};

struct Material {
    vec4 color;
    vec4 specular;
};

struct PointLight {
    vec4 position;
    vec3 color;
    float intensity;
};

#if !defined(__METAL_VERSION__)
static_assert(sizeof(int) == 4, "scene packet requires 32-bit int");
static_assert(sizeof(PacketMeta) == 16, "PacketMeta must be 16 bytes");
static_assert(sizeof(Camera) == 96, "Camera must be 96 bytes");
static_assert(sizeof(RenderControls) == 48, "RenderControls must be 48 bytes");
static_assert(sizeof(Counts) == 32, "Counts must be 32 bytes");
static_assert(sizeof(ScenePacketHeader) == 192, "ScenePacketHeader must be 192 bytes");
static_assert(sizeof(Object) == 32, "Object must be 32 bytes");
static_assert(sizeof(Material) == 32, "Material must be 32 bytes");
static_assert(sizeof(PointLight) == 32, "PointLight must be 32 bytes");
#endif

} // namespace geo
