#include <metal_stdlib>
using namespace metal;

constant int PACKET_MAGIC         = 0x4E545243;
constant int CONTRACT_VERSION     = 5;
constant int PACKET_HEADER_SIZE   = 128;
constant int OBJECT_SIZE          = 32;

constant int MODEL_H3             = 0;
constant int MODEL_S3             = 1;
constant int OBJECT_OPAQUE_SPHERE = 0;
constant int OBJECT_MIRROR_SPHERE = 1;

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
    float chartRadiusSin;
    float chartRadiusCos;
};

struct RenderControls {
    int maxBounces;
    int modelKind;
    float falloffK;
    float ambient;
    float bounceAttenuation;
    float pad0;
    float pad1;
    float pad2;
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
    float pad0;
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
    float3 position;
    float3 normal;
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

float4x4 identity4() {
    return float4x4(float4(1, 0, 0, 0),
                    float4(0, 1, 0, 0),
                    float4(0, 0, 1, 0),
                    float4(0, 0, 0, 1));
}

float3x3 identity3() {
    return float3x3(float3(1, 0, 0),
                    float3(0, 1, 0),
                    float3(0, 0, 1));
}

// Disk hemisphere x -> Poincare ball p.
float3 diskToPoincare(float3 x) {
    float w = sqrt(max(0.0f, 1.0f - dot(x, x)));
    return x / max(1.0f + w, EPS);
}

float3 diskToPoincareTangent(float3 x, float3 v) {
    float w = sqrt(max(0.0f, 1.0f - dot(x, x)));
    float denominator = max(1.0f + w, EPS);
    return v / denominator
         + x * (dot(x, v) / max(w * denominator * denominator, EPS));
}

float4 liftPointS3(float3 x) {
    float w = sqrt(max(0.0f, 1.0f - dot(x, x)));
    return float4(x, w);
}

float4 liftTangentS3(float3 x, float3 v) {
    float w = sqrt(max(0.0f, 1.0f - dot(x, x)));
    return float4(v, -dot(x, v) / max(w, EPS));
}

float4 liftPointPoincare(float3 p) {
    float r2 = dot(p, p);
    float D = max(1.0f - r2, EPS);
    return float4(2.0f * p / D, (1.0f + r2) / D);
}

float4 liftTangentPoincare(float3 p, float3 v) {
    float r2 = dot(p, p);
    float pv = dot(p, v);
    float D = max(1.0f - r2, EPS);
    return float4((2.0f / D) * (v + (2.0f * pv / D) * p),
                  4.0f * pv / (D * D));
}

// Intrinsic ambient point/tangent. kappa=+1 uses S3 in R4;
// kappa=-1 uses the H3 hyperboloid in R3,1.
float4 liftPointMetric(float3 x, float kappa) {
    return kappa > 0.0f
        ? liftPointS3(x)
        : liftPointPoincare(diskToPoincare(x));
}

float4 liftTangentMetric(float3 x, float3 v, float kappa) {
    if (kappa > 0.0f)
        return liftTangentS3(x, v);

    float3 p = diskToPoincare(x);
    return liftTangentPoincare(p, diskToPoincareTangent(x, v));
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

QuadraticSurface diskSurfaceToPoincare(float3 a, float b, float c) {
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

SurfaceCoeffs transformedSurfaceH3(SceneObject obj, float4x4 transform) {
    QuadraticSurface q = diskSurfaceToPoincare(
        float3(obj.a.x, obj.a.y, obj.a.z), obj.b, obj.c);
    AmbientSurface s = quadraticToAmbient(q, -1.0f);
    s.n = transform * s.n;
    return poincareToDiskSurface(ambientToQuadratic(s, -1.0f));
}

SurfaceCoeffs transformedSurfaceS3(SceneObject obj, float4x4 transform) {
    float4 A = transform * float4(obj.a.x, obj.a.y, obj.a.z, obj.b);
    SurfaceCoeffs s;
    s.a = A.xyz;
    s.b = A.w;
    s.c = obj.c;
    return s;
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

    float s = sqrt(max(discriminant, 0.0f));
    if (s < EPS) {
        roots.count = 1;
        roots.r0 = -b / (2.0f * a);
        return roots;
    }

    float q = -0.5f * (b + copysign(s, b));
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

Hit findNearestHit(float3 rayDirection,
                   float4x4 transform,
                   float radiusLimit,
                   float minimumT,
                   int modelKind,
                   device const SceneObject* objects,
                   int objectCount) {
    Hit nearest;
    nearest.valid = false;
    nearest.objectIndex = -1;
    nearest.t = 0.0f;
    nearest.order = INF;
    nearest.position = float3(0.0f);
    nearest.normal = float3(0.0f);

    for (int i = 0; i < objectCount; ++i) {
        SceneObject obj = objects[i];
        SurfaceCoeffs surface = modelKind == MODEL_H3
            ? transformedSurfaceH3(obj, transform)
            : transformedSurfaceS3(obj, transform);

        float ad = dot(surface.a, rayDirection);
        Roots roots = {0, 0.0f, 0.0f};

        if (fabs(surface.b) < EPS) {
            if (fabs(ad) < EPS)
                continue;
            roots.count = 1;
            roots.r0 = surface.c / ad;
        } else {
            float A = ad * ad + surface.b * surface.b;
            float B = -2.0f * surface.c * ad;
            float C = surface.c * surface.c - surface.b * surface.b;
            roots = solveQuadratic(A, B, C);
        }

        for (int rootIndex = 0; rootIndex < roots.count; ++rootIndex) {
            float t = rootIndex == 0 ? roots.r0 : roots.r1;
            float order = forwardOrder(t, radiusLimit, minimumT);
            if (order >= nearest.order)
                continue;

            float t2 = t * t;
            if (t2 >= 1.0f - EPS)
                continue;

            float w = sqrt(max(0.0f, 1.0f - t2));
            float lhs = ad * t + surface.b * w;
            if (fabs(lhs - surface.c) > 1e-3f)
                continue;

            float3 position = t * rayDirection;
            // Coordinate differential dF.  The x chart is the orthographic
            // hemisphere coordinate, whose round metric is
            //
            //   g = I + xx^T / w^2,       g^{-1} = I - xx^T.
            //
            // The H3 metric in this coordinate is conformal to this round
            // metric, so the same raised vector gives the normal direction
            // for both geometries (only its length changes).
            float3 gradientCovector = surface.a
                - (surface.b / max(w, EPS)) * position;
            float3 intrinsicNormal = gradientCovector
                - position * dot(position, gradientCovector);
            float normal2 = dot(intrinsicNormal, intrinsicNormal);
            if (normal2 < EPS * EPS)
                continue;

            nearest.valid = true;
            nearest.objectIndex = i;
            nearest.t = t;
            nearest.order = order;
            nearest.position = position;
            // Only the direction is used. Metric normalization is performed
            // after transporting this tangent to the chart origin.
            nearest.normal = intrinsicNormal * rsqrt(normal2);
        }
    }
    return nearest;
}

// Isometry sending P to (0,0,0,1), for either ambient metric
// G_kappa=diag(1,1,1,kappa).
float4x4 movePointToOrigin(float4 P, float kappa) {
    float3 u = P.xyz;
    float w = P.w;
    float scale = -kappa / max(1.0f + w, EPS);
    float3 c0 = float3(1,0,0) + scale * u * u.x;
    float3 c1 = float3(0,1,0) + scale * u * u.y;
    float3 c2 = float3(0,0,1) + scale * u * u.z;
    return float4x4(float4(c0, kappa*u.x),
                    float4(c1, kappa*u.y),
                    float4(c2, kappa*u.z),
                    float4(-u, w));
}

ReflectionStep makeReflectionStep(float3 hitPosition,
                                  float3 surfaceNormal,
                                  float3 incomingRayDirection,
                                  float kappa) {
    ReflectionStep result;
    result.valid = false;
    result.chartChange = identity4();
    result.rayDirection = float3(0.0f);

    float4 P = liftPointMetric(hitPosition, kappa);
    float4x4 B = movePointToOrigin(P, kappa);

    float3 D = (B * liftTangentMetric(hitPosition,
                                      incomingRayDirection,
                                      kappa)).xyz;
    float3 N = (B * liftTangentMetric(hitPosition,
                                      surfaceNormal,
                                      kappa)).xyz;
    float d2 = dot(D, D);
    float n2 = dot(N, N);
    if (d2 < EPS*EPS || n2 < EPS*EPS)
        return result;

    D *= rsqrt(d2);
    N *= rsqrt(n2);

    // At the ambient origin the tangent metric is ordinary Euclidean for
    // both S3 and H3, so this is the intrinsic specular reflection.
    result.valid = true;
    result.chartChange = B;
    result.rayDirection = normalize(reflect(D, N));
    return result;
}

// At a hit, create one intrinsic orthonormal frame at the origin. All BRDF
// dot products are then ordinary Euclidean dot products in this tangent space.
HitFrame makeHitFrame(Hit hit,
                      float3 incomingRayDirection,
                      float4x4 transform,
                      float kappa) {
    HitFrame frame;
    frame.valid = false;
    frame.sceneTransform = transform;
    frame.normal = float3(0.0f);
    frame.view = float3(0.0f);

    float4 P = liftPointMetric(hit.position, kappa);
    float4x4 B = movePointToOrigin(P, kappa);
    float3 N = (B * liftTangentMetric(hit.position, hit.normal, kappa)).xyz;
    float3 V = (B * liftTangentMetric(hit.position,
                                      -incomingRayDirection,
                                      kappa)).xyz;
    float n2 = dot(N, N);
    float v2 = dot(V, V);
    if (n2 < EPS*EPS || v2 < EPS*EPS)
        return frame;

    N *= rsqrt(n2);
    V *= rsqrt(v2);
    if (dot(N, V) < 0.0f)
        N = -N;

    frame.valid = true;
    frame.sceneTransform = B * transform;
    frame.normal = N;
    frame.view = V;
    return frame;
}

// The light is transformed into the recentered hit chart. At its origin:
// S3: Q=(sin(d)L,cos(d)); H3: Q=(sinh(d)L,cosh(d)).
LightSample samplePointLight(PointLight light,
                             float4x4 hitSceneTransform,
                             float radiusLimit,
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
    float4 Q = hitSceneTransform * liftPointMetric(position, kappa);
    float areaRadius2 = dot(Q.xyz, Q.xyz);
    if (areaRadius2 < EPS*EPS)
        return sample;

    float areaRadius = sqrt(areaRadius2);
    float t;
    float distance;
    if (kappa > 0.0f) {
        // This renderer's disk chart is the positive-w hemisphere.
        if (Q.w <= EPS)
            return sample;
        t = areaRadius;
        distance = atan2(areaRadius, Q.w);
    } else {
        if (Q.w <= 1.0f - 1e-4f)
            return sample;
        t = areaRadius / max(Q.w, EPS); // tanh(d)
        distance = asinh(areaRadius);
    }

    if (t <= SHADOW_HIT_EPS || t >= radiusLimit - EPS)
        return sample;

    sample.valid = true;
    sample.direction = Q.xyz / areaRadius;
    sample.lightT = t;
    sample.intrinsicDistance = distance;
    sample.areaRadiusSquared = areaRadius2;
    return sample;
}

bool isShadowed(LightSample light,
                float4x4 hitSceneTransform,
                float radiusLimit,
                int modelKind,
                device const SceneObject* objects,
                int objectCount) {
    Hit blocker = findNearestHit(light.direction,
                                 hitSceneTransform,
                                 radiusLimit,
                                 SHADOW_HIT_EPS,
                                 modelKind,
                                 objects,
                                 objectCount);
    return blocker.valid && blocker.t < light.lightT - SHADOW_HIT_EPS;
}

DirectLighting computeDirectLighting(Hit hit,
                                     float3 incomingRayDirection,
                                     float kappa,
                                     float4x4 transform,
                                     float radiusLimit,
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
    const float phongNormalization = (shininess + 2.0f) / (2.0f * PI);

    for (int i = 0; i < lightCount; ++i) {
        LightSample light = samplePointLight(lights[i],
                                             frame.sceneTransform,
                                             radiusLimit,
                                             kappa);
        if (!light.valid)
            continue;

        float NoL = max(dot(frame.normal, light.direction), 0.0f);
        if (NoL <= 0.0f)
            continue;

        if (isShadowed(light,
                       frame.sceneTransform,
                       radiusLimit,
                       modelKind,
                       objects,
                       objectCount))
            continue;

        // Curvature-correct radial area factor: sin^2(d) in S3 and
        // sinh^2(d) in H3. The leading 1 softens the point singularity.
        float attenuation = 1.0f /
            (1.0f + max(falloffK, 0.0f) * light.areaRadiusSquared);
        float3 lightColor = float3(lights[i].color.x,
                                   lights[i].color.y,
                                   lights[i].color.z);
        float3 irradiance = lightColor * lights[i].intensity * attenuation;

        result.diffuse += irradiance * NoL;

        float3 H = frame.view + light.direction;
        float h2 = dot(H, H);
        if (h2 > EPS*EPS) {
            H *= rsqrt(h2);
            float NoH = max(dot(frame.normal, H), 0.0f);
            float specularLobe = phongNormalization * pow(NoH, shininess) * NoL;
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
        reinterpret_cast<device const SceneObject*>(packet + PACKET_HEADER_SIZE);
    uint materialOffset = PACKET_HEADER_SIZE + uint(objectCount) * OBJECT_SIZE;
    device const Material* materials =
        reinterpret_cast<device const Material*>(packet + materialOffset);
    uint lightOffset = materialOffset + uint(materialCount) * 32;
    device const PointLight* lights =
        reinterpret_cast<device const PointLight*>(packet + lightOffset);

    float2 uv = (float2(pixel) + 0.5f) / float2(width, height);
    float2 screen = 2.0f * uv - 1.0f;
    screen.y = -screen.y;
    float3 rayDirection = normalize(
        header->camera.fwd.xyz
        + screen.x * header->camera.aspect * header->camera.fovTan
            * header->camera.right.xyz
        + screen.y * header->camera.fovTan * header->camera.up.xyz);

    float kappa = modelKappa(modelKind);
    float4x4 transform = identity4();
    float3 throughput = float3(1.0f);
    float3 radiance = float3(0.0f);
    int maxBounces = clamp(header->controls.maxBounces, 0, MAX_BOUNCES);

    for (int bounce = 0; bounce <= maxBounces; ++bounce) {
        Hit hit = findNearestHit(rayDirection,
                                 transform,
                                 header->camera.chartRadiusSin,
                                 SELF_HIT_EPS,
                                 modelKind,
                                 objects,
                                 objectCount);

        if (!hit.valid) {
            radiance += throughput * float3(header->controls.ambient);
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
                header->camera.chartRadiusSin,
                header->controls.falloffK,
                modelKind,
                objects,
                objectCount,
                lights,
                lightCount);

            radiance += throughput * (
                material.color.rgb
                    * (header->controls.ambient + direct.diffuse)
                + material.specular.rgb * material.specular.a
                    * direct.specular);
            break;
        }

        if (obj.kind == OBJECT_MIRROR_SPHERE) {
            if (bounce == maxBounces) {
                radiance += throughput * float3(header->controls.ambient);
                break;
            }

            throughput *= material.specular.rgb
                        * material.specular.a
                        * header->controls.bounceAttenuation;

            ReflectionStep reflection = makeReflectionStep(
                hit.position,
                hit.normal,
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
                              float3(1.0f)), 1.0f), pixel);
}
