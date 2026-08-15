#include <metal_stdlib>
using namespace metal;

// ============================================================
// Constants
// ============================================================

constant int PACKET_MAGIC            = 0x4E545243;
constant int CONTRACT_VERSION        = 2;
constant int PACKET_HEADER_SIZE      = 128;
constant int OBJECT_SIZE             = 32;

constant int MODEL_H3                = 0;
constant int MODEL_S3                = 1;

constant int OBJECT_OPAQUE_SPHERE    = 0;
constant int OBJECT_MIRROR_SPHERE    = 1;
constant int OBJECT_MIRROR_PLANE     = 2;

constant int MAX_BOUNCES             = 64;

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
    float pad0;
    float pad1;
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
    int pad0;
    int pad1;
};

struct PacketHeader {
    PacketMeta meta;
    Camera camera;
    RenderControls controls;
    Counts counts;
};

struct SceneObject {
    // Must be packed: packet stores exactly 12 bytes here.
    packed_float3 center;

    float radiusOrOffset;

    int kind;
    int colorIdx;

    int pad0;
    int pad1;
};


// ============================================================
// Internal representations
// ============================================================

// A generalized Euclidean sphere:
//
//      a |x|² + b·x + c = 0
//
// This includes planes when a = 0.
//
// Under a Möbius transformation, spheres and planes remain in
// this family.
struct QuadraticSurface {
    float a;
    float3 b;
    float c;
};


// Ambient representation:
//
//      <n, X>_κ = h
//
// where
//
//      <X,Y>_κ = X.xyz·Y.xyz + κ X.w Y.w
//
// κ = +1 for S³
// κ = -1 for H³.
//
// An ambient isometry simply transforms n by:
//
//      n' = T n
//
// while h remains unchanged.
struct AmbientSurface {
    float4 n;
    float h;
};


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

float3 objectCenter(SceneObject obj)
{
    return float3(
        obj.center.x,
        obj.center.y,
        obj.center.z
    );
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
// Chart <-> ambient model
// ============================================================
//
// Unified convention:
//
//              ( 2x , 1 - κ|x|² )
//      X(x) = ---------------------
//                   1 + κ|x|²
//
// κ = +1:
//
//      S³ ⊂ R⁴
//
// κ = -1:
//
//      H³ ⊂ R^{3,1}
//
// For H³, |x| < 1.
//
// At x = 0:
//
//      X = (0,0,0,1).
//
// ============================================================

float4 liftPoint(float3 x, float kappa)
{
    float r2 = dot(x, x);
    float D = 1.0f + kappa * r2;

    return float4(
        2.0f * x / D,
        (1.0f - kappa * r2) / D
    );
}


// Differential of liftPoint.
//
// v is a Euclidean chart tangent vector at x.
float4 liftTangent(
    float3 x,
    float3 v,
    float kappa
) {
    float r2 = dot(x, x);
    float xv = dot(x, v);

    float D = 1.0f + kappa * r2;

    float3 spatial =
        (2.0f / D) *
        (
            v
            - (2.0f * kappa * xv / D) * x
        );

    float w =
        -4.0f * kappa * xv / (D * D);

    return float4(spatial, w);
}


// ============================================================
// Packet object -> generalized sphere
// ============================================================

QuadraticSurface objectToQuadratic(SceneObject obj)
{
    QuadraticSurface q;

    float3 x = objectCenter(obj);

    if (
        obj.kind == OBJECT_OPAQUE_SPHERE ||
        obj.kind == OBJECT_MIRROR_SPHERE
    ) {
        // |p - center|² = radius²
        //
        // =>
        //
        // |p|² - 2 center·p
        // + |center|² - radius² = 0

        float r = obj.radiusOrOffset;

        q.a = 1.0f;
        q.b = -2.0f * x;
        q.c = dot(x, x) - r * r;
    }
    else {
        // normal·p = offset

        q.a = 0.0f;
        q.b = x;
        q.c = -obj.radiusOrOffset;
    }

    return q;
}


// ============================================================
// Generalized sphere <-> ambient hypersurface
// ============================================================
//
// For
//
//      q(x) = a|x|² + b·x + c,
//
// define
//
//      n.xyz = b
//      n.w   = -a + κc
//      h     = -(κa + c)
//
// Then:
//
//      <n, X(x)>_κ - h
//
//             2 q(x)
//      = ----------------
//          1 + κ|x|².
//
// Therefore q=0 exactly when <n,X>=h.
// ============================================================

AmbientSurface quadraticToAmbient(
    QuadraticSurface q,
    float kappa
) {
    AmbientSurface s;

    s.n = float4(
        q.b,
        -q.a + kappa * q.c
    );

    s.h =
        -(kappa * q.a + q.c);

    return s;
}


QuadraticSurface ambientToQuadratic(
    AmbientSurface s,
    float kappa
) {
    QuadraticSurface q;

    q.a =
        -0.5f * (s.n.w + kappa * s.h);

    q.b = s.n.xyz;

    q.c =
        0.5f * (kappa * s.n.w - s.h);

    return q;
}


// Transform an original packet object into the current ray chart.
QuadraticSurface transformedObject(
    SceneObject obj,
    float4x4 transform,
    float kappa
) {
    QuadraticSurface q =
        objectToQuadratic(obj);

    AmbientSurface s =
        quadraticToAmbient(q, kappa);

    // If X_current = T X_original, then
    //
    //     n_current = T n_original
    //
    // because T preserves the ambient metric.
    s.n = transform * s.n;

    return ambientToQuadratic(s, kappa);
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


// Convert a chart root into an ordering parameter along the
// FORWARD intrinsic geodesic.
//
// H³:
//
//      t = tanh(s/2), 0 < t < 1.
//
// So ordering by t is enough.
//
// S³:
//
//      t = tan(s/2).
//
// Forward motion from s=0:
//
//      0 < s < π      => t > 0
//      π < s < 2π     => t < 0.
//
// Therefore negative t values are valid: they represent the
// continuation after passing through the stereographic point
// at infinity.
float forwardOrder(
    float t,
    int modelKind
) {
    if (fabs(t) <= SELF_HIT_EPS)
        return INF;

    if (modelKind == MODEL_H3) {
        if (
            t <= SELF_HIT_EPS ||
            t >= 1.0f - EPS
        ) {
            return INF;
        }

        // Monotone with hyperbolic distance.
        return t;
    }

    // S³
    float s = 2.0f * atan(t);

    if (s <= SELF_HIT_EPS)
        s += TWO_PI;

    return s;
}


// ============================================================
// Find nearest object
// ============================================================

Hit findNearestHit(
    float3 rayDirection,
    float4x4 transform,
    float kappa,
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

        QuadraticSurface q =
            transformedObject(
                obj,
                transform,
                kappa
            );

        float linear =
            dot(q.b, rayDirection);

        Roots roots =
            solveQuadratic(
                q.a,
                linear,
                q.c
            );

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
                    modelKind
                );

            if (order >= nearest.order)
                continue;

            float3 position =
                t * rayDirection;

            // Euclidean normal to
            //
            //      a|x|² + b·x + c = 0.
            //
            // Because the stereographic/Poincaré metric is
            // conformal, this normal can be used for reflection.
            float3 gradient =
                2.0f * q.a * position
                + q.b;

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
            kappa
        );

    float4 V =
        liftTangent(
            hitPosition,
            normalize(reflectedDirection),
            kappa
        );

    // First move the hit point to the origin.
    float4x4 B =
        movePointToOrigin(
            P,
            kappa
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

    if (
        objectCount < 0 ||
        objectCount > 4096 ||
        materialCount < 0 ||
        materialCount > 256
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

    device const float4* materials =
        reinterpret_cast<
            device const float4*
        >(
            packet + materialOffset
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

    float kappa =
        modelKappa(modelKind);

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
                kappa,
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

        float4 material =
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

            float brightness =
                header->controls.ambient
                +
                (
                    1.0f
                    - header->controls.ambient
                )
                * falloff;

            radiance +=
                throughput
                * material.rgb
                * brightness;

            break;
        }

        // ----------------------------------------------------
        // Mirror
        // ----------------------------------------------------

        if (
            obj.kind ==
                OBJECT_MIRROR_SPHERE ||
            obj.kind ==
                OBJECT_MIRROR_PLANE
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
                material.rgb
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
                makeReflectionChartChange(
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
