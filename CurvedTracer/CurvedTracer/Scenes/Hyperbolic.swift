import Foundation
import GeometryCore

enum HyperbolicScene {
    private static func pointFromKlein(_ atlas: inout geo.Atlas, _ point: SIMD3<Float>) -> geo.vec4 {
        let magnitude = sqrt(point.x * point.x + point.y * point.y + point.z * point.z)
        if magnitude == 0 { return geo.vec4(0, 0, 0, 1) }
        let scale = atanh(magnitude) / magnitude
        return atlas.pointFromOriginTangent(
            geo.vec3(point.x * scale, point.y * scale, point.z * scale))
    }

    private static func addPoincareBall(
        _ atlas: inout geo.Atlas,
        chart: Int32 = 0,
        center: SIMD3<Float>,
        radius: Float,
        material: Int32
    ) {
        let centerMagnitude = sqrt(
            center.x * center.x + center.y * center.y + center.z * center.z)
        precondition(radius > 0 && centerMagnitude + radius < 1)

        // The radial endpoints of the Euclidean Poincare sphere determine its
        // intrinsic center and radius. The signed near endpoint also handles a
        // sphere containing the Poincare origin.
        let nearEndpoint = centerMagnitude - radius
        let farEndpoint = centerMagnitude + radius
        let centerDistance = atanh(farEndpoint) + atanh(nearEndpoint)
        let intrinsicRadius = atanh(farEndpoint) - atanh(nearEndpoint)
        let centerScale = centerMagnitude > 0 ? centerDistance / centerMagnitude : 0
        let centerPoint = atlas.pointFromOriginTangent(
            geo.vec3(
                center.x * centerScale,
                center.y * centerScale,
                center.z * centerScale))
        _ = atlas.addBall(chart, centerPoint, intrinsicRadius, material)
    }

    private static func intrinsicRadius(fromCompactAngle angle: Float) -> Float {
        atanh(sin(angle))
    }

    private static func multiply4(_ a: [Float], _ b: [Float]) -> [Float] {
        var r = [Float](repeating: 0, count: 16)
        for c in 0..<4 {
            for row in 0..<4 {
                for k in 0..<4 {
                    r[c * 4 + row] += a[k * 4 + row] * b[c * 4 + k]
                }
            }
        }
        return r
    }

    private static func identity() -> [Float] {
        [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    }
    private static func facePairing(_ u: SIMD3<Float>, distance: Float, twist: Float) -> [Float] {
        let c = cosh(distance)
        let s = sinh(distance)
        var boost: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        for col in 0..<3 {
            for row in 0..<3 {
                boost[col * 4 + row] += (c - 1) * u[row] * u[col]
            }
        }
        for i in 0..<3 {
            boost[12 + i] = s * u[i]
            boost[i * 4 + 3] = s * u[i]
        }
        boost[15] = c
        let ct = cos(twist)
        let st = sin(twist)
        let one = 1 - ct
        var rotation = [Float](repeating: 0, count: 16)
        rotation[15] = 1
        for col in 0..<3 {
            for row in 0..<3 {
                let delta: Float = row == col ? 1 : 0
                let cross: Float
                switch (row, col) {
                case (0, 1): cross = -u.z
                case (0, 2): cross = u.y
                case (1, 0): cross = u.z
                case (1, 2): cross = -u.x
                case (2, 0): cross = -u.y
                case (2, 1): cross = u.x
                default: cross = 0
                }
                rotation[col * 4 + row] = ct * delta + one * u[row] * u[col] + st * cross
            }
        }
        return multiply4(rotation, boost)
    }

    private static func addDiffuseMaterial(_ atlas: inout geo.Atlas, _ color: SIMD3<Float>) {
        _ = atlas.addMaterial(
            geo.vec4(color.x, color.y, color.z, 1), geo.vec4(0.3, 0.3, 0.3, 1))
    }

    private static func addMirrorMaterial(_ atlas: inout geo.Atlas) {
        _ = atlas.addMaterial(
            geo.vec4(0, 0.8, 0.9, 1), geo.vec4(0.45, 0.95, 1, 0.9))
    }

    private static func materials(_ atlas: inout geo.Atlas) {
        addDiffuseMaterial(&atlas, [0.95, 0.12, 0.08])
        addDiffuseMaterial(&atlas, [0.08, 0.55, 1])
        // Mirror material: cyan base tint plus a cyan-white reflected component.
        addMirrorMaterial(&atlas)
    }

    /// Builds the one-chart Poincaré-ball object and mirror demonstration.
    @discardableResult static func poincareBallDemo(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(0)
        _ = atlas.seed(intrinsicRadius(fromCompactAngle: Float.pi * 0.999 / 2))

        addDiffuseMaterial(&atlas, [1, 0, 0])
        addDiffuseMaterial(&atlas, [0, 1, 0])
        addDiffuseMaterial(&atlas, [0, 0, 1])
        addDiffuseMaterial(&atlas, [1, 1, 0])
        addDiffuseMaterial(&atlas, [0, 1, 1])
        addDiffuseMaterial(&atlas, [1, 0, 1])
        addMirrorMaterial(&atlas)
        addDiffuseMaterial(&atlas, [1, 0.5, 0])

        addPoincareBall(&atlas, center: [-0.05, 0, 0.10], radius: 0.06, material: 0)
        addPoincareBall(&atlas, center: [0.12, 0.04, 0.15], radius: 0.07, material: 1)
        addPoincareBall(&atlas, center: [-0.15, -0.06, 0.20], radius: 0.09, material: 2)
        addPoincareBall(&atlas, center: [-0.12, -0.08, -0.35], radius: 0.16, material: 5)
        addPoincareBall(&atlas, center: [0, 0, -0.45], radius: 0.18, material: 7)

        let mirrorDistance = atanh(Float(0.35))
        _ = atlas.addMirrorPlane(0, geo.vec3(0, -1, 0), mirrorDistance, 6)
        _ = atlas.addMirrorPlane(0, geo.vec3(0, 1, 0), mirrorDistance, 6)

        _ = atlas.addLight(
            0, pointFromKlein(&atlas, [0.30, 0.20, 0.10]), geo.vec3(1, 0.95, 0.80), 1)
        _ = atlas.addLight(
            0, pointFromKlein(&atlas, [-0.40, -0.20, 0.15]), geo.vec3(0.60, 0.70, 1), 0.5)

        atlas.setCamera(1, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
        atlas.setControls(6, 0.05, 0.25, 0.95, 2, 0, 0)
        let cameraPosition = pointFromKlein(&atlas, [0.2668035, 0.2668035, 0.2668035])
        let traceRadius = intrinsicRadius(fromCompactAngle: Float.pi * 0.99 / 2)
        let camera = atlas.cameraChartAt(0, cameraPosition, traceRadius)
        let result = atlas.build(camera, 64)
        if result != 0 { fatalError("H³ Poincaré-ball demo build failed: \(result)") }
        return camera
    }

    /// A curvature-small counterpart of the R³ path tracing room.
    @discardableResult static func pathTracingRoom(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(0)
        _ = atlas.seed(1.0)
        let white = atlas.addMaterial(
            geo.vec4(0.78, 0.78, 0.78, 1), geo.vec4(0, 0, 0, 0))
        let red = atlas.addMaterial(
            geo.vec4(0.78, 0.08, 0.05, 1), geo.vec4(0, 0, 0, 0))
        let green = atlas.addMaterial(
            geo.vec4(0.08, 0.68, 0.12, 1), geo.vec4(0, 0, 0, 0))
        let blue = atlas.addMaterial(
            geo.vec4(0.08, 0.28, 0.82, 1), geo.vec4(0, 0, 0, 0))
        let mirror = atlas.addMaterial(
            geo.vec4(0, 0, 0, 1), geo.vec4(0.92, 0.95, 1, 1))

        _ = atlas.addPlane(0, geo.vec3(1, 0, 0), -0.3, red, 0)
        _ = atlas.addPlane(0, geo.vec3(-1, 0, 0), -0.3, green, 0)
        _ = atlas.addPlane(0, geo.vec3(0, 1, 0), -0.3, white, 0)
        _ = atlas.addPlane(0, geo.vec3(0, -1, 0), -0.3, white, 0)
        _ = atlas.addPlane(0, geo.vec3(0, 0, -1), -0.45, white, 0)
        _ = atlas.addPlane(0, geo.vec3(0, 0, 1), -0.45, white, 0)
        _ = atlas.addBall(
            0, atlas.pointFromOriginTangent(geo.vec3(-0.114, -0.186, 0.06)),
            0.09, blue)
        _ = atlas.addBallSurface(
            0, atlas.pointFromOriginTangent(geo.vec3(0.12, -0.192, 0.135)),
            0.084, mirror, 1)
        _ = atlas.addLight(
            0, atlas.pointFromOriginTangent(geo.vec3(0, 0.216, -0.075)),
            geo.vec3(1, 0.92, 0.78), 18)

        atlas.setCamera(
            0.62, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0),
            geo.vec3(0, -0.08, 1))
        atlas.setControls(6, 3.9, 0.05, 0.95, 0, 0, 0)
        let camera = atlas.cameraChartAt(
            0, atlas.pointFromOriginTangent(geo.vec3(0, 0, -0.345)), 1.8)
        let result = atlas.build(camera, 64)
        if result != 0 { fatalError("H³ path tracing room build failed: \(result)") }
        return camera
    }

    /// Demonstrates clipped linear and quadratic surfaces in H³.
    @discardableResult static func primitiveGallery(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(0)
        _ = atlas.seed(3.0)
        addDiffuseMaterial(&atlas, [0.95, 0.16, 0.08])
        addDiffuseMaterial(&atlas, [0.10, 0.68, 1.0])
        addDiffuseMaterial(&atlas, [0.95, 0.72, 0.10])
        addMirrorMaterial(&atlas)

        let truncatedBall = atlas.addBallSurface(
            0, atlas.pointFromOriginTangent(geo.vec3(-0.45, -0.12, 0.38)),
            0.32, 0, 0)
        if truncatedBall < 0
            || atlas.addObjectClipPlane(truncatedBall, geo.vec3(1, 0, 0), 0.25) < 0
        {
            fatalError("invalid clipped H³ ball")
        }

        let triangle = atlas.addPlane(0, geo.vec3(0, 0, 1), 0.82, 1, 0)
        let triangleDirections: [geo.vec3] = [
            geo.vec3(1, 0, 0),
            geo.vec3(-0.5, 0.8660254, 0),
            geo.vec3(-0.5, -0.8660254, 0),
        ]
        if triangle < 0
            || triangleDirections.contains(where: {
                atlas.addObjectClipPlane(triangle, $0, 0.5) < 0
            })
        {
            fatalError("invalid clipped H³ triangle")
        }

        var quadric = [Float](repeating: 0, count: 16)
        quadric[0] = 1.0
        quadric[5] = 1.6
        quadric[10] = 0.7
        quadric[15] = -0.22
        let quadricPatch = atlas.addQuadric(0, quadric, 2, 0)
        if quadricPatch < 0
            || atlas.addObjectClipPlane(quadricPatch, geo.vec3(-1, 0, 0), 0.7) < 0
        {
            fatalError("invalid H³ quadric patch")
        }

        // A spacelike ambient normal with a nonzero level gives an
        // equidistant hypersurface rather than a totally geodesic plane.
        let mirrorPatch = atlas.addLinearSurface(
            0, geo.vec4(0, -1, 0, 0), sinh(Float(0.95)), 3, 1)
        if mirrorPatch < 0
            || atlas.addObjectClipPlane(mirrorPatch, geo.vec3(1, 0, 0), 0.65) < 0
            || atlas.addObjectClipPlane(mirrorPatch, geo.vec3(-1, 0, 0), 0.65) < 0
        {
            fatalError("invalid reflective H³ plane patch")
        }

        _ = atlas.addLight(
            0, pointFromKlein(&atlas, [-0.25, 0.20, 0.12]),
            geo.vec3(1, 0.92, 0.75), 1)
        _ = atlas.addLight(
            0, pointFromKlein(&atlas, [0.22, -0.12, 0.32]),
            geo.vec3(0.48, 0.66, 1), 0.6)
        atlas.setCamera(
            0.82, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1))
        atlas.setControls(5, 0.05, 0.2, 0.92, 2, 0, 0)
        let camera = atlas.cameraChartAt(
            0, atlas.pointFromOriginTangent(geo.vec3(0, 0, -0.12)), 2.7)
        let result = atlas.build(camera, 64)
        if result != 0 { fatalError("H³ primitive gallery build failed: \(result)") }
        return camera
    }

    @discardableResult static func honeycombCell(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(0)
        _ = atlas.seed(intrinsicRadius(fromCompactAngle: Float.pi * 0.999 / 2))

        addDiffuseMaterial(&atlas, [1, 0, 0])
        _ = atlas.addMaterial(geo.vec4(0.1, 0.1, 0.1, 1), geo.vec4(1.0, 1.0, 1.0, 1.0))

        // The central sphere was encoded by w = 1 / 0.98 in the previous
        // compact-chart scene.
        let ballRadius = acosh(1 / Float(0.98))
        _ = atlas.addBall(0, geo.vec4(0, 0, 0, 1), ballRadius, 0)

        // Faces of the regular cubic cell of the {4,3,5} honeycomb. The previous
        // Klein-coordinate offset was 0.4858682717566457 = tanh(faceDistance).
        let faceDistance = atanh(Float(0.4858682717566457))
        for direction in [
            geo.vec3(1, 0, 0), geo.vec3(-1, 0, 0),
            geo.vec3(0, 1, 0), geo.vec3(0, -1, 0),
            geo.vec3(0, 0, 1), geo.vec3(0, 0, -1),
        ] {
            _ = atlas.addMirrorPlane(0, direction, faceDistance, 1)
        }

        let lightOffset: Float = 0.32
        let warm = geo.vec3(1, 0.95, 0.80)
        let cool = geo.vec3(0.60, 0.70, 1)
        for (position, color) in [
            (SIMD3<Float>(-lightOffset, 0, 0), warm),
            (SIMD3<Float>(lightOffset, 0, 0), cool),
            (SIMD3<Float>(0, -lightOffset, 0), warm),
            (SIMD3<Float>(0, lightOffset, 0), cool),
            (SIMD3<Float>(0, 0, -lightOffset), warm),
            (SIMD3<Float>(0, 0, lightOffset), cool),
        ] {
            _ = atlas.addLight(0, pointFromKlein(&atlas, position), color, 0.8)
        }

        atlas.setCamera(
            1,
            16.0 / 9.0,
            geo.vec3(-0.7071068, 0.7071068, 0),
            geo.vec3(-0.4082483, -0.4082483, 0.8164966),
            geo.vec3(0.5773503, 0.5773503, 0.5773503))
        atlas.setControls(10, 0.05, 0.25, 0.95, 2, 0, 0)

        let cameraPosition = pointFromKlein(&atlas, [0.2668035, 0.2668035, 0.2668035])
        let traceRadius: Float = 20
        let camera = atlas.cameraChartAt(0, cameraPosition, traceRadius)
        let result = atlas.build(camera, 64)
        if result != 0 { fatalError("H³ honeycomb build failed: \(result)") }
        return camera
    }

    @discardableResult static func seifertWeberAtlas(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(0)
        // The outward portal collar puts the dodecahedron vertices at an
        // intrinsic radius of about 1.969. Keep the chart ball beyond them so
        // its tracing horizon cannot win before a portal near an edge.
        let chartRadius: Float = 2.05
        _ = atlas.seed(chartRadius)
        materials(&atlas)
        let phi: Float = (1 + sqrt(5)) / 2
        let scale: Float = 1 / sqrt(1 + phi * phi)
        let dirs = [
            SIMD3<Float>(0, 1, phi), SIMD3<Float>(0, -1, phi), SIMD3<Float>(1, phi, 0),
            SIMD3<Float>(-1, phi, 0), SIMD3<Float>(phi, 0, 1), SIMD3<Float>(phi, 0, -1),
        ].map { $0 * scale }
        let q: Float = 1 / sqrt(5)
        let inradius = asinh(sqrt((q + cos(2 * Float.pi / 5)) / (1 - q)))
        for u in dirs {
            let m = facePairing(u, distance: 2 * inradius, twist: 3 * Float.pi / 5)
            if atlas.addPortalPair(
                0, geo.vec3(-u.x, -u.y, -u.z), inradius, 0, geo.vec3(u.x, u.y, u.z), inradius, m) < 0
            {
                fatalError("invalid Seifert-Weber portal")
            }
        }
        addPoincareBall(&atlas, center: [0.17, -0.10, 0.05], radius: 0.09, material: 0)
        addPoincareBall(&atlas, center: [-0.20, 0.075, 0.13], radius: 0.10, material: 1)
        _ = atlas.addLight(
            0, pointFromKlein(&atlas, [0.10, -0.12, 0.18]), geo.vec3(1, 0.92, 0.72), 0.75)
        atlas.setCamera(0.9, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
        // Match the previous exponential-fog strength across the accumulated
        // intrinsic path, including every portal hop.
        atlas.setControls(5, 0.04, 0.16, 0.9, 2, 0, 0.0)
        let camera = atlas.cameraChartAt(0, geo.vec4(0, 0, 0, 1), 3.5)
        let result = atlas.buildAtlas(camera, 64, 1, 32)
        if result != 0 { fatalError("H³ atlas build failed: \(result)") }
        return camera
    }

    /// A state-expanded Seifert-Weber atlas used to compare the one-chart
    /// quotient with a sparse multi-chart graph. Every chart has the same
    /// dodecahedral coordinates and scene contents. Face pairings move between
    /// chart states, while zero trigger displacement keeps crossings on the
    /// mathematical faces and avoids overlap between displaced face collars.
    @discardableResult static func seifertWeberMultiChartAtlas(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(0)
        let chartRadius: Float = 2.05
        _ = atlas.seed(chartRadius)

        let chartCount: Int32 = 14
        let chartIdentity = identity()
        for chart in 1..<chartCount {
            if atlas.addChart(chartRadius, 0, chartIdentity, true) != chart {
                fatalError("failed to add Seifert-Weber chart state")
            }
        }

        materials(&atlas)
        let phi: Float = (1 + sqrt(5)) / 2
        let scale: Float = 1 / sqrt(1 + phi * phi)
        let directions = [
            SIMD3<Float>(0, 1, phi), SIMD3<Float>(0, -1, phi), SIMD3<Float>(1, phi, 0),
            SIMD3<Float>(-1, phi, 0), SIMD3<Float>(phi, 0, 1), SIMD3<Float>(phi, 0, -1),
        ].map { $0 * scale }
        let q: Float = 1 / sqrt(5)
        let inradius = asinh(sqrt((q + cos(2 * Float.pi / 5)) / (1 - q)))

        // Each generator acts as a permutation of the chart states. Because
        // every state carries the same local geometry, the extra state is not
        // observable in the rendered quotient, but it exercises a nontrivial
        // GPU chart graph. Shift 1 makes the graph connected.
        let stateShifts: [Int32] = [1, 2, 3, 5, 7, 9]
        for (generator, u) in directions.enumerated() {
            let pairing = facePairing(u, distance: 2 * inradius, twist: 3 * Float.pi / 5)
            for chart in 0..<chartCount {
                let neighbor = (chart + stateShifts[generator]) % chartCount
                if atlas.addPortalPairWithCollar(
                    chart, geo.vec3(-u.x, -u.y, -u.z), inradius,
                    neighbor, geo.vec3(u.x, u.y, u.z), inradius,
                    pairing, 0) < 0
                {
                    fatalError("invalid multi-chart Seifert-Weber portal")
                }
            }
        }

        // Duplicate local scene data because any chart state can be active.
        // The objects remain far inside every true face, preserving the
        // object-free collar independently of trigger-plane displacement.
        for chart in 0..<chartCount {
            addPoincareBall(
                &atlas, chart: chart, center: [0.17, -0.10, 0.05], radius: 0.09, material: 0)
            addPoincareBall(
                &atlas, chart: chart, center: [-0.20, 0.075, 0.13], radius: 0.10, material: 1)
            _ = atlas.addLight(
                chart, pointFromKlein(&atlas, [0.10, -0.12, 0.18]),
                geo.vec3(1, 0.92, 0.72), 0.75)
        }

        atlas.setCamera(
            0.9, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
        atlas.setControls(5, 0.04, 0.16, 0.9, 2, 0, 0.0)
        let camera = atlas.cameraChartAt(0, geo.vec4(0, 0, 0, 1), 3.5)
        let result = atlas.buildAtlas(camera, 64, 1, 32)
        if result != 0 { fatalError("H³ multi-chart atlas build failed: \(result)") }
        return camera
    }
}
