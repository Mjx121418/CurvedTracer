//
//  Renderer.swift
//  CurvedTracer
//

import AppKit
import Combine
import Darwin
import GeometryCore
import MetalFX
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    static let traceStatsWordCount = 8
    static let traceStatsByteCount = traceStatsWordCount * MemoryLayout<UInt32>.size
    static let maxScenePacketSize = 3_000_000
    struct FrameParameters {
        var sampleIndex: UInt32
        var exposure: Float
        var pad1: UInt32 = 0
        var pad2: UInt32 = 0
    }

    let performanceStats: PerformanceStats
    var device: (any MTLDevice)!

    var tracingPipelines: [Int: any MTLComputePipelineState] = [:]
    var photoTracingPipelines: [Int: any MTLComputePipelineState] = [:]
    var presentationPipeline: (any MTLRenderPipelineState)!
    var presentationCommandQueue: (any MTLCommandQueue)!
    var metalFXSpatialScaler: (any MTLFXSpatialScaler)?
    var metalFXOutputTextures: [any MTLTexture] = []
    var spatialScalerOutputWidth = 0
    var spatialScalerOutputHeight = 0
    var sceneBuffers: [any MTLBuffer] = []
    var photoSceneBuffer: (any MTLBuffer)!
    var frameParameterBuffers: [any MTLBuffer] = []
    var statusBuffers: [any MTLBuffer] = []

    var commandQueue: (any MTL4CommandQueue)!
    var commitOptions: MTL4CommitOptions!
    var commandBuffers: [any MTL4CommandBuffer] = []
    var commandAllocators: [any MTL4CommandAllocator] = []

    var frameEvent: (any MTLSharedEvent)!
    var frameEventValue: UInt64 = 0
    var frameCompletionValues: [UInt64] = []
    var traceReadyEvent: (any MTLEvent)!
    var traceReadyEventValue: UInt64 = 0
    var frameIndex: Int = 0
    let maxFramesInFlight = 3

    var argumentTables: [any MTL4ArgumentTable] = []
    var photoArgumentTables: [any MTL4ArgumentTable] = []
    var residencySet: (any MTLResidencySet)!

    var renderTextures: [any MTLTexture] = []
    var photoAccumulationTexture: (any MTLTexture)!
    var renderResolution: RenderResolution = .qhd540

    var cameraChart: Int32 = 0
    var atlas = geo.Atlas()

    var mouseMonitor: Any?
    var keyMonitor: Any?
    var keyUpMonitor: Any?
    var cameraControlEnabled = false
    var pendingMouseDX: Float = 0
    var pendingMouseDY: Float = 0
    let mouseSensitivity: Float = 0.005
    let cameraMoveSpeed: Float = 0.01
    let cameraRollSpeed: Float = 0.01
    let cameraAutoRotateSpeed: Float = 0.01
    var pressedKeys: [UInt16: Bool] = [:]
    var lastAtlasStatus: UInt32 = 0
    var photoModeState = PhotoModeState()

    var ambientSpace: AmbientSpace = .sphere
    var traversalMode: TraversalMode = .flat
    var euclideanFlatSceneVariant: EuclideanFlatSceneVariant = .objectDemo
    var sphericalFlatSceneVariant: SphericalFlatSceneVariant = .cell600
    var hyperbolicFlatSceneVariant: HyperbolicFlatSceneVariant = .honeycombCell
    var hyperbolicAtlasVariant: HyperbolicAtlasVariant = .oneChart
    var exposure: Float = 2.0
    var renderingMode: RenderingMode { photoModeState.renderingMode }

    init(performanceStats: PerformanceStats) {
        self.performanceStats = performanceStats
        super.init()
    }
}
