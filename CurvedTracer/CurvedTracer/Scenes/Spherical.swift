//
//  Spherical.swift
//  CurvedTracer
//

import Foundation
import GeometryCore

enum SphericalScene {
    private struct Vertex4 {
        let x: Float
        let y: Float
        let z: Float
        let w: Float
    }

    private static func addBall(_ atlas: inout geo.Atlas, chart: Int32,
                                _ v: Vertex4, cosRadius: Float, color: Int32) {
        _ = atlas.addObject(chart, 0, geo.vec3(v.x, v.y, v.z), v.w, cosRadius, color)
    }

    /// Builds the two-chart S³ test scene.
    ///
    /// The two charts are centered at antipodal points and use a very large
    /// radius (0.97π) so each camera chart can almost see the antipodal point.
    /// Balls sit at the 24 vertices of a 24-cell; one vertex is at the origin of
    /// each chart. Point lights are placed in the large gaps between balls.
    @discardableResult
    static func cell24(_ atlas: inout geo.Atlas) -> Int32 {
        let radius: Float = Float.pi * 0.97
        let ballCos: Float = 0.98   // ball geodesic radius 0.25

        atlas.start(1)   // S³
        _ = atlas.seed(radius)

        // Rotation by π in the x-w plane maps e4 to -e4, so chart 1 is centered
        // at the antipodal point of chart 0.
        let toAntipode: [Float] = [
            -1, 0, 0, 0,
             0, 1, 0, 0,
             0, 0, 1, 0,
             0, 0, 0, -1,
        ]
        _ = atlas.add(radius, 0, toAntipode, true)

        // Materials: the three canonical 24-cell vertex colors.
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 0.0, 1.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))

        let signs: [Float] = [-0.5, 0.5]

        // Chart 0: origin ball plus the 11 other 24-cell vertices with w >= 0.
        var chart0Vertices: [Vertex4] = []
        chart0Vertices.append(Vertex4(x: 0, y: 0, z: 0, w: 1))
        chart0Vertices.append(Vertex4(x: 1, y: 0, z: 0, w: 0))
        chart0Vertices.append(Vertex4(x: 0, y: 1, z: 0, w: 0))
        chart0Vertices.append(Vertex4(x: 0, y: 0, z: 1, w: 0))
        for sx in signs {
            for sy in signs {
                for sz in signs {
                    chart0Vertices.append(Vertex4(x: sx, y: sy, z: sz, w: 0.5))
                }
            }
        }

        // Chart 1: origin ball plus the 11 other vertices with w < 0, expressed
        // in chart-1 coordinates by applying the antipodal transition.
        var chart1Vertices: [Vertex4] = []
        chart1Vertices.append(Vertex4(x: 0, y: 0, z: 0, w: 1))
        chart1Vertices.append(Vertex4(x: 1, y: 0, z: 0, w: 0))
        chart1Vertices.append(Vertex4(x: 0, y: -1, z: 0, w: 0))
        chart1Vertices.append(Vertex4(x: 0, y: 0, z: -1, w: 0))
        for sx in signs {
            for sy in signs {
                for sz in signs {
                    chart1Vertices.append(Vertex4(x: -sx, y: sy, z: sz, w: 0.5))
                }
            }
        }

        // Canonical 24-cell 3-coloring:
        //   color 0: signed basis vectors
        //   color 1: half-vertices with even negative-sign parity
        //   color 2: half-vertices with odd negative-sign parity
        for v in chart0Vertices {
            var color: Int32 = 0
            if v.w == 0.5 {
                let negatives = (v.x < 0 ? 1 : 0)
                              + (v.y < 0 ? 1 : 0)
                              + (v.z < 0 ? 1 : 0)
                color = (negatives % 2 == 0) ? 1 : 2
            }
            addBall(&atlas, chart: 0, v, cosRadius: ballCos, color: color)
        }
        for v in chart1Vertices {
            var color: Int32 = 0
            if v.w == 0.5 {
                // Recover the original chart-0 sign pattern. For a chart-1
                // half-vertex v = (-sx, sy, sz, 0.5), the original was
                // (sx, sy, sz, -0.5), so the original sx is negative when
                // v.x > 0, and the original w was always negative.
                let negatives = (v.x > 0 ? 1 : 0)
                              + (v.y < 0 ? 1 : 0)
                              + (v.z < 0 ? 1 : 0)
                              + 1
                color = (negatives % 2 == 0) ? 1 : 2
            }
            addBall(&atlas, chart: 1, v, cosRadius: ballCos, color: color)
        }

        // Lights sit at the centers of 8 of the 24 cells. The 24 cell centers
        // are the vertices of the dual 24-cell; applying the same 3-coloring
        // method to that dual picks one symmetric color class. For the matching
        // {01, 23} the chosen centers are (±1/√2, ±1/√2, 0, 0) and
        // (0, 0, ±1/√2, ±1/√2).
        let invSqrt2: Float = 0.7071068
        _ = atlas.addLight(0, geo.vec3(-invSqrt2, -invSqrt2, 0), 0,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        //_ = atlas.addLight(0, geo.vec3(-invSqrt2,  invSqrt2, 0), 0,
        //                   geo.vec3(0.60, 0.70, 1.00), 0.6)
        _ = atlas.addLight(0, geo.vec3(0, 0, -invSqrt2), invSqrt2,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        //_ = atlas.addLight(0, geo.vec3(0, 0,  invSqrt2), invSqrt2,
        //                   geo.vec3(0.60, 0.70, 1.00), 0.6)

        _ = atlas.addLight(1, geo.vec3(-invSqrt2, -invSqrt2, 0), 0,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        //_ = atlas.addLight(1, geo.vec3(-invSqrt2,  invSqrt2, 0), 0,
        //                   geo.vec3(0.60, 0.70, 1.00), 0.6)
        _ = atlas.addLight(1, geo.vec3(0, 0, -invSqrt2), invSqrt2,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        //_ = atlas.addLight(1, geo.vec3(0, 0,  invSqrt2), invSqrt2,
        //                   geo.vec3(0.60, 0.70, 1.00), 0.6)

        atlas.setCamera(
            1.0,
            16.0 / 9.0,
            geo.vec3(1, 0, 0),
            geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1)
        )

        atlas.setControls(
            6,
            0.05,
            0.25,
            0.95,
            2.0,
            0.0,
            0.6
        )

        // Put the camera at the center of a 24-cell cell (dual vertex),
        // not at a 24-cell vertex.
        let cameraChart = atlas.cameraChartAt(0, geo.vec3(invSqrt2, 0, 0),
                                               invSqrt2, radius)
        let result = atlas.build(cameraChart, 64)
        if result != 0 {
            fatalError("build failed with code \(result)")
        }
        return cameraChart
    }

    // MARK: - 600-cell scene

    private static func dot(_ a: Vertex4, _ b: Vertex4) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    }

    private static func quaternionMultiply(_ a: Vertex4, _ b: Vertex4) -> Vertex4 {
        Vertex4(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    private static func quaternionConjugate(_ q: Vertex4) -> Vertex4 {
        Vertex4(x: -q.x, y: -q.y, z: -q.z, w: q.w)
    }

    private static func leftQuaternionFrame(_ q: Vertex4) -> [Float] {
        var m = [Float](repeating: 0, count: 16)
        m[0] = q.w
        m[1] = q.z
        m[2] = -q.y
        m[3] = -q.x
        m[4] = -q.z
        m[5] = q.w
        m[6] = q.x
        m[7] = -q.y
        m[8] = q.y
        m[9] = -q.x
        m[10] = q.w
        m[11] = -q.z
        m[12] = q.x
        m[13] = q.y
        m[14] = q.z
        m[15] = q.w
        return m
    }

    /// Transition matrix mapping chart coordinates at a 24-cell vertex `a` to
    /// chart coordinates at a 24-cell vertex `b`.
    ///
    /// The chart centered at a unit quaternion `c` uses the orthonormal frame
    /// `q -> c q` (left quaternion multiplication). Its local origin is the
    /// quaternion identity and maps to `c`.
    private static func transition(from a: Vertex4, to b: Vertex4) -> [Float] {
        leftQuaternionFrame(quaternionMultiply(quaternionConjugate(b), a))
    }

    private static func make24CellVertices() -> [Vertex4] {
        var vertices: [Vertex4] = []

        // Signed basis vectors (±1, 0, 0, 0).
        for axis in 0..<4 {
            for sign in [Float(-1.0), Float(1.0)] {
                switch axis {
                case 0:
                    vertices.append(Vertex4(x: sign, y: 0, z: 0, w: 0))
                case 1:
                    vertices.append(Vertex4(x: 0, y: sign, z: 0, w: 0))
                case 2:
                    vertices.append(Vertex4(x: 0, y: 0, z: sign, w: 0))
                default:
                    vertices.append(Vertex4(x: 0, y: 0, z: 0, w: sign))
                }
            }
        }

        // Half-vectors (±1/2, ±1/2, ±1/2, ±1/2).
        for sx in [Float(-0.5), Float(0.5)] {
            for sy in [Float(-0.5), Float(0.5)] {
                for sz in [Float(-0.5), Float(0.5)] {
                    for sw in [Float(-0.5), Float(0.5)] {
                        vertices.append(Vertex4(x: sx, y: sy, z: sz, w: sw))
                    }
                }
            }
        }

        // Put the quaternion identity (0,0,0,1) first; it becomes chart 0.
        vertices.sort { $0.w > $1.w }
        return vertices
    }

    private static func make24CellAdjacency(_ vertices: [Vertex4]) -> [[Int]] {
        var adjacency = [[Int]](repeating: [], count: vertices.count)
        for i in 0..<vertices.count {
            for j in (i + 1)..<vertices.count {
                let d = dot(vertices[i], vertices[j])
                if d > 0.49 && d < 0.51 {
                    adjacency[i].append(j)
                    adjacency[j].append(i)
                }
            }
        }
        return adjacency
    }

    /// Four neighbors of the identity vertex, one from each of the four
    /// non-binary-tetrahedral right cosets of the 600-cell vertices. This is
    /// the coset choice that makes the 24 charts' five balls exactly the 120
    /// vertices of the 600-cell with no duplicates.
    private static func cell600NeighborReps() -> [Vertex4] {
        [
            Vertex4(x: -0.3090169944, y: 0.0, z: -0.5, w: 0.8090169944),
            Vertex4(x: -0.5, y: 0.3090169944, z: 0.0, w: 0.8090169944),
            Vertex4(x: -0.5, y: -0.3090169944, z: 0.0, w: 0.8090169944),
            Vertex4(x: -0.3090169944, y: 0.0, z: 0.5, w: 0.8090169944)
        ]
    }

    /// Builds the 24-chart S³ scene whose balls sit at the 120 vertices of a
    /// 600-cell.
    ///
    /// The 24 charts are centered at the vertices of the inscribed 24-cell and
    /// are linked exactly according to the 24-cell graph. Every chart contains
    /// the same five local balls: one at the origin and four at 600-cell
    /// vertices adjacent to the origin, one chosen from each right coset of the
    /// binary-tetrahedral subgroup. Globally the 24 × 5 balls are the 120
    /// vertices of the 600-cell.
    @discardableResult
    static func cell600(_ atlas: inout geo.Atlas) -> Int32 {
        let radius: Float = Float.pi / 2
        let ballCos: Float = 0.995
        let cameraRadius: Float = Float.pi * 0.9

        atlas.start(1)   // S³
        let baseChart = atlas.seed(radius)

        // Five materials, one per local ball position/color.
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 0.0, 1.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(1.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 1.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))

        let centers = make24CellVertices()
        let adjacency = make24CellAdjacency(centers)

        // Create the charts along a spanning tree of the 24-cell graph, then
        // link the remaining edges so the atlas graph is exactly the 24-cell.
        var chartIDs = [Int32](repeating: -1, count: centers.count)
        chartIDs[0] = baseChart
        var queue = [0]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for neighbor in adjacency[current] where chartIDs[neighbor] < 0 {
                let m = transition(from: centers[current], to: centers[neighbor])
                let id = atlas.add(radius, chartIDs[current], m, true)
                chartIDs[neighbor] = id
                queue.append(neighbor)
            }
        }

        for i in 0..<centers.count {
            for neighbor in adjacency[i] where neighbor > i {
                let m = transition(from: centers[i], to: centers[neighbor])
                atlas.link(chartIDs[i], chartIDs[neighbor], m, true)
            }
        }

        // Author the same five local balls in every chart.
        let origin = Vertex4(x: 0, y: 0, z: 0, w: 1)
        let neighbors = cell600NeighborReps()
        for chartID in chartIDs {
            addBall(&atlas, chart: chartID, origin, cosRadius: ballCos, color: 0)
            for (colorIndex, neighbor) in neighbors.enumerated() {
                addBall(&atlas, chart: chartID, neighbor,
                        cosRadius: ballCos, color: Int32(colorIndex + 1))
            }
        }

        // One point light at the same local tetrahedral-cell-center position
        // in 4 charts chosen as symmetrically as possible: the positive
        // basis-vertex charts {e1, e2, e3, e4}, which form a regular
        // tetrahedron inside the 16-cell formed by the 8 basis vertices of
        // the 24-cell.
        let lightPosition = geo.vec3(0.2185080122, 0.2185080122, -0.2185080122)
        let lightColor = geo.vec3(1.00, 0.95, 0.80)
        for (index, center) in centers.enumerated() {
            let axisSum = abs(center.x) + abs(center.y) + abs(center.z) + abs(center.w)
            let isPositiveBasis = center.x > 0.9 || center.y > 0.9
                               || center.z > 0.9 || center.w > 0.9
            if axisSum > 0.9 && axisSum < 1.1 && isPositiveBasis {
                _ = atlas.addLight(chartIDs[index], lightPosition, lightColor, 1.0)
            }
        }

        atlas.setCamera(
            1.0,
            16.0 / 9.0,
            geo.vec3(1, 0, 0),
            geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1)
        )

        atlas.setControls(
            6,
            0.05,
            0.25,
            0.95,
            2.0,
            0.0,
            0.0
        )

        // Put the camera at the center of a tetrahedral 600-cell cell instead
        // of at a ball position.
        let cameraChart = atlas.cameraChartAt(
            0,
            geo.vec3(0.2185080122, 0.2185080122, -0.2185080122),
            cameraRadius
        )
        let result = atlas.build(cameraChart, 64)
        if result != 0 {
            fatalError("build failed with code \(result)")
        }
        return cameraChart
    }

    /// Builds the two-chart S³ test scene whose balls sit at the 8 vertices of
    /// a 16-cell. Each antipodal pair has its own material color. Two lights are
    /// placed at antipodal cell centers.
    @discardableResult
    static func cell16(_ atlas: inout geo.Atlas) -> Int32 {
        let radius: Float = Float.pi * 0.97
        let ballCos: Float = 0.98

        atlas.start(1)   // S³
        _ = atlas.seed(radius)

        let toAntipode: [Float] = [
            -1, 0, 0, 0,
             0, 1, 0, 0,
             0, 0, 1, 0,
             0, 0, 0, -1,
        ]
        _ = atlas.add(radius, 0, toAntipode, true)

        // One color for each antipodal vertex pair.
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 0.0, 1.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(1.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))

        // Chart 0: e4 and the three equatorial vertices with positive chart
        // coordinate axes.
        addBall(&atlas, chart: 0, Vertex4(x: 0, y: 0, z: 0, w: 1),
                cosRadius: ballCos, color: 3)
        addBall(&atlas, chart: 0, Vertex4(x: 1, y: 0, z: 0, w: 0),
                cosRadius: ballCos, color: 0)
        addBall(&atlas, chart: 0, Vertex4(x: 0, y: 1, z: 0, w: 0),
                cosRadius: ballCos, color: 1)
        addBall(&atlas, chart: 0, Vertex4(x: 0, y: 0, z: 1, w: 0),
                cosRadius: ballCos, color: 2)

        // Chart 1: -e4 (its origin) and the opposite equatorial vertices.
        addBall(&atlas, chart: 1, Vertex4(x: 0, y: 0, z: 0, w: 1),
                cosRadius: ballCos, color: 3)
        addBall(&atlas, chart: 1, Vertex4(x: 1, y: 0, z: 0, w: 0),
                cosRadius: ballCos, color: 0)
        addBall(&atlas, chart: 1, Vertex4(x: 0, y: -1, z: 0, w: 0),
                cosRadius: ballCos, color: 1)
        addBall(&atlas, chart: 1, Vertex4(x: 0, y: 0, z: -1, w: 0),
                cosRadius: ballCos, color: 2)

        // Two antipodal cell centers of the dual tesseract.
        _ = atlas.addLight(0, geo.vec3( 0.5,  0.5,  0.5), 0.5,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        _ = atlas.addLight(1, geo.vec3( 0.5, -0.5, -0.5), 0.5,
                           geo.vec3(0.60, 0.70, 1.00), 0.6)

        atlas.setCamera(
            1.0,
            16.0 / 9.0,
            geo.vec3(1, 0, 0),
            geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1)
        )

        atlas.setControls(
            6,
            0.05,
            0.25,
            0.95,
            2.0,
            0.0,
            0.6
        )

        // Put the camera at the center of a 16-cell tetrahedral cell,
        // not at a 16-cell vertex.
        let cameraChart = atlas.cameraChartAt(0, geo.vec3(0.5, 0.5, 0.5),
                                               0.5, radius)
        let result = atlas.build(cameraChart, 64)
        if result != 0 {
            fatalError("build failed with code \(result)")
        }
        return cameraChart
    }

    /// Single-chart S³ scene analogous to `HyperbolicScene.configure`.
    ///
    /// The chart radius is larger than π/2. A totally geodesic mirror sits at
    /// distance π/2 from the origin (the equator, w = 0), and the balls all lie
    /// in the w > 0 hemisphere containing the chart origin.
    @discardableResult
    static func configure(_ atlas: inout geo.Atlas) -> Int32 {
        let radius: Float = Float.pi * 0.99
        let ballCos: Float = 0.98

        atlas.start(1)   // S³
        _ = atlas.seed(radius)

        // Materials: red, green, blue, yellow, mirror.
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.0, 0.0, 1.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(1.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        // Mirror material: dark reflection so mirrored images are much dimmer
        // than the real balls.
        _ = atlas.addMaterial(geo.vec4(0.3, 0.3, 0.3, 1.0), geo.vec4(0.7, 0.7, 0.7, 0.7))

        // Totally geodesic mirror at distance π/2: the equator w = 0.
        _ = atlas.addObject(0, 1, geo.vec3(0, 0, 0), 1.0, 0.0, 4)

        // Four sparse balls in the w > 0 hemisphere. They sit at the corners
        // of a regular tetrahedron-like cross: pairwise angular separations are
        // 60° or 90°, much larger than the ball diameter (~29°).
        let s: Float = 0.7071068   // 1/√2
        _ = atlas.addObject(0, 0, geo.vec3( s, 0, 0), s, ballCos, 0)
        _ = atlas.addObject(0, 0, geo.vec3(-s, 0, 0), s, ballCos, 1)
        _ = atlas.addObject(0, 0, geo.vec3( 0, s, 0), s, ballCos, 2)
        _ = atlas.addObject(0, 0, geo.vec3( 0, 0, s), s, ballCos, 3)

        // Two lights in the w > 0 hemisphere, outside all balls.
        _ = atlas.addLight(0, geo.vec3(-0.2912, 0.4518, -0.7110), 0.4533,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        _ = atlas.addLight(0, geo.vec3( 0.3734,-0.7632, 0.2809), 0.4463,
                           geo.vec3(0.60, 0.70, 1.00), 0.6)

        atlas.setCamera(
            1.0,
            16.0 / 9.0,
            geo.vec3(1, 0, 0),
            geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1)
        )

        atlas.setControls(
            6,
            0.05,
            0.25,
            0.95,
            2.0,
            0.0,
            0.0
        )

        let cameraChart = atlas.cameraChartAt(0, geo.vec3(0, 0, 0), radius)
        let result = atlas.build(cameraChart, 64)
        if result != 0 {
            fatalError("build failed with code \(result)")
        }
        return cameraChart
    }
}
