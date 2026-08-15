# CONTRACT.md — C++ ⇄ Metal/Swift Seam

**Status:** v2 — intrinsic chart-atlas design (supersedes v0.1).
**Owner:** C++ side maintains this file and the shared artifacts it describes. The Metal/Swift side must be able to code against this document alone **without reading C++ sources**. Any change requires both sides to agree (see §9).

---

## 1. Purpose and division of labor

This repository is a ray tracer for 3-dimensional spherical (S³) and hyperbolic (H³) space. Work is split by toolchain:

| Side | Language | Owner | Responsibility |
|---|---|---|---|
| Geometry core + atlas | C++ | C++ owner | Chart atlas, Möbius transitions, flattening, reference tracer, tests |
| Render loop on GPU | Metal Shading Language (MSL) | Metal owner | Straight-ray casting, sphere/plane intersection, sphere-inversion reflection, shading |
| App / pipeline | Swift + SwiftUI | Metal owner | App shell, Metal pipeline, buffer upload, views |

**The scene is stored intrinsically** (§3): objects are Euclidean spheres/planes inside stereographic charts, charts relate only by pairwise overlap data (Möbius transition matrices), and there is **no** anchor chart and **no** stored embedding coordinate. For each frame, C++ flattens the visible region into a single **camera chart** and hands the Metal side one flat packet. **The renderer always works in one chart** (§7); it never sees the atlas, the transitions, or any hyperbolic/spherical (model-space) math.

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

**Header inventory (v2):**

| Header | Shared with MSL? | Contents |
|---|---|---|
| `Math.h` | **yes** | `vec3/vec4`, Euclidean ops, `mat4` (identity/mul/apply), scalar wrappers, clamp |
| `Intersect.h` | **yes** | ray↔Euclidean-sphere/plane intersection, **sphere inversion** (`invertSphere`), all in chart coordinates |
| `Hyperboloid.h` | no (host) | H³ ↔ Poincaré-ball maps, Minkowski `mdot`, geodesic `exp`, reflection (for Mobius round-trip, tests, cross-check) |
| `Sphere3.h` | no (host) | S³ ↔ R³ stereographic maps, `exp`, reflection |
| `Mobius.h` | no (host) | transition map (4×4), `apply/compose/inverse/applySphere` |
| `Chart.h` | no (host) | `Chart`, `ChartObject`, `Atlas`, flattening |
| `Scene.h` | **yes** | POD structs for Seam B (canonical layout, §5) |

The Metal side `#include`s only `Math.h`, `Intersect.h`, `Scene.h` (and any other header marked shared). It never re-implements math; it composes the shared functions into control flow.

---

## 3. Intrinsic chart atlas (Seam C, C++-internal)

### 3.1 Charts are stereographic projections

For each point of the manifold there is a stereographic chart centered there; the chart is **conformal**. In chart coordinates:

- **H³** — the chart is the **Poincaré ball** (unit ball, `|x| < 1`). Center `0` ↔ model point `(0,0,0,1)`; the boundary `|x|=1` is the ideal sphere. No point of H³ maps to infinity (the projection point lies off the model), so the chart is bounded.
- **S³** — the chart is all of **R³** (unbounded). Center `0` ↔ model point `(0,0,0,−1)` (south pole); the north pole `(0,0,0,1)` is the projection point and maps to **infinity**.

Maps (host-only, for round-trips and validation):

| | chart → model | model → chart |
|---|---|---|
| H³ | `(2x, 2y, 2z, 1+r²)/(1−r²)` | `(x, y, z)/(1 + w)` |
| S³ | `(2x, 2y, 2z, r²−1)/(1+r²)` | `(x, y, z)/(1 − w)` |

### 3.2 Charts relate only by overlap edges

- A `Chart` stores **only** its overlap edges: `{ neighborId, Mobius transition, numericallySafe flag }`, plus the ids of objects homed in it. No chart stores its center's embedding coordinate.
- The transition on an edge is a **Möbius transformation** (a conformal map), stored as a 4×4 matrix — Lorentz `O(3,1)` for H³, orthogonal `O(4)` for S³ — column-major, 64 bytes. `compose` = matrix multiply; `inverse` = matrix inverse.
- **There is no anchor chart.** The first chart created is the anchorless seed (id 0). Every subsequent chart is placed by linking to an existing chart: `chart_add(fromChart, M, safe)`.
- **Overlap vs close-enough are distinct** (design §3.3): an edge records the transition (overlap) *and* whether one hop keeps float32 distortion bounded (`numericallySafe`). Reachability uses all edges; flattening prefers safe hops.

### 3.3 Objects are chart-local Euclidean spheres/planes

An object is homed in exactly one chart and stored in that chart's coordinates:

| kind | storage | meaning |
|---|---|---|
| `OPAQUE` (0) | sphere `{center, radius}` | a solid geodesic ball (shaded, no reflection) |
| `MIRROR` (1) | sphere `{center, radius}` | a mirror = geodesic hyperplane / great sphere (reflected across) |
| `PLANE` (2) | `{normal, offset}` | a mirror through the chart center (the r→∞ limit of a mirror sphere) |

**Mirror validity** (the condition that makes reflection = sphere inversion an isometry, validated by `geo::Atlas::build`):

- H³ mirror sphere: `|center|² == radius² + 1` (orthogonal to the unit-sphere boundary).
- S³ mirror sphere: `|center|² == radius² − 1` (image of a great sphere).
- PLANE mirrors always pass through the origin; the reflection is plain Euclidean plane reflection.

**OPAQUE validity:** H³ spheres must satisfy `|center| + radius < 1` (interior). S³ has no interior bound.

### 3.4 Consistency = cocycle condition (replaces the anchor)

Because the atlas *is* its transition maps and nothing else, the maps must agree around every loop, or "the same point" would have different coordinates depending on path. `geo::Atlas::build` verifies: **every closed loop composes to identity within tolerance**. Group-built atlases (tessellation) satisfy this by construction; hand-authored atlases are checked and rejected on violation. Island charts (zero edges) are also rejected.

---

## 4. Coordinate systems and units (normative)

- Chart coordinates are **Euclidean R³**. For H³ they are bounded by `|x| < 1`; for S³ they are unbounded and the projection point is at infinity.
- All sphere radii / plane offsets are **chart (Euclidean) quantities**. Distances/radii are *not* hyperbolic/angular arc lengths — the metric is implicit in the chart. (Host-side model math, when needed for validation, uses the maps in §3.1.)
- `modelKind`: `0 = H³`, `1 = S³`. One scene has one model; objects, charts, and camera must agree.

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
└── materials[]    (16 B each, after objects[])
```

Fixed header total: **128 bytes**.

### 5.1 Field specs

**PacketMeta (16 B)** — self-describing; both sides verify and hard-fail on mismatch.

| Off | Name | Type | Value |
|---|---|---|---|
| 0 | `magic` | int32 | `0x4E545243` ("NTRC") |
| 4 | `contractVersion` | int32 | = `GEO_CONTRACT_VERSION` (currently **2**) |
| 8 | `objectSize` | int32 | 32 |
| 12 | `packetHeaderSize` | int32 | 128 |

**Camera (64 B)** — the camera is always at the chart origin; orientation is an orthonormal frame.

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `right` | vec3 + pad | unit tangent, camera right |
| 16 | `up` | vec3 + pad | unit tangent, camera up |
| 32 | `fwd` | vec3 + pad | unit tangent, into the scene (`right × up` handedness) |
| 48 | `fovTan` | float | tan(vertical FOV / 2) |
| 52 | `aspect` | float | width / height |
| 56,60 | pad | float,float | zero |

**RenderControls (32 B)** — tunables are *data*, so tuning never edits a shader.

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `maxBounces` | int32 | reflection-loop cap (GPU loop must be bounded by this) |
| 4 | `modelKind` | int32 | 0 = H³, 1 = S³ |
| 8 | `falloffK` | float | distance shading `1/(1 + falloffK·t)`, t = chart distance from origin |
| 12 | `ambient` | float | background floor added to every sample |
| 16 | `bounceAttenuation` | float | multiplier applied per reflection |
| 20..28 | pad | float×3 | zero |

**Counts (16 B)**

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `objectCount` | int32 | length of `objects[]` |
| 4 | `materialCount` | int32 | length of `materials[]` |
| 8,12 | pad | int32, int32 | zero |

**Object (32 B)** — one chart-local primitive.

| Off | Name | Type | Meaning |
|---|---|---|---|
| 0 | `center` | vec3 | sphere: Euclidean center; plane: unit normal |
| 12 | `radiusOrOffset` | float | sphere: Euclidean radius; plane: signed offset (≈0 for mirrors) |
| 16 | `kind` | int32 | 0 = OPAQUE sphere, 1 = MIRROR sphere, 2 = MIRROR plane |
| 20 | `colorIdx` | int32 | index into `materials[]` |
| 24,28 | pad | int32, int32 | zero |

**materials[] (16 B each)** — `vec4(r, g, b, a)` color table indexed by `colorIdx`.

### 5.2 Buffer slots (Swift/Metal side)

| Slot | Buffer |
|---|---|
| 0 | ScenePacket (header + arrays as one upload) |
| 1 | optional: golden reference texture, if CPU/GPU diff runs in-app |

### 5.3 Capacity limits (v2)

`MAX_OBJECTS = 4096`, `MAX_MATERIALS = 256`, `MAX_CHART_DEPTH = 64` (flattening BFS bound). Exceeding them is rejected by `geo::Atlas::build`.

---

## 6. C++ API (Seam B, Swift side)

Swift imports the `GeometryCore` Swift package and calls the host C++ classes directly with Swift C++ interop. Metal never sees the atlas or these classes.

**v2 surface (signatures are spec; C++ owner implements):**

```cpp
namespace geo {

class Atlas {
public:
    // 0 = H3, 1 = S3. Resets the atlas. Swift uses `start`; `begin` is the
    // same method but Swift C++ interop reserves `begin` for C++ iterators.
    void start(int modelKind);

    int seed();                                      // anchorless base chart, returns 0
    int add(int fromChart, const float m[16], bool safe);          // link new chart; returns new id
    void link(int a, int b, const float m_ab[16], bool safe);

    // kind: 0 = OPAQUE sphere, 1 = MIRROR sphere, 2 = MIRROR plane.
    // sphere: center + radiusOrOffset=radius.  plane: center=normal, radiusOrOffset=offset.
    int addObject(int chartId, int kind, const vec3& center, float radiusOrOffset, int colorIdx);
    int addMaterial(const vec4& color);

    void setCamera(float fovTan, float aspect,
                   const vec3& right, const vec3& up, const vec3& fwd);
    void setControls(int maxBounces, float falloffK, float ambient, float bounceAttenuation);

    // Validate (cocycle, islands, mirror/interior conditions) then flatten into
    // the camera chart. Returns 0 on success and fills the packet snapshot.
    int build(int cameraChart, int maxChartDepth);

    // Packet bytes. Swift reads the byte vector via packetBytes() (packet()
    // returns a C++ reference and is hidden by Swift C++ interop).
    std::vector<uint8_t> packetBytes() const;
    int packetSize() const;
};

}
```

If no material is authored before `build`, the builder emits one default white material at index 0.

**Error codes:** `0` OK; `1` island chart; `2` cocycle violation; `3` invalid object (mirror/interior condition); `4` unknown camera chart; `5` capacity exceeded; `6` model/kind mismatch.

---

## 7. Rendering model (how the GPU works — normative for the Metal owner)

### 7.1 Rays are straight lines from the origin

The camera is always at the chart origin. A pixel with NDC `(u,v) ∈ [0,1]²` has direction

```
d = normalize( fwd + right·(2u−1)·fovTan·aspect + up·(2v−1)·fovTan )
```

and the ray is `p(t) = t·d`, `t > ε` (`ε = 1e-4`). Only rays *through the origin* are straight geodesics in a stereographic chart; a general geodesic is a circular arc — **the GPU never constructs circular arcs** (see §7.2).

### 7.2 Unfold-the-world (reflection = sphere inversion, ray stays straight)

On a MIRROR hit, instead of bending the ray into a circular arc, the shader applies the mirror's **inversion to the entire object list** (closed-form: `invertSphere` / plane reflection, shared in `Intersect.h`), multiplies `bounceAttenuation`, and continues the *same* straight ray. Because the mirror is a valid isometry (validated mirror condition, §3.3), this is exact and keeps the renderer purely Euclidean and stateless-per-ray. Loop is flat and bounded by `maxBounces`; re-hitting the same mirror is excluded by `t > ε` + the "which side" test.

Per pixel:

1. nearest intersection of `p(t)=t·d` with the current sphere/plane list (Euclidean quadratics);
2. OPAQUE hit → shade with Euclidean normals (conformal ⇒ correct angles), distance falloff from `controls`; return;
3. MIRROR hit → invert the whole object list across that mirror; continue;
4. no hit → background gradient.

This is the exact algorithm the CPU reference tracer implements (`Tools/ReferenceTracer`), so the Metal owner transcribes rather than derives, and the CPU/GPU diff (macOS CI) validates the port.

---

## 8. Reference tracer & golden images (C++ side)

- `reference_tracer` (CPU, C++) implements §7.1–§7.2 with the same shared functions, iteration caps, and shading parameters, and writes PNGs.
- A model-space cross-check tracer (straight geodesics in the hyperboloid/sphere model) must agree within tolerance — it validates that the chart-native unfold is a faithful isometry unfolding.
- Every contract change that affects output regrows golden images in the same commit (§9). macOS CI diffs GPU vs CPU within a tolerance budget (per-channel `maxErr ≈ 5/255`, PSNR > 35 dB).

---

## 9. Versioning & change workflow (normative)

- `GEO_CONTRACT_VERSION` is currently **2**. `PacketMeta.contractVersion` must match; mismatch → upload rejected (and Swift-side assert).
- Any change to struct layout, enum values, coordinate/unit conventions, solver behavior, or any number in this document → **discuss first, bump version, land with tests + regrown goldens in the same change**.
- Adding a field extends the struct **at the end**; never reorder.
- Metal side reports shader-observed issues (NaN, precision, edge cases) to the C++ owner with a repro; C++ owner fixes shared math, adds a regression test, regrows goldens, bumps version.

---

## 10. Build & validation checklist (per side)

**C++ side (container):**
- [ ] `cmake -S . -B build && cmake --build build` — core + tests + reference tracer
- [ ] `ctest --test-dir build` green
- [ ] `static_assert`s: Object=32, Camera=64, RenderControls=32, Counts=16, PacketMeta=16, header=128 (printed by a test)
- [ ] reference renders match goldens

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

## 12. Open questions (resolve before v3)

1. Off-center camera: v2 renders only at the chart origin; a Möbius view-transform for arbitrary camera pose is deferred. Confirm this is acceptable for the first renderer.
2. Object splitting for spheres that span a chart's projection point (S³): v2 rejects at authoring; splitting heuristic deferred.
3. `PLANE` mirrors restricted to through-origin planes; general planes (offset ≠ 0) are represented as large mirror spheres. Acceptable?
