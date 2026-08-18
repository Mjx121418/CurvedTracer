//
//  MetalView.swift
//  CurvedTracer
//

import SwiftUI
import MetalKit
import GeometryCore
import Darwin
import AppKit

enum AmbientSpace: String, CaseIterable, Identifiable {
    case sphere = "S^3"
    case hyperbolic = "H^3"
    
    var id: Self { self }
}

struct MetalView: NSViewRepresentable {
    @Binding var ambientSpace: AmbientSpace

    func makeCoordinator() -> Renderer {
        Renderer()
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
        
        view.framebufferOnly = false
        DispatchQueue.main.async {
            view.window?.acceptsMouseMovedEvents = true
        }

        context.coordinator.configure(device: device, view: view)
        context.coordinator.ambientSpace = ambientSpace
        context.coordinator.setScenePacket()
        context.coordinator.installEventMonitors()

        view.delegate = context.coordinator

        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.ambientSpace = ambientSpace
    }
}


final class Renderer: NSObject, MTKViewDelegate {
    private var device: (any MTLDevice)!

    private var pipeline: (any MTLComputePipelineState)!
    private var sceneBuffers: [any MTLBuffer] = []
    
    private var commandQueue: (any MTL4CommandQueue)!
    private var commandBuffers: [any MTL4CommandBuffer] = []
    private var commandAllocators: [any MTL4CommandAllocator] = []

    private var frameEvent: (any MTLSharedEvent)!
    private var frameEventValue: UInt64 = 0
    private var frameIndex: Int = 0
    private let maxFramesInFlight = 3
    
    private var argumentTable: (any MTL4ArgumentTable)!
    private var residencySet: (any MTLResidencySet)!
    
    private var renderTexture: (any MTLTexture)!

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

    var ambientSpace: AmbientSpace = .sphere

    func installEventMonitors() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            if let self, self.cameraControlEnabled {
                self.queueMouseDelta(dx: event.deltaX, dy: event.deltaY)
            }
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self {
                if event.keyCode == 48 {   // Tab
                    self.setCameraControlEnabled(!self.cameraControlEnabled)
                    return nil
                }
                if self.isCameraControlKey(event.keyCode) {
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

    func configure(device: MTLDevice, view: MTKView) {
        self.device = device

        let library = device.makeDefaultLibrary()!
        guard let function = library.makeFunction(name: "raytrace") else {
            fatalError("raytrace shader not found")
        }
        self.pipeline = try! device.makeComputePipelineState(function: function)

        guard let commandQueue = device.makeMTL4CommandQueue() else {
            fatalError("Failed to create Metal 4 command queue")
        }
        self.commandQueue = commandQueue

        guard let frameEvent = device.makeSharedEvent() else {
            fatalError("Failed to create shared event")
        }
        self.frameEvent = frameEvent

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

        let maxPacketSize = 128 + 4096 * 32 + 256 * 16 + 16 * 32
        for _ in 0..<maxFramesInFlight {
            guard let buffer = device.makeBuffer(length: maxPacketSize, options: .storageModeShared) else {
                fatalError("Failed to create scene buffer")
            }
            sceneBuffers.append(buffer)
            residencySet.addAllocation(buffer)
        }

        let descriptor = MTL4ArgumentTableDescriptor()
        descriptor.maxBufferBindCount = 1
        descriptor.maxTextureBindCount = 1
        
        self.argumentTable = try! device.makeArgumentTable(descriptor: descriptor)
    }
    
    func setScenePacket() {
        // Build the hardcoded hyperbolic scene and obtain the camera chart id.
        atlas = geo.Atlas()
        // cameraChart = SphericalScene.cell24(&atlas)
        cameraChart = HyperbolicScene.configure(&atlas)
        // cameraChart = SphericalScene.configure(&atlas)

        // Copy the initial packet into every frame slot.
        for buffer in sceneBuffers {
            copyAtlasPacket(to: buffer)
        }
        if let firstBuffer = sceneBuffers.first {
            argumentTable.setAddress(firstBuffer.gpuAddress, index: 0)
        }

        self.residencySet.commit()
        self.residencySet.requestResidency()
    }

    private func copyAtlasPacket(to buffer: any MTLBuffer) {
        // Use the by-value packetBytes() accessor. The raw packetData() pointer
        // is an interior pointer into a C++ value type and is not safe to use
        // from Swift when atlas is a stored property.
        let packet = [UInt8](atlas.packetBytes())
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

        if pressedKeys[12] == true {   // Q: roll left
            atlas.cameraRoll(cameraRollSpeed)
        }
        if pressedKeys[14] == true {   // E: roll right
            atlas.cameraRoll(-cameraRollSpeed)
        }

        applyMovementKeys()

        // Arrow keys: hold to rotate, like Q/E.
        var yaw: Float = 0
        var pitch: Float = 0
        if pressedKeys[123] == true { yaw -= cameraAutoRotateSpeed }   // left arrow
        if pressedKeys[124] == true { yaw += cameraAutoRotateSpeed }   // right arrow
        if pressedKeys[126] == true { pitch -= cameraAutoRotateSpeed } // up arrow
        if pressedKeys[125] == true { pitch += cameraAutoRotateSpeed } // down arrow
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

        if pressedKeys[13] == true {   // W
            dx += fwd.x; dy += fwd.y; dz += fwd.z
        }
        if pressedKeys[1] == true {    // S
            dx -= fwd.x; dy -= fwd.y; dz -= fwd.z
        }
        if pressedKeys[2] == true {    // D
            dx += right.x; dy += right.y; dz += right.z
        }
        if pressedKeys[0] == true {    // A
            dx -= right.x; dy -= right.y; dz -= right.z
        }
        if pressedKeys[15] == true {   // R
            dx += up.x; dy += up.y; dz += up.z
        }
        if pressedKeys[3] == true {    // F
            dx -= up.x; dy -= up.y; dz -= up.z
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
        guard size.width > 0, size.height > 0 else {
            return
        }
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.colorPixelFormat, width: Int(size.width), height: Int(size.height), mipmapped: false)
        
        descriptor.storageMode = .private
        descriptor.usage = [.shaderWrite]
        
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create render texture")
        }
        
        renderTexture = texture
        
        residencySet.addAllocation(texture)
        residencySet.commit()
    }

    func draw(in view: MTKView) {
        guard
            let commandQueue,
            let renderTexture,
            let drawable = view.currentDrawable
        else {
            return
        }

        let index = frameIndex % maxFramesInFlight
        let commandAllocator = commandAllocators[index]
        let commandBuffer = commandBuffers[index]

        // The same allocator was last used maxFramesInFlight frames ago. Wait
        // until the GPU has signaled that the old command buffer completed
        // before resetting and reusing the allocator.
        let waitValue = frameIndex >= maxFramesInFlight
            ? UInt64(frameIndex - maxFramesInFlight + 1)
            : 0
        _ = frameEvent.wait(untilSignaledValue: waitValue, timeoutMS: 1000)

        updateScene()
        let result = atlas.build(cameraChart, 64)
        guard result == 0 else {
            return
        }

        copyAtlasPacket(to: sceneBuffers[index])

        commandAllocator.reset()
        commandBuffer.beginCommandBuffer(allocator: commandAllocator)

        argumentTable.setAddress(sceneBuffers[index].gpuAddress, index: 0)
        argumentTable.setTexture(renderTexture.gpuResourceID, index: 0)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setArgumentTable(argumentTable)
        
        let width = drawable.texture.width
        let height = drawable.texture.height
        
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)

        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        
        encoder.dispatchThreads(threadsPerGrid: threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        encoder.copy(sourceTexture: renderTexture, destinationTexture: drawable.texture)

        encoder.endEncoding()
        
        // Schedule the event signal, then close encoding and commit.
        frameEventValue += 1
        commandQueue.signalEvent(frameEvent, value: frameEventValue)

        commandBuffer.endCommandBuffer()

        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer])
        commandQueue.signalDrawable(drawable)
        
        drawable.present()
        
        frameIndex += 1
    }
}
