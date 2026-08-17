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
        _ = atlas.addLight(0, geo.vec3(-invSqrt2,  invSqrt2, 0), 0,
                           geo.vec3(0.60, 0.70, 1.00), 0.6)
        _ = atlas.addLight(0, geo.vec3(0, 0, -invSqrt2), invSqrt2,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        _ = atlas.addLight(0, geo.vec3(0, 0,  invSqrt2), invSqrt2,
                           geo.vec3(0.60, 0.70, 1.00), 0.6)

        _ = atlas.addLight(1, geo.vec3(-invSqrt2, -invSqrt2, 0), 0,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        _ = atlas.addLight(1, geo.vec3(-invSqrt2,  invSqrt2, 0), 0,
                           geo.vec3(0.60, 0.70, 1.00), 0.6)
        _ = atlas.addLight(1, geo.vec3(0, 0, -invSqrt2), invSqrt2,
                           geo.vec3(1.00, 0.95, 0.80), 1.0)
        _ = atlas.addLight(1, geo.vec3(0, 0,  invSqrt2), invSqrt2,
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
            0.95
        )

        let cameraChart = atlas.cameraChartAt(0, geo.vec3(0, 0, 0), radius)
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
            0.95
        )

        let cameraChart = atlas.cameraChartAt(0, geo.vec3(0, 0, 0), radius)
        let result = atlas.build(cameraChart, 64)
        if result != 0 {
            fatalError("build failed with code \(result)")
        }
        return cameraChart
    }
}
