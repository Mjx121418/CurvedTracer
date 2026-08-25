# CurvedTracer

CurvedTracer is a Metal ray tracer for three-dimensional spherical, hyperbolic,
and Euclidean geometry. Every scene is chart based: its camera, objects, and
lights are placed in coordinate domains of the appropriate native model:

- **S³** — the unit sphere in Euclidean R⁴;
- **H³** — the future unit hyperboloid in Lorentz R³,¹;
- **R³** — homogeneous points `(x,y,z,1)`.

Charts are connected by isometries that transport points, tangent vectors, and
the camera between local domains. Quotient spaces are realized by providing a
correct atlas: fundamental domains are represented by charts, identified
boundary surfaces become paired portals, and each portal carries the required
transition isometry. A ray crossing a portal continues in the corresponding
chart without introducing an artificial boundary in the represented space.

`GeometryCore` constructs and validates these chart graphs and encodes them for
the Metal tracer. The renderer therefore uses the same chart representation for
ordinary curved scenes, multi-chart covers, and quotient spaces.

## Scenes

### Primitive galleries

The selectable S³ and H³ galleries demonstrate truncated spherical surfaces,
geodesic triangles cut out by three half-spaces, reflective plane patches, and
homogeneous quadrics.

### Hopf fibration

The S³ Hopf-fibration scene places a thin tube around each of the 20 great-circle
fibers over the vertices of a regular dodecahedron in S². The fibers are split
between overlapping antipodal charts so every circle is rendered completely.

![Hopf fibration](<Images/Hopf.png>)

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
