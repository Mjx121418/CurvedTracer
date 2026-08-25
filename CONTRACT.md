# GeometryCore contract, version 12

Version 12 adds finite geodesic spherical emitters and explicit light-kind and
intrinsic-radius fields. Version 11 introduced oriented ambient linear
sections, clipped surface patches, and homogeneous quadratic surfaces.

## Models and points

`GEO_MODEL_H3 = 0`, `GEO_MODEL_S3 = 1`, and `GEO_MODEL_R3 = 2`. Curvatures are
respectively `-1`, `+1`, and `0`.

Canonical points are `vec4`:

| model | invariant | origin |
|---|---|---|
| S³ | `dot(P,P) = 1` | `(0,0,0,1)` |
| H³ | `P.xyz² - P.w² = -1`, `P.w > 0` | `(0,0,0,1)` |
| R³ | `P.w = 1` | `(0,0,0,1)` |

`Atlas::pointFromOriginTangent(v)` evaluates the exponential map using
`sin/cos`, `sinh/cosh`, or Euclidean addition. Input points are canonicalized
only within a small tolerance; malformed points are rejected.

Every chart radius and public distance is intrinsic. S³ requires `0 < R < π`.
H³ and R³ require positive finite values whose float32 derived parameters are
finite. A ball must satisfy `distance(origin,center) + radius <= chart.radius`.

## Isometries

`Isometry` stores a column-major homogeneous `mat4` and a `ModelKind`:

- S³ accepts orientation-preserving SO(4);
- H³ accepts orientation- and time-orientation-preserving SO⁺(3,1);
- R³ accepts orientation-preserving homogeneous SE(3).

It provides direct point and tangent application, composition, inverse, and
model-specific validation. Reflections, scales, bad affine rows, and
past-directed Lorentz transformations are rejected. Ordinary overlap edges
are still checked for cocycle consistency. Portal edges are separate and may
carry quotient holonomy.

## Typed authoring

The native public operations are:

```cpp
addBall(chart, vec4 center, float intrinsicRadius, material)
addBallSurface(chart, center, radius, material, response)
addLinearSurface(chart, vec4 normal, offset, material, response)
addPlane(chart, outwardDirection, signedDistance, material, response)
addMirrorPlane(chart, vec3 outwardDirection, float intrinsicDistance, material)
addQuadric(chart, columnMajorSymmetricMatrix, material, response)
addCliffordTorus(chart, material, response)
addObjectClip(object, normal, offset)
addObjectClipPlane(object, outwardDirection, signedDistance)
addLight(chart, vec4 position, color, intensity)
addSphericalAreaLight(chart, vec4 center, intrinsicRadius,
                      color, emittedRadiance)
cameraChartAt(chart, vec4 position, float intrinsicTraceRadius)
addPortalPair(chartA, outwardA, distanceA,
              chartB, outwardB, distanceB, pairingAB)
```

Directions are normalized internally. A geodesic plane with outward unit `u`
at distance `d` is encoded as:

| model | normal `n` | offset `h` | interior |
|---|---|---|---|
| S³ | `(cos(d)u,-sin(d))` | `0` | `<n,P> <= h` |
| H³ | `(cosh(d)u,sinh(d))` | `0` | `<n,P>_L <= h` |
| R³ | `(u,0)` | `d` | `dot(n,P) <= h` |

Linear surfaces use `metricDot(n,P) - h = 0`. In S³ and H³ this one equation
family includes geodesic spheres, totally geodesic planes, equidistant
hypersurfaces, and (in H³) null-normal horospheres. `addBallSurface` emits an
outward-oriented linear section in S³/H³ and a Euclidean sphere in R³.
`addBall` and `addMirrorPlane` remain opaque-ball and mirror-plane convenience
operations.

A quadric is the zero set `PᵀQP = 0` of a nonzero symmetric homogeneous 4×4
matrix. The coefficient scale is normalized during authoring. In R³,
`P=(x,y,z,1)`, so this includes affine quadratic and linear terms. Surface
response is independent of equation kind: both linear and quadratic surfaces
may be opaque or reflective.

Each object may carry up to 16 linear clips. A clip retains
`metricDot(n,P) <= h`; clip surfaces are invisible and do not create caps.

`addPortalPair` gives trigger planes a `0.01`-unit outward intrinsic collar.
`addPortalPairWithCollar` accepts an explicit nonnegative collar for atlas
experiments. A pairing must map its mathematical face to the opposite face and
its outward tangent to the neighbor's inward tangent. Camera movement and GPU
tracing use the exponential map, direct isometry tangent transport, and
compound portal reduction.

## Packet

`GEO_CONTRACT_VERSION` is 12 and `GEO_PACKET_MAGIC` is `0x41545243`. Both
`build()` and `buildAtlas()` emit:

```text
ScenePacketHeader (192)
GPUChart[chartCount] (32 each)
GPUPortal[portalCount] (96 each)
Object[objectCount] (48 each)
Quadric[quadricCount] (64 each)
PrimitiveClip[clipCount] (32 each)
Material[materialCount] (32 each)
PointLight[lightCount] (48 each)
```

`build()` emits one flattened chart and zero portals. `buildAtlas()` preserves
authored charts and quotient portals.

Despite its source-compatible name, `PointLight` is the common light record.
It stores position, color, intensity, intrinsic radius, and light kind. A point
light has kind `GEO_LIGHT_POINT`, radius zero, and retains the legacy empirical
falloff control. Both render modes apply the Lambertian `albedo/π` response to
point-light irradiance. Legacy application scenes multiply their authored
point-light intensities by π to preserve their original linear illumination.
A spherical emitter has kind `GEO_LIGHT_SPHERE`, positive intrinsic radius,
and interprets `color * intensity` as emitted radiance. The emitter must fit
inside its authored chart.

An object descriptor stores its equation kind, response, material, inline
linear/sphere coefficients, optional quadric index, and clip range. The three
former padding counts now contain `quadricCount`, `clipCount`, and one reserved
word. Flattened unbounded surfaces receive an internal source-chart ball clip;
authored-atlas tracing obtains the same bound from the active chart horizon.

Each chart stores its intrinsic radius and tracing parameter:

- S³: `tan(R/2)`;
- H³: `tanh(R/2)`;
- R³: `R/2`.

## Shader specialization

The `raytrace` and `photoTrace` kernels have function constants `SPACE_FORM`
(index 0) and `ENABLE_PORTALS` (index 1). The renderer caches all six pipeline
states for each kernel and rejects a packet whose `controls.modelKind` differs
from the specialization. Photo Mode traces light visibility rays through the
same specialized object and portal event machinery. Its trace statistics
include primary, mirror, diffuse, and visibility-ray portal work. The R³ Flat
`photoTrace`
specialization and both curved-space Flat specializations use a cosine-weighted
Lambertian path integrator with a black environment and physical perfect-mirror
continuation. S³ and H³ construct the sampling frame with their induced tangent
metrics and re-canonicalize every continued ray. Atlas Photo Mode continues
diffuse and mirror paths through the same portal transport as primary rays.
Its direct-light estimator deterministically enumerates the packet's bounded
light-lift tree and traces a portal-aware visibility ray toward every lift.
Finite spherical emitters are sampled uniformly in surface area. For intrinsic
radius `a`, their area is `4π Sκ(a)²`; a sample at distance `r` contributes the
Jacobian `abs(cos(thetaLight)) / Sκ(r)²`. This produces curvature-aware soft
shadows without applying the legacy point-light falloff. The direct estimator
also tests the cosine-weighted diffuse continuation direction against finite
emitters. Emitter-area and BSDF samples use their corresponding solid-angle
PDFs and the power heuristic for multiple importance sampling.

Real-time and Photo Mode use the same nonnegative exposure multiplier and
Reinhard display transform, `display = exposure * radiance /
(1 + exposure * radiance)`. Exposure changes affect display only; they do not
alter or reset Photo Mode's accumulated HDR radiance.

Radial calculations use
`Sκ(u)=2u/(1+κu²)` and `Cκ(u)=(1-κu²)/(1+κu²)`. Distance recovery is
`2 atan(u)`, `2 atanh(u)`, or `2u`. Linear sections retain the existing
half-angle root calculation. R³ quadrics use a line quadratic; S³ quadrics use
a double-angle sinusoid; H³ quadrics use a quadratic in `exp(2d)`. Candidate
roots are tested in distance order against every clip. Light propagation uses
the natural area radius `sin(d)`, `sinh(d)`, or `d`.
