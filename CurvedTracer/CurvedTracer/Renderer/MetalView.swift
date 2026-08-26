//
//  MetalView.swift
//  CurvedTracer
//

import AppKit
import MetalKit
import SwiftUI

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
