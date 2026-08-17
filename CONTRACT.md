# CONTRACT.md — C++ ⇄ Metal/Swift Seam

**Status:** v6 — signed-w S³ disk charts, dynamic camera chart, camera movement/rotation, and unified material specular.
**Owner:** C++ side maintains this file and the shared artifacts it describes. The Metal/Swift side must be able to code against this document alone **without reading C++ sources**. Any change requires both sides to agree (see §9).

---

## 1. Purpose and division of labor

This repository is a ray tracer for 3-dimensional spherical (S³) and hyperbolic (H³) space. Work is split by toolchain:

| Side | Language | Owner | Responsibility |
|---|---|---|---|
| Geometry core + atlas | C++ | C++ owner | Chart atlas, Möbius transitions, flattening, reference tracer, tests |
| Render loop on GPU | Metal Shading Language (MSL) | Metal owner | Straight-ray casting, disk-chart hyperplane-section intersection, ambient reflection, shading |
| App / pipeline | Swift + SwiftUI | Metal owner | App shell, Metal pipeline, buffer upload, views |

**The scene is stored intrinsically** (§3): objects are hyperplane sections of open disk charts on S³, charts relate only by pairwise overlap data (transition matrices), and there is **no** anchor chart and **no** stored embedding coordinate. Each chart has a radius. For each frame, C++ flattens the visible region into a single **camera chart** and hands the Metal side one flat packet. **The renderer always works in one chart** (§7); it never sees the atlas, the transitions, or any model-space math.

Three seams connect the sides; only (A) and (B) reach the Metal/Swift side, (C) is C++-internal:

- **(A) Shared math (source-level).** One set of MSL-safe headers, `#include`d verbatim by C++ host and `.metal` shaders.
- **(B) Scene packet (byte-level).** Flat POD buffer built by C++, uploaded verbatim by Swift, read by MSL as `constant`.
- **(C) Intrinsic atlas (C++-internal).** Charts + overlap graph + Möbius transitions + flattening. Swift reaches it through the `geo::Atlas` C++ API exposed by the GeometryCore Swift package (§6); Metal never touches it.

---

## 2. Shared math header rules (Seam A)

Shared headers live under `Sources/include/GeometryCore/` inside the `GeometryCore` Swift package and are compiled by **both** C++ (clang) and MSL (`#ifdef __METAL_VERSION__`). MSL is C++14-ish with restrictions, therefore:

1. **No** `<std*>` headers, no STL, no exceptions, no RTTI, no virtual functions, no dynamic allocation, no recursion, no templates over user types.
2. **float32 only** for geometry. `half` allowed only for GPU output colors/accumulation.
3. Everything in `namespace geo`, fixed names (`vec3/vec4`, `dot/cross/normalize`, scalar wrappers `mhCos/mhAcosh/mhLog/…`).
4. **Fast-math caveat:** `acos/acosh` domain clamping must be explicit (clamped argument) so it survives MSL fast-math. Never rely on the operation itself to reject out-of-domain input.
5. One version macro `GEO_CONTRACT_VERSION`, echoed into the packet; mismatch is a hard error at upload (§6, §9).

**Header inventory (v6):**

| Header | Shared with MSL? | Contents |
|---|---|---|
| `Math.h` | **yes** | `vec3/vec4`, Euclidean ops, `mat4` (identity/mul/apply), scalar wrappers, clamp |
| `Intersect.h` | **yes** | disk-chart ray↔hyperplane-section intersection, ambient reflection helpers, all in chart coordinates |
| `Hyperboloid.h` | no (host) | H³ disk ↔ Poincaré ↔ hyperboloid maps, Minkowski `mdot`, geodesic `exp`, reflection (for round-trip, tests, cross-check) |
| `Sphere3.h` | no (host) | S³ disk-chart ↔ ambient S³ maps, `exp`, reflection |
| `Mobius.h` | no (host) | transition map (4×4), `apply/compose/inverse/applySurface` |
| `Chart.h` | no (host) | `Chart` (with radius), `ChartObject`, `Atlas`, flattening/culling |
| `Scene.h` | **yes** | POD structs for Seam B (canonical layout, §5) |

The Metal side `#include`s only `Math.h`, `Intersect.h`, `Scene.h` (and any other header marked shared). It never re-implements math; it composes the shared functions into control flow.

---

## 3. Intrinsic chart atlas (Seam C, C++-internal)

### 3.1 Charts are open geodesic balls

The ambient model is the unit 3-sphere `S³ = { X ∈ R⁴ : |X| = 1 }`.

A chart is a **geodesic ball of radius `r` around an anchor point**. The anchor maps to `(0,0,0,1)`.

- **H³**: chart coordinates are points `x ∈ R³` with `|x| < sin(r)` and the embedding is `X = (x, sqrt(1 - |x|²))`. H³ is conformally embedded as the upper hemisphere `X.w > 0` of S³; the ideal boundary is the equator `X.w = 0`. A chart radius must satisfy `0 < r ≤ π/2`.
- **S³**: chart coordinates are the signed-w orthographic pair `(x, w)` with `|x|² + w² = 1`. The chart domain is `w > cos(r)` (equivalently geodesic distance from the anchor `< r`). A chart radius must satisfy `0 < r < π`; the chart must not contain the antipodal point of the anchor.

Charts have **variable size**. `r` is stored per chart and is not required to be `π/2`.

### 3.2 Charts, radii, and overlap edges

A `Chart` stores:

```text
{ id, radius, edges[{ neighborId, transition, safe }], objectIds, lightIds }
```

- The transition on an edge is a 4×4 matrix, column-major, 64 bytes:
  - S³: `O(4)` isometry
  - H³: `O(3,1)` Lorentz matrix in the hyperboloid model
- `compose` = matrix multiply, `inverse` = matrix inverse.
- There is **no anchor chart**. The first chart is the anchorless seed.
- Reachability uses all edges; flattening prefers safe hops.

### 3.2.1 Special camera chart and camera movement

The camera is rendered from a **distinguished camera chart**. `Atlas::cameraChartAt(fromChart, positionInFromChart, radius)` creates/reuses this chart and links it to a normal chart so that the desired anchor point becomes the camera-chart origin. `Atlas::build(cameraChart, maxChartDepth)` then flattens all reachable charts into that camera chart.

Camera movement is stateful:

- `cameraMove(movement)` interprets `movement` in the current camera chart's local frame, maps it back into the current parent chart, and re-parents the camera chart to the closest chart that contains the resulting point.
- If no existing chart contains the point, the camera is clamped back to the original parent chart, onto its disk boundary (`|x| = sin(r)`).
- After re-parenting, the camera frame (`right`/`up`/`fwd`) is parallel-transported into the new camera chart.

The camera chart radius is emitted in the packet as `chartRadiusSin`/`chartRadiusCos`. The shader culls hits with `|hit.position|² >= chartRadiusSin²`; `Atlas::build` itself emits all reachable objects/lights.

### 3.3 Objects are hyperplane sections of the disk

An object is homed in exactly one chart and stored as the intersection of the chart disk with an ambient 4D hyperplane:

```text
a·x + b·w = c,    w = sqrt(1 - |x|²)
```

where `(a ∈ R³, b ∈ R, c ∈ R)` are chart-local values.

| kind | meaning |
|---|---|
| `OPAQUE` (0) | a solid side of the surface; shaded, no reflection |
| `MIRROR` (1) | an isometric mirror; reflection = ambient reflection across the surface |

There is no separate `PLANE` kind. Old stereographic planes become hyperplane sections.

**Mirror validity** (validated by `geo::Atlas::build`):

- **S³ MIRROR**: a great sphere in S³:

  ```text
  c == 0,   |(a,b)| == 1
  ```

- **H³ MIRROR**: a hyperbolic hyperplane, orthogonal to the ideal equator:

  ```text
  b == 0,   |a| == 1
  ```

  and the surface must intersect the chart disk.

**OPAQUE validity**: the boundary must be a sphere (not a hyperplane) and the solid side must be representable inside the chart disk. Exact host-side bounds are derived in the implementation spike; `Atlas::build` rejects any opaque boundary that does not lie strictly inside its home chart and inside the camera chart disk.

### 3.4 Consistency = cocycle condition

Unchanged from v3: every closed loop must compose to identity within tolerance. Island charts are rejected.

---

## 4. Coordinate systems and units (normative)

- H³ chart coordinates are points `x ∈ R³` with `|x| < sin(r)`, where `r` is the chart radius.
- S³ chart coordinates are signed-w orthographic pairs `(x, w)` with `|x|² + w² = 1`; a chart contains points with `w > cos(r)`.
- All object coefficients `(a,b,c)`, light positions, and camera directions are chart quantities. `PointLight.positionW` stores the augmented fourth coordinate for both models.
- `modelKind`: `0 = H³`, `1 = S³`. One scene has one model.
- For H³ the largest chart is the upper hemisphere `r = π/2`. For S³ the largest chart is any geodesic ball of radius `r < π`.

---

## 5. Scene packet (Seam B, normative)

Single contiguous byte buffer: built by C++ (`geo::Atlas::build`), uploaded verbatim by Swift → `MTLBuffer`, read by MSL as `constant`. Layout is fixed; equality across C++/Swift/MSL is a hard requirement (Swift asserts sizes with `MemoryLayout`; C++ `static_assert`s them).

All integers **int32**, floats **float32**, little-endian. The packet is the **camera chart** coordinate frame: every object is already transformed into the camera chart (§7); the camera is at the origin.

```text
ScenePacket
├── PacketMeta     (16 B, offset   0)
├── Camera         (64 B, offset  16)
├── RenderControls (32 B, offset  80)
├── Counts         (16 B, offset 112)
├── objects[]      (32 B each, offset 128)
├── materials[]    (32 B each, after objects[])
└── lights[]       (32 B each, after materials[])
```

Fixed header total: **128 bytes**.

### 5.1 Field specs

**PacketMeta (16 B)**

| Off | Name | Type | Value |
|---|---|---|---|
| 0 | `magic` | int32 | `0x4E545243` ("NTRC") |
| 4 | `contractVersion` | int32 | = `GEO_CONTRACT_VERSION` (currently **6**) |
| 8 | `objectSize` | int32 | 32 |
| 12 | `packetHeaderSize` | int32 | 128 |

**Camera (64 B)** — camera at the chart origin; orientation is an orthonormal frame.

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `right` | vec3 + pad | unit tangent, camera right |
| 16 | `up` | vec3 + pad | unit tangent, camera up |
| 32 | `fwd` | vec3 + pad | unit tangent, into the scene |
| 48 | `fovTan` | float | tan(vertical FOV / 2) |
| 52 | `aspect` | float | width / height |
| 56 | `chartRadiusSin` | float | `sin(r)` for the camera chart |
| 60 | `chartRadiusCos` | float | `cos(r)` for the camera chart |

The shader culls a hit when:

```text
|hit.position|² >= chartRadiusSin²
```

**RenderControls (32 B)** — unchanged from v3.

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `maxBounces` | int32 | reflection-loop cap |
| 4 | `modelKind` | int32 | 0 = H³, 1 = S³ |
| 8 | `falloffK` | float | camera-chart distance falloff |
| 12 | `ambient` | float | background floor |
| 16 | `bounceAttenuation` | float | reflection throughput multiplier |
| 20..28 | pad | float×3 | zero |

**Counts (16 B)** — unchanged from v3.

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `objectCount` | int32 | length of `objects[]` |
| 4 | `materialCount` | int32 | length of `materials[]` |
| 8 | `lightCount` | int32 | length of `lights[]` |
| 12 | pad | int32 | zero |

**Object (32 B)** — one chart-local hyperplane section.

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `a` | vec3 | hyperplane normal part |
| 12 | `b` | float | hyperplane `w` coefficient |
| 16 | `c` | float | hyperplane right-hand side |
| 20 | `kind` | int32 | 0 = OPAQUE, 1 = MIRROR |
| 24 | `colorIdx` | int32 | index into `materials[]` |
| 28 | pad | int32 | zero |

**Material (32 B each)** — unified diffuse + specular material.

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `color` | vec4 | diffuse rgba |
| 16 | `specular` | vec4 | specular rgb + intensity in `a` |

**PointLight (32 B each)** — unchanged.

### 5.2 Buffer slots

| Slot | Buffer |
|---|---|
| 0 | ScenePacket (header + arrays as one upload) |
| 1 | optional: golden reference texture |

### 5.3 Capacity limits (v6)

`MAX_OBJECTS = 4096`, `MAX_MATERIALS = 256`, `MAX_LIGHTS = 16`, `MAX_CHART_DEPTH = 64`. Exceeding them is rejected by `geo::Atlas::build`.

The augmented chart coordinate is `(x,w)` for both models: signed for S³, `+sqrt(1-|x|²)` for H³. A chart contains points with `w > cos(r)`. `PointLight.positionW` carries `w`.

---

## 6. C++ API (Seam B, Swift side)

Swift imports the `GeometryCore` Swift package and calls the host C++ classes directly with Swift C++ interop. Metal never sees the atlas or these classes.

**Current surface (signatures are spec; C++ owner implements):**

```cpp
namespace geo {

struct CameraPlacement {
    int chartId;
    vec3 localPosition;
};

class Atlas {
public:
    // 0 = H3, 1 = S3. Resets the atlas. Swift uses `start`; `begin` is the
    // same method but Swift C++ interop reserves `begin` for C++ iterators.
    void start(int modelKind);

    // Anchorless base chart with radius r (radians). Returns 0.
    int seed(float radius);

    // Add a new chart of radius r, linked from `fromChart` by the transition
    // matrix m (column-major). Returns the new chart id.
    int addChart(float radius, int fromChart, const float m[16], bool safe);
    int add(float radius, int fromChart, const float m[16], bool safe);   // alias

    void linkCharts(int a, int b, const float m_ab[16], bool safe);
    void link(int a, int b, const float m_ab[16], bool safe);             // alias

    // kind: 0 = OPAQUE, 1 = MIRROR.
    // Object boundary in chart coordinates: a·x + b·sqrt(1 - |x|²) = c.
    int addObject(int chartId, int kind,
                  const vec3& a, float b, float c, int colorIdx);

    int addMaterial(const vec4& color, const vec4& specular);

    // Author a point light in any chart; it is flattened into the camera chart.
    int addLight(int chartId, const vec3& position, const vec3& color, float intensity);

    void setCamera(float fovTan, float aspect,
                   const vec3& right, const vec3& up, const vec3& fwd);
    void setControls(int maxBounces, float falloffK, float ambient, float bounceAttenuation);

    // Camera frame accessors (chart-space, orthonormal).
    vec3 cameraRight() const;
    vec3 cameraUp() const;
    vec3 cameraFwd() const;

    // Rotate the camera frame around a chart-space axis. The camera stays at
    // the chart origin; only the right/up/fwd frame changes.
    void cameraRotate(const vec3& axis, float deltaRadians);

    // Roll around the camera's own fwd axis. Positive rolls left.
    void cameraRoll(float deltaRadians);

    // Compute the placement resulting from a movement in startChart-local
    // coordinates. Re-parents to the closest chart containing the result;
    // otherwise clamps back to startChart's disk boundary.
    CameraPlacement resolveCameraPlacement(int startChart, const vec3& startLocal,
                                           const vec3& movement) const;

    // Create/replace the special camera chart anchored at positionInFromChart
    // (expressed in fromChart). Returns the camera chart id.
    int cameraChartAt(int fromChart, const vec3& positionInFromChart, float radius);

    // Stateful camera movement in the current camera chart's local frame.
    // Returns the camera chart id after re-parenting and re-anchoring.
    int cameraMove(const vec3& movement);
    int cameraChartId() const;

    // Validate and flatten. Returns 0, or an error code below.
    int build(int cameraChart, int maxChartDepth);

    std::vector<uint8_t> packetBytes() const;
    int packetSize() const;
    const void* packetData() const;   // Swift-visible raw pointer for upload
};

}
```

If no material is authored, `build` emits one default white material. If no light is authored, `lightCount` is 0.

**Error codes:** `0` OK; `1` island chart; `2` cocycle violation; `3` invalid object; `4` unknown camera chart; `5` capacity exceeded; `6` model/kind mismatch.

---

## 7. Rendering model (how the GPU works — normative for the Metal owner)

### 7.1 Rays from the camera origin

The camera is always at the chart origin. A pixel with NDC `(u,v) ∈ [0,1]²` has direction

```text
d = normalize( fwd + right·(2u−1)·fovTan·aspect + up·(2v−1)·fovTan )
```

- **H³**: the ray is `x(t) = t·d`, `t > ε` (`ε = 1e-4`), with `t = |x|`.
- **S³**: the ray is `(x,w)(t) = (sin t · d, cos t)`, `t > ε`, where `t` is geodesic distance from the camera origin.

In both models, rays through the origin are geodesics.

### 7.2 Surface intersection

Object boundaries are:

```text
a·x + b·w = c
```

where `w = sqrt(1 - |x|²)` for H³ and `(x,w)` is the signed-w S³ chart coordinate.

- **H³**: substituting `x = t d` gives `a·(t d) + b·sqrt(1 - t²) = c`. Squaring gives the quadratic in `t`:

```text
t²·((a·d)² + b²) - 2c·(a·d)·t + (c² - b²) = 0
```

Discard roots with `t ≤ ε`, and discard roots outside the chart disk `t² ≥ sin²(radius)`.

- **S³**: substituting `(x,w) = (sin t · d, cos t)` gives:

```text
(a·d) sin t + b cos t = c
```

The shader solves this trigonometric equation, discards roots with `t ≤ ε`, and discards roots with `t ≥ radius`.

### 7.3 Reflection

On a MIRROR hit:
1. Lift the hit point to the ambient model (hyperboloid for H³, sphere for S³).
2. Build the isometry that maps the hit point to the chart origin.
3. Reflect the ray direction across the surface normal in the tangent space at the origin.
4. Continue tracing from the new chart origin along the reflected direction.

### 7.4 Lighting convention (v6)

Lighting remains point lights in chart coordinates, as in v3, but the lift/unlift maps change:

- H³: `liftPoint(x) = hyperboloidLift(diskToPoincare(x))`
- S³: `liftPoint(x,w) = (x,w)`
- `liftTangent` and `unliftTangent` are the differentials of those maps.

At an OPAQUE hit point `p`, for each point light at current chart position `q`, compute the ambient tangent `V` at `P` pointing toward `Q`, map it back to the chart tangent `L`, and shade:

```text
falloff = 1 / (1 + controls.falloffK * t)

radiance = material.color.rgb
         * (controls.ambient
            + falloff * Σ light.color * light.intensity * max(dot(N, L), 0))
         + falloff * material.specular.rgb * material.specular.a
         * Σ light.color * light.intensity * pow(max(dot(N, H), 0), 32)
```

---

## 8. Reference tracer & golden images (C++ side)

- `reference_tracer` (CPU, C++) implements §7.1–§7.2 with the same shared functions, iteration caps, and shading parameters, and writes PNGs.
- A model-space cross-check tracer (straight geodesics in the hyperboloid/sphere model) must agree within tolerance — it validates that the chart-native unfold is a faithful isometry unfolding.
- Every contract change that affects output regrows golden images in the same commit (§9). macOS CI diffs GPU vs CPU within a tolerance budget (per-channel `maxErr ≈ 5/255`, PSNR > 35 dB).

---

## 9. Versioning & change workflow (normative)

- `GEO_CONTRACT_VERSION` is currently **6**. `PacketMeta.contractVersion` must match; mismatch → upload rejected (and Swift-side assert).
- Any change to struct layout, enum values, coordinate/unit conventions, solver behavior, or any number in this document → **discuss first, bump version, land with tests + regrown goldens in the same change**.
- Adding a field extends the struct **at the end**; never reorder.
- Metal side reports shader-observed issues (NaN, precision, edge cases) to the C++ owner with a repro; C++ owner fixes shared math, adds a regression test, regrows goldens, bumps version.

---

## 10. Build & validation checklist (per side)

**C++/Swift package (container or macOS):**

```bash
cd GeometryCore
swift test                 # Swift C++ interop + packet layout tests
swift run geometry_tests   # full C++ test suite
```

- [ ] `swift test` green
- [ ] `swift run geometry_tests` green
- [ ] `static_assert`s: Object=32, Camera=64, RenderControls=32, Counts=16, PacketMeta=16, header=128 (printed by a test)
- [ ] reference renders match goldens (when `Tools/ReferenceTracer` exists)

Container note: in this Linux container `swift test` requires `/usr/bin/clang` and `/usr/bin/clang++` to be symlinked to a clang that accepts `-index-store-path` (here `clang-21`).

**Metal/Swift side (macOS):**
- [ ] Swift mirrors structs; `MemoryLayout` matches the sizes above
- [ ] uploads `packetBytes()` → `MTLBuffer` verbatim
- [ ] shader `#include`s `Math.h` / `Intersect.h` / `Scene.h`; no local re-implementation of `geo::` math
- [ ] reflection loop flat, bounded by `maxBounces`, uses `invertSphere` (§7.2)
- [ ] CPU/GPU diff within tolerance (§8)

---

## 11. Out of scope (deliberately not contract)

- MSL file organization, pipeline setup, threading, per-frame heuristics — Metal owner's.
- Shading beyond LUT + distance falloff (extended later as *data*, §9 bump).
- SwiftUI layout/interaction.
- Anything aesthetic.

---

## 12. Notes on former open questions

1. H³ `OPAQUE` validity is enforced by host-side validation in `Atlas::build` (the boundary must lie inside the home chart disk and have positive radius).
2. The H³ `(a,b,c)` surface transformation law is implemented by `Mobius::applySurface`.
3. Off-center camera rendering is implemented through the special camera chart (`cameraChartAt`, `cameraMove`, `resolveCameraPlacement`).
4. For S³ charts with `r > π/2`, the shader culls exactly by `chartRadiusSin`; chart creation must still avoid the antipodal point.
