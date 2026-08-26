//
//  RendererInput.swift
//  CurvedTracer
//

import AppKit
import CoreGraphics
import GeometryCore

extension Renderer {
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

    func setCameraControlEnabled(_ enabled: Bool) {
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
    func updateScene() {
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
}
