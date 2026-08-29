//
//  RendererTypes.swift
//  CurvedTracer
//

import AppKit
import Combine
import Darwin
import GeometryCore
import MetalFX
import MetalKit
import SwiftUI

enum AmbientSpace: String, CaseIterable, Identifiable {
    case sphere = "S^3"
    case hyperbolic = "H^3"
    case euclidean = "R^3"

    var id: Self { self }
}

enum TraversalMode: String, CaseIterable, Identifiable {
    case flat = "Flat CPU"
    case atlas = "GPU Atlas"
    var id: Self { self }
}

enum RenderingMode: Equatable {
    case realtime
    case photo
}

struct PhotoConvergenceSettings: Equatable {
    static let maximumSupportedBounces: UInt32 = 64
    static let maximumGuaranteedBounces: UInt32 = 16
    static let `default` = PhotoConvergenceSettings(
        maximumBounces: 64,
        guaranteedBounces: 3)

    let maximumBounces: UInt32
    let guaranteedBounces: UInt32

    init(maximumBounces: Int, guaranteedBounces: Int) {
        let normalizedMaximum = min(
            max(maximumBounces, 1),
            Int(Self.maximumSupportedBounces))
        let normalizedGuaranteed = min(
            max(guaranteedBounces, 0),
            min(normalizedMaximum, Int(Self.maximumGuaranteedBounces)))
        self.maximumBounces = UInt32(normalizedMaximum)
        self.guaranteedBounces = UInt32(normalizedGuaranteed)
    }
}

struct PhotoModeState: Equatable {
    private(set) var renderingMode: RenderingMode = .realtime
    private(set) var sampleIndex: UInt32 = 0
    private(set) var convergenceSettings: PhotoConvergenceSettings = .default

    mutating func enter(convergenceSettings: PhotoConvergenceSettings = .default) {
        renderingMode = .photo
        sampleIndex = 0
        self.convergenceSettings = convergenceSettings
    }

    mutating func exit() {
        renderingMode = .realtime
        sampleIndex = 0
    }

    mutating func recordSubmittedSample() {
        guard renderingMode == .photo, sampleIndex < UInt32.max else { return }
        sampleIndex += 1
    }
}

enum HyperbolicAtlasVariant: String, CaseIterable, Identifiable {
    case oneChart = "Seifert-Weber (1 chart)"
    case multiChart = "Seifert-Weber (14-state atlas)"
    case towerTiling = "{3,7} tower observatory"

    var id: Self { self }
}

enum SphericalAtlasVariant: String, CaseIterable, Identifiable {
    case lensSpace = "Lens space L(5,2)"
    case towerTiling = "{3,5} tower observatory"

    var id: Self { self }
}

enum EuclideanAtlasVariant: String, CaseIterable, Identifiable {
    case torus = "Three-torus"
    case towerTiling = "{3,6} tower observatory"

    var id: Self { self }
}

enum EuclideanFlatSceneVariant: String, CaseIterable, Identifiable {
    case objectDemo = "Object and mirror demo"
    case pathTracingRoom = "Path tracing room"

    var id: Self { self }
}

enum SphericalFlatSceneVariant: String, CaseIterable, Identifiable {
    case cell600 = "600-cell (24 charts)"
    case objectDemo = "Object and mirror demo"
    case pathTracingRoom = "Path tracing room"
    case primitiveGallery = "Primitive gallery"
    case hopfFibration = "Hopf fibration"
    case hopfFacePatches = "Hopf face patches"
    case cliffordTorusConstruction = "Clifford torus construction"

    var id: Self { self }
}

enum HyperbolicFlatSceneVariant: String, CaseIterable, Identifiable {
    case honeycombCell = "{4,3,5} honeycomb cell"
    case poincareBallDemo = "Poincaré-ball demo"
    case pathTracingRoom = "Path tracing room"
    case primitiveGallery = "Primitive gallery"

    var id: Self { self }
}

struct PerformanceSnapshot {
    var framesPerSecond: Double = 0
    var frameMilliseconds: Double = 0
    var gpuMilliseconds: Double = 0
    var portalHopsPerRay: Double = 0
    var compoundHopsPerRay: Double = 0
    var portalTestsPerRay: Double = 0
    var maximumPortalHops: UInt32 = 0
    var hopLimitRays: UInt32 = 0
    var averageScatteringDepth: Double = 0
    var maximumScatteringDepth: UInt32 = 0
    var rouletteTerminationFraction: Double = 0
    var depthBoundTerminationFraction: Double = 0
}

final class PerformanceStats: ObservableObject {
    @Published private(set) var snapshot = PerformanceSnapshot()

    private var frameInterval = 0.0
    private var gpuDuration = 0.0
    private var portalHopsPerRay = 0.0
    private var compoundHopsPerRay = 0.0
    private var portalTestsPerRay = 0.0
    private var maximumPortalHops: UInt32 = 0
    private var hopLimitRays: UInt32 = 0
    private var averageScatteringDepth = 0.0
    private var maximumScatteringDepth: UInt32 = 0
    private var rouletteTerminationFraction = 0.0
    private var depthBoundTerminationFraction = 0.0
    private var lastFrameTime = 0.0
    private var lastPublishTime = 0.0
    private var hasTraceSample = false

    private func smooth(_ current: Double, _ sample: Double, alpha: Double) -> Double {
        current == 0 ? sample : current + alpha * (sample - current)
    }

    func recordFrame(at time: Double) {
        if lastFrameTime > 0 {
            frameInterval = smooth(frameInterval, time - lastFrameTime, alpha: 0.1)
        }
        lastFrameTime = time

        guard time - lastPublishTime >= 0.25 else { return }
        lastPublishTime = time
        snapshot = PerformanceSnapshot(
            framesPerSecond: frameInterval > 0 ? 1 / frameInterval : 0,
            frameMilliseconds: frameInterval * 1_000,
            gpuMilliseconds: gpuDuration * 1_000,
            portalHopsPerRay: portalHopsPerRay,
            compoundHopsPerRay: compoundHopsPerRay,
            portalTestsPerRay: portalTestsPerRay,
            maximumPortalHops: maximumPortalHops,
            hopLimitRays: hopLimitRays,
            averageScatteringDepth: averageScatteringDepth,
            maximumScatteringDepth: maximumScatteringDepth,
            rouletteTerminationFraction: rouletteTerminationFraction,
            depthBoundTerminationFraction: depthBoundTerminationFraction)
    }

    func recordGPUTime(seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        gpuDuration = smooth(gpuDuration, seconds, alpha: 0.1)
    }

    func resetPhotoConvergence() {
        averageScatteringDepth = 0
        maximumScatteringDepth = 0
        rouletteTerminationFraction = 0
        depthBoundTerminationFraction = 0
    }

    func recordTrace(
        rayCount: UInt32,
        portalHops: UInt32,
        compoundHops: UInt32,
        maximumHops: UInt32,
        hopLimitRays: UInt32,
        portalTests: UInt32,
        totalScatteringDepth: UInt32,
        maximumScatteringDepth: UInt32,
        rouletteTerminations: UInt32,
        depthBoundTerminations: UInt32
    ) {
        guard rayCount > 0 else { return }
        let rays = Double(rayCount)
        let alpha = hasTraceSample ? 0.15 : 1.0
        portalHopsPerRay = smooth(
            portalHopsPerRay, Double(portalHops) / rays, alpha: alpha)
        compoundHopsPerRay = smooth(
            compoundHopsPerRay, Double(compoundHops) / rays, alpha: alpha)
        portalTestsPerRay = smooth(
            portalTestsPerRay, Double(portalTests) / rays, alpha: alpha)
        averageScatteringDepth = smooth(
            averageScatteringDepth,
            Double(totalScatteringDepth) / rays,
            alpha: alpha)
        rouletteTerminationFraction = smooth(
            rouletteTerminationFraction,
            Double(rouletteTerminations) / rays,
            alpha: alpha)
        depthBoundTerminationFraction = smooth(
            depthBoundTerminationFraction,
            Double(depthBoundTerminations) / rays,
            alpha: alpha)
        maximumPortalHops = maximumHops
        self.maximumScatteringDepth = maximumScatteringDepth
        self.hopLimitRays = hopLimitRays
        hasTraceSample = true
    }
}

struct RenderResolution: Equatable {
    let width: Int
    let height: Int

    static let hd720 = RenderResolution(width: 1280, height: 720)
    static let qhd540 = RenderResolution(width: 960, height: 540)

    init(width: Int, height: Int) {
        precondition(
            Self.isValid(width: width, height: height),
            "render resolution dimensions must be positive")
        self.width = width
        self.height = height
    }

    static func isValid(width: Int, height: Int) -> Bool {
        width > 0 && height > 0
    }

    var aspectRatio: CGFloat {
        CGFloat(width) / CGFloat(height)
    }

    func isSpatialUpscaleTarget(
        width outputWidth: Int,
        height outputHeight: Int
    ) -> Bool {
        guard outputWidth >= width, outputHeight >= height,
              outputWidth > width || outputHeight > height
        else {
            return false
        }
        // MetalFX spatial scaling does not preserve aspect ratio itself. Allow
        // at most one pixel of rounding error in an otherwise matching target.
        let crossProductError = abs(outputWidth * height - outputHeight * width)
        return crossProductError <= max(width, height)
    }
}
