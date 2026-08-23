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

    @Test func allSpaceTraversalScenesBuildV10Packets() {
        #expect(AmbientSpace.allCases.count == 3)
        #expect(TraversalMode.allCases.count == 2)
        var atlas = geo.Atlas()
        let builders: [(inout geo.Atlas) -> Int32] = [
            SphericalScene.cell600, SphericalScene.lensSpaceL52,
            HyperbolicScene.honeycombCell, HyperbolicScene.seifertWeberAtlas,
            EuclideanScene.finite, EuclideanScene.torus,
        ]
        for build in builders {
            _ = build(&atlas)
            #expect(atlas.packetSize() >= 192)
        }
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

        _ = HyperbolicScene.configure(&atlas)
        var bytes = [UInt8](atlas.packetBytes())
        let chartCount = Int(int32(bytes, at: 160))
        let portalCount = Int(int32(bytes, at: 164))
        let objectCount = Int(int32(bytes, at: 168))
        #expect(objectCount == 7)
        #expect(int32(bytes, at: 172) == 8)
        #expect(int32(bytes, at: 176) == 2)
        let materialOffset = 192 + chartCount * 32 + portalCount * 96 + objectCount * 32
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
        let firstRadius = acosh(-float32(bytes, at: seifertObjectOffset + 16))
        let secondRadius = acosh(-float32(bytes, at: seifertObjectOffset + 32 + 16))
        #expect(abs(firstRadius - 0.1883983) < 0.0001)
        #expect(abs(secondRadius - 0.2143091) < 0.0001)

        let firstCenter = (0..<4).map { float32(bytes, at: seifertObjectOffset + $0 * 4) }
        let secondCenter = (0..<4).map { float32(bytes, at: seifertObjectOffset + 32 + $0 * 4) }
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
