import Foundation
import GeometryCore

enum TowerScene {
    private enum Model: Int32 {
        case hyperbolic = 0
        case spherical = 1
        case euclidean = 2
    }

    private struct Configuration {
        let model: Model
        let vertexDegree: Int
        let edgeLength: Float
        let tilingRadius: Float
        let enclosureRadius: Float
        let heroHeight: Float
        let lowerHeight: Float
        let fovTan: Float
        let viewDistance: Float
        let fogDensity: Float
        let lightRadiance: Float
    }

    private struct GroundVertex {
        // Coordinates are (x, y, w) in the z = 0 ground plane.
        let point: SIMD3<Float>
        let anchor: Int
    }

    private struct Materials {
        let ground: Int32
        let enclosure: Int32
        let stone: Int32
        let trim: Int32
        let roof: Int32
        let lantern: Int32
        let finial: Int32
    }

    @discardableResult
    static func spherical(_ atlas: inout geo.Atlas) -> Int32 {
        let edge = acos(1 / sqrt(Float(5)))
        return build(
            &atlas,
            Configuration(
                model: .spherical,
                vertexDegree: 5,
                edgeLength: edge,
                tilingRadius: 2.45,
                enclosureRadius: 2.72,
                heroHeight: 0.78,
                lowerHeight: 0.40,
                fovTan: 1.2,
                viewDistance: 3.05,
                fogDensity: 0,
                lightRadiance: 50))
    }

    @discardableResult
    static func euclidean(_ atlas: inout geo.Atlas) -> Int32 {
        return build(
            &atlas,
            Configuration(
                model: .euclidean,
                vertexDegree: 6,
                edgeLength: 1.25,
                tilingRadius: 2.55,
                enclosureRadius: 3.25,
                heroHeight: 1.15,
                lowerHeight: 0.50,
                fovTan: 0.82,
                viewDistance: 6.5,
                fogDensity: 0,
                lightRadiance: 72))
    }

    @discardableResult
    static func hyperbolic(_ atlas: inout geo.Atlas) -> Int32 {
        let angle = 2 * Float.pi / 7
        let edge = acosh(cos(angle) / (1 - cos(angle)))
        return build(
            &atlas,
            Configuration(
                model: .hyperbolic,
                vertexDegree: 7,
                edgeLength: edge,
                tilingRadius: 2.48,
                enclosureRadius: 3.18,
                heroHeight: 0.96,
                lowerHeight: 0.43,
                fovTan: 0.72,
                viewDistance: 7.0,
                fogDensity: 0.035,
                lightRadiance: 88))
    }

    private static func build(
        _ atlas: inout geo.Atlas,
        _ configuration: Configuration
    ) -> Int32 {
        atlas.start(configuration.model.rawValue)
        let exterior = atlas.seed()
        precondition(exterior == 0, "tower scene exterior chart must be chart zero")

        let materials = addMaterials(&atlas)
        addExterior(
            &atlas, configuration: configuration, materials: materials)

        let vertices = tilingVertices(configuration)
        precondition(vertices.count > configuration.vertexDegree)
        let allLowerVertices = Array(vertices.dropFirst())
        let nearestPlanar = SIMD2<Float>(
            vertices[1].point.x, vertices[1].point.y)
        let nearestPlanarLength = sqrt(
            nearestPlanar.x * nearestPlanar.x
                + nearestPlanar.y * nearestPlanar.y)
        precondition(nearestPlanarLength > 1e-4)
        let nearestTowerDirection = nearestPlanar / nearestPlanarLength
        let hyperbolicSymmetryBearing = -4 * Float.pi / 7
        let hyperbolicSymmetryDirection = SIMD2<Float>(
            cos(hyperbolicSymmetryBearing), sin(hyperbolicSymmetryBearing))
        let visibleLowerVertices: [GroundVertex]
        switch configuration.model {
        case .spherical:
            // The radius contains the five adjacent vertices and the five
            // vertices in the next ring. Keep the complete ten-tower set.
            visibleLowerVertices = allLowerVertices
            let closestDistance = groundDistance(
                vertices[0].point, vertices[1].point,
                model: configuration.model)
            let closestCount = allLowerVertices.filter {
                abs(groundDistance(
                    vertices[0].point, $0.point,
                    model: configuration.model) - closestDistance) < 2e-3
            }.count
            precondition(
                visibleLowerVertices.count == 10 && closestCount == 5,
                "spherical tower scene must retain both five-tower rings")
        case .euclidean:
            // Face the first adjacent lattice vertex and retain the open
            // forward half-plane. Reflection in that camera axis preserves
            // the chosen set without paying for towers behind the camera.
            visibleLowerVertices = allLowerVertices.filter {
                $0.point.x * nearestTowerDirection.x
                    + $0.point.y * nearestTowerDirection.y > 1e-4
            }
        case .hyperbolic:
            visibleLowerVertices = allLowerVertices.filter {
                $0.point.x * hyperbolicSymmetryDirection.x
                    + $0.point.y * hyperbolicSymmetryDirection.y > 1e-4
            }
        }
        precondition(!visibleLowerVertices.isEmpty)
        if configuration.model == .euclidean {
            precondition(
                hasReflectionSymmetry(
                    visibleLowerVertices,
                    axis: nearestTowerDirection,
                    model: configuration.model),
                "euclidean tower sector lost reflection symmetry")
        } else if configuration.model == .hyperbolic {
            precondition(
                hasReflectionSymmetry(
                    visibleLowerVertices,
                    axis: hyperbolicSymmetryDirection,
                    model: configuration.model),
                "hyperbolic tower sector lost reflection symmetry")
        }

        for vertex in visibleLowerVertices {
            let exteriorToInterior = moveGroundPointToOrigin(
                vertex.point, model: configuration.model)
            let chart = atlas.addChart(exterior, exteriorToInterior, true)
            precondition(chart >= 0, "failed to add lower-tower chart")

            addTower(
                &atlas, chart: chart, height: configuration.lowerHeight,
                detailed: false, model: configuration.model,
                materials: materials)
            // The portal volume extends slightly below z = 0 to give camera
            // and ray crossings a stable collar. Mirror the exterior ground
            // into every tower chart so a downward ray hits the ground before
            // it can leave through that lower collar.
            precondition(
                atlas.addPlane(
                    chart, geo.vec3(0, 0, 1), 0, materials.ground) >= 0,
                "failed to add lower-tower ground")

            let portalBottom = Float(-0.045)
            let portalTop = 1.045 * configuration.lowerHeight
            let portalCenterHeight = 0.5 * (portalBottom + portalTop)
            let portalRadius = 0.5 * (portalTop - portalBottom) + 0.012
            let portalCenter = atlas.pointFromOriginTangent(
                geo.vec3(0, 0, portalCenterHeight))
            let portal = atlas.addGeodesicBallPortal(
                exterior, chart, portalCenter, portalRadius,
                exteriorToInterior, 0.008)
            precondition(portal >= 0, "failed to add lower-tower portal")
        }

        let down = Float(0.34)
        let horizontal = sqrt(1 - down * down)
        let viewingDirection: SIMD2<Float>
        switch configuration.model {
        case .euclidean, .spherical:
            viewingDirection = nearestTowerDirection
        case .hyperbolic:
            viewingDirection = hyperbolicSymmetryDirection
        }
        let cameraRight = SIMD2<Float>(
            -viewingDirection.y, viewingDirection.x)
        atlas.setCamera(
            configuration.fovTan, 16.0 / 9.0,
            geo.vec3(cameraRight.x, cameraRight.y, 0),
            geo.vec3(
                down * viewingDirection.x,
                down * viewingDirection.y,
                horizontal),
            geo.vec3(
                horizontal * viewingDirection.x,
                horizontal * viewingDirection.y,
                -down))
        atlas.setControls(
            6, 0.07, 0.24, configuration.fogDensity > 0 ? 2 : 0,
            0, configuration.fogDensity)

        let cameraHeight = 1.11 * configuration.heroHeight
        let cameraPosition = atlas.pointFromOriginTangent(
            geo.vec3(0, 0, cameraHeight))
        let camera = atlas.cameraChartAt(
            exterior, cameraPosition, configuration.viewDistance)
        let result = atlas.buildAtlas(camera, 64, 1, 32)
        if result != 0 {
            fatalError("tower atlas build failed for model \(configuration.model): \(result)")
        }
        return camera
    }

    private static func hasReflectionSymmetry(
        _ vertices: [GroundVertex],
        axis: SIMD2<Float>,
        model: Model
    ) -> Bool {
        vertices.allSatisfy { vertex in
            let planar = SIMD2<Float>(vertex.point.x, vertex.point.y)
            let reflectedPlanar = 2 * axis * (
                planar.x * axis.x + planar.y * axis.y) - planar
            let reflected = SIMD3<Float>(
                reflectedPlanar.x, reflectedPlanar.y, vertex.point.z)
            return vertices.contains {
                groundDistance($0.point, reflected, model: model) < 2e-3
            }
        }
    }

    private static func addMaterials(_ atlas: inout geo.Atlas) -> Materials {
        let ground = atlas.addMaterial(
            geo.vec4(0.28, 0.32, 0.35, 1), 0.82, 0, 1.5, 0,
            geo.vec3(0, 0, 0))
        let enclosure = atlas.addMaterial(
            geo.vec4(0.18, 0.26, 0.40, 1), 0.9, 0, 1.5, 0,
            geo.vec3(0.07, 0.10, 0.17))
        let stone = atlas.addMaterial(
            geo.vec4(0.82, 0.68, 0.48, 1), 0.72, 0, 1.5, 0,
            geo.vec3(0, 0, 0))
        let trim = atlas.addMaterial(
            geo.vec4(0.58, 0.25, 0.09, 1), 0.30, 1, 1.5, 0,
            geo.vec3(0, 0, 0))
        let roof = atlas.addMaterial(
            geo.vec4(0.08, 0.30, 0.25, 1), 0.24, 1, 1.5, 0,
            geo.vec3(0, 0, 0))
        let lantern = atlas.addMaterial(
            geo.vec4(1.0, 0.48, 0.10, 1), 0.3, 0, 1.5, 0,
            geo.vec3(2.8, 0.75, 0.12))
        let finial = atlas.addMaterial(
            geo.vec4(0.84, 0.63, 0.20, 1), 0.16, 1, 1.5, 0,
            geo.vec3(0, 0, 0))
        precondition(
            [ground, enclosure, stone, trim, roof, lantern, finial]
                .allSatisfy { $0 >= 0 },
            "failed to create tower materials")
        return Materials(
            ground: ground, enclosure: enclosure, stone: stone, trim: trim,
            roof: roof, lantern: lantern, finial: finial)
    }

    private static func addExterior(
        _ atlas: inout geo.Atlas,
        configuration: Configuration,
        materials: Materials
    ) {
        _ = atlas.addPlane(0, geo.vec3(0, 0, 1), 0, materials.ground)
        _ = atlas.addBallSurface(
            0, geo.vec4(0, 0, 0, 1), configuration.enclosureRadius,
            materials.enclosure)
        addTower(
            &atlas, chart: 0, height: configuration.heroHeight,
            detailed: true, model: configuration.model,
            materials: materials)

        let height = 1.20 * configuration.heroHeight
        let spread = min(0.72 * configuration.enclosureRadius, 1.65)
        for (tangent, color, scale) in [
            (SIMD3<Float>(-0.72 * spread, -0.22 * spread, height),
             geo.vec3(1.0, 0.72, 0.46), Float(1.0)),
            (SIMD3<Float>(0.64 * spread, -0.42 * spread, 0.88 * height),
             geo.vec3(0.48, 0.68, 1.0), Float(0.82)),
            (SIMD3<Float>(0.10 * spread, 0.74 * spread, 0.72 * height),
             geo.vec3(1.0, 0.42, 0.26), Float(0.72)),
        ] {
            let position = atlas.pointFromOriginTangent(
                geo.vec3(tangent.x, tangent.y, tangent.z))
            _ = atlas.addSphericalAreaLight(
                0, position, 0.085, color,
                configuration.lightRadiance * scale)
        }
    }

    private static func addTower(
        _ atlas: inout geo.Atlas,
        chart: Int32,
        height: Float,
        detailed: Bool,
        model: Model,
        materials: Materials
    ) {
        let coordinate: (Float) -> Float = {
            projectiveDistance($0, model: model)
        }
        let h0 = coordinate(0)
        let hBase = coordinate(0.14 * height)
        let hShaft = coordinate(detailed ? 0.68 * height : 0.70 * height)

        addFrustum(
            &atlas, chart: chart, z0: h0, z1: hBase,
            r0: coordinate(0.105 * height),
            r1: coordinate(0.075 * height),
            lowerHeight: 0, upperHeight: 0.14 * height,
            material: materials.stone)

        addHyperboloid(
            &atlas, chart: chart,
            a: coordinate(0.058 * height),
            b: coordinate(0.46 * height),
            centerZ: coordinate(0.42 * height),
            lowerHeight: 0.14 * height,
            upperHeight: detailed ? 0.68 * height : 0.70 * height,
            material: materials.stone)

        if detailed {
            let hBalcony = coordinate(0.72 * height)
            let hCornice = coordinate(0.76 * height)
            addFrustum(
                &atlas, chart: chart, z0: hShaft, z1: hBalcony,
                r0: coordinate(0.064 * height),
                r1: coordinate(0.105 * height),
                lowerHeight: 0.68 * height, upperHeight: 0.72 * height,
                material: materials.trim)
            addFrustum(
                &atlas, chart: chart, z0: hBalcony, z1: hCornice,
                r0: coordinate(0.105 * height),
                r1: coordinate(0.070 * height),
                lowerHeight: 0.72 * height, upperHeight: 0.76 * height,
                material: materials.trim)
            addCylinder(
                &atlas, chart: chart, radius: coordinate(0.050 * height),
                lowerHeight: 0.76 * height, upperHeight: 0.89 * height,
                material: materials.lantern)
            addCone(
                &atlas, chart: chart,
                radius: coordinate(0.078 * height),
                lowerHeight: 0.89 * height, upperHeight: height,
                model: model, material: materials.roof)
        } else {
            addCylinder(
                &atlas, chart: chart, radius: coordinate(0.050 * height),
                lowerHeight: 0.70 * height, upperHeight: 0.78 * height,
                material: materials.lantern)
            addCone(
                &atlas, chart: chart,
                radius: coordinate(0.078 * height),
                lowerHeight: 0.78 * height, upperHeight: height,
                model: model, material: materials.roof)
        }

        let finialCenter = atlas.pointFromOriginTangent(
            geo.vec3(0, 0, 1.025 * height))
        _ = atlas.addBallSurface(
            chart, finialCenter, 0.018 * height, materials.finial)
    }

    private static func addFrustum(
        _ atlas: inout geo.Atlas,
        chart: Int32,
        z0: Float,
        z1: Float,
        r0: Float,
        r1: Float,
        lowerHeight: Float,
        upperHeight: Float,
        material: Int32
    ) {
        let slope = (r1 - r0) / (z1 - z0)
        let intercept = r0 - slope * z0
        var quadric = [Float](repeating: 0, count: 16)
        quadric[0] = 1
        quadric[5] = 1
        quadric[10] = -slope * slope
        quadric[11] = -slope * intercept
        quadric[14] = -slope * intercept
        quadric[15] = -intercept * intercept
        addClippedQuadric(
            &atlas, chart: chart, quadric: quadric,
            lowerHeight: lowerHeight, upperHeight: upperHeight,
            material: material)
    }

    private static func addHyperboloid(
        _ atlas: inout geo.Atlas,
        chart: Int32,
        a: Float,
        b: Float,
        centerZ: Float,
        lowerHeight: Float,
        upperHeight: Float,
        material: Int32
    ) {
        var quadric = [Float](repeating: 0, count: 16)
        let radial = 1 / (a * a)
        let axial = 1 / (b * b)
        quadric[0] = radial
        quadric[5] = radial
        quadric[10] = -axial
        quadric[11] = centerZ * axial
        quadric[14] = centerZ * axial
        quadric[15] = -centerZ * centerZ * axial - 1
        addClippedQuadric(
            &atlas, chart: chart, quadric: quadric,
            lowerHeight: lowerHeight, upperHeight: upperHeight,
            material: material)
    }

    private static func addCylinder(
        _ atlas: inout geo.Atlas,
        chart: Int32,
        radius: Float,
        lowerHeight: Float,
        upperHeight: Float,
        material: Int32
    ) {
        var quadric = [Float](repeating: 0, count: 16)
        quadric[0] = 1
        quadric[5] = 1
        quadric[15] = -radius * radius
        addClippedQuadric(
            &atlas, chart: chart, quadric: quadric,
            lowerHeight: lowerHeight, upperHeight: upperHeight,
            material: material)
    }

    private static func addCone(
        _ atlas: inout geo.Atlas,
        chart: Int32,
        radius: Float,
        lowerHeight: Float,
        upperHeight: Float,
        model: Model,
        material: Int32
    ) {
        addFrustum(
            &atlas, chart: chart,
            z0: projectiveDistance(lowerHeight, model: model),
            z1: projectiveDistance(upperHeight, model: model),
            r0: radius, r1: 0,
            lowerHeight: lowerHeight, upperHeight: upperHeight,
            material: material)
    }

    private static func addClippedQuadric(
        _ atlas: inout geo.Atlas,
        chart: Int32,
        quadric: [Float],
        lowerHeight: Float,
        upperHeight: Float,
        material: Int32
    ) {
        let object = atlas.addQuadric(chart, quadric, material)
        precondition(object >= 0, "failed to add tower quadric")
        precondition(
            atlas.addObjectClipPlane(
                object, geo.vec3(0, 0, -1), -lowerHeight) >= 0,
            "failed to add lower tower clip")
        precondition(
            atlas.addObjectClipPlane(
                object, geo.vec3(0, 0, 1), upperHeight) >= 0,
            "failed to add upper tower clip")
    }

    private static func projectiveDistance(_ distance: Float, model: Model) -> Float {
        switch model {
        case .spherical: return tan(distance)
        case .hyperbolic: return tanh(distance)
        case .euclidean: return distance
        }
    }

    private static func tilingVertices(_ configuration: Configuration) -> [GroundVertex] {
        let root = SIMD3<Float>(0, 0, 1)
        var vertices = [GroundVertex(point: root, anchor: -1)]
        for index in 0..<configuration.vertexDegree {
            let angle = 2 * Float.pi * Float(index) / Float(configuration.vertexDegree)
            let tangent = SIMD3<Float>(cos(angle), sin(angle), 0)
            vertices.append(
                GroundVertex(
                    point: groundStep(
                        from: root, direction: tangent,
                        distance: configuration.edgeLength,
                        model: configuration.model),
                    anchor: 0))
        }

        var cursor = 1
        while cursor < vertices.count {
            let vertex = vertices[cursor]
            let back = vertices[vertex.anchor].point
            let backward = groundDirection(
                from: vertex.point, to: back,
                distance: configuration.edgeLength,
                model: configuration.model)
            let transverse = perpendicularGroundDirection(
                point: vertex.point, tangent: backward,
                model: configuration.model)

            for index in 1..<configuration.vertexDegree {
                let angle = 2 * Float.pi * Float(index) / Float(configuration.vertexDegree)
                let direction = backward * cos(angle) + transverse * sin(angle)
                let candidate = canonicalGroundPoint(
                    groundStep(
                        from: vertex.point, direction: direction,
                        distance: configuration.edgeLength,
                        model: configuration.model),
                    model: configuration.model)
                if groundDistance(root, candidate, model: configuration.model)
                    > configuration.tilingRadius + 1e-4
                {
                    continue
                }
                if vertices.contains(where: {
                    groundDistance($0.point, candidate, model: configuration.model) < 2e-3
                }) {
                    continue
                }
                vertices.append(GroundVertex(point: candidate, anchor: cursor))
                precondition(vertices.count < 240, "tower tiling exceeded chart capacity")
            }
            cursor += 1
        }
        return vertices
    }

    private static func groundStep(
        from point: SIMD3<Float>,
        direction: SIMD3<Float>,
        distance: Float,
        model: Model
    ) -> SIMD3<Float> {
        switch model {
        case .spherical:
            return point * cos(distance) + direction * sin(distance)
        case .hyperbolic:
            return point * cosh(distance) + direction * sinh(distance)
        case .euclidean:
            return SIMD3<Float>(
                point.x + direction.x * distance,
                point.y + direction.y * distance,
                1)
        }
    }

    private static func groundDirection(
        from point: SIMD3<Float>,
        to destination: SIMD3<Float>,
        distance: Float,
        model: Model
    ) -> SIMD3<Float> {
        switch model {
        case .spherical:
            return (destination - point * cos(distance)) / sin(distance)
        case .hyperbolic:
            return (destination - point * cosh(distance)) / sinh(distance)
        case .euclidean:
            let delta = SIMD2<Float>(
                destination.x - point.x, destination.y - point.y)
            let unit = delta / sqrt(max(delta.x * delta.x + delta.y * delta.y, 1e-8))
            return SIMD3<Float>(unit.x, unit.y, 0)
        }
    }

    private static func perpendicularGroundDirection(
        point: SIMD3<Float>,
        tangent: SIMD3<Float>,
        model: Model
    ) -> SIMD3<Float> {
        switch model {
        case .spherical:
            return normalized(cross(point, tangent))
        case .hyperbolic:
            let crossed = cross(point, tangent)
            let minkowskiCross = SIMD3<Float>(crossed.x, crossed.y, -crossed.z)
            let norm = sqrt(max(groundMetricDot(
                minkowskiCross, minkowskiCross, model: model), 1e-8))
            return minkowskiCross / norm
        case .euclidean:
            return SIMD3<Float>(-tangent.y, tangent.x, 0)
        }
    }

    private static func canonicalGroundPoint(
        _ point: SIMD3<Float>, model: Model
    ) -> SIMD3<Float> {
        switch model {
        case .spherical:
            return normalized(point)
        case .hyperbolic:
            let scale = sqrt(max(-groundMetricDot(point, point, model: model), 1e-8))
            let result = point / scale
            return result.z < 0 ? -result : result
        case .euclidean:
            return SIMD3<Float>(point.x, point.y, 1)
        }
    }

    private static func groundDistance(
        _ first: SIMD3<Float>,
        _ second: SIMD3<Float>,
        model: Model
    ) -> Float {
        switch model {
        case .spherical:
            return acos(max(-1, min(1, euclideanDot(first, second))))
        case .hyperbolic:
            return acosh(max(1, -groundMetricDot(first, second, model: model)))
        case .euclidean:
            let x = first.x - second.x
            let y = first.y - second.y
            return sqrt(x * x + y * y)
        }
    }

    private static func groundMetricDot(
        _ first: SIMD3<Float>,
        _ second: SIMD3<Float>,
        model: Model
    ) -> Float {
        if model == .hyperbolic {
            return first.x * second.x + first.y * second.y - first.z * second.z
        }
        return euclideanDot(first, second)
    }

    private static func moveGroundPointToOrigin(
        _ point: SIMD3<Float>, model: Model
    ) -> [Float] {
        switch model {
        case .euclidean:
            var matrix = identityMatrix()
            matrix[12] = -point.x
            matrix[13] = -point.y
            return matrix
        case .spherical:
            let spatial = SIMD3<Float>(point.x, point.y, 0)
            let length = sqrt(euclideanDot(spatial, spatial))
            let axis = length > 1e-7 ? spatial / length : SIMD3<Float>(1, 0, 0)
            let scale = point.z - 1
            let c0 = SIMD3<Float>(1, 0, 0) + axis * (scale * axis.x)
            let c1 = SIMD3<Float>(0, 1, 0) + axis * (scale * axis.y)
            let c2 = SIMD3<Float>(0, 0, 1) + axis * (scale * axis.z)
            return [
                c0.x, c0.y, c0.z, spatial.x,
                c1.x, c1.y, c1.z, spatial.y,
                c2.x, c2.y, c2.z, spatial.z,
                -spatial.x, -spatial.y, -spatial.z, point.z,
            ]
        case .hyperbolic:
            let spatial = SIMD3<Float>(point.x, point.y, 0)
            let scale = 1 / max(1 + point.z, 1e-6)
            let c0 = SIMD3<Float>(1, 0, 0) + spatial * (scale * spatial.x)
            let c1 = SIMD3<Float>(0, 1, 0) + spatial * (scale * spatial.y)
            let c2 = SIMD3<Float>(0, 0, 1) + spatial * (scale * spatial.z)
            return [
                c0.x, c0.y, c0.z, -spatial.x,
                c1.x, c1.y, c1.z, -spatial.y,
                c2.x, c2.y, c2.z, -spatial.z,
                -spatial.x, -spatial.y, -spatial.z, point.z,
            ]
        }
    }

    private static func identityMatrix() -> [Float] {
        [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    }

    private static func euclideanDot(
        _ first: SIMD3<Float>, _ second: SIMD3<Float>
    ) -> Float {
        first.x * second.x + first.y * second.y + first.z * second.z
    }

    private static func cross(
        _ first: SIMD3<Float>, _ second: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            first.y * second.z - first.z * second.y,
            first.z * second.x - first.x * second.z,
            first.x * second.y - first.y * second.x)
    }

    private static func normalized(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        vector / sqrt(max(euclideanDot(vector, vector), 1e-8))
    }
}
