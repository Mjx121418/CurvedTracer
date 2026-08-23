# CurvedTracer

CurvedTracer is a Metal ray tracer for the three simply connected unit space
forms. Geometry is authored directly in its native model:

- **S³** — the unit sphere in Euclidean R⁴;
- **H³** — the future unit hyperboloid in Lorentz R³,¹;
- **R³** — homogeneous points `(x,y,z,1)`.

`GeometryCore` owns chart validation, isometries, camera transport, quotient
portals, and the version-10 GPU packet. Both CPU-flattened and authored-atlas
rendering consume that same packet and the same `raytrace` Metal kernel. At app
startup Metal compiles six specializations (three space forms, with portal
traversal on or off).

## Build and test GeometryCore

```sh
cd GeometryCore
swift test
swift run geometry_tests
```

The macOS app requires Metal 4 and can be opened through
`CurvedTracer/CurvedTracer.xcodeproj`. The UI exposes all six space/traversal
combinations. The authored R³ scene is a cubic 3-torus whose camera and rays
wrap continuously through three opposite-face translation pairings.

See [CONTRACT.md](CONTRACT.md) for packet layouts and geometry conventions.
