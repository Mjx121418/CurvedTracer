//
//  RendererDraw.swift
//  CurvedTracer
//

import Foundation
import Metal
import MetalKit
import MetalFX

extension Renderer {
    func draw(in view: MTKView) {
        guard let commandQueue else {
            return
        }

        let index = frameIndex % maxFramesInFlight
        let commandAllocator = commandAllocators[index]
        let commandBuffer = commandBuffers[index]
        let renderTexture = renderTextures[index]
        let frameRenderingMode = renderingMode

        // A slot can be reused only after the queue signal placed after its
        // previous commit has completed. Do not block the UI thread while a
        // long photo pass is running; MTKView will call us again for a later
        // display refresh.
        let waitValue = frameCompletionValues[index]
        if waitValue != 0, frameEvent.signaledValue < waitValue {
            return
        }

        // Acquire a drawable only after we know this frame can be submitted.
        // Holding or waiting for a drawable while the GPU slot is still busy
        // can starve SwiftUI and WindowServer presentation.
        guard let drawable = view.currentDrawable else {
            return
        }
        performanceStats.recordFrame(at: ProcessInfo.processInfo.systemUptime)

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
