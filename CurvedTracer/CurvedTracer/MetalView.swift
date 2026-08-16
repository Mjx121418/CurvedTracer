//
//  MetalView.swift
//  CurvedTracer
//
//

import SwiftUI
import MetalKit
import GeometryCore
import Darwin

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
        
        view.framebufferOnly = false

        context.coordinator.configure(device: device, view: view)
        context.coordinator.ambientSpace = ambientSpace
        context.coordinator.setScenePacket()

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

    var ambientSpace: AmbientSpace = .sphere

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
        // Create the atlas. 0 = H³, 1 = S³.
        atlas = geo.Atlas()
        atlas.start(0)

        // The anchorless base chart is always id 0. H3 chart radius: π/2.
        cameraChart = atlas.seed(1.5707963267948966)

        // Add materials first; colorIdx refers to these in order.
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 0.0, 1.0))  // material 0: red
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 0.0, 1.0))  // material 1: green
        _ = atlas.addMaterial(geo.vec4(0.0, 0.0, 1.0, 1.0))  // material 2: blue
        _ = atlas.addMaterial(geo.vec4(1.0, 1.0, 0.0, 1.0))  // material 3: yellow
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 1.0, 1.0))  // material 4: cyan
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 1.0, 1.0))  // material 5: magenta
        _ = atlas.addMaterial(geo.vec4(1.0, 1.0, 1.0, 1.0))  // material 6: white
        _ = atlas.addMaterial(geo.vec4(1.0, 0.5, 0.0, 1.0))  // material 7: orange

        // Simple v4 disk-chart objects: geodesic balls around the origin are
        // a=0, b=1, c=cos(radius). c=0.8 means disk radius sqrt(1-0.8²).
        _ = atlas.addObject(0, 0, geo.vec3(0, 0, 0), 1.0, 0.80, 0) // red
        _ = atlas.addObject(0, 0, geo.vec3(0, 0, 0), 1.0, 0.55, 1) // green
        _ = atlas.addObject(0, 0, geo.vec3(0, 0, 0), 1.0, 0.30, 2) // blue

        // H3 mirror hyperplane through the origin: a unit, b=0, c=0.
        _ = atlas.addObject(0, 1, geo.vec3(0, 0, 1), 0.0, 0.0, 6)

        // Point lights in the camera chart. H3 light positions must be inside
        // the Poincare ball.
        _ = atlas.addLight(0, geo.vec3( 0.30, 0.20, 0.10), geo.vec3(1.00, 0.95, 0.80), 1.0)  // warm key
        _ = atlas.addLight(0, geo.vec3(-0.40,-0.20, 0.15), geo.vec3(0.60, 0.70, 1.00), 0.5)  // cool fill

        // Camera is always at the chart origin; specify an orthonormal frame.
        atlas.setCamera(
            1.0,
            16.0 / 9.0,
            geo.vec3(1, 0, 0),
            geo.vec3(0, 1, 0),
            geo.vec3(0, 0, 1)
        )

        atlas.setControls(
            3,
            0.05,
            0.15,
            0.95
        )

        // Validate and flatten into the camera chart.
        let result = atlas.build(cameraChart, 64)
        if result != 0 {
            fatalError("build failed with code \(result)")
        }

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
        // Per-frame modification example: orbit the camera around +y.
        // Replace this with whatever animation/input logic you need.
        atlas.cameraRotate(geo.vec3(0, 1, 0), 0.01)
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
