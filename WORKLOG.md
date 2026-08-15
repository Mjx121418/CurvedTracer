# WORKLOG

Non-Euclidean ray tracer for 3-dimensional spherical (S³) and hyperbolic (H³) space.
C++ owns the geometry/atlas; the Metal owner owns the GPU render loop + SwiftUI.
The seam between the two is `CONTRACT.md` (v2).

---

## How to build & test (in this container)

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure
```

---

## Phase 1 — completed ✅

**Objective:** prove the two hardest pieces of the architecture before building on them:
(1) a shared MSL-safe math layer that compiles identically in C++ and Metal,
(2) the Möbius transition map that makes the intrinsic chart atlas work.

### What was built

| File | Purpose |
|---|---|
| `Sources/GeometryCore/include/GeometryCore/Math.h` | **Shared with MSL.** `vec3/vec4`, Euclidean ops, `mat4` (identity/mul/apply), scalar wrappers (`mhCos/mhAcosh/…`). `#ifdef __METAL_VERSION__` guard. No `<std*>`, no allocation, float32 only. |
| `Sources/GeometryCore/include/GeometryCore/Hyperboloid.h` | Host-only. H³ ↔ Poincaré-ball maps, Minkowski `mdot`, geodesic `exp`, Lorentz reflection. |
| `Sources/GeometryCore/include/GeometryCore/Sphere3.h` | Host-only. S³ ↔ R³ stereographic maps, geodesic `exp`, great-sphere reflection. |
| `Sources/GeometryCore/include/GeometryCore/Mobius.h` + `src/Mobius.cpp` | Host-only. The chart transition map: `apply` (chart point), `compose`, `inverse`, `applySphere` (sphere→sphere, or sphere→plane at the projection point). |
| `CMakeLists.txt` | Builds static lib `GeometryCore` + `geometry_tests`. |
| `Tests/Cpp/*` | Dependency-free test harness (`test_framework.h`) + suites. |
| `CONTRACT.md` | Rewritten to **v2** (intrinsic chart atlas design). |
| `.gitignore`, `git init` | Repo on `main`; 2 commits. |

### Key design decisions locked in Phase 1

- **Intrinsic atlas, no anchor chart, no stored embedding coordinate** — charts hold only overlap edges `{neighbor, Möbius 4×4, safe}`. Consistency is the **cocycle condition** (loops compose to identity).
- **Objects are chart-local Euclidean spheres/planes** (`OPAQUE` / `MIRROR` sphere / `MIRROR` plane). A mirror is valid only under `|center|² = radius² ± 1` (H³ `+`, S³ `−`); this is what makes reflection = sphere inversion an isometry.
- **Renderer packet is chart-native** (128-byte header + `objects[]` + `materials[]`); camera always at the chart origin; GPU does straight rays + sphere inversion (§7 of CONTRACT).
- **C++ reaches Swift only through a pure-C `extern "C"` API** (`CCApi.h`) — no C++ ABI crosses the boundary; the packet is an immutable byte snapshot.

### Bugs found & fixed by the tests

1. **H³ distance used `acos` instead of `acosh`** — `cosh(d) = −⟨a,b⟩`, so it must be `acosh`. Added `mhAcosh` to `Math.h`; fixed `Hyperboloid.h::distance`.
2. **`applySphere` produced NaN at the projection point** (S³) — when a sampled sphere point maps to infinity. Now detects non-finite samples and falls back to the plane representation.

### Test status

`geometry_tests`: **80 checks, all passing.**

---

## Phase 2 — plan (next)

**Objective:** make the intrinsic chart atlas work end-to-end on the C++ side, producing the renderer packet the Metal side will upload. Everything stays testable in this container.

### 2.1 `Intersect.h` — shared with MSL (fill `Tests/Cpp/test_intersect.cpp`)

Euclidean, chart-coordinate primitives the GPU will also call:

- `raySphere(rayOrigin=0, dir, center, radius, tMin) → t` (quadratic, nearest positive root).
- `rayPlane(dir, normal, offset) → t`.
- `invertSphere(mirrorCenter, mirrorRadius, c, r) → (c′, r′, isPlane)` — closed form
  `d = c − m`, `D = |d|² − r²`, `k = R²`, `c′ = m + k·d/D`, `r′ = k·r/|D|`; `|D|≈0 ⇒ plane`.
- `reflectPlane(dir, normal)` for `MIRROR` planes.

MSL-safe (no `<std*>`, no allocation). Unit tests: hit/miss, tangent, plane hit, inversion sphere→sphere, inversion→plane (`D=0`), plane reflection.

### 2.2 `Scene.h` — shared POD packet (matches `CONTRACT.md` §5)

`PacketMeta` (16 B), `Camera` (64 B), `RenderControls` (32 B), `Counts` (16 B), `Object` (32 B), `materials` (16 B each). `static_assert` sizes (header = 128, Object = 32, …) and a runtime test that prints them for the Swift `MemoryLayout` check.

### 2.3 `Chart.h` + `Atlas` — host-only (C++ with std)

- `ChartObject { chartId, kind, center, radiusOrOffset, colorIdx }`.
- `Chart { id, edges[{neighborId, Mobius, safe}], objectIds }`.
- `Atlas`: `seed()`, `add(from, M, safe)`, `link(a,b,M,safe)`, `addObject(...)`.
- `build(cameraChart, maxDepth)`: validate **islands**, **cocycle** (loops → identity), **mirror/interior conditions**; then **flatten** — BFS over safe edges, compose `Mobius` along path, `applySphere` into the camera chart, emit `ScenePacket`.

### 2.4 `CCApi.h` / `CCApi.cpp` — the Swift-facing C API (`CONTRACT.md` §6)

`geo_scene_begin / geo_chart_seed / geo_chart_add / geo_chart_link / geo_object_add / geo_camera_set / geo_controls_set / geo_scene_build / geo_packet_ptr / geo_packet_size / geo_error_string / geo_contract_version`. Single internal `Atlas`; snapshot is valid until the next build; errors returned as codes (no exceptions across the boundary).

### 2.5 Phase-2 tests (`test_atlas.cpp` + extend `test_intersect.cpp`)

- Intersect: hit/miss/tangent/plane/inversion cases.
- Atlas: seed+link, cocycle valid vs injected-invalid (must reject), island rejection, flatten **path-independence** (same chart reached via different safe paths ⇒ identical packet), **two-chart scene == direct camera-chart scene**, S³ antipode renders without NaN.
- Packet: `static_assert`s + end-to-end build via C API and byte-layout verification.

### 2.6 (optional, after 2.1–2.5) Swift binding proof

`Package.swift` + `RenderCore` Swift target + `swift test` on Linux calling `geo_scene_*` and asserting the returned `ScenePacket` bytes match `CONTRACT.md` §5 via `MemoryLayout`. Proves the C++↔Swift seam in this container before any Mac build.

### Acceptance criteria for Phase 2

- `ctest` green, including cocycle/island/NaN guards and flatten correctness.
- A scene authored in two charts flattens identically to the same scene authored directly in the camera chart.
- The produced `ScenePacket` byte layout matches `CONTRACT.md` §5 exactly (asserted, not assumed).

---

## Phase 3+ (preview, not started)

- `Tools/ReferenceTracer`: chart-native CPU tracer (straight rays + unfold-the-world inversion) → PNG; model-space cross-check tracer must agree.
- Golden images (H³ single-chart, H³ multi-chart, S³ antipode) + macOS CI CPU/GPU diff.
- Off-center camera (Möbius view transform), object splitting at the S³ projection point (CONTRACT §12).
