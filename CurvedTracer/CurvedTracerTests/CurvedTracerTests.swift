//
//  CurvedTracerTests.swift
//  CurvedTracerTests
//

import Foundation
import GeometryCore
import Testing

@testable import CurvedTracer

struct CurvedTracerTests {

    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
    }

    private func int32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: uint32(bytes, at: offset))
    }

    private func float32(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: uint32(bytes, at: offset))
    }

    private func firstLightIntensity(_ bytes: [UInt8]) -> Float {
        let chartCount = Int(int32(bytes, at: 160))
        let portalCount = Int(int32(bytes, at: 164))
        let objectCount = Int(int32(bytes, at: 168))
        let materialCount = Int(int32(bytes, at: 172))
        let lightCount = Int(int32(bytes, at: 176))
        let quadricCount = Int(int32(bytes, at: 180))
        let clipCount = Int(int32(bytes, at: 184))
        #expect(lightCount > 0)
        let lightOffset = 192
            + chartCount * 32
            + portalCount * 112
            + objectCount * 48
            + quadricCount * 64
            + clipCount * 32
            + materialCount * 48
        return float32(bytes, at: lightOffset + 28)
    }

    private func materialOffset(_ bytes: [UInt8], index: Int) -> Int {
        let chartCount = Int(int32(bytes, at: 160))
        let portalCount = Int(int32(bytes, at: 164))
        let objectCount = Int(int32(bytes, at: 168))
        let materialCount = Int(int32(bytes, at: 172))
        let quadricCount = Int(int32(bytes, at: 180))
        let clipCount = Int(int32(bytes, at: 184))
        #expect(index >= 0 && index < materialCount)
        return 192
            + chartCount * 32
            + portalCount * 112
            + objectCount * 48
            + quadricCount * 64
            + clipCount * 32
            + index * 48
    }

    private func objectUsesMaterial(_ bytes: [UInt8], material: Int32) -> Bool {
        let chartCount = Int(int32(bytes, at: 160))
        let portalCount = Int(int32(bytes, at: 164))
        let objectCount = Int(int32(bytes, at: 168))
        let firstObject = 192 + chartCount * 32 + portalCount * 112
        return (0..<objectCount).contains {
            int32(bytes, at: firstObject + $0 * 48 + 24) == material
        }
    }

    private func matrix(_ bytes: [UInt8], at offset: Int) -> [Float] {
        (0..<16).map { float32(bytes, at: offset + $0 * 4) }
    }

    private func matrixProduct(_ left: [Float], _ right: [Float]) -> [Float] {
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

    private func matrixTranspose(_ matrix: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: 16)
        for column in 0..<4 {
            for row in 0..<4 {
                result[row * 4 + column] = matrix[column * 4 + row]
            }
        }
        return result
    }

    private func s3MovePointToOrigin(_ point: geo.vec4) -> [Float] {
        let scale = -1 / max(1 + point.w, 1e-6)
        let u = SIMD3<Float>(point.x, point.y, point.z)
        let c0 = SIMD3<Float>(1, 0, 0) + u * (scale * u.x)
        let c1 = SIMD3<Float>(0, 1, 0) + u * (scale * u.y)
        let c2 = SIMD3<Float>(0, 0, 1) + u * (scale * u.z)
        [
            c0.x, c0.y, c0.z, u.x,
            c1.x, c1.y, c1.z, u.y,
            c2.x, c2.y, c2.z, u.z,
            -u.x, -u.y, -u.z, point.w,
        ]
    }

    @Test func renderResolutionDefaultsAndValidation() {
        #expect(RenderResolution.qhd540.width == 960)
        #expect(RenderResolution.qhd540.height == 540)
        #expect(RenderResolution.qhd540.aspectRatio == 16.0 / 9.0)
        #expect(RenderResolution.hd720.width == 1280)
        #expect(RenderResolution.hd720.height == 720)
        #expect(RenderResolution.hd720.aspectRatio == 16.0 / 9.0)
        #expect(RenderResolution(width: 1024, height: 768).aspectRatio == 4.0 / 3.0)
        #expect(RenderResolution.isValid(width: 1, height: 1))
        #expect(!RenderResolution.isValid(width: 0, height: 720))
        #expect(!RenderResolution.isValid(width: 1280, height: -1))
        #expect(
            RenderResolution.hd720.isSpatialUpscaleTarget(
                width: 1920, height: 1080))
        #expect(
            RenderResolution.hd720.isSpatialUpscaleTarget(
                width: 2560, height: 1440))
        #expect(
            !RenderResolution.hd720.isSpatialUpscaleTarget(
                width: 1280, height: 720))
        #expect(
            !RenderResolution.hd720.isSpatialUpscaleTarget(
                width: 1600, height: 1000))
    }

    @Test func photoModeStateStartsStopsAndResetsProgress() {
        var state = PhotoModeState()
        #expect(state.renderingMode == .realtime)
        #expect(state.sampleIndex == 0)

        state.recordSubmittedSample()
        #expect(state.sampleIndex == 0)

        state.enter()
        #expect(state.renderingMode == .photo)
        #expect(state.sampleIndex == 0)
        state.recordSubmittedSample()
        state.recordSubmittedSample()
        #expect(state.sampleIndex == 2)

        state.exit()
        #expect(state.renderingMode == .realtime)
        #expect(state.sampleIndex == 0)

        state.enter()
        #expect(state.renderingMode == .photo)
        #expect(state.sampleIndex == 0)
    }

    @Test func performanceStatisticsNormalizeAndPublishSamples() {
        let stats = PerformanceStats()
        stats.recordFrame(at: 10)
        stats.recordGPUTime(seconds: 0.01)
        stats.recordTrace(
            rayCount: 100,
            portalHops: 200,
            compoundHops: 5,
            maximumHops: 7,
            hopLimitRays: 1,
            portalTests: 1_200)
        stats.recordFrame(at: 10.5)

        #expect(abs(stats.snapshot.framesPerSecond - 2) < 0.0001)
        #expect(abs(stats.snapshot.frameMilliseconds - 500) < 0.0001)
        #expect(abs(stats.snapshot.gpuMilliseconds - 10) < 0.0001)
        #expect(abs(stats.snapshot.portalHopsPerRay - 2) < 0.0001)
        #expect(abs(stats.snapshot.compoundHopsPerRay - 0.05) < 0.0001)
        #expect(abs(stats.snapshot.portalTestsPerRay - 12) < 0.0001)
        #expect(stats.snapshot.maximumPortalHops == 7)
        #expect(stats.snapshot.hopLimitRays == 1)
    }

    @Test func allSpaceTraversalScenesBuildV16MaterialPackets() {
        #expect(AmbientSpace.allCases.count == 3)
        #expect(TraversalMode.allCases.count == 2)
        #expect(EuclideanFlatSceneVariant.allCases.count == 2)
        #expect(SphericalFlatSceneVariant.allCases.count == 7)
        #expect(HyperbolicFlatSceneVariant.allCases.count == 4)
        #expect(SphericalAtlasVariant.allCases.count == 2)
        #expect(EuclideanAtlasVariant.allCases.count == 2)
        #expect(HyperbolicAtlasVariant.allCases.count == 3)
        var atlas = geo.Atlas()
        let builders: [(inout geo.Atlas) -> Int32] = [
            SphericalScene.cell600, SphericalScene.objectDemo,
            SphericalScene.pathTracingRoom,
            SphericalScene.primitiveGallery, SphericalScene.hopfFibration,
            SphericalScene.hopfFacePatches,
            SphericalScene.cliffordTorusConstruction,
            SphericalScene.lensSpaceL52,
            HyperbolicScene.honeycombCell, HyperbolicScene.poincareBallDemo,
            HyperbolicScene.pathTracingRoom,
            HyperbolicScene.primitiveGallery,
            HyperbolicScene.seifertWeberAtlas,
            HyperbolicScene.seifertWeberMultiChartAtlas,
            EuclideanScene.finite, EuclideanScene.pathTracingRoom,
            EuclideanScene.torus,
            TowerScene.spherical, TowerScene.euclidean,
            TowerScene.hyperbolic,
        ]
        for build in builders {
            _ = build(&atlas)
            let bytes = [UInt8](atlas.packetBytes())
            #expect(atlas.packetSize() >= 192)
            #expect(int32(bytes, at: 4) == 16)
            let materialCount = Int(int32(bytes, at: 172))
            #expect(materialCount > 0)
        }
    }

    @Test func sphericalAndEuclideanTowerLayoutsUseNearestTowerAxis() {
        var atlas = geo.Atlas()

        _ = TowerScene.spherical(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 160) == 11)
        #expect(int32(bytes, at: 164) == 20)
        var forward = atlas.cameraFwd()
        #expect(forward.x > 0.9)
        #expect(abs(forward.y) < 0.0001)
        #expect(forward.z < 0)

        _ = TowerScene.euclidean(&atlas)
        bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 160) == 9)
        #expect(int32(bytes, at: 164) == 16)
        forward = atlas.cameraFwd()
        #expect(forward.x > 0.9)
        #expect(abs(forward.y) < 0.0001)
        #expect(forward.z < 0)
    }

    @Test func primitiveGalleriesEncodeLinearQuadraticAndClippedSurfaces() {
        var atlas = geo.Atlas()
        _ = SphericalScene.primitiveGallery(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 5)
        #expect(int32(bytes, at: 172) == 5)
        #expect(int32(bytes, at: 180) == 2)
        #expect(int32(bytes, at: 184) == 8)
        let firstObject = 192 + 32
        #expect(int32(bytes, at: firstObject + 20) == 0)
        let mirror = firstObject + 2 * 48
        #expect(int32(bytes, at: mirror + 32) == 4)
        for ring in 0..<2 {
            let object = firstObject + (3 + ring) * 48
            #expect(int32(bytes, at: object + 20) == 2)
            #expect(int32(bytes, at: object + 24) == Int32(3 + ring))
            #expect(int32(bytes, at: object + 28) == 8)
            #expect(int32(bytes, at: object + 32) == 0)
            #expect(int32(bytes, at: object + 36) == Int32(ring))
        }

        _ = HyperbolicScene.primitiveGallery(&atlas)
        bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 4)
        #expect(int32(bytes, at: 180) == 1)
        #expect(int32(bytes, at: 184) == 9)
        let hyperbolicMirror = 192 + 32 + 3 * 48
        #expect(int32(bytes, at: hyperbolicMirror + 32) == 4)
    }

    @Test func catalogPointLightsCompensateLambertianNormalization() {
        var atlas = geo.Atlas()
        _ = EuclideanScene.finite(&atlas)
        #expect(
            abs(firstLightIntensity([UInt8](atlas.packetBytes())) - Float.pi)
                < 0.0001)

        _ = EuclideanScene.pathTracingRoom(&atlas)
        #expect(
            abs(firstLightIntensity([UInt8](atlas.packetBytes())) - 100)
                < 0.0001)
    }

    @Test func pathTracingRoomsEncodeEmissiveSurfaceMaterials() {
        var atlas = geo.Atlas()
        let builders: [(inout geo.Atlas) -> Int32] = [
            EuclideanScene.pathTracingRoom,
            SphericalScene.pathTracingRoom,
            HyperbolicScene.pathTracingRoom,
        ]
        for build in builders {
            _ = build(&atlas)
            let bytes = [UInt8](atlas.packetBytes())
            #expect(int32(bytes, at: 172) == 8)
            let emitter = materialOffset(bytes, index: 7)
            #expect(abs(float32(bytes, at: emitter + 16) - 8) < 0.0001)
            #expect(abs(float32(bytes, at: emitter + 20) - 2) < 0.0001)
            #expect(abs(float32(bytes, at: emitter + 24) - 0.25) < 0.0001)
            #expect(objectUsesMaterial(bytes, material: 7))
        }
    }

    @Test func hopfFibrationUsesDodecahedralFiberTubes() {
        var atlas = geo.Atlas()
        _ = SphericalScene.hopfFibration(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 160) == 1)
        #expect(int32(bytes, at: 164) == 0)
        #expect(int32(bytes, at: 168) == 20)
        #expect(int32(bytes, at: 172) == 5)
        #expect(int32(bytes, at: 176) == 2)
        #expect(int32(bytes, at: 180) == 20)
        #expect(int32(bytes, at: 184) == 0)

        let cameraPlacement = SphericalScene.hopfFibrationCameraPlacement()
        let point = cameraPlacement.point
        let hopfImage = SIMD3<Float>(
            2 * (point.x * point.z + point.y * point.w),
            2 * (point.x * point.y - point.z * point.w),
            point.x * point.x + point.w * point.w
                - point.y * point.y - point.z * point.z)
        let base = cameraPlacement.base
        #expect(abs(hopfImage.x - base.x) < 0.0001)
        #expect(abs(hopfImage.y - base.y) < 0.0001)
        #expect(abs(hopfImage.z - base.z) < 0.0001)
        let cameraForward = atlas.cameraFwd()
        #expect(
            abs(cameraForward.x - cameraPlacement.centeredForward.x) < 0.0001)
        #expect(
            abs(cameraForward.y - cameraPlacement.centeredForward.y) < 0.0001)
        #expect(
            abs(cameraForward.z - cameraPlacement.centeredForward.z) < 0.0001)

        let firstObject = 192 + 32
        var fiberMaterials: [Int32] = []
        for fiber in 0..<20 {
            let object = firstObject + fiber * 48
            let material = int32(bytes, at: object + 24)
            #expect(material >= 0 && material < 5)
            fiberMaterials.append(material)
            #expect(int32(bytes, at: object + 20) == 2)
            #expect(int32(bytes, at: object + 28) == 0)
            #expect(int32(bytes, at: object + 32) == 0)
            #expect(int32(bytes, at: object + 36) == Int32(fiber))
        }

        // The flattened packet is expressed in the camera-centered frame.
        // Undo that frame before recovering each tube's S² base direction.
        let cameraFrame = s3MovePointToOrigin(cameraPlacement.point)
        let inverseCameraFrame = matrixTranspose(cameraFrame)
        let firstQuadric = firstObject + 20 * 48
        var directions: [SIMD3<Float>] = []
        var directionsByMaterial = [[SIMD3<Float>]](repeating: [], count: 5)
        var cubeVertexCount = 0
        var goldenVertexCount = 0
        let inverseRootThree = 1 / sqrt(Float(3))
        let phi = (Float(1) + sqrt(5)) / 2
        let base = cameraPlacement.base
        let goldenPattern = [Float(0), 1 / phi, phi].map {
            $0 * inverseRootThree
        }
        for fiber in 0..<20 {
            let flatQuadric = matrix(bytes, at: firstQuadric + fiber * 64)
            let quadric = matrixProduct(
                matrixProduct(inverseCameraFrame, flatQuadric), cameraFrame)
            let raw = SIMD3<Float>(
                -(quadric[2] + quadric[8]) / 2,
                -(quadric[1] + quadric[4]) / 2,
                (quadric[5] - quadric[0]) / 2)
            let direction = raw / sqrt(
                raw.x * raw.x + raw.y * raw.y + raw.z * raw.z)
            for previous in directions {
                let delta = direction - previous
                #expect(
                    delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
                        > 0.01)
            }
            directions.append(direction)
            directionsByMaterial[Int(fiberMaterials[fiber])].append(direction)

            let coordinates = [
                abs(direction.x), abs(direction.y), abs(direction.z),
            ].sorted()
            if coordinates[0] > 0.5 {
                cubeVertexCount += 1
                for coordinate in coordinates {
                    #expect(abs(coordinate - inverseRootThree) < 0.0001)
                }
            } else {
                goldenVertexCount += 1
                for index in 0..<3 {
                    #expect(abs(coordinates[index] - goldenPattern[index]) < 0.0001)
                }
            }
        }
        #expect(cubeVertexCount == 8)
        #expect(goldenVertexCount == 12)

        let faceProducts = directions.map {
            $0.x * base.x + $0.y * base.y + $0.z * base.z
        }.sorted(by: >)
        for index in 1..<5 {
            #expect(abs(faceProducts[index] - faceProducts[0]) < 0.0001)
        }
        #expect(faceProducts[4] - faceProducts[5] > 0.1)

        for tetrahedron in directionsByMaterial {
            #expect(tetrahedron.count == 4)
            for first in 0..<tetrahedron.count {
                for second in (first + 1)..<tetrahedron.count {
                    let product = tetrahedron[first].x * tetrahedron[second].x
                        + tetrahedron[first].y * tetrahedron[second].y
                        + tetrahedron[first].z * tetrahedron[second].z
                    #expect(abs(product + 1 / Float(3)) < 0.0001)
                }
            }
        }

        // The source atlas has two large, complementary charts. Each chart
        // owns ten complete tubes; no explicit hemisphere clips are needed.
        #expect(atlas.buildAtlas(atlas.cameraChartId(), 64, 1, 32) == 0)
        bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 160) == 2)
        #expect(int32(bytes, at: 164) == 0)
        #expect(int32(bytes, at: 168) == 20)
        #expect(int32(bytes, at: 176) == 2)
        #expect(int32(bytes, at: 180) == 20)
        #expect(int32(bytes, at: 184) == 0)
        #expect(float32(bytes, at: 192) == 0)
        #expect(float32(bytes, at: 196) == 0)
        #expect(float32(bytes, at: 224) == 0)
        #expect(float32(bytes, at: 228) == 0)
        #expect(int32(bytes, at: 192 + 20) == 10)
        #expect(int32(bytes, at: 224 + 20) == 10)
        #expect(int32(bytes, at: 192 + 28) == 2)
        #expect(int32(bytes, at: 224 + 28) == 0)
        #expect(abs(float32(bytes, at: 16) - 0) < 0.0001)
        #expect(abs(float32(bytes, at: 20) - 0) < 0.0001)
        #expect(abs(float32(bytes, at: 24) - 0) < 0.0001)
        #expect(abs(float32(bytes, at: 28) - 1) < 0.0001)
    }

    @Test func hopfFacePatchesUseCliffordTorusClips() {
        var atlas = geo.Atlas()
        _ = SphericalScene.hopfFacePatches(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 160) == 1)
        #expect(int32(bytes, at: 164) == 0)
        #expect(int32(bytes, at: 168) == 10)
        #expect(int32(bytes, at: 172) == 5)
        #expect(int32(bytes, at: 176) == 2)
        #expect(int32(bytes, at: 180) == 30)
        #expect(int32(bytes, at: 184) == 30)

        let firstObject = 192 + 32
        let firstClip = firstObject + 10 * 48 + 30 * 64
        for patch in 0..<10 {
            let object = firstObject + patch * 48
            #expect(int32(bytes, at: object + 20) == 2)
            #expect(int32(bytes, at: object + 24) == Int32(patch % 5))
            #expect(int32(bytes, at: object + 28) == Int32(patch * 3))
            #expect(int32(bytes, at: object + 32) == 3)
            #expect(int32(bytes, at: object + 36) == Int32(patch * 3))

            let clip = firstClip + patch * 3 * 32
            #expect(int32(bytes, at: clip + 20) == 2)
            #expect(int32(bytes, at: clip + 24) == Int32(patch * 3 + 1))
            #expect(int32(bytes, at: clip + 28) == 0)
            #expect(int32(bytes, at: clip + 32 + 20) == 2)
            #expect(int32(bytes, at: clip + 32 + 24) == Int32(patch * 3 + 2))
            #expect(int32(bytes, at: clip + 32 + 28) == 0)
            #expect(int32(bytes, at: clip + 64 + 20) == 0)
        }

        // The third authored clip splits each patch at the chart equator.
        // The second chart owns the complementary hemisphere, so flattening
        // remains disjoint while a radius-independent camera can complete a
        // fiber loop without changing its coordinate chart.
        #expect(atlas.buildAtlas(atlas.cameraChartId(), 64, 1, 32) == 0)
        bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 160) == 2)
        #expect(int32(bytes, at: 168) == 10)
        #expect(int32(bytes, at: 180) == 30)
        #expect(int32(bytes, at: 184) == 30)

        let placement = SphericalScene.hopfFibrationCameraPlacement()
        let initialForward = atlas.cameraFwd()
        var visitedCharts = Set<Int32>([atlas.cameraChartId()])
        for _ in 0..<628 {
            let forward = atlas.cameraFwd()
            _ = atlas.cameraMove(
                geo.vec3(forward.x * 0.01, forward.y * 0.01, forward.z * 0.01))
            visitedCharts.insert(atlas.cameraChartId())
        }
        #expect(visitedCharts == Set([Int32(0)]))
        #expect(atlas.cameraChartId() == 0)
        #expect(abs(atlas.cameraFwd().x - initialForward.x) < 0.0001)
        #expect(abs(atlas.cameraFwd().y - initialForward.y) < 0.0001)
        #expect(abs(atlas.cameraFwd().z - initialForward.z) < 0.0001)
        #expect(atlas.buildAtlas(atlas.cameraChartId(), 64, 1, 32) == 0)
        bytes = [UInt8](atlas.packetBytes())
        #expect(abs(float32(bytes, at: 16)) < 0.01)
        #expect(abs(float32(bytes, at: 20)) < 0.01)
        #expect(abs(float32(bytes, at: 24)) < 0.01)
        #expect(abs(float32(bytes, at: 28) - 1) < 0.01)

        let cameraForward = atlas.cameraFwd()
        #expect(abs(cameraForward.x - placement.centeredForward.x) < 0.01)
        #expect(abs(cameraForward.y - placement.centeredForward.y) < 0.01)
        #expect(abs(cameraForward.z - placement.centeredForward.z) < 0.01)
    }

    @Test func cliffordTorusUsesEightCheckerboardReflectionPatches() {
        var atlas = geo.Atlas()
        _ = SphericalScene.cliffordTorusConstruction(&atlas)
        let bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 12)
        #expect(int32(bytes, at: 172) == 4)
        #expect(int32(bytes, at: 180) == 12)
        #expect(int32(bytes, at: 184) == 36)

        let firstObject = 192 + 32
        var colors: [Int32] = []
        for piece in 0..<8 {
            let object = firstObject + piece * 48
            #expect(int32(bytes, at: object + 20) == 2)
            colors.append(int32(bytes, at: object + 24))
            #expect(int32(bytes, at: object + 28) == Int32(piece * 4))
            #expect(int32(bytes, at: object + 32) == 4)
            #expect(int32(bytes, at: object + 36) == Int32(piece))
        }
        #expect(Set(colors) == Set([Int32(0), Int32(1)]))

        // Each polar-circle tube is split into two chart-local hemispheres.
        for half in 0..<4 {
            let object = firstObject + (8 + half) * 48
            #expect(int32(bytes, at: object + 20) == 2)
            #expect(int32(bytes, at: object + 24) == Int32(2 + half / 2))
            #expect(int32(bytes, at: object + 28) == Int32(32 + half))
            #expect(int32(bytes, at: object + 32) == 1)
            #expect(int32(bytes, at: object + 36) == Int32(8 + half))
        }

        let signs = [
            [1, 1, 1, 1], [1, 1, -1, -1], [1, -1, 1, -1],
            [1, -1, -1, 1], [-1, 1, 1, -1], [-1, 1, -1, 1],
            [-1, -1, 1, 1], [-1, -1, -1, -1],
        ]
        let edgeHalfTurns = [
            [1, 1, -1, -1], [-1, 1, 1, -1],
            [-1, -1, 1, 1], [1, -1, -1, 1],
        ]
        for piece in signs.indices {
            for halfTurn in edgeHalfTurns {
                let neighborSigns = zip(signs[piece], halfTurn).map { pair in
                    pair.0 * pair.1
                }
                let neighbor = signs.firstIndex(of: neighborSigns)!
                #expect(colors[piece] != colors[neighbor])
            }
        }

        var visitedCharts = Set<Int32>([atlas.cameraChartId()])
        for _ in 0..<400 {
            let forward = atlas.cameraFwd()
            _ = atlas.cameraMove(
                geo.vec3(forward.x * 0.01, forward.y * 0.01, forward.z * 0.01))
            visitedCharts.insert(atlas.cameraChartId())
        }
        #expect(visitedCharts == Set([Int32(0)]))
        #expect(atlas.build(atlas.cameraChartId(), 64) == 0)
    }

    @Test func multiChartSeifertWeberBuildsStateGraph() {
        var atlas = geo.Atlas()
        _ = HyperbolicScene.seifertWeberMultiChartAtlas(&atlas)
        let bytes = [UInt8](atlas.packetBytes())

        #expect(int32(bytes, at: 160) == 14)
        #expect(int32(bytes, at: 164) == 168)
        #expect(int32(bytes, at: 168) == 28)
        #expect(int32(bytes, at: 176) == 14)

        let firstPortalOffset = 192 + 14 * 32
        // Explicit zero displacement puts the trigger on the mathematical
        // face: H3 normals use sinh(distance) in their w component.
        let q: Float = 1 / sqrt(5)
        let inradius = asinh(sqrt((q + cos(2 * Float.pi / 5)) / (1 - q)))
        #expect(abs(abs(float32(bytes, at: firstPortalOffset + 64 + 12)) - sinh(inradius)) < 0.0001)
        #expect(int32(bytes, at: firstPortalOffset + 100) == 1)
    }

    @Test func sphericalAtlasIsLensSpaceL52() {
        var atlas = geo.Atlas()
        _ = SphericalScene.lensSpaceL52(&atlas)
        let bytes = [UInt8](atlas.packetBytes())

        #expect(int32(bytes, at: 160) == 1)
        #expect(int32(bytes, at: 164) == 2)
        #expect(int32(bytes, at: 168) == 2)
        #expect(int32(bytes, at: 172) == 2)
        #expect(int32(bytes, at: 176) == 1)
        #expect(float32(bytes, at: 192) == 0)
        #expect(float32(bytes, at: 196) == 0)

        let firstPortalOffset = 192 + 32
        let generator = matrix(bytes, at: firstPortalOffset)
        #expect(abs(generator[0] - cos(2 * Float.pi / 5)) < 0.0001)
        #expect(abs(generator[5] - cos(4 * Float.pi / 5)) < 0.0001)
        #expect(int32(bytes, at: firstPortalOffset + 100) == 0)
        #expect(int32(bytes, at: firstPortalOffset + 104) == 1)

        var fifthPower: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        for _ in 0..<5 {
            fifthPower = matrixProduct(fifthPower, generator)
        }
        for index in 0..<16 {
            let expected: Float = index % 5 == 0 ? 1 : 0
            #expect(abs(fifthPower[index] - expected) < 0.0001)
        }
    }

    @Test func sphericalFlatSceneIsFull600Cell() {
        var atlas = geo.Atlas()
        _ = SphericalScene.cell600(&atlas)
        let bytes = [UInt8](atlas.packetBytes())

        // CPU flattening emits one camera chart, but it must contain all five
        // local vertices from each of the 24 authored overlap charts.
        #expect(int32(bytes, at: 160) == 1)
        #expect(int32(bytes, at: 164) == 0)
        #expect(int32(bytes, at: 168) == 120)
        #expect(int32(bytes, at: 172) == 5)
        #expect(int32(bytes, at: 176) == 4)
        #expect(abs(float32(bytes, at: 88) - Float.pi * 0.9) < 0.0001)
    }

    @Test func physicalMirrorTintAndAtlasFogAreEncodedInScenePackets() {
        var atlas = geo.Atlas()

        _ = HyperbolicScene.poincareBallDemo(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        let chartCount = Int(int32(bytes, at: 160))
        let portalCount = Int(int32(bytes, at: 164))
        let objectCount = Int(int32(bytes, at: 168))
        #expect(objectCount == 7)
        #expect(int32(bytes, at: 172) == 8)
        #expect(int32(bytes, at: 176) == 2)
        let quadricCount = Int(int32(bytes, at: 180))
        let clipCount = Int(int32(bytes, at: 184))
        let materialOffset = 192 + chartCount * 32 + portalCount * 112
            + objectCount * 48 + quadricCount * 64 + clipCount * 32
        let mirrorColorOffset = materialOffset + 6 * 48
        #expect(abs(float32(bytes, at: mirrorColorOffset) - 0.405) < 0.0001)
        #expect(abs(float32(bytes, at: mirrorColorOffset + 4) - 0.855) < 0.0001)
        #expect(abs(float32(bytes, at: mirrorColorOffset + 8) - 0.9) < 0.0001)
        #expect(float32(bytes, at: mirrorColorOffset + 28) == 0.0)
        #expect(float32(bytes, at: mirrorColorOffset + 32) == 1.0)

        _ = HyperbolicScene.seifertWeberAtlas(&atlas)
        bytes = [UInt8](atlas.packetBytes())
        #expect(abs(float32(bytes, at: 140) - 0.6) < 0.0001)
        #expect(float32(bytes, at: 192) == 0)
        #expect(float32(bytes, at: 196) == 0)
        let seifertPortalCount = Int(int32(bytes, at: 164))
        let seifertObjectOffset = 192 + 32 + seifertPortalCount * 112
        let firstRadius = acosh(float32(bytes, at: seifertObjectOffset + 16))
        let secondRadius = acosh(float32(bytes, at: seifertObjectOffset + 48 + 16))
        #expect(abs(firstRadius - 0.1883983) < 0.0001)
        #expect(abs(secondRadius - 0.2143091) < 0.0001)

        let firstCenter = (0..<4).map { float32(bytes, at: seifertObjectOffset + $0 * 4) }
        let secondCenter = (0..<4).map { float32(bytes, at: seifertObjectOffset + 48 + $0 * 4) }
        let lorentzProduct =
        firstCenter[0] * secondCenter[0]
        + firstCenter[1] * secondCenter[1]
        + firstCenter[2] * secondCenter[2]
        - firstCenter[3] * secondCenter[3]
        #expect(abs(acosh(-lorentzProduct) - 0.8624676) < 0.0001)

        _ = EuclideanScene.torus(&atlas)
        bytes = [UInt8](atlas.packetBytes())
        #expect(abs(float32(bytes, at: 140) - 0.6) < 0.0001)
    }

    @Test func pathRoomUsesConductorAndDielectricGGXDispatch() {
        var atlas = geo.Atlas()
        _ = EuclideanScene.pathTracingRoom(&atlas)
        let bytes = [UInt8](atlas.packetBytes())
        let chartCount = Int(int32(bytes, at: 160))
        let portalCount = Int(int32(bytes, at: 164))
        let objectCount = Int(int32(bytes, at: 168))
        let materialCount = Int(int32(bytes, at: 172))
        let quadricCount = Int(int32(bytes, at: 180))
        let clipCount = Int(int32(bytes, at: 184))
        #expect(objectCount == 11)
        #expect(materialCount == 8)

        let objectOffset = 192 + chartCount * 32 + portalCount * 112
        let blueObjectOffset = objectOffset + 6 * 48
        #expect(int32(bytes, at: blueObjectOffset + 24) == 3)
        let mirrorObjectOffset = objectOffset + 7 * 48
        #expect(int32(bytes, at: mirrorObjectOffset + 24) == 4)

        let materialOffset = objectOffset + objectCount * 48
            + quadricCount * 64 + clipCount * 32
        let blueMaterialOffset = materialOffset + 3 * 48
        #expect(abs(float32(bytes, at: blueMaterialOffset + 28) - 0.38) < 0.0001)
        #expect(float32(bytes, at: blueMaterialOffset + 32) == 0.0)
        #expect(float32(bytes, at: blueMaterialOffset + 36) == 1.5)
        #expect(float32(bytes, at: blueMaterialOffset + 40) == 0.0)
        let mirrorMaterialOffset = materialOffset + 4 * 48
        #expect(abs(float32(bytes, at: mirrorMaterialOffset) - 0.92) < 0.0001)
        #expect(abs(float32(bytes, at: mirrorMaterialOffset + 4) - 0.95) < 0.0001)
        #expect(float32(bytes, at: mirrorMaterialOffset + 8) == 1.0)
        #expect(float32(bytes, at: mirrorMaterialOffset + 28) == 0.0)
        #expect(float32(bytes, at: mirrorMaterialOffset + 32) == 1.0)
        #expect(float32(bytes, at: mirrorMaterialOffset + 40) == 0.0)

        let glassObjectOffset = objectOffset + 8 * 48
        #expect(int32(bytes, at: glassObjectOffset + 24) == 5)
        let glassMaterialOffset = materialOffset + 5 * 48
        #expect(abs(float32(bytes, at: glassMaterialOffset) - 0.98) < 0.0001)
        #expect(abs(float32(bytes, at: glassMaterialOffset + 4) - 0.99) < 0.0001)
        #expect(float32(bytes, at: glassMaterialOffset + 8) == 1.0)
        #expect(abs(float32(bytes, at: glassMaterialOffset + 28) - 0.18) < 0.0001)
        #expect(float32(bytes, at: glassMaterialOffset + 32) == 0.0)
        #expect(float32(bytes, at: glassMaterialOffset + 36) == 1.5)
        #expect(float32(bytes, at: glassMaterialOffset + 40) == 1.0)

        let roughMetalObjectOffset = objectOffset + 9 * 48
        #expect(int32(bytes, at: roughMetalObjectOffset + 24) == 6)
        let roughMetalMaterialOffset = materialOffset + 6 * 48
        #expect(abs(float32(bytes, at: roughMetalMaterialOffset) - 0.95) < 0.0001)
        #expect(abs(float32(bytes, at: roughMetalMaterialOffset + 4) - 0.64) < 0.0001)
        #expect(abs(float32(bytes, at: roughMetalMaterialOffset + 8) - 0.2) < 0.0001)
        #expect(abs(float32(bytes, at: roughMetalMaterialOffset + 28) - 0.32) < 0.0001)
        #expect(float32(bytes, at: roughMetalMaterialOffset + 32) == 1.0)
        #expect(float32(bytes, at: roughMetalMaterialOffset + 40) == 0.0)
    }

}
