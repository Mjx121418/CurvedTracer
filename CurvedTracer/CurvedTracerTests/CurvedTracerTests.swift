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
            + portalCount * 96
            + objectCount * 48
            + quadricCount * 64
            + clipCount * 32
            + materialCount * 64
        return float32(bytes, at: lightOffset + 28)
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

    @Test func renderResolutionDefaultsAndValidation() {
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

    @Test func allSpaceTraversalScenesBuildV13Packets() {
        #expect(AmbientSpace.allCases.count == 3)
        #expect(TraversalMode.allCases.count == 2)
        #expect(EuclideanFlatSceneVariant.allCases.count == 2)
        #expect(SphericalFlatSceneVariant.allCases.count == 6)
        #expect(HyperbolicFlatSceneVariant.allCases.count == 4)
        #expect(HyperbolicAtlasVariant.allCases.count == 2)
        var atlas = geo.Atlas()
        let builders: [(inout geo.Atlas) -> Int32] = [
            SphericalScene.cell600, SphericalScene.objectDemo,
            SphericalScene.pathTracingRoom,
            SphericalScene.primitiveGallery, SphericalScene.hopfFibration,
            SphericalScene.cliffordTorusConstruction,
            SphericalScene.lensSpaceL52,
            HyperbolicScene.honeycombCell, HyperbolicScene.poincareBallDemo,
            HyperbolicScene.pathTracingRoom,
            HyperbolicScene.primitiveGallery,
            HyperbolicScene.seifertWeberAtlas,
            HyperbolicScene.seifertWeberMultiChartAtlas,
            EuclideanScene.finite, EuclideanScene.pathTracingRoom,
            EuclideanScene.torus,
        ]
        for build in builders {
            _ = build(&atlas)
            #expect(atlas.packetSize() >= 192)
            #expect(int32([UInt8](atlas.packetBytes()), at: 4) == 13)
        }
    }

    @Test func primitiveGalleriesEncodeLinearQuadraticAndClippedSurfaces() {
        var atlas = geo.Atlas()
        _ = SphericalScene.primitiveGallery(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 5)
        #expect(int32(bytes, at: 172) == 5)
        #expect(int32(bytes, at: 180) == 2)
        #expect(int32(bytes, at: 184) == 10)
        let firstObject = 192 + 32
        #expect(int32(bytes, at: firstObject + 20) == 0)
        for ring in 0..<2 {
            let object = firstObject + (3 + ring) * 48
            #expect(int32(bytes, at: object + 20) == 2)
            #expect(int32(bytes, at: object + 28) == Int32(3 + ring))
            #expect(int32(bytes, at: object + 36) == 1)
            #expect(int32(bytes, at: object + 40) == Int32(ring))
        }

        _ = HyperbolicScene.primitiveGallery(&atlas)
        bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 4)
        #expect(int32(bytes, at: 180) == 1)
        #expect(int32(bytes, at: 184) == 10)
    }

    @Test func legacyPointLightsCompensateLambertianNormalization() {
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

    @Test func hopfFibrationUsesDodecahedralFiberTubes() {
        var atlas = geo.Atlas()
        _ = SphericalScene.hopfFibration(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 40)
        #expect(int32(bytes, at: 172) == 5)
        #expect(int32(bytes, at: 180) == 40)
        #expect(int32(bytes, at: 184) == 80)

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
            let firstHalf = firstObject + fiber * 2 * 48
            let secondHalf = firstHalf + 48
            let material = int32(bytes, at: firstHalf + 28)
            #expect(material >= 0 && material < 5)
            #expect(int32(bytes, at: secondHalf + 28) == material)
            fiberMaterials.append(material)

            for half in 0..<2 {
                let halfIndex = fiber * 2 + half
                let object = firstObject + halfIndex * 48
                #expect(int32(bytes, at: object + 20) == 2)
                #expect(int32(bytes, at: object + 32) == Int32(halfIndex * 2))
                #expect(int32(bytes, at: object + 36) == 2)
                #expect(int32(bytes, at: object + 40) == Int32(halfIndex))
            }
        }

        // Inspect un-recentered chart quadrics when recovering their S² base
        // directions; the rendered packet is expressed in camera coordinates.
        #expect(atlas.buildAtlas(atlas.cameraChartId(), 64, 1, 32) == 0)
        bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 160) == 2)
        #expect(int32(bytes, at: 168) == 40)
        #expect(int32(bytes, at: 180) == 40)
        #expect(int32(bytes, at: 184) == 40)
        let firstQuadric = 192 + 2 * 32 + 40 * 48
        let inverseRootThree = 1 / sqrt(Float(3))
        let phi = (Float(1) + sqrt(5)) / 2
        let goldenPattern = [Float(0), 1 / phi, phi].map {
            $0 * inverseRootThree
        }
        var directions: [SIMD3<Float>] = []
        var directionsByMaterial = [[SIMD3<Float>]](repeating: [], count: 5)
        var cubeVertexCount = 0
        var goldenVertexCount = 0
        for fiber in 0..<20 {
            let quadric = matrix(bytes, at: firstQuadric + fiber * 64)
            let pairedQuadric = matrix(
                bytes, at: firstQuadric + (20 + fiber) * 64)
            for index in 0..<16 {
                #expect(abs(quadric[index] - pairedQuadric[index]) < 0.0001)
            }

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
    }

    @Test func cliffordTorusUsesEightCheckerboardReflectionPatches() {
        var atlas = geo.Atlas()
        _ = SphericalScene.cliffordTorusConstruction(&atlas)
        let bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 12)
        #expect(int32(bytes, at: 172) == 4)
        #expect(int32(bytes, at: 180) == 12)
        #expect(int32(bytes, at: 184) == 48)

        let firstObject = 192 + 32
        var colors: [Int32] = []
        for piece in 0..<8 {
            let object = firstObject + piece * 48
            #expect(int32(bytes, at: object + 20) == 2)
            colors.append(int32(bytes, at: object + 28))
            #expect(int32(bytes, at: object + 32) == Int32(piece * 5))
            #expect(int32(bytes, at: object + 36) == 5)
            #expect(int32(bytes, at: object + 40) == Int32(piece))
        }
        #expect(Set(colors) == Set([Int32(0), Int32(1)]))

        // Each polar-circle tube is split into two chart-local hemispheres.
        for half in 0..<4 {
            let object = firstObject + (8 + half) * 48
            #expect(int32(bytes, at: object + 20) == 2)
            #expect(int32(bytes, at: object + 28) == Int32(2 + half / 2))
            #expect(int32(bytes, at: object + 32) == Int32(40 + half * 2))
            #expect(int32(bytes, at: object + 36) == 2)
            #expect(int32(bytes, at: object + 40) == Int32(8 + half))
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
        #expect(visitedCharts == Set([Int32(0), Int32(1)]))
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
        #expect(int32(bytes, at: firstPortalOffset + 84) == 1)
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
        #expect(float32(bytes, at: 192) > Float.pi / 2)

        let firstPortalOffset = 192 + 32
        let generator = matrix(bytes, at: firstPortalOffset)
        #expect(abs(generator[0] - cos(2 * Float.pi / 5)) < 0.0001)
        #expect(abs(generator[5] - cos(4 * Float.pi / 5)) < 0.0001)
        #expect(int32(bytes, at: firstPortalOffset + 84) == 0)
        #expect(int32(bytes, at: firstPortalOffset + 88) == 1)

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

    @Test func mirrorTintAndAtlasFogAreEncodedInScenePackets() {
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
        let materialOffset = 192 + chartCount * 32 + portalCount * 96
            + objectCount * 48 + quadricCount * 64 + clipCount * 32
        let mirrorColorOffset = materialOffset + 6 * 64
        #expect(float32(bytes, at: mirrorColorOffset) == 0.0)
        #expect(abs(float32(bytes, at: mirrorColorOffset + 4) - 0.8) < 0.0001)
        #expect(abs(float32(bytes, at: mirrorColorOffset + 8) - 0.9) < 0.0001)
        #expect(int32(bytes, at: mirrorColorOffset + 28) == 1)

        _ = HyperbolicScene.seifertWeberAtlas(&atlas)
        bytes = [UInt8](atlas.packetBytes())
        #expect(abs(float32(bytes, at: 140) - 0.6) < 0.0001)
        #expect(abs(float32(bytes, at: 192) - 2.05) < 0.0001)
        let seifertPortalCount = Int(int32(bytes, at: 164))
        let seifertObjectOffset = 192 + 32 + seifertPortalCount * 96
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

    @Test func pathRoomUsesPhysicalConductorGGXAndDielectricDispatch() {
        var atlas = geo.Atlas()
        _ = EuclideanScene.pathTracingRoom(&atlas)
        let bytes = [UInt8](atlas.packetBytes())
        let chartCount = Int(int32(bytes, at: 160))
        let portalCount = Int(int32(bytes, at: 164))
        let objectCount = Int(int32(bytes, at: 168))
        let materialCount = Int(int32(bytes, at: 172))
        let quadricCount = Int(int32(bytes, at: 180))
        let clipCount = Int(int32(bytes, at: 184))
        #expect(objectCount == 10)
        #expect(materialCount == 7)

        let objectOffset = 192 + chartCount * 32 + portalCount * 96
        let mirrorObjectOffset = objectOffset + 7 * 48
        // The object is deliberately opaque: its physical material selects
        // ideal-conductor reflection independently of this legacy field.
        #expect(int32(bytes, at: mirrorObjectOffset + 24) == 0)
        #expect(int32(bytes, at: mirrorObjectOffset + 28) == 4)

        let materialOffset = objectOffset + objectCount * 48
            + quadricCount * 64 + clipCount * 32
        let mirrorMaterialOffset = materialOffset + 4 * 64
        #expect(abs(float32(bytes, at: mirrorMaterialOffset) - 0.92) < 0.0001)
        #expect(abs(float32(bytes, at: mirrorMaterialOffset + 4) - 0.95) < 0.0001)
        #expect(float32(bytes, at: mirrorMaterialOffset + 8) == 1.0)
        #expect(int32(bytes, at: mirrorMaterialOffset + 28) == 0)
        #expect(float32(bytes, at: mirrorMaterialOffset + 48) == 0.0)
        #expect(float32(bytes, at: mirrorMaterialOffset + 52) == 1.0)
        #expect(float32(bytes, at: mirrorMaterialOffset + 60) == 0.0)

        let glassObjectOffset = objectOffset + 8 * 48
        #expect(int32(bytes, at: glassObjectOffset + 24) == 0)
        #expect(int32(bytes, at: glassObjectOffset + 28) == 5)
        let glassMaterialOffset = materialOffset + 5 * 64
        #expect(abs(float32(bytes, at: glassMaterialOffset) - 0.98) < 0.0001)
        #expect(abs(float32(bytes, at: glassMaterialOffset + 4) - 0.99) < 0.0001)
        #expect(float32(bytes, at: glassMaterialOffset + 8) == 1.0)
        #expect(int32(bytes, at: glassMaterialOffset + 28) == 0)
        #expect(float32(bytes, at: glassMaterialOffset + 48) == 0.0)
        #expect(float32(bytes, at: glassMaterialOffset + 52) == 0.0)
        #expect(float32(bytes, at: glassMaterialOffset + 56) == 1.5)
        #expect(float32(bytes, at: glassMaterialOffset + 60) == 1.0)

        let roughMetalObjectOffset = objectOffset + 9 * 48
        #expect(int32(bytes, at: roughMetalObjectOffset + 24) == 0)
        #expect(int32(bytes, at: roughMetalObjectOffset + 28) == 6)
        let roughMetalMaterialOffset = materialOffset + 6 * 64
        #expect(abs(float32(bytes, at: roughMetalMaterialOffset) - 0.95) < 0.0001)
        #expect(abs(float32(bytes, at: roughMetalMaterialOffset + 4) - 0.64) < 0.0001)
        #expect(abs(float32(bytes, at: roughMetalMaterialOffset + 8) - 0.2) < 0.0001)
        #expect(int32(bytes, at: roughMetalMaterialOffset + 28) == 0)
        #expect(abs(float32(bytes, at: roughMetalMaterialOffset + 48) - 0.32) < 0.0001)
        #expect(float32(bytes, at: roughMetalMaterialOffset + 52) == 1.0)
        #expect(float32(bytes, at: roughMetalMaterialOffset + 60) == 0.0)
    }

}
