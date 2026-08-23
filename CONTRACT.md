# GeometryCore contract, version 10

Version 10 is a clean native-model contract. Compact spherical-disk authoring
and the former v7/v9 packet split are not part of this contract.

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
addMirrorPlane(chart, vec3 outwardDirection, float intrinsicDistance, material)
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

Portal trigger planes include a `0.01`-unit outward intrinsic collar. A pairing
must map its mathematical face to the opposite face and its outward tangent to
the neighbor's inward tangent. Camera movement and GPU tracing use the
exponential map, direct isometry tangent transport, and compound portal
reduction.

## Packet

`GEO_CONTRACT_VERSION` is 10 and `GEO_PACKET_MAGIC` is `0x41545243`. Both
`build()` and `buildAtlas()` emit:

```text
ScenePacketHeader (192)
GPUChart[chartCount] (32 each)
GPUPortal[portalCount] (96 each)
Object[objectCount] (32 each)
Material[materialCount] (32 each)
PointLight[lightCount] (32 each)
```

`build()` emits one flattened chart and zero portals. `buildAtlas()` preserves
authored charts and quotient portals.

The 32-byte object is `vec4 geometry`, `float parameter`, kind, material, and
padding. For balls, `geometry` is the model center and `parameter` is
`cos(radius)` in S³, `-cosh(radius)` in H³, or the radius in R³. For mirrors,
`geometry` is the ambient plane normal and `parameter` is its offset.

Each chart stores its intrinsic radius and tracing parameter:

- S³: `tan(R/2)`;
- H³: `tanh(R/2)`;
- R³: `R/2`.

## Shader specialization

The single `raytrace` kernel has function constants `SPACE_FORM` (index 0) and
`ENABLE_PORTALS` (index 1). The renderer caches all six pipeline states and
rejects a packet whose `controls.modelKind` differs from the specialization.

Radial calculations use
`Sκ(u)=2u/(1+κu²)` and `Cκ(u)=(1-κu²)/(1+κu²)`. Distance recovery is
`2 atan(u)`, `2 atanh(u)`, or `2u`. Curved balls and planes use ambient
quadratics; R³ balls use the Euclidean sphere quadratic and R³ planes use a
linear root. Light attenuation uses the natural area radius `sin(d)`,
`sinh(d)`, or `d`.
