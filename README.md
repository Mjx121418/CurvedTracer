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

## Scenes

### Hyperbolic honeycomb

A cell of the honeycomb {4,3,5} is a hyperbolic cube.
The faces of the cube are treated as mirrors.
A ball is placed at the center of the cube.

![Hyperbolic {4,3,5} honeycomb scene](<Images/{4,3,5}.png>)

### Euclidean 3-torus

A 3-torus can be contructed by identifying the three pairs of faces of a cube.
Three balls are put into the 3-torus.
Rays wrap continuously through identified faces.

![Euclidean cubic 3-torus scene](<Images/T^3.png>)

## Camera controls

Press **Tab** to enable or disable camera control. While it is enabled, the
cursor is hidden and the following controls are active:

- **Mouse**: look left, right, up, or down.
- **W / S**: move forward or backward.
- **A / D**: move left or right.
- **R / F**: move up or down.
- **Q / E**: roll left or right.
- **Arrow keys**: turn left or right and look up or down.

Movement and rotation use the camera's current local frame.
In GPU-atlas quotient scenes, camera movement passes continuously through portal faces.

## Build and test GeometryCore

```sh
cd GeometryCore
swift test
swift run geometry_tests
```

The macOS app requires Metal 4 and can be opened through `CurvedTracer/CurvedTracer.xcodeproj`.
The UI exposes all six space/traversal combinations.

See [CONTRACT.md](CONTRACT.md) for packet layouts and geometry conventions.

## Acknowledgements

Most of the code in this project was written by AI models, specifically ChatGPT 5.6 Sol and DeepSeek-V4-Pro, under human direction and review.
