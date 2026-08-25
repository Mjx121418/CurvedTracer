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
    TraceShared.metalh
        packet records and validation
        decoded scene view
        constant-curvature metric helpers
        primitive intersections
        nearest-event queries
        portal traversal
        camera-ray construction
        shared diagnostics

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
1280×720 tracing resolution. Keep the existing ring of BGRA8 display textures.

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
because the tracing resolution remains 1280×720. If MetalFX is unavailable or
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

Extend diffuse and mirror continuation through existing portal transport.
For direct lighting, enumerate the current bounded set of light lifts, trace a
visibility ray toward each lift, and retain the existing light-state and
portal-hop safety limits.

Validate in this order:

```text
Euclidean 3-torus
Lens space
Seifert–Weber space
```

Only after correctness should light-lift selection become stochastic.

---

## Milestone G — Russian roulette and convergence controls

After a few fixed bounces, derive a survival probability from path throughput,
cap it below one, terminate rejected paths, and divide surviving throughput by
the probability. Keep the fixed maximum depth as a safety bound.

Later convergence work may add:

- per-pixel variance estimates;
- adaptive stopping;
- low-discrepancy sample sequences; and
- improved light-selection probabilities.

These are optimizations rather than correctness prerequisites.

---

## Milestone H — Finite area lights and radiometry

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

This stage is the first expected GeometryCore packet-contract revision.

---

## Milestone I — Physical materials

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

1. ideal dielectric glass;
2. rough dielectric GGX;
3. rough conductor GGX; and
4. emissive materials.

Local BSDF evaluation remains in the Euclidean tangent space for all three
ambient geometries.

---

## Milestone J — Profiling and acceleration

Do not add acceleration structures before measuring the working path tracer.
The current per-chart linear object scan may eventually need:

- per-chart BVHs;
- primitive grouping;
- portal-aware pruning; or
- a wavefront path architecture.

Profile first. Retain the simpler one-thread-per-pixel path loop until
divergence or intersection cost is demonstrated to be the limiting factor.

---

## Later work

Leave these features until the core renderer is correct and stable:

- difficult caustics;
- bidirectional path tracing or photon methods;
- participating media;
- spectral transport;
- motion blur;
- denoising;
- environment maps; and
- physically modeled cameras and image export.

---

## Recommended commit sequence

```text
A. Extract shared tracing code without changing real-time output
B. Add progressive Photo Mode, HDR accumulation, and stochastic pixels
C. Add reusable visibility rays and Photo Mode hard shadows
D. Add Euclidean Lambertian GI and physical mirror handling
E. Extend the integrator to Flat S³ and H³
F. Extend it through quotient portals
G. Add Russian roulette and convergence improvements
H. Add radiometrically correct finite lights and MIS
I. Redesign materials
J. Profile and optimize
```

The first major finish line is Milestone F: progressive HDR transport with
antialiasing, hard shadows, diffuse global illumination, perfect reflections,
and portal-aware paths in S³, H³, and R³.
