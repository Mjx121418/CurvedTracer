//
//  RendererScene.swift
//  CurvedTracer
//

import Foundation
import Darwin
import GeometryCore
import Metal

extension Renderer {
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
            case .hopfFacePatches:
                cameraChart = SphericalScene.hopfFacePatches(&atlas)
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
        case (.atlas, .sphere):
            switch sphericalAtlasVariant {
            case .lensSpace: cameraChart = SphericalScene.lensSpaceL52(&atlas)
            case .towerTiling: cameraChart = TowerScene.spherical(&atlas)
            }
        case (.atlas, .hyperbolic):
            switch hyperbolicAtlasVariant {
            case .oneChart: cameraChart = HyperbolicScene.seifertWeberAtlas(&atlas)
            case .multiChart: cameraChart = HyperbolicScene.seifertWeberMultiChartAtlas(&atlas)
            case .towerTiling: cameraChart = TowerScene.hyperbolic(&atlas)
            }
        case (.atlas, .euclidean):
            switch euclideanAtlasVariant {
            case .torus: cameraChart = EuclideanScene.torus(&atlas)
            case .towerTiling: cameraChart = TowerScene.euclidean(&atlas)
            }
        }

        // draw(in:) uploads into a frame slot only after that slot's previous
        // GPU work completes. Avoid touching all in-flight buffers here when
        // the user switches scenes.
        self.residencySet.commit()
        self.residencySet.requestResidency()
    }

    func buildCurrentPacket() -> Int32 {
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

        switch mode {
        case .realtime:
            // Exiting does not mutate any resource used by an in-flight photo
            // pass. Flip the CPU state immediately; each realtime frame will
            // still wait for its own slot before reusing GPU resources.
            photoModeState.exit()
            return true
        case .photo:
            guard waitForAllFrames() else { return false }
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

    func copyAtlasPacket(to buffer: any MTLBuffer) {
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
}
