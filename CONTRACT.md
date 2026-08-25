# GeometryCore contract, version 11

Version 11 adds oriented ambient linear sections, clipped surface patches, and
homogeneous quadratic surfaces to the native-model contract.

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

`GEO_CONTRACT_VERSION` is 11 and `GEO_PACKET_MAGIC` is `0x41545243`. Both
`build()` and `buildAtlas()` emit:

```text
ScenePacketHeader (192)
GPUChart[chartCount] (32 each)
GPUPortal[portalCount] (96 each)
Object[objectCount] (48 each)
Quadric[quadricCount] (64 each)
PrimitiveClip[clipCount] (32 each)
Material[materialCount] (32 each)
PointLight[lightCount] (32 each)
```

`build()` emits one flattened chart and zero portals. `buildAtlas()` preserves
authored charts and quotient portals.

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
from the specialization.

Radial calculations use
`Sκ(u)=2u/(1+κu²)` and `Cκ(u)=(1-κu²)/(1+κu²)`. Distance recovery is
`2 atan(u)`, `2 atanh(u)`, or `2u`. Linear sections retain the existing
half-angle root calculation. R³ quadrics use a line quadratic; S³ quadrics use
a double-angle sinusoid; H³ quadrics use a quadratic in `exp(2d)`. Candidate
roots are tested in distance order against every clip. Light attenuation uses
the natural area radius `sin(d)`, `sinh(d)`, or `d`.
