# CurvedTracer Photo Mode / Path Tracing Roadmap

This roadmap describes the staged addition of a progressive Photo Mode to the
current CurvedTracer renderer. It reflects the workspace architecture in which
Metal 4 performs tracing, a conventional Metal queue runs MetalFX, and a final
presentation pass writes to the `MTKView` drawable.

The current renderer already provides much of the geometric machinery needed
by a path tracer:

- intrinsic geodesic rays in S³, H³, and R³;
- primitive intersections and nearest-event selection;
- GPU chart and quotient-portal traversal;
- iterative mirror continuation with radiance and throughput state; and
- intrinsic point-light attenuation.

Photo Mode should evolve this implementation without duplicating its geometry
engine. Geometry and portal traversal must remain independent of the
integrator that launches a ray.

---

## Shader architecture

Keep reusable shader code separate from the two entry points:

```text
Shaders/
    TraceShared.metal               include hub
    TraceTypes.metal                packet records and shared diagnostics
    TraceMath.metal                 constant-curvature ray and frame helpers
    TraceBSDF.metal                 material evaluation and sampling
    TraceIntersection.metal         primitive, portal, and visibility queries
    TraceLighting.metal              direct lighting and fog
    TracePacket.metal                packet validation and camera rays
    TracePath.metal                 deterministic path-tracing helpers

    tracer.metal
        deterministic real-time integrator and raytrace kernel
        stochastic photo integrator and photoTrace kernel
        accumulation and tone mapping

    presentation.metal
```

During the progressive-foundation milestone, both kernels may call the same
deterministic sample evaluator. Once diffuse path tracing is added, only the
geometry, portal, packet, and diagnostic helpers remain shared; integrator
logic stays in the entry-point source or an integrator-specific header.

The reusable ray state is:

```cpp
struct RayState {
    float4 point;
    float4 tangent;
    int chartId;
};
```

Secondary-ray helpers must return both their surface result and the transported
ray/chart state. They must also report malformed geometry, portal-hop limits,
and tracing-horizon termination rather than collapsing all failures into a
miss.

---

## Milestone A — Shared tracing extraction

Move reusable data structures and functions out of the current monolithic
shader. Keep include guards and internal linkage so the tracing compilation
unit can include the shared file safely.

The existing real-time image must remain unchanged after extraction:

- the same six space/traversal specializations;
- the same pixel-center camera rays;
- the same fog, direct lighting, mirrors, and diagnostics; and
- the same BGRA8 output.

No GeometryCore packet or contract change is required.

---

## Milestone B — Progressive Photo Mode foundation

This is the first visible Photo Mode release.

### User interaction

Add a `Start Photo Mode` / `Stop Photo Mode` button. Entering the mode:

- releases mouse capture;
- clears pending mouse and keyboard motion;
- freezes the current camera, scene packet, traversal mode, and render
  parameters;
- disables scene and traversal selectors; and
- resets the accumulated sample count.

While Photo Mode is active, no camera input or scene rebuild is allowed.
Exiting returns to real-time rendering at the same camera position and
orientation.

### Frozen snapshot

Do not reuse a ring-buffered scene allocation as the frozen source. Build the
selected Flat CPU or GPU Atlas packet once and copy it into a dedicated,
immutable photo scene buffer after all prior in-flight work has completed.

If snapshot construction fails, log the build error and remain in real-time
mode.

### Accumulation

Use one persistent private `rgba32Float` accumulation texture at the fixed
960×540 tracing resolution. Keep the existing ring of BGRA8 display textures.

One display callback submits one sample per pixel. For sample index `N`:

```text
sum(N + 1) = sum(N) + sample(N)
average    = sum(N + 1) / (N + 1)
```

Sample zero initializes every accumulation texel without reading its previous
contents. This makes entry and re-entry reset deterministic without a separate
clear pass.

Metal 4 does not infer access dependencies. Every photo dispatch must encode a
dispatch-to-dispatch producer barrier so a later pass cannot read the shared
accumulation texture before the preceding write completes.

### Stochastic subpixel sampling

Seed a stateless 32-bit hash from pixel coordinates and sample index. Generate
two independent uniform values and replace the fixed pixel-center ray with:

```text
(pixel.x + xi.x, pixel.y + xi.y), xi in [0, 1)^2
```

The first Photo Mode integrator otherwise retains deterministic real-time
lighting. This milestone therefore provides progressive antialiasing and
validates snapshotting, RNG, accumulation, reset behavior, HDR storage, and
continuous presentation before adding expensive secondary paths.

### Tone mapping and presentation

Do not clamp radiance inside the shared sample evaluator. Photo Mode stores HDR
radiance, computes the current average, and initially applies fixed-exposure
Reinhard mapping:

```text
mapped = exposed / (1 + exposed)
```

Use an initial fixed exposure multiplier of `2.0`, then write the mapped result
into the current BGRA8 display texture before MetalFX.
The current MetalFX scaler is configured for perceptual BGRA8 input, so it must
not receive the raw HDR sum. The final presentation shader remains responsible
only for viewport placement and copying the selected display texture to the
drawable.

Window resizing may reconfigure MetalFX, but it does not reset accumulation
because the tracing resolution remains 960×540. If MetalFX is unavailable or
the drawable is not a compatible upscale target, retain the existing direct
presentation fallback.

### Milestone criterion

- All six space/traversal specializations enter and exit Photo Mode.
- The camera and packet remain fixed while samples accumulate.
- Object boundaries converge smoothly as sample count grows.
- Re-entry starts from one fresh sample.
- Rapid toggles and window resizing cause no resource race or Metal validation
  failure.

---

## Milestone C — Reusable secondary visibility

Status: implemented for hard point-light shadows in Photo Mode. The real-time
integrator remains unshadowed. Photo Mode's portal-hop and portal-test
diagnostics include both camera and visibility-ray traversal work.

Introduce a portal-aware operation equivalent to:

```cpp
SurfaceTrace traceToSurface(RayState ray, float maximumDistance);
bool traceAny(RayState ray, float maximumDistance);
```

Both operations use the same object and portal event machinery as primary and
mirror rays. They must apply the intrinsic self-intersection epsilon and stop
at the requested distance without treating a tracing-horizon miss as a hit.

Validate visibility first in R³ Flat, then S³ Flat and H³ Flat. Consume it in
Photo Mode for hard point-light shadows. Enabling the extra shadow cost in the
real-time integrator is a separate product decision, not a prerequisite.

For GPU Atlas scenes, enumerate the same bounded light lifts used by current
direct lighting. Trace toward each lift through the portal system and accept
its contribution only if the secondary ray reaches the light distance without
hitting a surface.

---

## Milestone D — Euclidean Lambertian path tracing

Status: implemented for R³ Flat. The stochastic integrator uses a fixed path
depth, explicit point-light visibility, cosine-weighted diffuse continuation,
a black environment, and energy-conserving perfect-mirror continuation. The
selectable Path tracing room scene provides the milestone validation setup.
Milestone E subsequently generalizes this integrator to Flat S³ and H³; atlas
specializations remain deterministic pending Milestone F.

Develop the first global-illumination integrator in R³ Flat mode.

At an opaque surface:

1. Estimate direct point-light illumination with a visibility ray.
2. Cosine-sample the hemisphere about the oriented normal.
3. Multiply throughput by the diffuse albedo.
4. Continue from the hit point with the sampled direction.

For a Lambertian BRDF,

```text
f = albedo / pi
pdf = cos(theta) / pi
```

so cosine-weighted sampling reduces the throughput update to multiplication by
the albedo.

Point lights are delta emitters and therefore contribute through explicit
light sampling; a BSDF-sampled path has zero probability of hitting one.

Use a fixed maximum depth initially. Add Russian roulette only after the
reference implementation is stable.

### Mirror correction

Preserve deterministic perfect-mirror continuation, but do not copy the
real-time branch literally. The real-time shader adds the non-reflected base
color to radiance. In a physical integrator that term is absorption, not
emission. Photo Mode should multiply throughput by mirror reflectance and
continue, without adding absorbed energy to radiance.

### Environment and fog

Do not reinterpret the current `ambient` and fog controls as global
illumination or participating media. Begin with a black environment and no
photo-mode fog. A separate environment-radiance model can be added later.

### Milestone criterion

A simple R³ scene demonstrates hard shadows, indirect illumination, color
bleeding, corner darkening, and perfect reflection.

---

## Milestone E — Flat S³ and H³ path tracing

Status: implemented. Flat S³ and H³ use metric Gram–Schmidt to build a local
orthonormal tangent frame for cosine-weighted diffuse continuation. Every
bounce receives a fresh segment horizon and is re-canonicalized before
propagation. Curvature-small Path tracing room variants provide direct visual
comparison with R³.

At a hit point, construct an orthonormal basis in the local tangent space and
cosine-sample about the surface normal. The BSDF remains locally Euclidean;
constant curvature changes propagation of the sampled tangent rather than the
Lambertian formula.

Validate with scenes much smaller than the curvature radius. Their output
should approach the equivalent Euclidean result.

Reset the per-segment horizon for each new bounce while retaining explicit
limits on total bounce depth and portal work. This prevents the camera’s
primary-ray horizon from becoming an unintended total path-length cutoff.

---

## Milestone F — Quotient and GPU Atlas path tracing

Status: implemented. All atlas specializations use the stochastic integrator.
Diffuse and specular segments continue through `traceToSurface`. Direct
lighting traverses the existing bounded light-lift tree to form a candidate
set, then stochastically selects one candidate for its portal-aware visibility
query. Bounce depth, light-hop, light-state, and chart-hop controls remain
explicit safety limits.

Extend diffuse and mirror continuation through existing portal transport.
The initial implementation enumerated the current bounded set of light lifts
and traced a visibility ray toward each lift. Retain that candidate definition
and the existing light-state and portal-hop safety limits as light selection
becomes stochastic.

Validate in this order:

```text
Euclidean 3-torus
Lens space
Seifert–Weber space
```

Stochastic light-lift selection follows the validated deterministic reference
and preserves its mean radiance through the selection PMF.

---

## Milestone G — Russian roulette and convergence controls

Status: implemented. Photo Mode has a renderer-owned maximum depth independent
of scene-authored real-time depth. Pre-photo integer controls default to 64
maximum continuations and three guaranteed continuations and are frozen during
accumulation. Later continuations survive with probability
`clamp(max(throughput), 0.05, 0.95)` and divide surviving throughput by that
probability. Exact-zero throughput terminates directly; tiny nonzero paths are
handled by roulette.

Later convergence work may add:

- per-pixel variance estimates;
- adaptive stopping;
- low-discrepancy sample sequences; and
- improved light-selection probabilities.

These are optimizations rather than correctness prerequisites.

The remaining convergence sequence is:

1. replace variable-dimension hash sampling with a scrambled low-discrepancy
   sequence whose dimensions are assigned to pixels, lights, BSDFs, dielectric
   lobes, and roulette decisions; and
2. add per-pixel variance estimates and adaptive dispatch only after the sample
   sequence is stable.

The fixed depth and bounded light-lift tree remain explicit truncations even
though the roulette decision itself is unbiased. The terminal surface is
shaded before the depth guard prevents another continuation.

---

## Milestone H — Finite area lights and radiometry

Status: geodesic spherical emitter sampling and soft shadows are implemented
with the light record introduced in version 12. Samples are uniform in emitter area and use
the curvature-aware area-to-solid-angle Jacobian below. Direct lighting uses
both emitter-area samples and the diffuse continuation direction, combined by
the power heuristic. Emitter intersections are evaluated as light events for
MIS without making the light records ordinary scene geometry.

Photo Mode selects one uniformly distributed light/lift candidate per surface
instead of launching a visibility ray for every bounded candidate. If the
candidate set has size `N`, its selection probability is `q = 1/N`: explicit
light samples divide their contribution by `q`, and both sides of MIS use the
full directional density `q * p(direction | candidate)`. The candidate is
chosen with online reservoir sampling so no packet-side light distribution is
required. The BSDF-sampled branch still checks all finite emitter lifts to find
the first emitter reached along its direction; those root tests are cheaper
than launching one visibility ray per candidate.

A later weighted distribution may replace uniform selection. Its PMF should be
based on stable, nonnegative quantities such as emitted power and intrinsic
emitter area, must be included in both MIS densities, and must retain a fallback
for zero-total-power packets.

Real-time and Photo Mode share an interactive exposure multiplier and the same
Reinhard display transform. Point-light diffuse response is normalized by
`1/π`; original preview scenes compensate their legacy light authoring values
by π.

Before implementing finite emitters, validate the curved-space Jacobians used
to convert between surface-area and directional probability densities.

For constant curvature, use the area radius:

```text
S_k(r) = sin(r)   in S³
       = r        in R³
       = sinh(r)  in H³
```

The geometric spreading term is `S_k(r)^2`, and an emitter-area PDF converts
schematically as:

```text
d_omega = abs(cos(theta_light)) / S_k(r)^2 * d_area
```

After this audit, add geodesic spherical area lights, soft shadows, and then
multiple importance sampling. Do not add area lights first and repair their
radiometry afterward.

### Deferred emissive-geometry sampling

Emission-on-hit does not make arbitrary geometry an efficient direct-light
source. A later light-sampling extension should build a distribution over
emissive objects, sample each supported primitive with its intrinsic area
measure, convert its area PDF to solid angle, and combine it with BSDF sampling
through the existing MIS interface. Keep this separate from material emission
itself: it adds light-selection state and visibility rays, whereas visible
emission is only a surface-hit term.

The finite-light records were introduced in an earlier packet revision;
future geometry additions such as quadric clips should likewise version the
contract explicitly while preserving existing record sizes where possible.

---

## Milestone I — Physical materials

Status: complete for the supported endpoint materials. Version 13 introduced
base color, emission, roughness, metallic, IOR, and transmission; version 14
removed the compatibility marker, legacy-specular fields, and object response
semantics. The application scene catalog now uses physical materials
exclusively. Metallic one with zero roughness is an ideal conductor, while
metallic zero with zero transmission is Lambertian. The path-tracing-room
mirror balls exercise this dispatch while authored as opaque objects.
Real-time and Photo Mode share the selection, Lambertian
evaluation/PDF/sampling, ideal-conductor delta sampling,
smooth ideal-dielectric sampling, isotropic rough-conductor GGX, and isotropic
rough-dielectric GGX. The GGX lobes use Trowbridge–Reitz normals, separable
Smith masking-shadowing, visible-normal sampling, and matching MIS PDFs.
Conductors use colored Schlick Fresnel. Dielectrics use exact IOR Fresnel and a
refractive half-vector Jacobian. Opaque dielectrics combine GGX reflection with
a Fresnel-reduced Lambertian substrate using a mixture PDF. Rough blue plastic,
gold, and frosted-glass balls in each path-tracing room validate the lobes in
R³, S³, and H³.

Ideal glass uses exact Fresnel lobe probabilities, Snell refraction, total
internal reflection, and relative-IOR radiance scaling in the local tangent
space. A glass ball in each path-tracing room exercises entry and exit. The
current dielectric model assumes air outside a closed outward-oriented object
and does not support nested media. Partial transmission and intermediate
metallicity produce a diagnostic instead of silently rendering as diffuse.
Two-sided physical emission contributes whenever a path reaches a surface;
small orange emitters in all three path-tracing rooms validate direct camera
hits and reflected hits. Arbitrary emissive surfaces are not automatically
registered for next-event sampling, so explicit light records remain the
efficient way to illuminate other objects.

Once diffuse GI, mirrors, point lights, area lights, and MIS are stable, evolve
the material contract toward:

```text
baseColor
roughness
metallic
IOR
transmission
emission
```

Recommended order:

1. ideal dielectric glass (implemented for smooth, fully transmissive closed
   objects);
2. rough conductor GGX (implemented for fully metallic reflection);
3. rough dielectric GGX (implemented for transmissive glass and opaque
   dielectric layering); and
4. emissive materials (implemented as emission-on-hit).

Local BSDF evaluation remains in the Euclidean tangent space for all three
ambient geometries.

### Deferred mixed materials

Intermediate metallic values and partial transmission require explicit
mixtures of diffuse, conductor, dielectric-reflection, and dielectric-
transmission lobes. Add them only with matched evaluation, sampling, and PDFs;
do not interpolate the existing endpoint results after sampling. The legacy
scene catalog migration is complete, so this work can proceed later without
conflating endpoint compatibility with new mixed-lobe behavior.

### Deferred nested dielectric media

Nested and overlapping transmissive objects require each path to carry its
current medium and IOR history across reflection, refraction, and portal
transport. Implement a bounded medium stack only after single-boundary glass
and mixed transmission are stable. The stack must define behavior for malformed
overlaps and stack overflow rather than assuming every back face returns to
air.

### Legacy material migration

Status: complete in contract version 14. Scene-authored diffuse, plastic,
mirror, glass, conductor, and emissive surfaces use the unified material
packet. Geometry no longer carries a response kind, and the authoring API and
shaders no longer expose legacy materials, Blinn–Phong specular state, mirror
response flags, or empirical bounce attenuation. Material records are now 48
bytes and BSDF dispatch is exclusively material-driven.

---

## Milestone J — Profiling and acceleration

Status: in progress. Uniform stochastic light/lift selection is the first
measured-risk optimization: candidate discovery is unchanged, but explicit
visibility work is reduced from one ray per candidate to at most one ray per
surface. macOS GPU measurements and long-run image comparisons are still
required before choosing a geometry acceleration structure.

Do not add acceleration structures before measuring the working path tracer.
The current per-chart linear object scan may eventually need:

- per-chart BVHs;
- primitive grouping;
- portal-aware pruning; or
- a wavefront path architecture.

Profile first. Retain the simpler one-thread-per-pixel path loop until
divergence or intersection cost is demonstrated to be the limiting factor.

### Profiling phase

Average and maximum scattering depth plus roulette- and depth-bound-termination
fractions are now recorded. Add visibility-ray, light-candidate,
object/quadric/clip-test, portal-test, and portal-hop metrics per camera sample.
Retain GPU timestamps around tracing, MetalFX, and presentation.
Use the three path-tracing rooms, Hopf fibration, all three tower observatories,
and a many-state quotient as the standard benchmark set.

### Optimization decision tree

- If visibility rays dominate, improve light/lift selection before changing
  geometry traversal.
- If object tests dominate, add conservative per-chart bounds and then a
  per-chart BVH without changing exact primitive intersection routines.
- If portal tests dominate, group or bound portal faces while preserving
  compound collar reduction and hop ordering.
- If long-path divergence dominates, evaluate queue compaction or a wavefront
  integrator only after the simpler changes are measured.

Every optimization must compare GPU time, tests per sample, diagnostics, and
long-run mean radiance against the reference implementation. A faster image
with systematically changed brightness is not an acceptable result.

### Near-term work order

1. Validate uniform light/lift selection on macOS: compare GPU time and
   converged mean luminance against the previous all-lights estimator in a
   one-light room, a multi-light room, Hopf fibration, and an atlas scene.
2. Complete the remaining profiling counters and capture the standard benchmark
   set at 960×540 with fixed camera snapshots and sample counts. Depth and
   roulette counters are implemented; validate the 64/3 default on Metal.
3. Introduce a dimensioned, scrambled low-discrepancy sampler, then add
   per-pixel variance tracking and adaptive work allocation.
4. Choose BVH, portal pruning, or wavefront scheduling only from the resulting
   measurements. Preserve the current exact intersection and transport paths
   as a reference configuration during that work.

---

## Later work

Leave these features until the core renderer is correct and stable:

- difficult specular and dielectric caustics, after nested-media tracking;
- bidirectional path tracing or photon methods;
- participating media;
- spectral transport;
- motion blur;
- denoising;
- environment maps; and
- physically modeled cameras and image export.

Nearer-term quality extensions, in recommended order, are direct sampling of
supported emissive primitives, importance-sampled environment lighting, mixed
metallic/partial-transmission lobes with matched PDFs, and a bounded medium
stack for nested dielectric objects. Denoising should follow variance tracking
rather than becoming a substitute for correct sampling.

---

## Recommended commit sequence

```text
A. Extract shared tracing code without changing real-time output
B. Add progressive Photo Mode, HDR accumulation, and stochastic pixels
C. Add reusable visibility rays and Photo Mode hard shadows
D. Add Euclidean Lambertian GI and physical mirror handling
E. Extend the integrator to Flat S³ and H³
F. Extend it through quotient portals
G. Add Russian roulette; continue convergence improvements
H. Add radiometrically correct finite lights and MIS
I. Redesign materials
J. Profile and optimize
```

Milestones A–I are complete for the currently supported endpoint materials and
light types. Milestone J is the active phase. The next finish line is a
profiled Photo Mode whose stochastic light selection, roulette depth, and
converged mean radiance have been validated across S³, H³, R³, and atlas
scenes.
