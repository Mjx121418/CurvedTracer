//
//  MetalView.swift
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

struct PhotoModeState: Equatable {
    private(set) var renderingMode: RenderingMode = .realtime
    private(set) var sampleIndex: UInt32 = 0

    mutating func enter() {
        renderingMode = .photo
        sampleIndex = 0
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
            hopLimitRays: hopLimitRays)
    }

    func recordGPUTime(seconds: Double) {
        guard seconds > 0, seconds.isFinite else { return }
        gpuDuration = smooth(gpuDuration, seconds, alpha: 0.1)
    }

    func recordTrace(
        rayCount: UInt32,
        portalHops: UInt32,
        compoundHops: UInt32,
        maximumHops: UInt32,
        hopLimitRays: UInt32,
        portalTests: UInt32
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
        maximumPortalHops = maximumHops
        self.hopLimitRays = hopLimitRays
        hasTraceSample = true
    }
}

struct RenderResolution: Equatable {
    let width: Int
    let height: Int

    static let hd720 = RenderResolution(width: 1280, height: 720)

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

struct MetalView: NSViewRepresentable {
    @Binding var ambientSpace: AmbientSpace
    @Binding var traversalMode: TraversalMode
    @Binding var euclideanFlatSceneVariant: EuclideanFlatSceneVariant
    @Binding var sphericalFlatSceneVariant: SphericalFlatSceneVariant
    @Binding var hyperbolicFlatSceneVariant: HyperbolicFlatSceneVariant
    @Binding var hyperbolicAtlasVariant: HyperbolicAtlasVariant
    @Binding var renderingMode: RenderingMode
    @Binding var exposure: Double
    let performanceStats: PerformanceStats
    let renderResolution: RenderResolution

    func makeCoordinator() -> Renderer {
        Renderer(performanceStats: performanceStats)
    }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable")
        }

        guard device.supportsFamily(.metal4) else {
            fatalError("Metal 4 is unavailable")
        }

        let view = MTKView(frame: .zero, device: device)

        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(
            red: 0.2,
            green: 0.4,
            blue: 0.8,
            alpha: 1.0
        )
        view.preferredFramesPerSecond = 60

        // MetalFX writes to a private intermediate texture. The drawable is
        // used only as a render target by the final presentation pass.
        view.framebufferOnly = true
        DispatchQueue.main.async {
            view.window?.acceptsMouseMovedEvents = true
        }

        context.coordinator.configure(
            device: device,
            view: view,
            renderResolution: renderResolution)
        context.coordinator.ambientSpace = ambientSpace
        context.coordinator.traversalMode = traversalMode
        context.coordinator.euclideanFlatSceneVariant = euclideanFlatSceneVariant
        context.coordinator.sphericalFlatSceneVariant = sphericalFlatSceneVariant
        context.coordinator.hyperbolicFlatSceneVariant = hyperbolicFlatSceneVariant
        context.coordinator.hyperbolicAtlasVariant = hyperbolicAtlasVariant
        context.coordinator.exposure = Float(max(exposure, 0))
        context.coordinator.setScenePacket()
        if renderingMode == .photo,
           !context.coordinator.setRenderingMode(.photo)
        {
            let actualMode = context.coordinator.renderingMode
            DispatchQueue.main.async {
                renderingMode = actualMode
            }
        }
        context.coordinator.installEventMonitors()

        view.delegate = context.coordinator

        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        if context.coordinator.ambientSpace != ambientSpace
            || context.coordinator.traversalMode != traversalMode
            || context.coordinator.euclideanFlatSceneVariant != euclideanFlatSceneVariant
            || context.coordinator.sphericalFlatSceneVariant != sphericalFlatSceneVariant
            || context.coordinator.hyperbolicFlatSceneVariant != hyperbolicFlatSceneVariant
            || context.coordinator.hyperbolicAtlasVariant != hyperbolicAtlasVariant
        {
            context.coordinator.ambientSpace = ambientSpace
            context.coordinator.traversalMode = traversalMode
            context.coordinator.euclideanFlatSceneVariant = euclideanFlatSceneVariant
            context.coordinator.sphericalFlatSceneVariant = sphericalFlatSceneVariant
            context.coordinator.hyperbolicFlatSceneVariant = hyperbolicFlatSceneVariant
            context.coordinator.hyperbolicAtlasVariant = hyperbolicAtlasVariant
            context.coordinator.setScenePacket()
        }
        if context.coordinator.renderingMode != renderingMode,
           !context.coordinator.setRenderingMode(renderingMode)
        {
            let actualMode = context.coordinator.renderingMode
            DispatchQueue.main.async {
                renderingMode = actualMode
            }
        }
        context.coordinator.exposure = Float(max(exposure, 0))
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    private static let traceStatsWordCount = 8
    private static let traceStatsByteCount = traceStatsWordCount * MemoryLayout<UInt32>.size
    private static let maxScenePacketSize = 3_000_000
    private struct FrameParameters {
        var sampleIndex: UInt32
        var exposure: Float
        var pad1: UInt32 = 0
        var pad2: UInt32 = 0
    }

    private let performanceStats: PerformanceStats
    private var device: (any MTLDevice)!

    private var tracingPipelines: [Int: any MTLComputePipelineState] = [:]
    private var photoTracingPipelines: [Int: any MTLComputePipelineState] = [:]
    private var presentationPipeline: (any MTLRenderPipelineState)!
    private var presentationCommandQueue: (any MTLCommandQueue)!
    private var metalFXSpatialScaler: (any MTLFXSpatialScaler)?
    private var metalFXOutputTextures: [any MTLTexture] = []
    private var spatialScalerOutputWidth = 0
    private var spatialScalerOutputHeight = 0
    private var sceneBuffers: [any MTLBuffer] = []
    private var photoSceneBuffer: (any MTLBuffer)!
    private var frameParameterBuffers: [any MTLBuffer] = []
    private var statusBuffers: [any MTLBuffer] = []

    private var commandQueue: (any MTL4CommandQueue)!
    private var commitOptions: MTL4CommitOptions!
    private var commandBuffers: [any MTL4CommandBuffer] = []
    private var commandAllocators: [any MTL4CommandAllocator] = []

    private var frameEvent: (any MTLSharedEvent)!
    private var frameEventValue: UInt64 = 0
    private var frameCompletionValues: [UInt64] = []
    private var traceReadyEvent: (any MTLEvent)!
    private var traceReadyEventValue: UInt64 = 0
    private var frameIndex: Int = 0
    private let maxFramesInFlight = 3

    private var argumentTables: [any MTL4ArgumentTable] = []
    private var photoArgumentTables: [any MTL4ArgumentTable] = []
    private var residencySet: (any MTLResidencySet)!

    private var renderTextures: [any MTLTexture] = []
    private var photoAccumulationTexture: (any MTLTexture)!
    private var renderResolution: RenderResolution = .hd720

    private var cameraChart: Int32 = 0
    private var atlas = geo.Atlas()

    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var keyUpMonitor: Any?
    private var cameraControlEnabled = false
    private var pendingMouseDX: Float = 0
    private var pendingMouseDY: Float = 0
    private let mouseSensitivity: Float = 0.005
    private let cameraMoveSpeed: Float = 0.01
    private let cameraRollSpeed: Float = 0.01
    private let cameraAutoRotateSpeed: Float = 0.01
    private var pressedKeys: [UInt16: Bool] = [:]
    private var lastAtlasStatus: UInt32 = 0
    private var photoModeState = PhotoModeState()

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

    func installEventMonitors() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            if let self, self.cameraControlEnabled {
                self.queueMouseDelta(dx: event.deltaX, dy: event.deltaY)
            }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self {
                if event.keyCode == 48 {  // Tab
                    if self.renderingMode == .photo {
                        return nil
                    }
                    self.setCameraControlEnabled(!self.cameraControlEnabled)
                    return nil
                }
                if self.isCameraControlKey(event.keyCode) {
                    if self.renderingMode == .photo {
                        return nil
                    }
                    self.pressedKeys[event.keyCode] = true
                    return nil
                }
            }
            return event
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            if let self, self.isCameraControlKey(event.keyCode) {
                self.pressedKeys[event.keyCode] = false
            }
            return event
        }
    }

    private func queueMouseDelta(dx: CGFloat, dy: CGFloat) {
        pendingMouseDX += Float(dx)
        pendingMouseDY += Float(dy)
    }

    private func setCameraControlEnabled(_ enabled: Bool) {
        guard cameraControlEnabled != enabled else {
            pendingMouseDX = 0
            pendingMouseDY = 0
            return
        }
        cameraControlEnabled = enabled
        pendingMouseDX = 0
        pendingMouseDY = 0

        if enabled {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }
    }

    private func isCameraControlKey(_ keyCode: UInt16) -> Bool {
        // W=13, A=0, S=1, D=2, R=15, F=3, Q=12, E=14,
        // arrows: left=123, right=124, down=125, up=126
        return keyCode == 13 || keyCode == 0 || keyCode == 1
        || keyCode == 2 || keyCode == 15 || keyCode == 3
        || keyCode == 12 || keyCode == 14
        || keyCode == 123 || keyCode == 124
        || keyCode == 125 || keyCode == 126
    }

    func configure(
        device: MTLDevice,
        view: MTKView,
        renderResolution: RenderResolution
    ) {
        self.device = device
        self.renderResolution = renderResolution
        precondition(
            MemoryLayout<FrameParameters>.stride == 16,
            "frame parameter layout must match FrameGPU")

        let library = device.makeDefaultLibrary()!
        for model in Int32(0)...Int32(2) {
            for portalsEnabled in [false, true] {
                let constants = MTLFunctionConstantValues()
                var modelValue = model
                var portalValue = portalsEnabled
                constants.setConstantValue(&modelValue, type: .int, index: 0)
                constants.setConstantValue(&portalValue, type: .bool, index: 1)
                let function: any MTLFunction
                do {
                    function = try library.makeFunction(
                        name: "raytrace",
                        constantValues: constants)
                } catch {
                    fatalError(
                        "raytrace specialization failed; library functions: "
                        + "\(library.functionNames); error: \(error)")
                }
                tracingPipelines[Int(model) * 2 + (portalsEnabled ? 1 : 0)] =
                try! device.makeComputePipelineState(function: function)

                let photoFunction: any MTLFunction
                do {
                    photoFunction = try library.makeFunction(
                        name: "photoTrace",
                        constantValues: constants)
                } catch {
                    fatalError(
                        "photoTrace specialization failed; library functions: "
                        + "\(library.functionNames); error: \(error)")
                }
                photoTracingPipelines[
                    Int(model) * 2 + (portalsEnabled ? 1 : 0)
                ] = try! device.makeComputePipelineState(function: photoFunction)
            }
        }

        guard
            let presentationVertex = library.makeFunction(name: "presentVertex"),
            let presentationFragment = library.makeFunction(name: "presentFragment")
        else {
            fatalError("presentation shaders not found")
        }
        let presentationDescriptor = MTLRenderPipelineDescriptor()
        presentationDescriptor.label = "Fixed-resolution presentation pipeline"
        presentationDescriptor.vertexFunction = presentationVertex
        presentationDescriptor.fragmentFunction = presentationFragment
        presentationDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        self.presentationPipeline = try! device.makeRenderPipelineState(
            descriptor: presentationDescriptor)

        guard let commandQueue = device.makeMTL4CommandQueue() else {
            fatalError("Failed to create Metal 4 command queue")
        }
        self.commandQueue = commandQueue
        guard let presentationCommandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create presentation command queue")
        }
        presentationCommandQueue.label = "Presentation and MetalFX queue"
        self.presentationCommandQueue = presentationCommandQueue
        let commitOptions = MTL4CommitOptions()
        commitOptions.addFeedbackHandler { [weak performanceStats] feedback in
            let duration = feedback.gpuEndTime - feedback.gpuStartTime
            guard duration > 0 else { return }
            DispatchQueue.main.async {
                performanceStats?.recordGPUTime(seconds: duration)
            }
        }
        self.commitOptions = commitOptions

        guard let frameEvent = device.makeSharedEvent() else {
            fatalError("Failed to create shared event")
        }
        self.frameEvent = frameEvent
        guard let traceReadyEvent = device.makeEvent() else {
            fatalError("Failed to create trace-ready GPU event")
        }
        self.traceReadyEvent = traceReadyEvent
        frameCompletionValues = Array(repeating: 0, count: maxFramesInFlight)

        for _ in 0..<maxFramesInFlight {
            guard
                let commandBuffer = device.makeCommandBuffer(),
                let commandAllocator = device.makeCommandAllocator()
            else {
                fatalError("Failed to create Metal 4 command objects")
            }
            commandBuffers.append(commandBuffer)
            commandAllocators.append(commandAllocator)
        }

        self.commandQueue.addResidencySet(view.residencySet)

        let residencySetDescreptior = MTLResidencySetDescriptor()
        residencySetDescreptior.label = "Curved Ray Tracer App Residency Set"
        do {
            self.residencySet = try device.makeResidencySet(descriptor: residencySetDescreptior)
        } catch {
            fatalError("Failed to create residency set: \(error)")
        }
        self.commandQueue.addResidencySet(self.residencySet)

        // Covers the v14 packet maxima, including 48-byte material records.
        guard let photoSceneBuffer = device.makeBuffer(
            length: Self.maxScenePacketSize,
            options: .storageModeShared)
        else {
            fatalError("Failed to create frozen photo scene buffer")
        }
        photoSceneBuffer.label = "Frozen Photo Mode scene packet"
        self.photoSceneBuffer = photoSceneBuffer
        residencySet.addAllocation(photoSceneBuffer)

        for _ in 0..<maxFramesInFlight {
            guard let buffer = device.makeBuffer(
                length: Self.maxScenePacketSize,
                options: .storageModeShared)
            else {
                fatalError("Failed to create scene buffer")
            }
            sceneBuffers.append(buffer)
            residencySet.addAllocation(buffer)
            guard
                let status = device.makeBuffer(
                    length: Self.traceStatsByteCount,
                    options: .storageModeShared)
            else {
                fatalError("Failed to create atlas status buffer")
            }
            statusBuffers.append(status)
            residencySet.addAllocation(status)

            guard let parameters = device.makeBuffer(
                length: MemoryLayout<FrameParameters>.stride,
                options: .storageModeShared)
            else {
                fatalError("Failed to create frame parameter buffer")
            }
            frameParameterBuffers.append(parameters)
            residencySet.addAllocation(parameters)
        }

        let realtimeArgumentDescriptor = MTL4ArgumentTableDescriptor()
        realtimeArgumentDescriptor.maxBufferBindCount = 3
        realtimeArgumentDescriptor.maxTextureBindCount = 1
        let photoArgumentDescriptor = MTL4ArgumentTableDescriptor()
        photoArgumentDescriptor.maxBufferBindCount = 3
        photoArgumentDescriptor.maxTextureBindCount = 2

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: view.colorPixelFormat,
            width: renderResolution.width,
            height: renderResolution.height,
            mipmapped: false)
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.shaderRead, .shaderWrite]

        let accumulationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: renderResolution.width,
            height: renderResolution.height,
            mipmapped: false)
        accumulationDescriptor.storageMode = .private
        accumulationDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let photoAccumulationTexture = device.makeTexture(
            descriptor: accumulationDescriptor)
        else {
            fatalError("Failed to create Photo Mode accumulation texture")
        }
        photoAccumulationTexture.label =
        "Photo Mode HDR accumulation \(renderResolution.width)x\(renderResolution.height)"
        self.photoAccumulationTexture = photoAccumulationTexture
        residencySet.addAllocation(photoAccumulationTexture)

        for frame in 0..<maxFramesInFlight {
            argumentTables.append(
                try! device.makeArgumentTable(descriptor: realtimeArgumentDescriptor))
            photoArgumentTables.append(
                try! device.makeArgumentTable(descriptor: photoArgumentDescriptor))

            guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                fatalError("Failed to create fixed-resolution render texture")
            }
            texture.label =
            "Ray tracing target \(renderResolution.width)x\(renderResolution.height), frame \(frame)"
            renderTextures.append(texture)
            residencySet.addAllocation(texture)

            memset(statusBuffers[frame].contents(), 0, Self.traceStatsByteCount)
            argumentTables[frame].setAddress(
                sceneBuffers[frame].gpuAddress,
                index: 0)
            argumentTables[frame].setAddress(
                statusBuffers[frame].gpuAddress,
                index: 1)
            argumentTables[frame].setAddress(
                frameParameterBuffers[frame].gpuAddress,
                index: 2)
            argumentTables[frame].setTexture(texture.gpuResourceID, index: 0)

            photoArgumentTables[frame].setAddress(
                photoSceneBuffer.gpuAddress,
                index: 0)
            photoArgumentTables[frame].setAddress(
                statusBuffers[frame].gpuAddress,
                index: 1)
            photoArgumentTables[frame].setAddress(
                frameParameterBuffers[frame].gpuAddress,
                index: 2)
            photoArgumentTables[frame].setTexture(
                texture.gpuResourceID,
                index: 0)
            photoArgumentTables[frame].setTexture(
                photoAccumulationTexture.gpuResourceID,
                index: 1)
        }

        configureSpatialScaler(
            outputWidth: Int(view.drawableSize.width),
            outputHeight: Int(view.drawableSize.height),
            pixelFormat: view.colorPixelFormat)
    }

    func setScenePacket() {
        atlas = geo.Atlas()
        lastAtlasStatus = 0
        switch (traversalMode, ambientSpace) {
        case (.flat, .sphere):
            switch sphericalFlatSceneVariant {
            case .cell600: cameraChart = SphericalScene.cell600(&atlas)
            case .objectDemo: cameraChart = SphericalScene.objectDemo(&atlas)
            case .pathTracingRoom:
                cameraChart = SphericalScene.pathTracingRoom(&atlas)
            case .primitiveGallery: cameraChart = SphericalScene.primitiveGallery(&atlas)
            case .hopfFibration: cameraChart = SphericalScene.hopfFibration(&atlas)
            case .cliffordTorusConstruction:
                cameraChart = SphericalScene.cliffordTorusConstruction(&atlas)
            }
        case (.flat, .hyperbolic):
            switch hyperbolicFlatSceneVariant {
            case .honeycombCell: cameraChart = HyperbolicScene.honeycombCell(&atlas)
            case .poincareBallDemo: cameraChart = HyperbolicScene.poincareBallDemo(&atlas)
            case .pathTracingRoom:
                cameraChart = HyperbolicScene.pathTracingRoom(&atlas)
            case .primitiveGallery: cameraChart = HyperbolicScene.primitiveGallery(&atlas)
            }
        case (.flat, .euclidean):
            switch euclideanFlatSceneVariant {
            case .objectDemo: cameraChart = EuclideanScene.finite(&atlas)
            case .pathTracingRoom:
                cameraChart = EuclideanScene.pathTracingRoom(&atlas)
            }
        case (.atlas, .sphere): cameraChart = SphericalScene.lensSpaceL52(&atlas)
        case (.atlas, .hyperbolic):
            switch hyperbolicAtlasVariant {
            case .oneChart: cameraChart = HyperbolicScene.seifertWeberAtlas(&atlas)
            case .multiChart: cameraChart = HyperbolicScene.seifertWeberMultiChartAtlas(&atlas)
            }
        case (.atlas, .euclidean): cameraChart = EuclideanScene.torus(&atlas)
        }

        // draw(in:) uploads into a frame slot only after that slot's previous
        // GPU work completes. Avoid touching all in-flight buffers here when
        // the user switches scenes.
        self.residencySet.commit()
        self.residencySet.requestResidency()
    }

    private func buildCurrentPacket() -> Int32 {
        traversalMode == .atlas
        ? atlas.buildAtlas(cameraChart, 64, 1, 32)
        : atlas.build(cameraChart, 64)
    }

    private func waitForAllFrames() -> Bool {
        for value in frameCompletionValues where value != 0 {
            if !frameEvent.wait(untilSignaledValue: value, timeoutMS: 1000) {
                NSLog("Timed out waiting to change rendering mode")
                return false
            }
        }
        return true
    }

    @discardableResult
    func setRenderingMode(_ mode: RenderingMode) -> Bool {
        guard mode != renderingMode else { return true }
        guard waitForAllFrames() else { return false }

        switch mode {
        case .realtime:
            photoModeState.exit()
            return true
        case .photo:
            let result = buildCurrentPacket()
            guard result == 0 else {
                NSLog(
                    "GeometryCore Photo Mode snapshot failed with error %d",
                    result)
                return false
            }
            copyAtlasPacket(to: photoSceneBuffer)
            setCameraControlEnabled(false)
            pendingMouseDX = 0
            pendingMouseDY = 0
            pressedKeys.removeAll()
            photoModeState.enter()
            return true
        }
    }

    private func copyAtlasPacket(to buffer: any MTLBuffer) {
        // Use the by-value packetBytes() accessor. The raw packetData() pointer
        // is an interior pointer into a C++ value type and is not safe to use
        // from Swift when atlas is a stored property.
        let packet = [UInt8](atlas.packetBytes())
        precondition(packet.count <= buffer.length, "scene packet exceeds the Metal buffer")
        let contents = buffer.contents()
        _ = packet.withUnsafeBytes { rawBuffer in
            memcpy(contents, rawBuffer.baseAddress!, rawBuffer.count)
        }
    }

    private func updateScene() {
        guard cameraControlEnabled else {
            return
        }

        if pendingMouseDX != 0 || pendingMouseDY != 0 {
            // Always rotate around the camera's current local axes.
            atlas.cameraRotate(atlas.cameraUp(), pendingMouseDX * mouseSensitivity)
            atlas.cameraRotate(atlas.cameraRight(), pendingMouseDY * mouseSensitivity)
            pendingMouseDX = 0
            pendingMouseDY = 0
        }

        if pressedKeys[12] == true {  // Q: roll left
            atlas.cameraRoll(cameraRollSpeed)
        }
        if pressedKeys[14] == true {  // E: roll right
            atlas.cameraRoll(-cameraRollSpeed)
        }

        applyMovementKeys()

        // Arrow keys: hold to rotate, like Q/E.
        var yaw: Float = 0
        var pitch: Float = 0
        if pressedKeys[123] == true { yaw -= cameraAutoRotateSpeed }  // left arrow
        if pressedKeys[124] == true { yaw += cameraAutoRotateSpeed }  // right arrow
        if pressedKeys[126] == true { pitch -= cameraAutoRotateSpeed }  // up arrow
        if pressedKeys[125] == true { pitch += cameraAutoRotateSpeed }  // down arrow
        if yaw != 0 {
            atlas.cameraRotate(atlas.cameraUp(), yaw)
        }
        if pitch != 0 {
            atlas.cameraRotate(atlas.cameraRight(), pitch)
        }
    }

    private func applyMovementKeys() {
        let right = atlas.cameraRight()
        let up = atlas.cameraUp()
        let fwd = atlas.cameraFwd()

        var dx: Float = 0
        var dy: Float = 0
        var dz: Float = 0

        if pressedKeys[13] == true {  // W
            dx += fwd.x
            dy += fwd.y
            dz += fwd.z
        }
        if pressedKeys[1] == true {  // S
            dx -= fwd.x
            dy -= fwd.y
            dz -= fwd.z
        }
        if pressedKeys[2] == true {  // D
            dx += right.x
            dy += right.y
            dz += right.z
        }
        if pressedKeys[0] == true {  // A
            dx -= right.x
            dy -= right.y
            dz -= right.z
        }
        if pressedKeys[15] == true {  // R
            dx += up.x
            dy += up.y
            dz += up.z
        }
        if pressedKeys[3] == true {  // F
            dx -= up.x
            dy -= up.y
            dz -= up.z
        }

        if dx == 0, dy == 0, dz == 0 {
            return
        }

        let movement = geo.vec3(
            dx * cameraMoveSpeed,
            dy * cameraMoveSpeed,
            dz * cameraMoveSpeed
        )

        cameraChart = atlas.cameraMove(movement)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        configureSpatialScaler(
            outputWidth: Int(size.width),
            outputHeight: Int(size.height),
            pixelFormat: view.colorPixelFormat)
    }

    private func configureSpatialScaler(
        outputWidth: Int,
        outputHeight: Int,
        pixelFormat: MTLPixelFormat
    ) {
        metalFXSpatialScaler = nil
        metalFXOutputTextures = []
        spatialScalerOutputWidth = 0
        spatialScalerOutputHeight = 0

        guard
            renderResolution.isSpatialUpscaleTarget(
                width: outputWidth, height: outputHeight),
            let device,
            MTLFXSpatialScalerDescriptor.supportsDevice(device)
        else {
            return
        }

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = renderResolution.width
        descriptor.inputHeight = renderResolution.height
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = pixelFormat
        descriptor.outputTextureFormat = pixelFormat
        descriptor.colorProcessingMode = .perceptual

        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            return
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false)
        outputDescriptor.storageMode = .private
        outputDescriptor.usage = MTLTextureUsage.shaderRead.union(
            scaler.outputTextureUsage)
        var outputTextures: [any MTLTexture] = []
        for frame in 0..<maxFramesInFlight {
            guard let texture = device.makeTexture(descriptor: outputDescriptor) else {
                return
            }
            texture.label =
            "MetalFX output \(outputWidth)x\(outputHeight), frame \(frame)"
            outputTextures.append(texture)
        }

        scaler.inputContentWidth = renderResolution.width
        scaler.inputContentHeight = renderResolution.height
        metalFXSpatialScaler = scaler
        metalFXOutputTextures = outputTextures
        spatialScalerOutputWidth = outputWidth
        spatialScalerOutputHeight = outputHeight
        NSLog(
            "MetalFX spatial upscale enabled: %dx%d -> %dx%d",
            renderResolution.width, renderResolution.height,
            outputWidth, outputHeight)
    }

    private func activeSpatialScaler(
        for input: any MTLTexture,
        output: any MTLTexture,
        drawableTexture: any MTLTexture
    ) -> (any MTLFXSpatialScaler)? {
        guard
            let metalFXSpatialScaler,
            drawableTexture.width == spatialScalerOutputWidth,
            drawableTexture.height == spatialScalerOutputHeight,
            input.usage.contains(metalFXSpatialScaler.colorTextureUsage),
            output.width == spatialScalerOutputWidth,
            output.height == spatialScalerOutputHeight,
            output.storageMode == .private,
            output.usage.contains(metalFXSpatialScaler.outputTextureUsage),
            output.usage.contains(.shaderRead)
        else {
            return nil
        }
        return metalFXSpatialScaler
    }

    private func presentationViewport(for drawableTexture: any MTLTexture) -> MTLViewport {
        let drawableWidth = Double(drawableTexture.width)
        let drawableHeight = Double(drawableTexture.height)
        let sourceAspect =
        Double(renderResolution.width)
        / Double(renderResolution.height)
        let drawableAspect = drawableWidth / drawableHeight

        if drawableAspect > sourceAspect {
            let width = drawableHeight * sourceAspect
            return MTLViewport(
                originX: 0.5 * (drawableWidth - width),
                originY: 0,
                width: width,
                height: drawableHeight,
                znear: 0,
                zfar: 1)
        }

        let height = drawableWidth / sourceAspect
        return MTLViewport(
            originX: 0,
            originY: 0.5 * (drawableHeight - height),
            width: drawableWidth,
            height: height,
            znear: 0,
            zfar: 1)
    }

    private func consumeTraceStats(from buffer: any MTLBuffer) {
        let words = buffer.contents().bindMemory(
            to: UInt32.self,
            capacity: Self.traceStatsWordCount)
        let errorBits = words[0]
        performanceStats.recordTrace(
            rayCount: words[1],
            portalHops: words[2],
            compoundHops: words[3],
            maximumHops: words[4],
            hopLimitRays: words[5],
            portalTests: words[6])

        if errorBits != lastAtlasStatus {
            if errorBits == 0 {
                NSLog("GPU tracing diagnostics cleared")
            } else {
                var labels: [String] = []
                if errorBits & 0x00000004 != 0 {
                    labels.append("invalid ray state/canonicalization")
                }
                if errorBits & 0x00000080 != 0 {
                    labels.append("invalid Photo Mode BSDF sample")
                }
                if errorBits & 0x00000100 != 0 {
                    labels.append("invalid Photo Mode emitter sample")
                }
                if labels.isEmpty {
                    NSLog("GPU tracing diagnostics: 0x%08x", errorBits)
                } else {
                    NSLog(
                        "GPU tracing diagnostics: 0x%08x (%@)",
                        errorBits,
                        labels.joined(separator: ", "))
                }
            }
            lastAtlasStatus = errorBits
        }
        memset(buffer.contents(), 0, Self.traceStatsByteCount)
    }

    func draw(in view: MTKView) {
        guard
            let commandQueue,
            let drawable = view.currentDrawable
        else {
            return
        }
        performanceStats.recordFrame(at: ProcessInfo.processInfo.systemUptime)

        let index = frameIndex % maxFramesInFlight
        let commandAllocator = commandAllocators[index]
        let commandBuffer = commandBuffers[index]
        let renderTexture = renderTextures[index]
        let frameRenderingMode = renderingMode

        // A slot can be reused only after the queue signal placed after its
        // previous commit has completed. Never continue after a timeout: doing
        // so would let the CPU mutate resources that the GPU is still using.
        let waitValue = frameCompletionValues[index]
        if waitValue != 0,
           !frameEvent.wait(untilSignaledValue: waitValue, timeoutMS: 1000)
        {
            NSLog("Timed out waiting for GPU frame slot %d", index)
            return
        }

        consumeTraceStats(from: statusBuffers[index])

        let sampleIndex: UInt32
        let argumentTable: any MTL4ArgumentTable
        switch frameRenderingMode {
        case .realtime:
            updateScene()
            let result = buildCurrentPacket()
            guard result == 0 else {
                NSLog("GeometryCore scene build failed with error %d", result)
                return
            }
            copyAtlasPacket(to: sceneBuffers[index])
            sampleIndex = 0
            argumentTable = argumentTables[index]
        case .photo:
            guard photoModeState.sampleIndex < UInt32.max else {
                NSLog("Photo Mode reached its maximum sample count")
                return
            }
            sampleIndex = photoModeState.sampleIndex
            argumentTable = photoArgumentTables[index]
        }
        var parameters = FrameParameters(
            sampleIndex: sampleIndex,
            exposure: max(exposure, 0))
        _ = withUnsafeBytes(of: &parameters) { bytes in
            memcpy(
                frameParameterBuffers[index].contents(),
                bytes.baseAddress!,
                bytes.count)
        }

        commandAllocator.reset()
        commandBuffer.beginCommandBuffer(allocator: commandAllocator)

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        let modelIndex: Int
        switch ambientSpace {
        case .hyperbolic: modelIndex = 0
        case .sphere: modelIndex = 1
        case .euclidean: modelIndex = 2
        }
        let pipelineIndex = modelIndex * 2 + (traversalMode == .atlas ? 1 : 0)
        let activePipeline = frameRenderingMode == .photo
        ? photoTracingPipelines[pipelineIndex]
        : tracingPipelines[pipelineIndex]
        guard let activePipeline
        else {
            fatalError("missing tracing specialization")
        }
        computeEncoder.setComputePipelineState(activePipeline)
        computeEncoder.setArgumentTable(argumentTable)

        let width = renderTexture.width
        let height = renderTexture.height

        let threadWidth = activePipeline.threadExecutionWidth
        let threadHeight = max(1, activePipeline.maxTotalThreadsPerThreadgroup / threadWidth)

        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)

        computeEncoder.dispatchThreads(
            threadsPerGrid: threadsPerGrid,
            threadsPerThreadgroup: threadsPerGroup)
        if frameRenderingMode == .photo {
            // Every photo pass reads the HDR sum written by the preceding
            // pass, including when that pass is in another command buffer.
            computeEncoder.barrier(
                afterStages: .dispatch,
                beforeQueueStages: .dispatch,
                visibilityOptions: .device)
        }
        let metalFXOutputTexture =
        metalFXOutputTextures.indices.contains(index)
        ? metalFXOutputTextures[index]
        : nil
        let activeSpatialScaler = metalFXOutputTexture.flatMap {
            self.activeSpatialScaler(
                for: renderTexture,
                output: $0,
                drawableTexture: drawable.texture)
        }
        computeEncoder.endEncoding()

        guard let presentationCommandBuffer = presentationCommandQueue.makeCommandBuffer()
        else {
            return
        }
        presentationCommandBuffer.label = "Present traced frame"
        traceReadyEventValue += 1
        let traceReadyValue = traceReadyEventValue
        presentationCommandBuffer.encodeWaitForEvent(
            traceReadyEvent, value: traceReadyValue)

        let presentationTexture: any MTLTexture
        if let activeSpatialScaler, let metalFXOutputTexture {
            activeSpatialScaler.colorTexture = renderTexture
            activeSpatialScaler.outputTexture = metalFXOutputTexture
            activeSpatialScaler.inputContentWidth = renderResolution.width
            activeSpatialScaler.inputContentHeight = renderResolution.height
            activeSpatialScaler.encode(commandBuffer: presentationCommandBuffer)
            presentationTexture = metalFXOutputTexture
        } else {
            presentationTexture = renderTexture
        }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard
            let presentationEncoder = presentationCommandBuffer.makeRenderCommandEncoder(
                descriptor: renderPass)
        else {
            return
        }
        presentationEncoder.setRenderPipelineState(presentationPipeline)
        presentationEncoder.setFragmentTexture(presentationTexture, index: 0)
        presentationEncoder.setViewport(presentationViewport(for: drawable.texture))
        presentationEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6)
        presentationEncoder.endEncoding()

        commandBuffer.endCommandBuffer()

        // The GPU event bridges the Metal 4 ray-tracing queue to the
        // conventional Metal queue used by the stable MetalFX encoder.
        commandQueue.commit([commandBuffer], options: commitOptions)
        commandQueue.signalEvent(traceReadyEvent, value: traceReadyValue)

        frameEventValue += 1
        frameCompletionValues[index] = frameEventValue
        presentationCommandBuffer.encodeSignalEvent(
            frameEvent, value: frameEventValue)
        presentationCommandBuffer.present(drawable)
        presentationCommandBuffer.commit()

        if frameRenderingMode == .photo {
            photoModeState.recordSubmittedSample()
        }

        frameIndex += 1
    }
}
