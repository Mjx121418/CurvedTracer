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

    @Test func allSpaceTraversalScenesBuildV11Packets() {
        #expect(AmbientSpace.allCases.count == 3)
        #expect(TraversalMode.allCases.count == 2)
        #expect(SphericalFlatSceneVariant.allCases.count == 4)
        #expect(HyperbolicFlatSceneVariant.allCases.count == 3)
        #expect(HyperbolicAtlasVariant.allCases.count == 2)
        var atlas = geo.Atlas()
        let builders: [(inout geo.Atlas) -> Int32] = [
            SphericalScene.cell600, SphericalScene.objectDemo,
            SphericalScene.primitiveGallery, SphericalScene.cliffordTorusConstruction,
            SphericalScene.lensSpaceL52,
            HyperbolicScene.honeycombCell, HyperbolicScene.poincareBallDemo,
            HyperbolicScene.primitiveGallery,
            HyperbolicScene.seifertWeberAtlas,
            HyperbolicScene.seifertWeberMultiChartAtlas,
            EuclideanScene.finite, EuclideanScene.torus,
        ]
        for build in builders {
            _ = build(&atlas)
            #expect(atlas.packetSize() >= 192)
            #expect(int32([UInt8](atlas.packetBytes()), at: 4) == 11)
        }
    }

    @Test func primitiveGalleriesEncodeLinearQuadraticAndClippedSurfaces() {
        var atlas = geo.Atlas()
        _ = SphericalScene.primitiveGallery(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 3)
        #expect(int32(bytes, at: 180) == 0)
        #expect(int32(bytes, at: 184) == 8)
        let firstObject = 192 + 32
        #expect(int32(bytes, at: firstObject + 20) == 0)

        _ = HyperbolicScene.primitiveGallery(&atlas)
        bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 4)
        #expect(int32(bytes, at: 180) == 1)
        #expect(int32(bytes, at: 184) == 10)
    }

    @Test func cliffordTorusUsesEightCheckerboardReflectionPatches() {
        var atlas = geo.Atlas()
        _ = SphericalScene.cliffordTorusConstruction(&atlas)
        let bytes = [UInt8](atlas.packetBytes())
        #expect(int32(bytes, at: 168) == 8)
        #expect(int32(bytes, at: 172) == 2)
        #expect(int32(bytes, at: 180) == 8)
        #expect(int32(bytes, at: 184) == 40)

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
        let mirrorColorOffset = materialOffset + 6 * 32
        #expect(float32(bytes, at: mirrorColorOffset) == 0.0)
        #expect(abs(float32(bytes, at: mirrorColorOffset + 4) - 0.8) < 0.0001)
        #expect(abs(float32(bytes, at: mirrorColorOffset + 8) - 0.9) < 0.0001)

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

}
