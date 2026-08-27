import Foundation
import GeometryCore

enum SphericalScene {
    // Preserve the original previews after normalizing point-light shading by 1/π.
    private static let previewPointLightScale = Float.pi

    private static func addPreviewMaterial(
        _ atlas: inout geo.Atlas,
        _ color: geo.vec4
    ) -> Int32 {
        atlas.addMaterial(
            color, 0.5, 0, 1.5, 0, geo.vec3(0, 0, 0))
    }

    private static func addLambertianMaterial(
        _ atlas: inout geo.Atlas,
        _ color: geo.vec4
    ) -> Int32 {
        atlas.addMaterial(
            color, 0, 0, 1.5, 0, geo.vec3(0, 0, 0))
    }

    private static func addMirrorMaterial(
        _ atlas: inout geo.Atlas,
        _ color: geo.vec4
    ) -> Int32 {
        atlas.addMaterial(
            color, 0, 1, 1.5, 0, geo.vec3(0, 0, 0))
    }

    private static let lensFaceDistance = Float.pi / 5
    private static let antipodalMatrix: [Float] = [
        -1, 0, 0, 0,
        0, -1, 0, 0,
        0, 0, -1, 0,
        0, 0, 0, -1,
    ]

    private static func cliffordTorusQuadric() -> [Float] {
        var quadric = [Float](repeating: 0, count: 16)
        quadric[2] = 0.5
        quadric[8] = 0.5
        quadric[7] = -0.5
        quadric[13] = -0.5
        return quadric
    }

    private static func orthogonalRingQuadrics(radius: Float) -> [[Float]] {
        let torus = cliffordTorusQuadric()
        let level = 0.5 * cos(2 * radius)
        return [Float(1), Float(-1)].map { circle in
            var tube = torus.map { -circle * $0 }
            for diagonal in [0, 5, 10, 15] {
                tube[diagonal] = level
            }
            return tube
        }
    }

    private static func dodecahedronVertices() -> [SIMD3<Float>] {
        let phi = (Float(1) + sqrt(5)) / 2
        let inversePhi = 1 / phi
        var vertices: [SIMD3<Float>] = []

        for x in [Float(-1), Float(1)] {
            for y in [Float(-1), Float(1)] {
                for z in [Float(-1), Float(1)] {
                    vertices.append(SIMD3<Float>(x, y, z))
                }
            }
        }
        for firstSign in [Float(-1), Float(1)] {
            for secondSign in [Float(-1), Float(1)] {
                vertices.append(
                    SIMD3<Float>(0, firstSign * inversePhi, secondSign * phi))
                vertices.append(
                    SIMD3<Float>(firstSign * inversePhi, secondSign * phi, 0))
                vertices.append(
                    SIMD3<Float>(firstSign * phi, 0, secondSign * inversePhi))
            }
        }
        return vertices.map { $0 / sqrt(3) }
    }

    // One of the two chiral compounds of five tetrahedra inscribed in the
    // dodecahedron. Icosahedral rotations permute these five vertex sets.
    private static let dodecahedronTetrahedra: [[Int]] = [
        [0, 3, 5, 6],
        [1, 8, 12, 19],
        [2, 9, 16, 17],
        [4, 10, 11, 18],
        [7, 13, 14, 15],
    ]

    private static func dodecahedronVertexMaterials() -> [Int32] {
        var materials = [Int32](repeating: -1, count: 20)
        for (material, tetrahedron) in dodecahedronTetrahedra.enumerated() {
            for vertex in tetrahedron {
                precondition(materials[vertex] < 0, "overlapping tetrahedra")
                materials[vertex] = Int32(material)
            }
        }
        precondition(
            materials.allSatisfy { $0 >= 0 },
            "incomplete tetrahedral compound")
        return materials
    }

    static func hopfFibrationCameraPlacement() -> (
        base: SIMD3<Float>, point: geo.vec4, centeredForward: geo.vec3
    ) {
        // (0, φ, 1) is a vertex of the dual icosahedron, hence the center
        // direction of one dodecahedron face.
        let phi = (Float(1) + sqrt(5)) / 2
        let base = SIMD3<Float>(0, phi, 1) / sqrt(phi * phi + 1)

        // Choose the lift with z₁ positive and real. Multiplication of both
        // complex coordinates by exp(it) traces the Hopf fiber, with ambient
        // tangent (w, -z, y, -x). At this lift, recentering the camera leaves
        // the tangent's xyz coordinates unchanged.
        let point = hopfLift(base)
        let centeredForward = geo.vec3(point.w, -point.z, point.y)
        return (base, point, centeredForward)
    }

    private static func hopfLift(_ base: SIMD3<Float>) -> geo.vec4 {
        let z1Real = sqrt((1 + base.z) / 2)
        return geo.vec4(
            0, base.x / (2 * z1Real), -base.y / (2 * z1Real), z1Real)
    }

    private static func s3FiberPoint(
        _ point: geo.vec4, _ tangent: geo.vec4, _ offset: Float
    ) -> geo.vec4 {
        let cosine = cos(offset)
        let sine = sin(offset)
        return geo.vec4(
            cosine * point.x + sine * tangent.x,
            cosine * point.y + sine * tangent.y,
            cosine * point.z + sine * tangent.z,
            cosine * point.w + sine * tangent.w)
    }

    /// For z₁ = w + ix and z₂ = y + iz, the Hopf map is
    ///
    ///   h(x,y,z,w) = (2(xz + yw), 2(xy - zw), x² + w² - y² - z²).
    ///
    /// The inverse image of a base point is a great circle. Its radius-r tube
    /// is the homogeneous quadric base·h(P) = cos(2r)|P|².
    private static func hopfFiberTubeQuadric(
        base: SIMD3<Float>, radius: Float
    ) -> [Float] {
        let level = cos(2 * radius)
        var quadric = [Float](repeating: 0, count: 16)
        for diagonal in [0, 5, 10, 15] {
            quadric[diagonal] = level
        }

        quadric[0] -= base.z
        quadric[5] += base.z
        quadric[10] += base.z
        quadric[15] -= base.z
        quadric[1] = -base.y
        quadric[4] = -base.y
        quadric[11] = base.y
        quadric[14] = base.y
        quadric[2] = -base.x
        quadric[8] = -base.x
        quadric[7] = -base.x
        quadric[13] = -base.x
        return quadric
    }

    // Column-major SO(4) frame that maps a point q to the identity. This
    // mirrors Atlas::movePointToOrigin while keeping the scene independent of
    // that private host-side helper.
    private static func s3MovePointToOrigin(_ point: geo.vec4) -> [Float] {
        let scale = -1 / max(1 + point.w, 1e-6)
        let u = SIMD3<Float>(point.x, point.y, point.z)
        let c0 = SIMD3<Float>(1, 0, 0) + u * (scale * u.x)
        let c1 = SIMD3<Float>(0, 1, 0) + u * (scale * u.y)
        let c2 = SIMD3<Float>(0, 0, 1) + u * (scale * u.z)
        return [
            c0.x, c0.y, c0.z, u.x,
            c1.x, c1.y, c1.z, u.y,
            c2.x, c2.y, c2.z, u.z,
            -u.x, -u.y, -u.z, point.w,
        ]
    }

    private static func matrixTranspose(_ matrix: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                result[row * 4 + column] = matrix[column * 4 + row]
            }
        }
        return result
    }

    private static func matrixProduct(
        _ left: [Float], _ right: [Float]
    ) -> [Float] {
        var result = [Float](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                for index in 0..<4 {
                    result[column * 4 + row] +=
                        left[index * 4 + row] * right[column * 4 + index]
                }
            }
        }
        return result
    }

    private static func matrixApply(
        _ matrix: [Float], _ point: geo.vec4
    ) -> geo.vec4 {
        geo.vec4(
            matrix[0] * point.x + matrix[4] * point.y
                + matrix[8] * point.z + matrix[12] * point.w,
            matrix[1] * point.x + matrix[5] * point.y
                + matrix[9] * point.z + matrix[13] * point.w,
            matrix[2] * point.x + matrix[6] * point.y
                + matrix[10] * point.z + matrix[14] * point.w,
            matrix[3] * point.x + matrix[7] * point.y
                + matrix[11] * point.z + matrix[15] * point.w)
    }

    private static func transformQuadric(
        _ quadric: [Float], by isometry: [Float]
    ) -> [Float] {
        // All Hopf scene frames are orthogonal, so Q' = M Q Mᵀ is the
        // homogeneous-conic change of coordinates for the active frame M.
        matrixProduct(
            isometry,
            matrixProduct(quadric, matrixTranspose(isometry)))
    }

    /// The inverse of the standard L(5, 2) generator
    ///
    ///     (z₁, z₂) ↦ (exp(2πi/5) z₁, exp(4πi/5) z₂),
    ///
    /// using z₁ = w + ix and z₂ = y + iz. The inverse pairs the
    /// positive-x face of the spherical lune directly with its negative-x
    /// face. It generates the same free cyclic action of order five.
    private static func inverseLensGenerator() -> [Float] {
        let firstAngle = -2 * Float.pi / 5
        let secondAngle = -4 * Float.pi / 5
        let firstCosine = cos(firstAngle)
        let firstSine = sin(firstAngle)
        let secondCosine = cos(secondAngle)
        let secondSine = sin(secondAngle)

        // Column-major matrix acting on (x, y, z, w).
        return [
            firstCosine, 0, 0, -firstSine,
            0, secondCosine, secondSine, 0,
            0, -secondSine, secondCosine, 0,
            firstSine, 0, 0, firstCosine,
        ]
    }

    // MARK: - 600-cell scene

    private struct Vertex4 {
        let x: Float
        let y: Float
        let z: Float
        let w: Float

        var point: geo.vec4 {
            geo.vec4(x, y, z, w)
        }
    }

    private static func dot(_ first: Vertex4, _ second: Vertex4) -> Float {
        first.x * second.x
            + first.y * second.y
            + first.z * second.z
            + first.w * second.w
    }

    private static func quaternionMultiply(_ first: Vertex4, _ second: Vertex4) -> Vertex4 {
        Vertex4(
            x: first.w * second.x + first.x * second.w
                + first.y * second.z - first.z * second.y,
            y: first.w * second.y - first.x * second.z
                + first.y * second.w + first.z * second.x,
            z: first.w * second.z + first.x * second.y
                - first.y * second.x + first.z * second.w,
            w: first.w * second.w - first.x * second.x
                - first.y * second.y - first.z * second.z)
    }

    private static func quaternionConjugate(_ quaternion: Vertex4) -> Vertex4 {
        Vertex4(
            x: -quaternion.x,
            y: -quaternion.y,
            z: -quaternion.z,
            w: quaternion.w)
    }

    private static func leftQuaternionFrame(_ quaternion: Vertex4) -> [Float] {
        [
            quaternion.w, quaternion.z, -quaternion.y, -quaternion.x,
            -quaternion.z, quaternion.w, quaternion.x, -quaternion.y,
            quaternion.y, -quaternion.x, quaternion.w, -quaternion.z,
            quaternion.x, quaternion.y, quaternion.z, quaternion.w,
        ]
    }

    /// Maps local coordinates in the chart centered at `source` into local
    /// coordinates in the chart centered at `destination`.
    private static func transition(
        from source: Vertex4,
        to destination: Vertex4
    ) -> [Float] {
        let relativeCenter = quaternionMultiply(quaternionConjugate(destination), source)
        return leftQuaternionFrame(relativeCenter)
    }

    private static func make24CellVertices() -> [Vertex4] {
        var vertices: [Vertex4] = []

        // The eight signed coordinate basis vectors.
        for axis in 0..<4 {
            for sign in [Float(-1), Float(1)] {
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

        // The sixteen half-coordinate vertices.
        for x in [Float(-0.5), Float(0.5)] {
            for y in [Float(-0.5), Float(0.5)] {
                for z in [Float(-0.5), Float(0.5)] {
                    for w in [Float(-0.5), Float(0.5)] {
                        vertices.append(Vertex4(x: x, y: y, z: z, w: w))
                    }
                }
            }
        }

        // Make the quaternion identity the seed chart.
        vertices.sort { $0.w > $1.w }
        return vertices
    }

    private static func make24CellAdjacency(_ vertices: [Vertex4]) -> [[Int]] {
        var adjacency = [[Int]](repeating: [], count: vertices.count)
        for first in vertices.indices {
            for second in vertices.indices where second > first {
                let product = dot(vertices[first], vertices[second])
                if product > 0.49, product < 0.51 {
                    adjacency[first].append(second)
                    adjacency[second].append(first)
                }
            }
        }
        return adjacency
    }

    /// One neighbor of the identity from each non-binary-tetrahedral right
    /// coset. Repeating these five local positions over the 24 charts produces
    /// all 120 vertices of the 600-cell exactly once.
    private static func cell600NeighborRepresentatives() -> [Vertex4] {
        [
            Vertex4(x: -0.3090169944, y: 0, z: -0.5, w: 0.8090169944),
            Vertex4(x: -0.5, y: 0.3090169944, z: 0, w: 0.8090169944),
            Vertex4(x: -0.5, y: -0.3090169944, z: 0, w: 0.8090169944),
            Vertex4(x: -0.3090169944, y: 0, z: 0.5, w: 0.8090169944),
        ]
    }

    private static func positiveWPoint(_ coordinates: geo.vec3) -> geo.vec4 {
        let wSquared = 1
            - coordinates.x * coordinates.x
            - coordinates.y * coordinates.y
            - coordinates.z * coordinates.z
        return geo.vec4(
            coordinates.x,
            coordinates.y,
            coordinates.z,
            sqrt(max(wSquared, 0)))
    }

    private static func configure(_ atlas: inout geo.Atlas) {
        atlas.start(1)
        _ = atlas.seed()
        let colors: [geo.vec4] = [
            geo.vec4(0.95, 0.12, 0.08, 1), geo.vec4(0.10, 0.65, 1, 1),
            geo.vec4(0.96, 0.72, 0.10, 1), geo.vec4(0.42, 0.90, 0.32, 1),
        ]
        for color in colors { _ = addPreviewMaterial(&atlas, color) }
        _ = addMirrorMaterial(&atlas, geo.vec4(0.405, 0.855, 0.9, 1))

        // A deterministic, asymmetric sample of the 600-cell directions.
        let phi: Float = (1 + sqrt(5)) / 2
        let directions: [SIMD3<Float>] = [
            [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1],
            [1, phi, 1 / phi], [-phi, 1, -1 / phi], [1 / phi, -phi, 1], [-1 / phi, -1, -phi],
        ]
        for (index, raw) in directions.enumerated() {
            let d =
            raw / sqrt(raw.x * raw.x + raw.y * raw.y + raw.z * raw.z)
            * (0.55 + 0.12 * Float(index % 3))
            let p = atlas.pointFromOriginTangent(geo.vec3(d.x, d.y, d.z))
            _ = atlas.addBall(0, p, 0.11 + 0.015 * Float(index % 2), Int32(index % 4))
        }
        _ = atlas.addPlane(0, geo.vec3(0, -1, 0), 1.25, 4)
        _ = atlas.addLight(
            0, atlas.pointFromOriginTangent(geo.vec3(-0.4, 0.25, -0.15)),
            geo.vec3(1, 0.92, 0.74), previewPointLightScale)
        _ = atlas.addLight(
            0, atlas.pointFromOriginTangent(geo.vec3(0.3, -0.1, 0.5)),
            geo.vec3(0.5, 0.7, 1), 0.55 * previewPointLightScale)
        atlas.setCamera(0.85, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
        atlas.setControls(6, 0.05, 0.18, 2, 0, 0.0)
    }

    /// Builds the original one-chart object and mirror demonstration.
    @discardableResult static func objectDemo(_ atlas: inout geo.Atlas) -> Int32 {
        configure(&atlas)
        let camera = atlas.cameraChartAt(
            0, atlas.pointFromOriginTangent(geo.vec3(0.12, 0.08, -0.1)), 2.6)
        let result = atlas.build(camera, 64)
        if result != 0 { fatalError("S³ object demo build failed: \(result)") }
        return camera
    }

    /// A curvature-small counterpart of the R³ path tracing room.
    @discardableResult static func pathTracingRoom(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(1)
        _ = atlas.seed()
        let white = addLambertianMaterial(
            &atlas, geo.vec4(0.78, 0.78, 0.78, 1))
        let red = addLambertianMaterial(
            &atlas, geo.vec4(0.78, 0.08, 0.05, 1))
        let green = addLambertianMaterial(
            &atlas, geo.vec4(0.08, 0.68, 0.12, 1))
        let blue = atlas.addMaterial(
            geo.vec4(0.08, 0.28, 0.82, 1), 0.38, 0, 1.5, 0,
            geo.vec3(0, 0, 0))
        let mirror = atlas.addMaterial(
            geo.vec4(0.92, 0.95, 1, 1), 0, 1, 1.5, 0,
            geo.vec3(0, 0, 0))
        let roughGlass = atlas.addMaterial(
            geo.vec4(0.98, 0.99, 1, 1), 0.18, 0, 1.5, 1,
            geo.vec3(0, 0, 0))
        let roughMetal = atlas.addMaterial(
            geo.vec4(0.95, 0.64, 0.2, 1), 0.32, 1, 1.5, 0,
            geo.vec3(0, 0, 0))
        let emitter = atlas.addMaterial(
            geo.vec4(0, 0, 0, 1), 0, 0, 1.5, 0,
            geo.vec3(8, 2, 0.25))

        _ = atlas.addPlane(0, geo.vec3(1, 0, 0), -0.3, red)
        _ = atlas.addPlane(0, geo.vec3(-1, 0, 0), -0.3, green)
        _ = atlas.addPlane(0, geo.vec3(0, 1, 0), -0.3, white)
        _ = atlas.addPlane(0, geo.vec3(0, -1, 0), -0.3, white)
        _ = atlas.addPlane(0, geo.vec3(0, 0, -1), -0.45, white)
        _ = atlas.addPlane(0, geo.vec3(0, 0, 1), -0.45, white)
        _ = atlas.addBall(
            0, atlas.pointFromOriginTangent(geo.vec3(-0.114, -0.186, 0.06)),
            0.09, blue)
        _ = atlas.addBallSurface(
            0, atlas.pointFromOriginTangent(geo.vec3(0.12, -0.192, 0.135)),
            0.084, mirror)
        _ = atlas.addBallSurface(
            0, atlas.pointFromOriginTangent(geo.vec3(0, -0.204, -0.105)),
            0.066, roughGlass)
        _ = atlas.addBallSurface(
            0, atlas.pointFromOriginTangent(geo.vec3(0.186, -0.222, -0.096)),
            0.054, roughMetal)
        _ = atlas.addBallSurface(
            0, atlas.pointFromOriginTangent(geo.vec3(-0.174, 0.135, 0.054)),
            0.03, emitter)
        _ = atlas.addSphericalAreaLight(
            0, atlas.pointFromOriginTangent(geo.vec3(0, 0.216, -0.075)),
            0.036, geo.vec3(1, 0.92, 0.78), 100)

        atlas.setCamera(
            0.62, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0),
            geo.vec3(0, -0.08, 1))
        atlas.setControls(6, 3.9, 0.05, 0, 0, 0)
        let camera = atlas.cameraChartAt(
            0, atlas.pointFromOriginTangent(geo.vec3(0, 0, -0.345)), 1.8)
        let result = atlas.build(camera, 64)
        if result != 0 { fatalError("S³ path tracing room build failed: \(result)") }
        return camera
    }

    /// Demonstrates linear sections, convex clipping, and independent mirror
    /// response in S³.
    @discardableResult static func primitiveGallery(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(1)
        _ = atlas.seed()

        _ = addPreviewMaterial(&atlas, geo.vec4(0.95, 0.18, 0.08, 1))
        _ = addPreviewMaterial(&atlas, geo.vec4(0.12, 0.72, 1.0, 1))
        _ = addMirrorMaterial(&atlas, geo.vec4(0.44, 0.836, 0.88, 1))
        _ = addPreviewMaterial(&atlas, geo.vec4(1.0, 0.82, 0.12, 1))
        _ = addPreviewMaterial(&atlas, geo.vec4(0.20, 0.92, 0.42, 1))

        let truncatedBall = atlas.addBallSurface(
            0, atlas.pointFromOriginTangent(geo.vec3(0.48, -0.18, 0.22)),
            0.28, 0)
        if truncatedBall < 0
            || atlas.addObjectClipPlane(truncatedBall, geo.vec3(-1, 0, 0), -0.35) < 0
        {
            fatalError("invalid clipped S³ ball")
        }

        let triangle = atlas.addPlane(0, geo.vec3(0, 0, 1), 0.72, 1)
        let triangleDirections: [geo.vec3] = [
            geo.vec3(1, 0, 0),
            geo.vec3(-0.5, 0.8660254, 0),
            geo.vec3(-0.5, -0.8660254, 0),
        ]
        if triangle < 0
            || triangleDirections.contains(where: {
                atlas.addObjectClipPlane(triangle, $0, 0.48) < 0
            })
        {
            fatalError("invalid clipped S³ triangle")
        }

        let mirrorPatch = atlas.addPlane(0, geo.vec3(0, -1, 0), 1.05, 2)
        if mirrorPatch < 0
            || atlas.addObjectClipPlane(mirrorPatch, geo.vec3(1, 0, 0), 0.65) < 0
            || atlas.addObjectClipPlane(mirrorPatch, geo.vec3(-1, 0, 0), 0.65) < 0
            || atlas.addObjectClipPlane(mirrorPatch, geo.vec3(0, 0, 1), 0.65) < 0
            || atlas.addObjectClipPlane(mirrorPatch, geo.vec3(0, 0, -1), 0.65) < 0
        {
            fatalError("invalid reflective S³ plane patch")
        }

        // Thin tubes around two orthogonal great circles. Both fit wholly in
        // this chart, so unlike the full-sphere Clifford scene they need no
        // antipodal split.
        for (index, tube) in orthogonalRingQuadrics(radius: 0.02).enumerated() {
            if atlas.addQuadric(0, tube, Int32(3 + index)) < 0 {
                fatalError("invalid S³ orthogonal ring")
            }
        }

        _ = atlas.addLight(
            0, atlas.pointFromOriginTangent(geo.vec3(-0.35, 0.25, 0.15)),
            geo.vec3(1, 0.92, 0.75), previewPointLightScale)
        _ = atlas.addLight(
            0, atlas.pointFromOriginTangent(geo.vec3(0.2, -0.15, 0.55)),
            geo.vec3(0.45, 0.65, 1), 0.65 * previewPointLightScale)
        atlas.setCamera(
            0.82, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1))
        atlas.setControls(5, 0.05, 0.2, 2, 0, 0)
        let camera = atlas.cameraChartAt(
            0, atlas.pointFromOriginTangent(geo.vec3(0, 0, -0.12)), 3)
        let result = atlas.build(camera, 64)
        if result != 0 { fatalError("S³ primitive gallery build failed: \(result)") }
        return camera
    }

    /// Places thin tubes around the 20 Hopf fibers over the vertices of a
    /// regular dodecahedron in S².
    @discardableResult static func hopfFibration(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(1)
        // Recenter the construction at the camera and divide the 20 complete
        // fibers evenly between this frame and the antipodal face frame.
        let cameraPlacement = hopfFibrationCameraPlacement()
        let cameraFrame = s3MovePointToOrigin(cameraPlacement.point)
        _ = atlas.seed()

        // The second chart is centered on a lift of the opposite face center.
        // Its base direction is the negative of the camera's, so it contains
        // the complementary ten fibers. The frame is parent-to-child; its
        // inverse therefore maps the child chart origin to this center when
        // the atlas is flattened for rendering.
        let oppositeBase = -cameraPlacement.base
        let oppositeCenter = matrixApply(
            cameraFrame, hopfLift(oppositeBase))
        let oppositeChartFrame = s3MovePointToOrigin(oppositeCenter)
        let oppositeChart = atlas.addChart(0, oppositeChartFrame, true)
        if oppositeChart != 1 { fatalError("invalid Hopf chart pair") }

        let colors: [geo.vec4] = [
            geo.vec4(0.96, 0.20, 0.10, 1),
            geo.vec4(0.08, 0.62, 1.00, 1),
            geo.vec4(1.00, 0.78, 0.08, 1),
            geo.vec4(0.18, 0.90, 0.38, 1),
            geo.vec4(0.78, 0.22, 0.96, 1),
        ]
        for color in colors {
            _ = addPreviewMaterial(&atlas, color)
        }

        let vertices = dodecahedronVertices()
        let vertexMaterials = dodecahedronVertexMaterials()
        precondition(vertices.count == 20, "invalid dodecahedron vertex set")
        for (fiber, vertex) in vertices.enumerated() {
            let tube = transformQuadric(
                hopfFiberTubeQuadric(base: vertex, radius: 0.02),
                by: cameraFrame)
            let material = vertexMaterials[fiber]
            let baseProduct = vertex.x * cameraPlacement.base.x
                + vertex.y * cameraPlacement.base.y
                + vertex.z * cameraPlacement.base.z
            let chart = baseProduct < 0
                ? Int32(0) : oppositeChart
            let localTube = chart == 0
                ? tube
                : transformQuadric(tube, by: oppositeChartFrame)
            if atlas.addQuadric(chart, localTube, material) < 0 {
                fatalError("invalid Hopf fiber tube")
            }
        }

        // Put the finite emitters on the camera's Hopf fiber, one on each
        // side of the camera along its great-circle viewing direction.
        let fiberTangent = geo.vec4(cameraPlacement.centeredForward, 0)
        let fiberOffset: Float = 0.55
        let warmLightCenter = s3FiberPoint(
            cameraPlacement.point, fiberTangent, fiberOffset)
        let coolLightCenter = s3FiberPoint(
            cameraPlacement.point, fiberTangent, -fiberOffset)
        let areaLightRadius: Float = 0.06
        let areaLightRadiance: Float = 80
        _ = atlas.addSphericalAreaLight(
            0, matrixApply(cameraFrame, warmLightCenter), areaLightRadius,
            geo.vec3(1, 0.92, 0.75), areaLightRadiance)
        _ = atlas.addSphericalAreaLight(
            0, matrixApply(cameraFrame, coolLightCenter), areaLightRadius,
            geo.vec3(0.45, 0.68, 1), 0.7 * areaLightRadiance)
        let forward = cameraPlacement.centeredForward
        let right = geo.vec3(0, 0, 1)
        let up = geo.vec3(forward.y, -forward.x, 0)
        atlas.setCamera(0.88, 16.0 / 9.0, right, up, forward)
        atlas.setControls(5, 0.05, 0.2, 2, 0, 0)
        let camera = atlas.cameraChartAt(
            0, geo.vec4(0, 0, 0, 1), Float.pi * 0.98)
        let result = atlas.build(camera, 64)
        if result != 0 { fatalError("Hopf fibration build failed: \(result)") }
        return camera
    }

    /// Displays the inverse images of the five edges of the dodecahedron face
    /// centered at the camera's base point. Each edge is a segment of a base
    /// great circle, so its inverse image is a Clifford torus clipped by the
    /// two neighboring edge tori.
    @discardableResult static func hopfFacePatches(
        _ atlas: inout geo.Atlas
    ) -> Int32 {
        atlas.start(1)
        // Two antipodal authored coordinate frames cover the complete S³.
        // Each patch is split by the chart equator, so flattening does not
        // duplicate the surface.
        let cameraPlacement = hopfFibrationCameraPlacement()
        let cameraFrame = s3MovePointToOrigin(cameraPlacement.point)
        _ = atlas.seed()
        let oppositeChart = atlas.addChart(0, antipodalMatrix, true)
        if oppositeChart != 1 {
            fatalError("invalid Hopf face-patch chart pair")
        }

        let colors: [geo.vec4] = [
            geo.vec4(0.96, 0.20, 0.10, 1),
            geo.vec4(0.08, 0.62, 1.00, 1),
            geo.vec4(1.00, 0.78, 0.08, 1),
            geo.vec4(0.18, 0.90, 0.38, 1),
            geo.vec4(0.78, 0.22, 0.96, 1),
        ]
        for color in colors {
            _ = addPreviewMaterial(&atlas, color)
        }

        let vertices = dodecahedronVertices()
        // These are the five vertices of the face whose outward normal is
        // (0, φ, 1). They are ordered cyclically around that face.
        let faceIndices = [18, 12, 3, 17, 7]
        let faceCenter = cameraPlacement.base
        var edgeNormals = [SIMD3<Float>]()
        for edge in 0..<faceIndices.count {
            let first = vertices[faceIndices[edge]]
            let second = vertices[faceIndices[(edge + 1) % faceIndices.count]]
            var normal = SIMD3<Float>(
                first.y * second.z - first.z * second.y,
                first.z * second.x - first.x * second.z,
                first.x * second.y - first.y * second.x)
            let normalLength = sqrt(
                normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
            normal /= normalLength
            let centerDot = normal.x * faceCenter.x
                + normal.y * faceCenter.y + normal.z * faceCenter.z
            if centerDot < 0 {
                normal = -normal
            }
            edgeNormals.append(normal)
        }

        for chart in [Int32(0), oppositeChart] {
            // In chart 0, w >= 0 owns the northern half of each patch. The
            // antipodal chart receives the same local half, which maps back to
            // w <= 0 in chart 0. The linear clip keeps the two authored copies
            // disjoint when build() flattens the atlas.
            let chartFrame = chart == 0 ? cameraFrame :
                matrixProduct(antipodalMatrix, cameraFrame)
            for edge in 0..<edgeNormals.count {
                // At radius π/4, hopfFiberTubeQuadric is exactly the Clifford
                // torus over the corresponding base great circle. Its value is
                // -normal·h(P), so <= 0 retains the face-side hemisphere.
                let torus = transformQuadric(
                    hopfFiberTubeQuadric(
                        base: edgeNormals[edge], radius: Float.pi / 4),
                    by: chartFrame)
                let patch = atlas.addQuadric(
                    chart, torus, Int32(edge % colors.count))
                if patch < 0 {
                    fatalError("invalid Hopf face patch")
                }

                let previous = transformQuadric(
                    hopfFiberTubeQuadric(
                        base: edgeNormals[(edge + edgeNormals.count - 1)
                            % edgeNormals.count], radius: Float.pi / 4),
                    by: chartFrame)
                let next = transformQuadric(
                    hopfFiberTubeQuadric(
                        base: edgeNormals[(edge + 1) % edgeNormals.count],
                        radius: Float.pi / 4),
                    by: chartFrame)
                if atlas.addObjectClipQuadric(patch, previous, false) < 0
                    || atlas.addObjectClipQuadric(patch, next, false) < 0
                    || atlas.addObjectClip(
                        patch, geo.vec4(0, 0, 0, -1), 0) < 0
                {
                    fatalError("invalid Hopf face patch clip")
                }
            }
        }

        // Keep the same two finite emitters on the camera fiber as the Hopf
        // tube scene, so the patch scene has a directly comparable view.
        let fiberTangent = geo.vec4(cameraPlacement.centeredForward, 0)
        let fiberOffset: Float = 0.55
        let warmLightCenter = s3FiberPoint(
            cameraPlacement.point, fiberTangent, fiberOffset)
        let coolLightCenter = s3FiberPoint(
            cameraPlacement.point, fiberTangent, -fiberOffset)
        let areaLightRadius: Float = 0.06
        let areaLightRadiance: Float = 80
        _ = atlas.addSphericalAreaLight(
            0, matrixApply(cameraFrame, warmLightCenter), areaLightRadius,
            geo.vec3(1, 0.92, 0.75), areaLightRadiance)
        _ = atlas.addSphericalAreaLight(
            0, matrixApply(cameraFrame, coolLightCenter), areaLightRadius,
            geo.vec3(0.45, 0.68, 1), 0.7 * areaLightRadiance)

        let forward = cameraPlacement.centeredForward
        let right = geo.vec3(0, 0, 1)
        let up = geo.vec3(forward.y, -forward.x, 0)
        atlas.setCamera(0.88, 16.0 / 9.0, right, up, forward)
        atlas.setControls(5, 0.05, 0.2, 2, 0, 0)
        let camera = atlas.cameraChartAt(
            0, geo.vec4(0, 0, 0, 1), Float.pi * 0.98)
        let result = atlas.build(camera, 64)
        if result != 0 {
            fatalError("Hopf face patches build failed: \(result)")
        }
        return camera
    }

    /// Displays Lawson's reflection construction of the Clifford torus. The
    /// linked polar circles are P = C₁₂ and Q = C₃₄, with the four uniformly
    /// spaced points ±e₁, ±e₂ on P and ±e₃, ±e₄ on Q. The base minimal disk
    /// is the positive-orthant patch of xz = yw, bounded by the great-circle
    /// arcs e₁e₂, e₂e₃, e₃e₄, and e₄e₁. Half-turns about those edges generate
    /// the eight diagonal SO(4) images below.
    @discardableResult static func cliffordTorusConstruction(
        _ atlas: inout geo.Atlas
    ) -> Int32 {
        atlas.start(1)
        // Two antipodal authored charts cover S³. Every patch has explicit
        // orthant or hemisphere ownership, so flattening does not depend on a
        // radial chart bound. Camera movement remains in its selected
        // coordinate chart independently of these authoring bounds.
        _ = atlas.seed()
        let antipodalChart = atlas.addChart(0, antipodalMatrix, true)
        if antipodalChart != 1 { fatalError("invalid antipodal S³ chart") }
        _ = addPreviewMaterial(&atlas, geo.vec4(0.95, 0.24, 0.10, 1))
        _ = addPreviewMaterial(&atlas, geo.vec4(0.08, 0.62, 1.0, 1))
        _ = addPreviewMaterial(&atlas, geo.vec4(1.0, 0.82, 0.12, 1))
        _ = addPreviewMaterial(&atlas, geo.vec4(0.20, 0.92, 0.42, 1))

        // The symmetric matrix represents xz - yw = 0. This is an isometric
        // coordinate form of the usual x² + y² = z² + w² Clifford torus.
        let quadric = cliffordTorusQuadric()

        // Each even sign pattern is a diagonal orientation-preserving
        // isometry preserving xz = yw. Applied to the positive patch, these
        // are precisely the eight pieces obtained by successive edge
        // half-turns. Opposite signs identify the image orthant.
        let imageSigns: [[Float]] = [
            [1, 1, 1, 1],
            [1, 1, -1, -1],
            [1, -1, 1, -1],
            [1, -1, -1, 1],
            [-1, 1, 1, -1],
            [-1, 1, -1, 1],
            [-1, -1, 1, 1],
            [-1, -1, -1, -1],
        ]

        for globalSigns in imageSigns {
            // This parity changes under every edge half-turn, so patches
            // sharing a great-circle edge always receive different colors.
            let color: Int32 = globalSigns[0] * globalSigns[2] < 0 ? 1 : 0
            let chart: Int32 = globalSigns[3] > 0 ? 0 : antipodalChart
            // Chart 1 uses y = -x, so all four orthant signs reverse there.
            let localSigns = chart == 0 ? globalSigns : globalSigns.map { -$0 }
            let patch = atlas.addQuadric(chart, quadric, color)
            if patch < 0 { fatalError("invalid Clifford torus patch") }

            let coordinates = [
                geo.vec4(-localSigns[0], 0, 0, 0),
                geo.vec4(0, -localSigns[1], 0, 0),
                geo.vec4(0, 0, -localSigns[2], 0),
                geo.vec4(0, 0, 0, -localSigns[3]),
            ]
            for normal in coordinates {
                if atlas.addObjectClip(patch, normal, 0) < 0 {
                    fatalError("invalid Clifford torus patch clip")
                }
            }
        }

        // In these coordinates the two polar great circles are
        //
        //   C₊(t) = (cos t, sin t,  cos t, -sin t) / √2,
        //   C₋(t) = (cos t, sin t, -cos t,  sin t) / √2.
        //
        // They are orthogonal and both remain π/4 from the Clifford torus.
        // The level sets q = ±cos(2r)/2 are the surfaces at distance r from
        // C₊ and C₋. Split each thin tube into its two w-hemispheres so every
        // half remains wholly inside its owning antipodal chart.
        for (tube, material) in zip(
            orthogonalRingQuadrics(radius: 0.02), [Int32(2), Int32(3)])
        {
            for chart in [Int32(0), antipodalChart] {
                let half = atlas.addQuadric(chart, tube, material)
                if half < 0
                    || atlas.addObjectClip(half, geo.vec4(0, 0, 0, -1), 0) < 0
                {
                    fatalError("invalid Clifford polar-circle tube")
                }
            }
        }

        _ = atlas.addLight(
            0, atlas.pointFromOriginTangent(geo.vec3(-0.42, 0.28, 0.20)),
            geo.vec3(1, 0.92, 0.74), previewPointLightScale)
        _ = atlas.addLight(
            0, atlas.pointFromOriginTangent(geo.vec3(0.30, -0.18, 0.52)),
            geo.vec3(0.45, 0.68, 1), 0.7 * previewPointLightScale)
        atlas.setCamera(
            0.82, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1))
        atlas.setControls(5, 0.05, 0.2, 2, 0, 0)
        let cameraOffset: Float = 0.28
        let cameraPosition = geo.vec4(
            cos(cameraOffset) / sqrt(2), sin(cameraOffset) / sqrt(2),
            cos(cameraOffset) / sqrt(2), sin(cameraOffset) / sqrt(2))
        let camera = atlas.cameraChartAt(
            0, cameraPosition, Float.pi * 0.98)
        let result = atlas.build(camera, 64)
        if result != 0 {
            fatalError("Clifford torus construction build failed: \(result)")
        }
        return camera
    }

    /// Builds the original 24-chart 600-cell scene. The overlap graph is the
    /// complete 24-cell graph: 24 chart vertices, degree eight, and 96 edges.
    @discardableResult static func cell600(_ atlas: inout geo.Atlas) -> Int32 {
        let ballRadius = acos(Float(0.995))
        let viewDistance = Float.pi * 0.9

        atlas.start(1)
        let baseChart = atlas.seed()

        let colors: [geo.vec4] = [
            geo.vec4(1, 0, 0, 1),
            geo.vec4(0, 1, 0, 1),
            geo.vec4(0, 0, 1, 1),
            geo.vec4(1, 1, 0, 1),
            geo.vec4(0, 1, 1, 1),
        ]
        for color in colors {
            _ = addPreviewMaterial(&atlas, color)
        }

        let centers = make24CellVertices()
        let adjacency = make24CellAdjacency(centers)
        let edgeCount = adjacency.reduce(0) { $0 + $1.count } / 2
        precondition(
            centers.count == 24
                && adjacency.allSatisfy { $0.count == 8 }
                && edgeCount == 96,
            "invalid 24-cell chart graph")

        // Create all charts along a spanning tree first.
        var chartIDs = [Int32](repeating: -1, count: centers.count)
        chartIDs[0] = baseChart
        var queue = [0]
        var nextQueueIndex = 0
        while nextQueueIndex < queue.count {
            let current = queue[nextQueueIndex]
            nextQueueIndex += 1

            for neighbor in adjacency[current] where chartIDs[neighbor] < 0 {
                let matrix = transition(from: centers[current], to: centers[neighbor])
                let chart = atlas.add(chartIDs[current], matrix, true)
                if chart < 0 {
                    fatalError("failed to add 600-cell chart")
                }
                chartIDs[neighbor] = chart
                queue.append(neighbor)
            }
        }

        // Restore every non-tree edge so the overlap graph is exactly the
        // historical 24-cell graph rather than only its spanning tree.
        for chartIndex in centers.indices {
            for neighbor in adjacency[chartIndex] where neighbor > chartIndex {
                let matrix = transition(from: centers[chartIndex], to: centers[neighbor])
                atlas.link(chartIDs[chartIndex], chartIDs[neighbor], matrix, true)
                if atlas.lastError() != 0 {
                    fatalError("failed to link 600-cell charts")
                }
            }
        }

        let origin = Vertex4(x: 0, y: 0, z: 0, w: 1)
        let neighbors = cell600NeighborRepresentatives()
        for chart in chartIDs {
            _ = atlas.addBall(chart, origin.point, ballRadius, 0)
            for (index, neighbor) in neighbors.enumerated() {
                _ = atlas.addBall(chart, neighbor.point, ballRadius, Int32(index + 1))
            }
        }

        // Retain the original four symmetrically placed lights.
        let lightCoordinates = geo.vec3(0.2185080122, 0.2185080122, -0.2185080122)
        let lightPosition = positiveWPoint(lightCoordinates)
        let lightColor = geo.vec3(1, 0.95, 0.8)
        for (index, center) in centers.enumerated() {
            let axisSum = abs(center.x) + abs(center.y) + abs(center.z) + abs(center.w)
            let isPositiveBasis = center.x > 0.9
                || center.y > 0.9
                || center.z > 0.9
                || center.w > 0.9
            if axisSum > 0.9, axisSum < 1.1, isPositiveBasis {
                _ = atlas.addLight(
                    chartIDs[index], lightPosition, lightColor,
                    previewPointLightScale)
            }
        }

        atlas.setCamera(
            1,
            16.0 / 9.0,
            geo.vec3(1, 0, 0),
            geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1))
        atlas.setControls(6, 0.05, 0.25, 2, 0, 0)

        let cameraPosition = positiveWPoint(lightCoordinates)
        let camera = atlas.cameraChartAt(0, cameraPosition, viewDistance)
        let result = atlas.build(camera, 64)
        if result != 0 {
            fatalError("S³ 600-cell build failed: \(result)")
        }
        return camera
    }

    @discardableResult static func lensSpaceL52(_ atlas: inout geo.Atlas) -> Int32 {
        atlas.start(1)

        _ = atlas.seed()

        _ = addPreviewMaterial(&atlas, geo.vec4(0.95, 0.12, 0.08, 1))
        _ = addPreviewMaterial(&atlas, geo.vec4(0.10, 0.65, 1.00, 1))

        // Keep both balls well inside the lune while separating them enough
        // that their quotient copies make the face identification apparent.
        let firstCenter = atlas.pointFromOriginTangent(geo.vec3(0.17, -0.32, 0.25))
        let secondCenter = atlas.pointFromOriginTangent(geo.vec3(-0.16, 0.29, -0.29))
        _ = atlas.addBall(0, firstCenter, 0.18, 0)
        _ = atlas.addBall(0, secondCenter, 0.21, 1)

        _ = atlas.addLight(
            0,
            atlas.pointFromOriginTangent(geo.vec3(0.05, 0.28, 0.18)),
            geo.vec3(1.0, 0.92, 0.72),
            0.8 * previewPointLightScale)

        let portal = atlas.addPortalPair(
            0, geo.vec3(1, 0, 0), lensFaceDistance,
            0, geo.vec3(-1, 0, 0), lensFaceDistance,
            inverseLensGenerator())
        if portal < 0 { fatalError("invalid L(5, 2) face pairing") }

        atlas.setCamera(
            0.9,
            16.0 / 9.0,
            geo.vec3(1, 0, 0),
            geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1))
        atlas.setControls(5, 0.04, 0.18, 2, 0, 0.18)

        let cameraPosition = atlas.pointFromOriginTangent(geo.vec3(0.06, -0.04, 0.08))
        let camera = atlas.cameraChartAt(0, cameraPosition, 2.8)
        let result = atlas.buildAtlas(camera, 64, 2, 32)
        if result != 0 { fatalError("L(5, 2) atlas build failed: \(result)") }
        return camera
    }
}
