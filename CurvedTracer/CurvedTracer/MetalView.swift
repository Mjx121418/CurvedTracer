//
//  MetalView.swift
//  CurvedTracer
//
//

import SwiftUI
import MetalKit

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

        context.coordinator.configure(device: device, view: view)
        context.coordinator.ambientSpace = ambientSpace

        view.delegate = context.coordinator

        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.ambientSpace = ambientSpace
    }
}


final class Renderer: NSObject, MTKViewDelegate {
    private var commandQueue: (any MTL4CommandQueue)?
    private var commandBuffer: (any MTL4CommandBuffer)?
    private var commandAllocator: (any MTL4CommandAllocator)?

    var ambientSpace: AmbientSpace = .sphere

    func configure(device: MTLDevice, view: MTKView) {
        guard
            let commandQueue = device.makeMTL4CommandQueue(),
            let commandBuffer = device.makeCommandBuffer(),
            let commandAllocator = device.makeCommandAllocator()
        else {
            fatalError("Failed to create Metal 4 command objects")
        }

        self.commandQueue = commandQueue
        self.commandBuffer = commandBuffer
        self.commandAllocator = commandAllocator

        commandQueue.addResidencySet(view.residencySet)
    }

    func mtkView(
        _ view: MTKView,
        drawableSizeWillChange size: CGSize
    ) {
    }

    func draw(in view: MTKView) {
        guard
            let commandQueue,
            let commandBuffer,
            let commandAllocator,
            let drawable = view.currentDrawable,
            let descriptor = view.currentMTL4RenderPassDescriptor
        else {
            return
        }

        commandAllocator.reset()
        commandBuffer.beginCommandBuffer(allocator: commandAllocator)

        guard let encoder =
            commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            )
        else {
            return
        }

        // No drawing yet. The render pass only clears the drawable.
        encoder.endEncoding()

        commandBuffer.endCommandBuffer()

        commandQueue.waitForDrawable(drawable)
        commandQueue.commit([commandBuffer])
        commandQueue.signalDrawable(drawable)

        drawable.present()
    }
}
