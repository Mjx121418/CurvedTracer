# WORKLOG

Non-Euclidean ray tracer for 3-dimensional spherical (S³) and hyperbolic (H³) space.
C++ owns the geometry/atlas; the Metal owner owns the GPU render loop + SwiftUI.
The seam between the two is `CONTRACT.md` (v5).

---

## How to build & test (in this container)

All commands run inside the `GeometryCore` folder (the Swift package root).

```bash
cd GeometryCore

# Swift package + Swift C++ interop smoke tests
swift test

# Full C++ test suite, built by SwiftPM as an executable target
swift run geometry_tests
```

---

## Current status — v5 disk-chart core (in progress)

- `CONTRACT.md` is v5 (disk charts on S³, variable chart radii, unified diffuse+specular material).
- GeometryCore C++ and Swift APIs are v4:
  - `seed(radius)`, `add(radius, from, M, safe)`
  - `addObject(chartId, kind, a, b, c, colorIdx)`
  - `addLight(...)`, `addMaterial(...)`
  - `Mobius::applyChartPoint`, `Mobius::applySurface`
- Old public `Mobius::apply` / `applySphere` / `applyPlane` APIs removed from the header; internal Poincaré helpers remain private.
- `tracer.metal` updated to v4 disk-chart intersection/reflection (needs Xcode compile verification).
- Current tests:
  - `swift test` → 3 passed
  - `swift run geometry_tests` → 149 passed

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
- **Swift reaches C++ through the `GeometryCore` Swift package using C++ interop** — the API surface is `geo::Atlas` and the shared `geo::` packet structs; the packet is an immutable byte snapshot (`packetBytes()`).

### Bugs found & fixed by the tests

1. **H³ distance used `acos` instead of `acosh`** — `cosh(d) = −⟨a,b⟩`, so it must be `acosh`. Added `mhAcosh` to `Math.h`; fixed `Hyperboloid.h::distance`.
2. **`applySphere` produced NaN at the projection point** (S³) — when a sampled sphere point maps to infinity. Now detects non-finite samples and falls back to the plane representation.

### Test status

`geometry_tests`: **80 checks, all passing.**

---

## Phase 2 — completed ✅

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

### 2.4 Swift-facing C++ API (`CONTRACT.md` §6)

`geo::Atlas` (`start` / `seed` / `add` / `link` / `addObject` / `addMaterial` / `setCamera` / `setControls` / `build` / `packetBytes` / `packetSize`). Single internal `Atlas`; snapshot is valid until the next build; errors returned as codes. The original pure-C `CCApi.h` / `CCApi.cpp` were removed when the Swift package moved to direct C++ interop.

### 2.5 Phase-2 tests (`test_atlas.cpp` + extend `test_intersect.cpp`)

- Intersect: hit/miss/tangent/plane/inversion cases.
- Atlas: seed+link, cocycle valid vs injected-invalid (must reject), island rejection, flatten **path-independence** (same chart reached via different safe paths ⇒ identical packet), **two-chart scene == direct camera-chart scene**, S³ antipode renders without NaN.
- Packet: `static_assert`s + end-to-end build via `geo::Atlas` and byte-layout verification.

### What was built

| File | Purpose |
|---|---|
| `Sources/include/GeometryCore/Intersect.h` | Shared with MSL. `raySphere`, `rayPlane`, `invertSphere`, `reflectPlane`. |
| `Sources/include/GeometryCore/Scene.h` | Shared with MSL. POD packet structs, `GEO_CONTRACT_VERSION`, size `static_assert`s. |
| `Sources/include/GeometryCore/Chart.h` + `Sources/src/Chart.cpp` | Host-only `Atlas`, chart graph, cocycle validation, flattening, packet emission. |
| `Mobius.h` / `Mobius.cpp` | Added `applyPlane` and robust H3 sphere sampling (inside the unit ball). |
| `Tests/Cpp/test_intersect.cpp`, `test_atlas.cpp`, `test_mobius.cpp` | Filled Phase-2 suites. |

**Test status:** `geometry_tests` — **217 checks, all passing.**

### 2.6 Swift package + C++ interop proof

`GeometryCore/Package.swift` exposes `GeometryCore` as a Swift Package Manager C++ target (`Sources`). The Swift test target (`Tests/SwiftGeometryCoreTests`) imports it directly with Swift C++ interop.

- C++ target sources: `Sources/src/Mobius.cpp`, `Sources/src/Chart.cpp`; public headers under `Sources/include/GeometryCore`.
- `Atlas::start` added as the Swift-visible alias for `begin` (Swift C++ interop reserves `begin` as a C++ iterator method).
- `Atlas::packetBytes()` / `Atlas::packetSize()` expose the built packet to Swift (Swift hides `packet()` because it returns a C++ reference).
- `swift test` verifies packet struct sizes via `MemoryLayout`, builds a scene, and reads packet bytes.
- `swift run geometry_tests` runs the full 217-check C++ test suite through SwiftPM.

**Container note:** `swift test` requires a clang that accepts `-index-store-path`; in this container `/usr/bin/clang` and `/usr/bin/clang++` are symlinked to `clang-21`.

### Acceptance criteria for Phase 2

- `swift run geometry_tests` green, including cocycle/island/NaN guards and flatten correctness.
- A scene authored in two charts flattens identically to the same scene authored directly in the camera chart.
- The produced `ScenePacket` byte layout matches `CONTRACT.md` §5 exactly (asserted, not assumed).

---

## Phase 3 — lighting v3 (historical)

- Contract bumped to `GEO_CONTRACT_VERSION = 3`.
- Packet added `lights[]` (`PointLight`: 32 bytes) after `materials[]`; `Counts.lightCount` added.
- `Atlas::addLight(chartId, position, color, intensity)` authored point lights in any chart.
- `MAX_LIGHTS = 16`.

## Phase 4 — v4 disk charts (current)

- Contract bumped to `GEO_CONTRACT_VERSION = 4`.
- Charts are open disks on S³ with variable radius.
- Objects are hyperplane sections `a·x + b·sqrt(1-|x|²) = c`.
- C++ GeometryCore and Swift API implemented.
- Remaining: `tracer.metal` v4 intersection/reflection, then reference tracer and goldens.

### Not started

- `Tools/ReferenceTracer`: chart-native CPU tracer (straight rays + unfold-the-world inversion) → PNG; model-space cross-check tracer must agree.
- Golden images (H³ single-chart, H³ multi-chart, S³ antipode) + macOS CI CPU/GPU diff.
- Off-center camera (Möbius view transform).
