# GeometryCore contract, version 16

Version 16 adds clipped linear and homogeneous-quadric portal faces plus a
model-aware capped equidistant-tube authoring operation. Portal records grow to
112 bytes; objects and portals share the quadric and primitive-clip tables.
Version 15 added homogeneous quadric object clips while preserving the 32-byte
clip record. Version 14 removed the
transitional legacy-material boundary. BSDF selection
is exclusively material-driven; objects no longer carry opaque/mirror response
state, and the packet no longer carries compatibility or Blinn–Phong fields.
Version 13 added the physical-material packet and shared shader BSDF interface.

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

Charts are radius-free coordinate states. Camera view distance and object or
emitter radii are independent intrinsic quantities. S³ requires their positive
radii and view distances to be less than π. H³ requires derived `sinh/cosh`
values to remain finite; R³ requires positive finite values. Signed plane and
portal-trigger distances are validated independently from object radii and
camera view distance.

## Geodesics and rays

An oriented geodesic is represented by a canonical ambient point `P` and a
unit tangent `V` at that point. For S³ and H³, `metricDot(P,V) = 0`; for R³,
`P.w = 1` and `V.w = 0`. Intrinsic distance is the ray parameter:

| model | point after distance `d` | tangent after distance `d` |
|---|---|---|
| S³ | `cos(d) P + sin(d) V` | `-sin(d) P + cos(d) V` |
| H³ | `cosh(d) P + sinh(d) V` | `sinh(d) P + cosh(d) V` |
| R³ | `P + d V` | `V` |

Camera, continuation, visibility, and portal rays all use this point–tangent
representation. Linear and quadric intersections are solved analytically from
the current `P` and `V`; tracing does not require the ray to start at a chart
origin. Portal transitions apply the directed isometry to both fields and then
restore their model invariants.

`build()` may transform a flattened scene so its packet camera lies at the
model origin. This is only a coordinate normalization and is not a ray-model
precondition. `buildAtlas()` retains the authored camera point.

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
seed()
addChart(fromChart, columnMajorIsometry, safe)
addBall(chart, vec4 center, float intrinsicRadius, material)
addBallSurface(chart, center, radius, material)
addLinearSurface(chart, vec4 normal, offset, material)
addPlane(chart, outwardDirection, signedDistance, material)
addQuadric(chart, columnMajorSymmetricMatrix, material)
addCliffordTorus(chart, material)
addObjectClip(object, normal, offset)
addObjectClipPlane(object, outwardDirection, signedDistance)
addObjectClipQuadric(object, columnMajorSymmetricMatrix, keepPositive)
addMaterial(baseColor, roughness, metallic, IOR, transmission, emission)
addLight(chart, vec4 position, color, intensity)
addSphericalAreaLight(chart, vec4 center, intrinsicRadius,
                      color, emittedRadiance)
cameraChartAt(chart, vec4 position, float viewDistance)
addPortalPair(chartA, outwardA, distanceA,
              chartB, outwardB, distanceB, pairingAB)
addGeodesicBallPortal(exteriorChart, interiorChart, interiorCenter,
                      radius, exteriorToInterior, triggerCollar)
addCappedTubePortal(exteriorChart, interiorChart, axis, radius,
                    lowerAxialDistance, upperAxialDistance,
                    exteriorToInterior, triggerCollar)
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
`addBall` remains a convenience operation for `addBallSurface`.

A quadric is the zero set `PᵀQP = 0` of a nonzero symmetric homogeneous 4×4
matrix. The coefficient scale is normalized during authoring. In R³,
`P=(x,y,z,1)`, so this includes affine quadratic and linear terms. Surface
scattering is independent of equation kind: linear and quadratic surfaces both
obtain their BSDF exclusively from their material.

Each object may carry up to 16 clips. Linear clips retain
`metricDot(n,P) <= h`. A quadric clip retains `PᵀQP <= 0` when
`keepPositive` is false and `PᵀQP >= 0` when it is true. Quadric matrices are
normalized and transformed with the containing chart during flattening. Clip
surfaces are invisible and do not create caps, so intersecting a plane with a
quadric produces only the retained portion of the plane.

`addPortalPair` gives trigger planes a `0.01`-unit outward intrinsic collar.
`addPortalPairWithCollar` accepts an explicit nonnegative collar for atlas
experiments. A pairing must map its mathematical face to the opposite face and
its outward tangent to the neighbor's inward tangent. Camera movement and GPU
tracing use the exponential map, direct isometry tangent transport, and
compound portal reduction. Both apply the directed portal's `toNeighbor`
transition directly after crossing its trigger; they do not consult the reverse
portal. `reversePortal` is packet bookkeeping for bounded light-lift traversal:
it suppresses the immediate parent edge and supplies the already-authored
neighbor-to-current inverse map. Portals are the only CPU camera-transition
triggers. Ordinary overlap edges develop chart coordinates during flattening;
crossing a radial chart horizon does not select an overlap edge or clamp the
camera.

A portal face has either a linear or homogeneous-quadric equation and may
carry up to four linear or quadric clips. Clips are tested at the candidate
portal intersection and are invisible. This makes a portal a finite surface
patch rather than the entire supporting plane or quadric. GPU rays and CPU
camera motion both select the earliest outward, clip-valid crossing along the
traveled geodesic segment.

`addCappedTubePortal` creates a closed portal volume around the geodesic through
the interior-chart origin in the supplied axis direction. It adds a quadric
equidistant-cylinder pair clipped between the axial bounds and two geodesic cap
pairs clipped to the cylinder interior and their respective axial collar. The
exterior records form a closed tube contracted by the requested collar, while
the interior records form a closed tube expanded by it. Each set of component
clips meets at its own circular seam, preventing both an unpaired cap annulus
and compound reduction against a distant cap.
All three exterior records transition to `interiorChart`; their reverse records
transition back to `exteriorChart`. Equivalent parallel portal edges are
deduplicated during bounded light-lift traversal so the three faces do not
multiply the same lifted lights.

`addGeodesicBallPortal` creates a closed one-surface portal volume. The
exterior entry sphere is contracted by the requested intrinsic collar and
oriented toward its center; the interior exit sphere is expanded by the collar
and oriented away from its center. Spherical and hyperbolic space use exact
ambient linear geodesic-sphere equations. Euclidean space uses a homogeneous
quadric. The center is authored in interior-chart coordinates and transformed
into the exterior chart with `exteriorToInterior`'s inverse.

## Packet

`GEO_CONTRACT_VERSION` is 16 and `GEO_PACKET_MAGIC` is `0x41545243`. Both
`build()` and `buildAtlas()` emit:

```text
ScenePacketHeader (192)
GPUChart[chartCount] (32 each)
GPUPortal[portalCount] (112 each)
Object[objectCount] (48 each)
Quadric[quadricCount] (64 each; object, portal, and clip matrices share this table)
PrimitiveClip[clipCount] (32 each)
Material[materialCount] (48 each)
PointLight[lightCount] (48 each)
```

`build()` emits one flattened chart and zero portals. `buildAtlas()` preserves
authored charts and quotient portals. Either mode accepts any canonical camera
position in its active coordinate state.

A material stores `baseColor`, three-component `emission`, `roughness`,
`metallic`, `IOR`, `transmission`, and one reserved float. `addMaterial`
validates unit-range base color, roughness, metallic, and transmission; finite
`IOR >= 1`; and nonnegative finite emission. Material records are 48 bytes.
There is no legacy authoring entry point or compatibility mode.

The former bounce-attenuation slot in `RenderControls` is reserved in version
14. `setControls` no longer accepts an empirical bounce multiplier.

`PointLight` is the common light record.
It stores position, color, intensity, intrinsic radius, and light kind. A point
light has kind `GEO_LIGHT_POINT`, radius zero, and uses the empirical
falloff control. Both render modes apply the Lambertian `albedo/π` response to
point-light irradiance. Catalog preview scenes retain π-scaled point-light
intensities to preserve their original linear illumination after this
normalization.
A spherical emitter has kind `GEO_LIGHT_SPHERE`, positive intrinsic radius,
and interprets `color * intensity` as emitted radiance.

An object descriptor stores its equation kind, material index, inline
linear/sphere coefficients, optional quadric index, clip range, and two
reserved words. Object records remain 48 bytes. Builds do not implicitly clip
objects to a chart domain. Surface extent and overlap ownership are defined by
the object's authored linear and quadric clips. In atlas traversal, an explicit
portal changes the coordinate state before any farther object can be hit, and
camera view distance terminates traversal.

A portal descriptor stores its directed transition, equation kind, inline
linear coefficients or quadric index, clip range, destination chart, and
reverse-record index. Linear portals without clips retain their version-15
behavior.

`Camera.reservedFloat0` and `GPUChart.reserved0/reserved1` are zeroed
compatibility fields that preserve the version-15 packet sizes. Shaders do not
read them. Primitive clips use kind 0 for linear inequalities and kind 2 for
quadric inequalities; the former implicit ball-clip kind 1 is retired.

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
Its direct-light estimator enumerates the packet's bounded light-lift tree as a
candidate set and uses online reservoir sampling to choose one candidate
uniformly. For `N` candidates the selection probability is `q = 1/N`; the
selected candidate is the only one that launches an explicit-light visibility
ray, and its contribution is divided by `q`. This changes variance and GPU
work, but not expected radiance.
Finite spherical emitters are sampled uniformly in surface area. For intrinsic
radius `a`, their area is `4π Sκ(a)²`; a sample at distance `r` contributes the
Jacobian `abs(cos(thetaLight)) / Sκ(r)²`. This produces curvature-aware soft
shadows without applying the empirical point-light falloff. The direct estimator
also tests the cosine-weighted diffuse continuation direction against finite
emitters. Emitter-area and BSDF samples use their corresponding solid-angle
PDFs and the power heuristic for multiple importance sampling. Both MIS sides
use the complete light-technique density `q * p(direction | candidate)`. The
BSDF branch still tests every finite-emitter candidate to identify the nearest
emitter reached by its already-sampled direction; it does not launch an
explicit visibility ray for every candidate.

Photo Mode receives its maximum and guaranteed continuation counts in the
per-frame uniform rather than reading the scene-authored real-time bounce
count. The UI defaults to 64 maximum continuations and three guaranteed
continuations and freezes both values for an accumulation. After the guaranteed
count, Russian roulette uses
`clamp(max(throughput.r, throughput.g, throughput.b), 0.05, 0.95)`. A surviving
path divides its throughput by that probability before tracing the next
segment, so its conditional expected throughput is unchanged. Exact-zero
throughput terminates directly; nonzero throughput is left to roulette.
Roulette is not applied to portal hops or visibility rays. The selected maximum
is a hard truncation guard: its terminal surface still contributes emission and
direct light, but cannot launch another BSDF continuation.

Photo Mode trace statistics include total and maximum scattering depth plus
roulette- and depth-bound-termination counts. The renderer normalizes these by
camera sample count for the performance overlay. A depth-bound termination is
diagnostic evidence of possible truncation rather than a tracing error.

Both kernels use the shared `evaluateBSDF` and `sampleBSDF` interface. Neither
interface accepts object response state. An evaluation returns the BSDF value
and directional PDF. A sample returns the
continued direction, throughput weight, PDF, event type, and delta flag. The
version-14 implementation provides cosine-weighted Lambertian evaluation and
sampling, ideal and rough conductor reflection, and ideal and rough dielectric
reflection/refraction. A physical material with zero transmission, metallic
zero, and roughness zero is Lambertian. Positive roughness selects an opaque
dielectric layer: exact-IOR GGX reflection over a Fresnel-reduced Lambertian
substrate. Its sampler mixes visible-normal reflection and cosine-weighted
diffuse directions and reports the combined PDF. Metallic one with zero
transmission selects a conductor: roughness zero is an ideal reflection
colored by `baseColor`, while positive
roughness uses an isotropic GGX microfacet BRDF. GGX maps perceptual roughness
to `alpha = max(roughness², 0.001)`, uses the Trowbridge–Reitz normal
distribution, separable Smith masking-shadowing, and a `baseColor` Schlick
Fresnel approximation. Photo Mode samples its visible-normal distribution and
reports the matching solid-angle PDF for MIS. Real-time mode directly evaluates
the same lobe under the scene lights and uses the material color as an indirect
specular ambient approximation.

Opaque dielectric layers are two-sided coatings. After orienting the shading
normal toward the incident side, both faces evaluate Fresnel as air-to-material
and therefore have identical reflection properties. Only transmissive
dielectrics distinguish entering from exiting and swap their incident and
transmitted IORs.

A material with metallic zero and transmission one is dielectric glass.
Roughness zero selects the ideal interface; positive roughness selects an
isotropic GGX microfacet dielectric. Both use exact unpolarized Fresnel, Snell
refraction, total internal reflection, and the squared relative-IOR radiance
Jacobian. Rough glass samples the same visible-normal distribution as the
conductor and applies the refractive half-vector Jacobian to its transmission
PDF. Its `baseColor` tints transmission but not reflection. Real-time rough
glass evaluates its GGX reflection under the scene lights and uses a stable
macro-normal dominant-lobe continuation for the transmitted view.

Dielectric surfaces currently assume an air exterior, a homogeneous material
interior, and an outward geometric normal. Closed balls satisfy this contract;
nested or overlapping dielectric media do not yet carry an IOR stack. Photo
Mode stochastically selects the Fresnel lobes. The single-path real-time tracer
chooses the dominant lobe and applies that lobe's Fresnel coefficient. Partial
transmission and intermediate metallic values report an unsupported material
diagnostic until their mixed lobes exist. Specular continuations are energy
conserving and do not apply empirical bounce attenuation. The interface and
tangent-frame construction are common to R³, S³, and H³. Material emission is
two-sided and is added as
outgoing radiance whenever either tracer reaches the surface, after applying
the current path throughput. Emission does not implicitly create a light
record or a visibility ray; explicit point and spherical lights remain the
efficient direct-light sampling mechanism. The remaining rough/mixed cases are
reserved for later stages.

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
