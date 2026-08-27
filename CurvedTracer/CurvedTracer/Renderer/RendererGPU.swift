//
//  RendererGPU.swift
//  CurvedTracer
//

import Foundation
import AppKit
import GeometryCore
import Metal
import MetalFX
import MetalKit

extension Renderer {
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

        // Covers the v15 packet maxima, including 48-byte material records.
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
}
