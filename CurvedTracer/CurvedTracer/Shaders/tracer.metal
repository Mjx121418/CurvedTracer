#include <metal_stdlib>
using namespace metal;

constant int PACKET_MAGIC         = 0x4E545243;
constant int CONTRACT_VERSION     = 6;
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
constant float TWO_PI             = 6.28318530717958647693f;

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
    float chartRadiusSin;
    float chartRadiusCos;
};

struct RenderControls {
    int maxBounces;
    int modelKind;
    float falloffK;
    float ambient;
    float bounceAttenuation;

    // CONTRACT v6 keeps these at the former pad0/pad1/pad2 offsets.
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

struct SurfaceCoeffs {
    float3 a;
    float b;
    float c;
};

struct QuadraticSurface {
    float a;
    float3 b;
    float c;
};

// In H3 this represents <n,X>_L = h.
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
    float t;
    float order;
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
    float lightT;
    float intrinsicDistance;
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

float ambientDot(float4 a, float4 b, float kappa) {
    return dot(a.xyz, b.xyz) + kappa * a.w * b.w;
}

float4x4 identity4() {
    return float4x4(float4(1, 0, 0, 0),
                    float4(0, 1, 0, 0),
                    float4(0, 0, 1, 0),
                    float4(0, 0, 0, 1));
}

float wrapTwoPi(float t) {
    t = fmod(t, TWO_PI);
    return t < 0.0f ? t + TWO_PI : t;
}

int decodeFogMode(float encodedMode) {
    int mode = int(floor(encodedMode + 0.5f));
    // return clamp(mode, FOG_DISABLED, FOG_EXPONENTIAL);
    return FOG_EXPONENTIAL;
}

// View-path transmittance from the camera to an intrinsic path distance.
// Both enabled modes have compact support at chartRadius. Exponential mode is
// normalized so that T(0)=1 and T(chartRadius)=0 instead of leaving a hard
// discontinuity at the camera-chart boundary.
float fogVisibility(float distance,
                    float chartRadius,
                    int fogMode,
                    float fogStartFraction,
                    float fogDensity) {
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

    float atBoundary = exp(-opticalDepth);
    float atDistance = exp(-density * distance);
    return clamp((atDistance - atBoundary)
                 / max(1.0f - atBoundary, EPS),
                 0.0f,
                 1.0f);
}

float intrinsicHitDistance(Hit hit, int modelKind) {
    if (modelKind == MODEL_S3)
        return hit.t;

    // The H3 compact radial parameter is t=tanh(d).
    float compactT = clamp(hit.t, 0.0f, 1.0f - EPS);
    return atanh(compactT);
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
    return kappa > 0.0f
        ? float4(hit.ambientPoint.w * rayDirection, -radialComponent)
        : float4(hit.ambientPoint.w * rayDirection,  radialComponent);
}

AmbientSurface quadraticToAmbient(QuadraticSurface q, float kappa) {
    AmbientSurface s;
    s.n = float4(q.b, -q.a + kappa * q.c);
    s.h = -(kappa * q.a + q.c);
    return s;
}

QuadraticSurface ambientToQuadratic(AmbientSurface s, float kappa) {
    QuadraticSurface q;
    q.a = -0.5f * (s.n.w + kappa * s.h);
    q.b = s.n.xyz;
    q.c = 0.5f * (kappa * s.n.w - s.h);
    return q;
}

QuadraticSurface diskSurfaceToPoincare(float3 a,
                                       float b,
                                       float c) {
    QuadraticSurface q;
    q.a = b + c;
    q.b = -2.0f * a;
    q.c = c - b;
    return q;
}

SurfaceCoeffs poincareToDiskSurface(QuadraticSurface q) {
    SurfaceCoeffs s;
    s.a = -0.5f * q.b;
    s.b = 0.5f * (q.a - q.c);
    s.c = 0.5f * (q.a + q.c);
    return s;
}

AmbientSurface transformedAmbientSurfaceH3(SceneObject obj,
                                             float4x4 transform) {
    QuadraticSurface q = diskSurfaceToPoincare(
        float3(obj.a.x, obj.a.y, obj.a.z), obj.b, obj.c);
    AmbientSurface surface = quadraticToAmbient(q, -1.0f);
    surface.n = transform * surface.n;
    return surface;
}

SurfaceCoeffs ambientSurfaceToDiskH3(AmbientSurface surface) {
    return poincareToDiskSurface(
        ambientToQuadratic(surface, -1.0f));
}

float4 transformedSurfaceNormalS3(SceneObject obj,
                                  float4x4 transform) {
    return transform * float4(obj.a.x, obj.a.y, obj.a.z, obj.b);
}

SurfaceCoeffs ambientSurfaceToDiskS3(float4 A, float c) {
    SurfaceCoeffs surface;
    surface.a = A.xyz;
    surface.b = A.w;
    surface.c = c;
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

float forwardOrder(float t, float radiusLimit, float minimumT) {
    if (t <= minimumT || t >= radiusLimit - EPS)
        return INF;
    return t;
}

Hit emptyHit() {
    Hit hit;
    hit.valid = false;
    hit.objectIndex = -1;
    hit.t = 0.0f;
    hit.order = INF;
    hit.ambientPoint = float4(0, 0, 0, 1);
    hit.ambientNormal = float4(0.0f);
    return hit;
}

Hit findNearestHit(float3 rayDirection,
                   float4x4 transform,
                   float h3RadiusLimit,
                   float minimumT,
                   int modelKind,
                   float s3ChartRadius,
                   device const SceneObject* objects,
                   int objectCount) {
    Hit nearest = emptyHit();

    for (int i = 0; i < objectCount; ++i) {
        SceneObject obj = objects[i];

        AmbientSurface ambientH3;
        ambientH3.n = float4(0.0f);
        ambientH3.h = 0.0f;
        float4 ambientNormalS3 = float4(0.0f);
        SurfaceCoeffs surface;

        if (modelKind == MODEL_H3) {
            ambientH3 = transformedAmbientSurfaceH3(obj, transform);
            surface = ambientSurfaceToDiskH3(ambientH3);
        } else {
            ambientNormalS3 = transformedSurfaceNormalS3(obj, transform);
            surface = ambientSurfaceToDiskS3(ambientNormalS3, obj.c);
        }

        float ad = dot(surface.a, rayDirection);

        if (modelKind == MODEL_S3) {
            // (a.d)sin(t)+b cos(t)=c.
            float amplitude = sqrt(ad * ad + surface.b * surface.b);
            if (amplitude < EPS || fabs(surface.c) > amplitude + EPS)
                continue;

            float k = clamp(surface.c / amplitude, -1.0f, 1.0f);
            float asinK = asin(k);
            float phase = atan2(surface.b, ad);
            float roots[2] = {
                wrapTwoPi(asinK - phase),
                wrapTwoPi(PI - asinK - phase)
            };

            for (int rootIndex = 0; rootIndex < 2; ++rootIndex) {
                float t = roots[rootIndex];
                float order = forwardOrder(t,
                                           s3ChartRadius,
                                           minimumT);
                if (order >= nearest.order)
                    continue;

                float sinT = sin(t);
                float cosT = cos(t);
                float lhs = ad * sinT + surface.b * cosT;
                if (fabs(lhs - surface.c) > 1e-3f)
                    continue;

                float4 P = float4(sinT * rayDirection, cosT);
                float4 N = ambientNormalS3
                         - P * dot(ambientNormalS3, P);
                float normal2 = dot(N, N);
                if (normal2 < EPS * EPS)
                    continue;

                nearest.valid = true;
                nearest.objectIndex = i;
                nearest.t = t;
                nearest.order = order;
                nearest.ambientPoint = P;
                nearest.ambientNormal = N * rsqrt(normal2);
            }
            continue;
        }

        // H3 compact ray x=t d, t=tanh(intrinsic distance).
        Roots roots = {0, 0.0f, 0.0f};
        if (fabs(surface.b) < EPS) {
            if (fabs(ad) < EPS)
                continue;
            roots.count = 1;
            roots.r0 = surface.c / ad;
        } else {
            float A = ad * ad + surface.b * surface.b;
            float B = -2.0f * surface.c * ad;
            float C = surface.c * surface.c
                    - surface.b * surface.b;
            roots = solveQuadratic(A, B, C);
        }

        for (int rootIndex = 0; rootIndex < roots.count; ++rootIndex) {
            float t = rootIndex == 0 ? roots.r0 : roots.r1;
            float order = forwardOrder(t,
                                       h3RadiusLimit,
                                       minimumT);
            if (order >= nearest.order)
                continue;

            float t2 = t * t;
            if (t2 >= 1.0f - EPS)
                continue;

            float compactW = sqrt(max(0.0f, 1.0f - t2));
            float lhs = ad * t + surface.b * compactW;
            if (fabs(lhs - surface.c) > 1e-3f)
                continue;

            float3 position = t * rayDirection;
            float inverseW = 1.0f / max(compactW, EPS);
            float4 X = float4(position * inverseW, inverseW);

            // For <n,X>_L=h and <X,X>_L=-1, N=n+hX.
            float4 N = ambientH3.n + ambientH3.h * X;
            float normal2 = ambientDot(N, N, -1.0f);
            if (normal2 < EPS * EPS)
                continue;

            nearest.valid = true;
            nearest.objectIndex = i;
            nearest.t = t;
            nearest.order = order;
            nearest.ambientPoint = X;
            nearest.ambientNormal = N * rsqrt(normal2);
        }
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
                             float h3RadiusLimit,
                             float s3ChartRadius,
                             float kappa) {
    LightSample sample;
    sample.valid = false;
    sample.direction = float3(0.0f);
    sample.lightT = 0.0f;
    sample.intrinsicDistance = 0.0f;
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
    float rayParameter;
    float distance;

    if (kappa > 0.0f) {
        rayParameter = atan2(areaRadius, Q.w);
        distance = rayParameter;
        if (rayParameter <= SHADOW_HIT_EPS ||
            rayParameter >= s3ChartRadius - EPS)
            return sample;
    } else {
        if (Q.w <= 1.0f - 1e-4f)
            return sample;
        rayParameter = areaRadius / max(Q.w, EPS);
        distance = asinh(areaRadius);
        if (rayParameter <= SHADOW_HIT_EPS ||
            rayParameter >= h3RadiusLimit - EPS)
            return sample;
    }

    sample.valid = true;
    sample.direction = Q.xyz / areaRadius;
    sample.lightT = rayParameter;
    sample.intrinsicDistance = distance;
    sample.areaRadiusSquared = areaRadius2;
    return sample;
}

bool isShadowed(LightSample light,
                float4x4 hitSceneTransform,
                float h3RadiusLimit,
                float s3ChartRadius,
                int modelKind,
                device const SceneObject* objects,
                int objectCount) {
    Hit blocker = findNearestHit(light.direction,
                                 hitSceneTransform,
                                 h3RadiusLimit,
                                 SHADOW_HIT_EPS,
                                 modelKind,
                                 s3ChartRadius,
                                 objects,
                                 objectCount);
    return blocker.valid
        && blocker.t < light.lightT - SHADOW_HIT_EPS;
}

DirectLighting computeDirectLighting(Hit hit,
                                     float3 incomingRayDirection,
                                     float kappa,
                                     float4x4 transform,
                                     float h3RadiusLimit,
                                     float s3ChartRadius,
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
                                             h3RadiusLimit,
                                             s3ChartRadius,
                                             kappa);
        if (!light.valid)
            continue;

        float NoL = max(dot(frame.normal, light.direction), 0.0f);
        if (NoL <= 0.0f)
            continue;

        if (isShadowed(light,
                       frame.sceneTransform,
                       h3RadiusLimit,
                       s3ChartRadius,
                       modelKind,
                       objects,
                       objectCount))
            continue;

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

    float3 rayDirection = normalize(
        header->camera.fwd.xyz
        + screen.x
            * header->camera.aspect
            * header->camera.fovTan
            * header->camera.right.xyz
        + screen.y
            * header->camera.fovTan
            * header->camera.up.xyz);

    float kappa = modelKappa(modelKind);
    float s3ChartRadius = atan2(header->camera.chartRadiusSin,
                                header->camera.chartRadiusCos);
    if (s3ChartRadius < 0.0f)
        s3ChartRadius += TWO_PI;

    // A single exponential chart is injective only for radius < pi.
    if (modelKind == MODEL_S3 &&
        (s3ChartRadius <= EPS || s3ChartRadius >= PI - EPS)) {
        output.write(float4(0,1,1,1), pixel);
        return;
    }

    float h3RadiusLimit = header->camera.chartRadiusSin;

    // CONTRACT v6 stores sin(R),cos(R) for S3 and tanh(R) in
    // chartRadiusSin for H3. Convert both to one intrinsic path budget.
    float chartRadius;
    if (modelKind == MODEL_S3) {
        chartRadius = s3ChartRadius;
    } else {
        if (h3RadiusLimit <= EPS || h3RadiusLimit >= 1.0f) {
            output.write(float4(0,1,1,1), pixel);
            return;
        }
        chartRadius = atanh(h3RadiusLimit);
    }

    int fogMode = decodeFogMode(header->controls.fogMode);
    float fogStartFraction = header->controls.fogStartFraction;
    float fogDensity = header->controls.fogDensity;
    float3 fogColor = float3(header->controls.ambient);

    float4x4 transform = identity4();
    float3 throughput = float3(1.0f);
    float3 radiance = float3(0.0f);
    float pathDistance = 0.0f;
    int maxBounces = clamp(header->controls.maxBounces,
                           0,
                           MAX_BOUNCES);

    for (int bounce = 0; bounce <= maxBounces; ++bounce) {
        float remainingDistance = chartRadius - pathDistance;
        if (remainingDistance <= EPS) {
            radiance += throughput * fogColor;
            break;
        }

        // Reflected charts are recentered at every hit, but the radius is one
        // camera-relative optical-path budget. Give this segment only what is
        // left instead of restarting the full chart radius after each bounce.
        float segmentH3RadiusLimit = h3RadiusLimit;
        float segmentS3ChartRadius = s3ChartRadius;
        if (modelKind == MODEL_H3)
            segmentH3RadiusLimit = tanh(remainingDistance);
        else
            segmentS3ChartRadius = remainingDistance;

        Hit hit = findNearestHit(rayDirection,
                                 transform,
                                 segmentH3RadiusLimit,
                                 SELF_HIT_EPS,
                                 modelKind,
                                 segmentS3ChartRadius,
                                 objects,
                                 objectCount);

        if (!hit.valid) {
            // With no hit before the horizon, the rest of the path terminates
            // in the chart-boundary fog/background.
            radiance += throughput * fogColor;
            break;
        }

        float previousVisibility = fogVisibility(
            pathDistance,
            chartRadius,
            fogMode,
            fogStartFraction,
            fogDensity);

        float segmentDistance = intrinsicHitDistance(hit, modelKind);
        pathDistance += segmentDistance;

        float currentVisibility = fogVisibility(
            pathDistance,
            chartRadius,
            fogMode,
            fogStartFraction,
            fogDensity);

        float segmentVisibility = previousVisibility > EPS
            ? currentVisibility / previousVisibility
            : 0.0f;
        segmentVisibility = clamp(segmentVisibility, 0.0f, 1.0f);

        // Integrate the homogeneous background contribution before applying
        // the material at this hit. This keeps the ordering correct across
        // lossy mirrors as well as ideal ones.
        radiance += throughput
                  * fogColor
                  * (1.0f - segmentVisibility);
        throughput *= segmentVisibility;

        if (currentVisibility <= EPS) {
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
                h3RadiusLimit,
                s3ChartRadius,
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
