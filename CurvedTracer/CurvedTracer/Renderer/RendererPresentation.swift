//
//  RendererPresentation.swift
//  CurvedTracer
//

import Foundation
import Metal
import MetalFX
import MetalKit

extension Renderer {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        configureSpatialScaler(
            outputWidth: Int(size.width),
            outputHeight: Int(size.height),
            pixelFormat: view.colorPixelFormat)
    }

    func configureSpatialScaler(
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

    func activeSpatialScaler(
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

    func presentationViewport(for drawableTexture: any MTLTexture) -> MTLViewport {
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

    func consumeTraceStats(from buffer: any MTLBuffer) {
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
            portalTests: words[6],
            totalScatteringDepth: words[7],
            maximumScatteringDepth: words[8],
            rouletteTerminations: words[9],
            depthBoundTerminations: words[10])

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
}
