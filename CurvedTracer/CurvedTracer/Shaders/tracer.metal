#include <metal_stdlib>
using namespace metal;

// ============================================================
// Constants
// ============================================================

constant int PACKET_MAGIC            = 0x4E545243;
constant int CONTRACT_VERSION        = 5;
constant int PACKET_HEADER_SIZE      = 128;
constant int OBJECT_SIZE             = 32;

constant int MODEL_H3                = 0;
constant int MODEL_S3                = 1;

constant int OBJECT_OPAQUE_SPHERE    = 0;
constant int OBJECT_MIRROR_SPHERE    = 1;

constant int MAX_BOUNCES             = 64;
constant int MAX_LIGHTS               = 16;

constant float EPS                   = 1e-5f;
constant float SELF_HIT_EPS          = 1e-4f;
constant float INF                   = 1e30f;
constant float PI                    = 3.14159265358979323846f;
constant float TWO_PI                = 6.28318530717958647692f;


// ============================================================
// Scene packet
// ============================================================

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
    // Must be packed: packet stores exactly 12 bytes here.
    packed_float3 a;

    float b;
    float c;

    int kind;
    int colorIdx;

    int pad0;
};

struct PointLight {
    // Must be packed: packet stores exactly 12 bytes here.
    packed_float3 position;

    float pad0;

    packed_float3 color;

    float intensity;
};

struct Material {
    float4 color;
    float4 specular;
};


// ============================================================
// Internal representations
// ============================================================

// A disk-chart surface:
//
//     a·x + b·sqrt(1-|x|²) = c
struct SurfaceCoeffs {
    float3 a;
    float b;
    float c;
};


// ============================================================
// H3 Poincare-ball helpers (used for H3 mirror unfold only)
// ============================================================

struct QuadraticSurface {
    float a;
    float3 b;
    float c;
};

struct AmbientSurface {
    float4 n;
    float h;
};

float3 diskToPoincare(float3 x)
{
    float w = sqrt(max(0.0f, 1.0f - dot(x, x)));
    return x / (1.0f + w);
}

float3 poincareToDisk(float3 p)
{
    float r2 = dot(p, p);
    return p * (2.0f / (1.0f + r2));
}

// Differential of disk -> Poincare.
float3 diskToPoincareTangent(
    float3 x,
    float3 v
) {
    float w = sqrt(max(0.0f, 1.0f - dot(x, x)));
    float denom = 1.0f + w;
    return v / denom
         + x * (dot(x, v) / max(w * denom * denom, EPS));
}

// Old H3 lift: Poincare ball -> hyperboloid.
float4 liftPointPoincare(float3 p)
{
    float r2 = dot(p, p);
    float D = 1.0f - r2;
    return float4(
        2.0f * p / D,
        (1.0f + r2) / D
    );
}

float4 liftTangentPoincare(
    float3 p,
    float3 v
) {
    float r2 = dot(p, p);
    float pv = dot(p, v);
    float D = 1.0f - r2;

    return float4(
        (2.0f / D) * (v + (2.0f * pv / D) * p),
        4.0f * pv / (D * D)
    );
}

AmbientSurface quadraticToAmbient(
    QuadraticSurface q,
    float kappa
) {
    AmbientSurface s;
    s.n = float4(q.b, -q.a + kappa * q.c);
    s.h = -(kappa * q.a + q.c);
    return s;
}

QuadraticSurface ambientToQuadratic(
    AmbientSurface s,
    float kappa
) {
    QuadraticSurface q;
    q.a = -0.5f * (s.n.w + kappa * s.h);
    q.b = s.n.xyz;
    q.c = 0.5f * (kappa * s.n.w - s.h);
    return q;
}

// Disk surface (a,b,c) -> Poincare quadratic.
QuadraticSurface diskSurfaceToPoincare(
    float3 a,
    float b,
    float c
) {
    // Disk equation a·x + b·w = c, with p = x/(1+w).
    // Poincare equation: (b+c)|p|² - 2a·p + (c-b) = 0.
    QuadraticSurface q;
    q.a = b + c;
    q.b = -2.0f * a;
    q.c = c - b;
    return q;
}

// Poincare quadratic -> disk surface (a,b,c).
SurfaceCoeffs poincareToDiskSurface(
    QuadraticSurface q
) {
    SurfaceCoeffs s;
    s.a = q.b * -0.5f;
    s.b = (q.a - q.c) * 0.5f;
    s.c = (q.a + q.c) * 0.5f;
    return s;
}

// Transform a disk surface through an H3 Lorentz transform.
SurfaceCoeffs transformedSurfaceH3(
    SceneObject obj,
    float4x4 transform
) {
    QuadraticSurface q =
        diskSurfaceToPoincare(
            float3(obj.a.x, obj.a.y, obj.a.z),
            obj.b,
            obj.c
        );

    AmbientSurface s =
        quadraticToAmbient(q, -1.0f);

    s.n = transform * s.n;

    QuadraticSurface q2 =
        ambientToQuadratic(s, -1.0f);

    return poincareToDiskSurface(q2);
}


// Hit information in the CURRENT ray chart.
struct Hit {
    bool valid;

    int objectIndex;

    // Euclidean chart parameter:
    //
    //      x = t * rayDirection
    //
    float t;

    // Used to compare hits along the forward intrinsic ray.
    float order;

    float3 position;
    float3 normal;
};


// ============================================================
// Small helpers
// ============================================================

float modelKappa(int modelKind)
{
    return (modelKind == MODEL_S3) ? 1.0f : -1.0f;
}

float4x4 identity4()
{
    return float4x4(
        float4(1, 0, 0, 0),
        float4(0, 1, 0, 0),
        float4(0, 0, 1, 0),
        float4(0, 0, 0, 1)
    );
}

float3x3 identity3()
{
    return float3x3(
        float3(1, 0, 0),
        float3(0, 1, 0),
        float3(0, 0, 1)
    );
}


// ============================================================
// Chart <-> ambient disk model (CONTRACT v4)
//
//     X(x) = (x, sqrt(1 - |x|²))
//
// For both H³ and S³ the ambient model is S³.
// ============================================================

float4 liftPoint(float3 x, float kappa)
{
    float r2 = dot(x, x);
    float w = sqrt(max(0.0f, 1.0f - r2));
    return float4(x, w);
}


// Differential of liftPoint.
float4 liftTangent(
    float3 x,
    float3 v,
    float kappa
) {
    float w = sqrt(max(0.0f, 1.0f - dot(x, x)));
    return float4(v, -dot(x, v) / max(w, EPS));
}


float3 unliftPoint(float4 X, float kappa)
{
    return X.xyz;
}


float3 unliftTangent(float4 X, float4 V)
{
    return V.xyz;
}


// ============================================================
// Packet object -> disk-chart surface coefficients
// ============================================================

SurfaceCoeffs transformedSurface(
    SceneObject obj,
    float4x4 transform
) {
    float4 A =
        float4(
            obj.a.x,
            obj.a.y,
            obj.a.z,
            obj.b
        );

    // The shader operates in the disk model, where both H³ and S³ use S³
    // ambient isometries. A plane A·X = c transforms as A' = M A, c' = c.
    float4 Ap =
        transform * A;

    SurfaceCoeffs surface;
    surface.a = Ap.xyz;
    surface.b = Ap.w;
    surface.c = obj.c;
    return surface;
}


// ============================================================
// Ray / generalized sphere intersection
// ============================================================
//
// The ray in EVERY bounce chart is:
//
//      x(t) = t d.
//
// Therefore:
//
//      q(td)
//        = a t²
//        + (b·d)t
//        + c.
//
// ============================================================

struct Roots {
    int count;
    float r0;
    float r1;
};


Roots solveQuadratic(
    float a,
    float b,
    float c
) {
    Roots roots;
    roots.count = 0;
    roots.r0 = 0.0f;
    roots.r1 = 0.0f;

    // Linear case: plane.
    if (fabs(a) < EPS) {
        if (fabs(b) < EPS)
            return roots;

        roots.count = 1;
        roots.r0 = -c / b;

        return roots;
    }

    float discriminant =
        b * b - 4.0f * a * c;

    if (discriminant < -EPS)
        return roots;

    discriminant =
        max(discriminant, 0.0f);

    float s = sqrt(discriminant);

    if (s < EPS) {
        roots.count = 1;
        roots.r0 = -b / (2.0f * a);

        return roots;
    }

    // Numerically more stable than directly evaluating
    // both quadratic-formula roots.
    float q =
        -0.5f *
        (
            b + copysign(s, b)
        );

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


// Chart roots are ordered by t. In the disk model t = |x| and geodesic
// distance is monotone in t for both H³ and S³.
float forwardOrder(
    float t,
    float radiusSin
) {
    if (t <= SELF_HIT_EPS)
        return INF;

    if (t >= radiusSin - EPS)
        return INF;

    return t;
}


// ============================================================
// Point-light shading
// ============================================================

float3 computeLighting(
    float3 position,
    float3 normal,
    float kappa,
    float4x4 transform,
    device const PointLight* lights,
    int lightCount
) {
    float4 P =
        liftPoint(
            position,
            kappa
        );

    float3 result =
        float3(0.0f);

    for (
        int i = 0;
        i < lightCount;
        ++i
    ) {
        // Light position is authored in the camera chart; transform it
        // into the current ray chart like the objects.
        float4 Q =
            transform *
            liftPoint(
                lights[i].position,
                kappa
            );

        // Unit ambient tangent at P pointing toward Q. The disk model embeds
        // both H³ and S³ in S³, so use the sphere tangent projection.
        float4 V =
            Q - P * dot(P, Q);

        float3 chartL =
            unliftTangent(
                P,
                V
            );

        float chartL2 =
            dot(
                chartL,
                chartL
            );

        if (chartL2 < EPS * EPS) {
            continue;
        }

        float3 L =
            chartL * rsqrt(chartL2);

        float diffuse =
            max(
                dot(
                    normal,
                    L
                ),
                0.0f
            );

        result += lights[i].color * lights[i].intensity * diffuse;
    }

    return result;
}


// ============================================================
// Point-light specular
// ============================================================

float3 computeSpecular(
    float3 position,
    float3 normal,
    float kappa,
    float4x4 transform,
    device const PointLight* lights,
    int lightCount
) {
    float4 P =
        liftPoint(
            position,
            kappa
        );

    float3 viewDirection =
        -normalize(position);

    float3 result =
        float3(0.0f);

    for (
        int i = 0;
        i < lightCount;
        ++i
    ) {
        float4 Q =
            transform *
            liftPoint(
                lights[i].position,
                kappa
            );

        float4 V =
            Q - P * dot(P, Q);

        float3 chartL =
            unliftTangent(
                P,
                V
            );

        float chartL2 =
            dot(chartL, chartL);

        if (chartL2 < EPS * EPS) {
            continue;
        }

        float3 L =
            chartL * rsqrt(chartL2);

        float3 H =
            normalize(L + viewDirection);

        float specular =
            pow(
                max(
                    dot(normal, H),
                    0.0f
                ),
                32.0f
            );

        result +=
            lights[i].color
            * lights[i].intensity
            * specular;
    }

    return result;
}


// ============================================================
// Find nearest object
// ============================================================

Hit findNearestHit(
    float3 rayDirection,
    float4x4 transform,
    float radiusSin,
    int modelKind,
    device const SceneObject* objects,
    int objectCount
) {
    Hit nearest;

    nearest.valid = false;
    nearest.objectIndex = -1;
    nearest.t = 0.0f;
    nearest.order = INF;
    nearest.position = float3(0.0f);
    nearest.normal = float3(0.0f);

    for (int i = 0; i < objectCount; ++i) {

        SceneObject obj = objects[i];

        SurfaceCoeffs surface =
            (modelKind == MODEL_H3)
                ? transformedSurfaceH3(obj, transform)
                : transformedSurface(obj, transform);

        float3 a = surface.a;
        float b = surface.b;
        float c = surface.c;

        float ad = dot(a, rayDirection);

        Roots roots;
        roots.count = 0;
        roots.r0 = 0.0f;
        roots.r1 = 0.0f;

        if (fabs(b) < EPS) {
            // a·x = c  =>  t = c / (a·d)
            if (fabs(ad) < EPS)
                continue;
            roots.count = 1;
            roots.r0 = c / ad;
            roots.r1 = roots.r0;
        } else {
            // a·(t d) + b·sqrt(1 - t²) = c
            // Squared: ((a·d)² + b²)t² - 2c(a·d)t + (c² - b²) = 0.
            float A = ad * ad + b * b;
            float B = -2.0f * c * ad;
            float C = c * c - b * b;

            roots = solveQuadratic(A, B, C);
        }

        for (int rootIndex = 0;
             rootIndex < roots.count;
             ++rootIndex)
        {
            float t =
                (rootIndex == 0)
                    ? roots.r0
                    : roots.r1;

            float order =
                forwardOrder(
                    t,
                    radiusSin
                );

            if (order >= nearest.order)
                continue;

            // Verify the original equation (squaring may add roots).
            float t2 = t * t;
            if (t2 >= 1.0f - EPS)
                continue;

            float w =
                sqrt(max(0.0f, 1.0f - t2));

            float lhs =
                a.x * t * rayDirection.x
                + a.y * t * rayDirection.y
                + a.z * t * rayDirection.z
                + b * w;

            if (fabs(lhs - c) > 1e-3f)
                continue;

            float3 position =
                t * rayDirection;

            // Gradient of a·x + b·sqrt(1-|x|²) - c.
            float3 gradient =
                a - (b / max(w, EPS)) * position;

            float gradient2 =
                dot(gradient, gradient);

            if (gradient2 < EPS * EPS)
                continue;

            nearest.valid = true;
            nearest.objectIndex = i;
            nearest.t = t;
            nearest.order = order;
            nearest.position = position;
            nearest.normal =
                gradient * rsqrt(gradient2);
        }
    }

    return nearest;
}


// ============================================================
// Rotation sending one unit vector to another
// ============================================================

float3x3 quaternionRotation(float4 q)
{
    // q = (x,y,z,w)

    float x = q.x;
    float y = q.y;
    float z = q.z;
    float w = q.w;

    float xx = x * x;
    float yy = y * y;
    float zz = z * z;

    float xy = x * y;
    float xz = x * z;
    float yz = y * z;

    float xw = x * w;
    float yw = y * w;
    float zw = z * w;

    // Metal matrices are column-major.

    float3 c0 = float3(
        1.0f - 2.0f * (yy + zz),
        2.0f * (xy + zw),
        2.0f * (xz - yw)
    );

    float3 c1 = float3(
        2.0f * (xy - zw),
        1.0f - 2.0f * (xx + zz),
        2.0f * (yz + xw)
    );

    float3 c2 = float3(
        2.0f * (xz + yw),
        2.0f * (yz - xw),
        1.0f - 2.0f * (xx + yy)
    );

    return float3x3(c0, c1, c2);
}


float3x3 rotationFromTo(
    float3 from,
    float3 to
) {
    float3 a = normalize(from);
    float3 b = normalize(to);

    float c =
        clamp(dot(a, b), -1.0f, 1.0f);

    if (c > 1.0f - 1e-6f)
        return identity3();

    // Nearly opposite vectors.
    if (c < -1.0f + 1e-6f) {

        float3 basis =
            (fabs(a.x) < 0.9f)
                ? float3(1, 0, 0)
                : float3(0, 1, 0);

        float3 axis =
            normalize(cross(a, basis));

        // 180-degree rotation:
        //
        // q = (axis, 0)
        return quaternionRotation(
            float4(axis, 0.0f)
        );
    }

    // Quaternion sending a -> b:
    //
    //      q.xyz = cross(a,b)
    //      q.w   = 1 + dot(a,b)

    float4 q =
        float4(
            cross(a, b),
            1.0f + c
        );

    q = normalize(q);

    return quaternionRotation(q);
}


// Embed an ordinary spatial rotation into SO(4) or SO(3,1).
//
// It fixes the ambient point (0,0,0,1).
float4x4 embedSpatialRotation(float3x3 R)
{
    float3 c0 = R[0];
    float3 c1 = R[1];
    float3 c2 = R[2];

    return float4x4(
        float4(c0.x, c0.y, c0.z, 0.0f),
        float4(c1.x, c1.y, c1.z, 0.0f),
        float4(c2.x, c2.y, c2.z, 0.0f),
        float4(0, 0, 0, 1)
    );
}


// ============================================================
// Ambient transvection sending P to the chart origin
// ============================================================
//
// P = (u,w).
//
// Unified matrix:
//
//             [ I - κ uuᵀ/(1+w)    -u ]
//      B(P) = [                         ]
//             [      κuᵀ             w ]
//
// It satisfies:
//
//      B(P) P = (0,0,0,1)
//
// and:
//
//      Bᵀ Gκ B = Gκ,
//      Gκ = diag(1,1,1,κ).
//
// For S³ it is an SO(4) rotation.
// For H³ it is a Lorentz boost.
// ============================================================

float4x4 movePointToOrigin(
    float4 P,
    float kappa
) {
    float3 u = P.xyz;
    float w = P.w;

    float denominator =
        max(1.0f + w, EPS);

    float scale =
        -kappa / denominator;

    // Columns of:
    //
    // I - κ uuᵀ/(1+w)

    float3 c0 =
        float3(1, 0, 0)
        + scale * u * u.x;

    float3 c1 =
        float3(0, 1, 0)
        + scale * u * u.y;

    float3 c2 =
        float3(0, 0, 1)
        + scale * u * u.z;

    return float4x4(
        float4(
            c0.x,
            c0.y,
            c0.z,
            kappa * u.x
        ),

        float4(
            c1.x,
            c1.y,
            c1.z,
            kappa * u.y
        ),

        float4(
            c2.x,
            c2.y,
            c2.z,
            kappa * u.z
        ),

        float4(
            -u.x,
            -u.y,
            -u.z,
            w
        )
    );
}


// ============================================================
// Build the coordinate change after a mirror reflection
// ============================================================
//
// Current ray:
//
//      x = t d.
//
// At hit point p:
//
//      reflected = reflect(d, normal)
//
// We construct A such that:
//
//      A(p) = 0
//
// and:
//
//      dA_p(reflected) || d.
//
// Therefore, after changing coordinates by A, the new reflected
// ray is once again:
//
//      x = t d.
//
// ============================================================

float4x4 makeReflectionChartChange(
    float3 hitPosition,
    float3 reflectedDirection,
    float3 targetRayDirection,
    float kappa
) {
    float4 P =
        liftPoint(
            hitPosition,
            1.0f
        );

    float4 V =
        liftTangent(
            hitPosition,
            normalize(reflectedDirection),
            1.0f
        );

    // First move the hit point to the origin.
    float4x4 B =
        movePointToOrigin(
            P,
            1.0f
        );

    // Tangent after this coordinate change.
    float4 movedV =
        B * V;

    float3 movedDirection =
        normalize(movedV.xyz);

    // Then rotate around the origin so the reflected tangent
    // becomes the original fixed ray direction.
    float3x3 R3 =
        rotationFromTo(
            movedDirection,
            targetRayDirection
        );

    float4x4 R =
        embedSpatialRotation(R3);

    return R * B;
}


// H3 mirror unfold. The hit point and reflected direction are first converted
// from disk coordinates to the Poincare ball, then the old H3 hyperboloid
// machinery builds the Lorentz transition.
float4x4 makeReflectionChartChangeH3(
    float3 hitPosition,
    float3 reflectedDirection,
    float3 targetRayDirection
) {
    float3 hitPoincare =
        diskToPoincare(hitPosition);

    float3 reflectedPoincare =
        diskToPoincareTangent(
            hitPosition,
            normalize(reflectedDirection)
        );

    float4 P =
        liftPointPoincare(hitPoincare);

    float4 V =
        liftTangentPoincare(
            hitPoincare,
            normalize(reflectedPoincare)
        );

    float4x4 B =
        movePointToOrigin(
            P,
            -1.0f
        );

    float4 movedV =
        B * V;

    float3 movedDirection =
        normalize(movedV.xyz);

    float3x3 R3 =
        rotationFromTo(
            movedDirection,
            targetRayDirection
        );

    float4x4 R =
        embedSpatialRotation(R3);

    return R * B;
}


// ============================================================
// Main ray tracing kernel
// ============================================================

kernel void raytrace(
    device const uchar* packet
        [[buffer(0)]],

    texture2d<float, access::write> output
        [[texture(0)]],

    uint2 pixel
        [[thread_position_in_grid]]
) {
    uint width = output.get_width();
    uint height = output.get_height();

    if (
        pixel.x >= width ||
        pixel.y >= height
    ) {
        return;
    }

    // --------------------------------------------------------
    // Packet header
    // --------------------------------------------------------

    device const PacketHeader* header =
        reinterpret_cast<
            device const PacketHeader*
        >(packet);

    // Bright magenta = packet contract failure.
    if (
        header->meta.magic != PACKET_MAGIC ||
        header->meta.contractVersion
            != CONTRACT_VERSION ||
        header->meta.objectSize
            != OBJECT_SIZE ||
        header->meta.packetHeaderSize
            != PACKET_HEADER_SIZE
    ) {
        output.write(
            float4(1, 0, 1, 1),
            pixel
        );

        return;
    }

    if (
        header->controls.modelKind != MODEL_H3 &&
        header->controls.modelKind != MODEL_S3
    ) {
        output.write(
            float4(1, 1, 0, 1),
            pixel
        );

        return;
    }

    int objectCount =
        header->counts.objectCount;

    int materialCount =
        header->counts.materialCount;

    int lightCount =
        header->counts.lightCount;

    if (
        objectCount < 0 ||
        objectCount > 4096 ||
        materialCount < 0 ||
        materialCount > 256 ||
        lightCount < 0 ||
        lightCount > MAX_LIGHTS
    ) {
        output.write(
            float4(1, 0, 1, 1),
            pixel
        );

        return;
    }

    // --------------------------------------------------------
    // Variable packet arrays
    // --------------------------------------------------------

    device const SceneObject* objects =
        reinterpret_cast<
            device const SceneObject*
        >(
            packet + PACKET_HEADER_SIZE
        );

    uint materialOffset =
        PACKET_HEADER_SIZE
        + uint(objectCount) * OBJECT_SIZE;

    device const Material* materials =
        reinterpret_cast<
            device const Material*
        >(
            packet + materialOffset
        );

    uint lightOffset =
        materialOffset
        + uint(materialCount) * 32;

    device const PointLight* lights =
        reinterpret_cast<
            device const PointLight*
        >(
            packet + lightOffset
        );

    // --------------------------------------------------------
    // Primary ray
    // --------------------------------------------------------

    float2 resolution =
        float2(
            float(width),
            float(height)
        );

    float2 uv =
        (
            float2(pixel)
            + float2(0.5f)
        )
        / resolution;

    // [-1,1]^2
    float2 screen =
        2.0f * uv - 1.0f;

    // Texture Y increases downward.
    screen.y = -screen.y;

    float3 rayDirection =
        normalize(
            header->camera.fwd.xyz
            + screen.x
                * header->camera.aspect
                * header->camera.fovTan
                * header->camera.right.xyz
            + screen.y
                * header->camera.fovTan
                * header->camera.up.xyz
        );

    int modelKind =
        header->controls.modelKind;

    // Disk model: both H³ and S³ use S³ ambient isometries.
    float kappa = 1.0f;

    // --------------------------------------------------------
    // Accumulated Möbius/isometry transformation
    //
    // Maps:
    //
    //      original camera chart
    //             ↓
    //      current ray chart
    //
    // Every bounce still traces the fixed ray:
    //
    //      x = t * rayDirection.
    // --------------------------------------------------------

    float4x4 transform =
        identity4();

    float3 throughput =
        float3(1.0f);

    float3 radiance =
        float3(0.0f);

    int maxBounces =
        clamp(
            header->controls.maxBounces,
            0,
            MAX_BOUNCES
        );

    // Primary segment + up to maxBounces reflected segments.
    for (
        int bounce = 0;
        bounce <= maxBounces;
        ++bounce
    ) {
        Hit hit =
            findNearestHit(
                rayDirection,
                transform,
                header->camera.chartRadiusSin,
                modelKind,
                objects,
                objectCount
            );

        // ----------------------------------------------------
        // Miss
        // ----------------------------------------------------

        if (!hit.valid) {
            radiance +=
                throughput
                * float3(
                    header->controls.ambient
                );

            break;
        }

        SceneObject obj =
            objects[hit.objectIndex];

        // Defensive check.
        if (
            obj.colorIdx < 0 ||
            obj.colorIdx >= materialCount
        ) {
            radiance = float3(1, 0, 1);
            break;
        }

        Material material =
            materials[obj.colorIdx];

        // ----------------------------------------------------
        // Opaque surface
        // ----------------------------------------------------

        if (
            obj.kind ==
            OBJECT_OPAQUE_SPHERE
        ) {
            // Contract says t is chart distance from origin.
            //
            // Since x = t d and |d|=1:
            //
            //      chart distance = |t|.
            float chartDistance =
                fabs(hit.t);

            float falloff =
                1.0f /
                (
                    1.0f
                    + header->controls.falloffK
                    * chartDistance
                );

            float3 diffuseLighting =
                computeLighting(
                    hit.position,
                    hit.normal,
                    kappa,
                    transform,
                    lights,
                    lightCount
                );

            float3 specularLighting =
                computeSpecular(
                    hit.position,
                    hit.normal,
                    kappa,
                    transform,
                    lights,
                    lightCount
                );

            radiance +=
                throughput
                * (
                    material.color.rgb
                    * (
                        header->controls.ambient
                        + falloff * diffuseLighting
                    )
                    + falloff
                    * material.specular.rgb
                    * material.specular.a
                    * specularLighting
                );

            break;
        }

        // ----------------------------------------------------
        // Mirror
        // ----------------------------------------------------

        if (
            obj.kind ==
                OBJECT_MIRROR_SPHERE
        ) {
            // No further reflection allowed.
            if (bounce == maxBounces) {
                radiance +=
                    throughput
                    * float3(
                        header->controls.ambient
                    );

                break;
            }

            throughput *=
                material.specular.rgb
                * material.specular.a
                * header
                    ->controls
                    .bounceAttenuation;

            // Because the chart metric is conformal,
            // Euclidean reflection gives the correct angle.
            float3 reflected =
                normalize(
                    reflect(
                        rayDirection,
                        hit.normal
                    )
                );

            // Coordinate change:
            //
            // current chart -> next chart.
            float4x4 step =
                (modelKind == MODEL_H3)
                    ? makeReflectionChartChangeH3(
                        hit.position,
                        reflected,
                        rayDirection
                    )
                    : makeReflectionChartChange(
                        hit.position,
                        reflected,
                        rayDirection,
                        kappa
                    );

            // Original -> current was transform.
            //
            // Current -> next is step.
            //
            // Therefore:
            //
            // Original -> next = step * transform.
            transform =
                step * transform;

            continue;
        }

        // Unknown object kind.
        radiance = float3(1, 0, 1);
        break;
    }

    output.write(
        float4(
            clamp(
                radiance,
                float3(0.0f),
                float3(1.0f)
            ),
            1.0f
        ),
        pixel
    );
}
