#pragma once
// Shared with MSL.  Scene packet layout, CONTRACT.md §5.
// POD structs only; static_asserts are host-only so MSL sees pure declarations.
#include "GeometryCore/Math.h"

#define GEO_CONTRACT_VERSION 4
#define GEO_PACKET_MAGIC 0x4E545243  // "NTRC" as an int32 field

#define GEO_MAX_OBJECTS 4096
#define GEO_MAX_MATERIALS 256
#define GEO_MAX_LIGHTS 16
#define GEO_MAX_CHART_DEPTH 64

#define GEO_MODEL_H3 0
#define GEO_MODEL_S3 1

#define GEO_OBJECT_OPAQUE 0
#define GEO_OBJECT_MIRROR 1

namespace geo {

// 16 bytes
struct PacketMeta {
    int magic;              // 0 = GEO_PACKET_MAGIC
    int contractVersion;    // 4 = GEO_CONTRACT_VERSION
    int objectSize;         // 8 = sizeof(Object) == 32
    int packetHeaderSize;   // 12 = sizeof(ScenePacketHeader) == 128
};

// 64 bytes
struct Camera {
    vec3 right;      // 0
    float padRight;  // 12
    vec3 up;         // 16
    float padUp;     // 28
    vec3 fwd;        // 32
    float padFwd;    // 44
    float fovTan;    // 48
    float aspect;    // 52
    float chartRadiusSin; // 56
    float chartRadiusCos; // 60
};

// 32 bytes
struct RenderControls {
    int maxBounces;         // 0
    int modelKind;          // 4
    float falloffK;         // 8
    float ambient;          // 12
    float bounceAttenuation;// 16
    float pad0;             // 20
    float pad1;             // 24
    float pad2;             // 28
};

// 16 bytes
struct Counts {
    int objectCount;        // 0
    int materialCount;      // 4
    int lightCount;         // 8
    int pad0;               // 12
};

// 32 bytes
struct Object {
    vec3 a;                 // 0   hyperplane normal part
    float b;                // 12  hyperplane w coefficient
    float c;                // 16  hyperplane right-hand side
    int kind;               // 20  GEO_OBJECT_OPAQUE / GEO_OBJECT_MIRROR
    int colorIdx;           // 24
    int pad0;               // 28
};

// 16 bytes
struct Material {
    vec4 color;             // r,g,b,a
};

// 32 bytes
struct PointLight {
    vec3 position;          // 0   chart-space light position
    float pad0;             // 12
    vec3 color;             // 16  linear light color
    float intensity;        // 28  multiplier
};

// 128 bytes
struct ScenePacketHeader {
    PacketMeta meta;        // 0
    Camera camera;          // 16
    RenderControls controls;// 80
    Counts counts;          // 112
};

#if !defined(__METAL_VERSION__)
static_assert(sizeof(int) == 4, "Scene packet requires 32-bit int");
static_assert(sizeof(PacketMeta) == 16, "PacketMeta must be 16 bytes");
static_assert(sizeof(Camera) == 64, "Camera must be 64 bytes");
static_assert(sizeof(RenderControls) == 32, "RenderControls must be 32 bytes");
static_assert(sizeof(Counts) == 16, "Counts must be 16 bytes");
static_assert(sizeof(Object) == 32, "Object must be 32 bytes");
static_assert(sizeof(Material) == 16, "Material must be 16 bytes");
static_assert(sizeof(PointLight) == 32, "PointLight must be 32 bytes");
static_assert(sizeof(ScenePacketHeader) == 128, "ScenePacketHeader must be 128 bytes");
#endif

} // namespace geo
