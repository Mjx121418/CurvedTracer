//
//  Hyperbolic.swift
//  CurvedTracer
//

import Foundation
import GeometryCore

enum HyperbolicScene {
    /// Builds the hardcoded hyperbolic test scene in `atlas`.
    /// Returns the camera chart id.
    @discardableResult
    static func configure(_ atlas: inout geo.Atlas) -> Int32 {
        // Create the atlas. 0 = H³, 1 = S³.
        atlas.start(0)

        // The anchorless base chart is always id 0. H3 chart radius: π/2.
        _ = atlas.seed(Float.pi * 0.999 / 2)

        // Add materials first; colorIdx refers to these in order.
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))  // material 0: red
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))  // material 1: green
        _ = atlas.addMaterial(geo.vec4(0.0, 0.0, 1.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))  // material 2: blue
        _ = atlas.addMaterial(geo.vec4(1.0, 1.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))  // material 3: yellow
        _ = atlas.addMaterial(geo.vec4(0.0, 1.0, 1.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))  // material 4: cyan
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 1.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))  // material 5: magenta
        _ = atlas.addMaterial(geo.vec4(0.15, 0.15, 0.15, 1.0), geo.vec4(0.5, 0.95, 0.97, 1.0))  // material 6: silver mirror
        _ = atlas.addMaterial(geo.vec4(1.0, 0.5, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))  // material 7: orange

        // v4 disk-chart objects arranged like the pre-v4 H3 scene.
        // Each OPAQUE is the disk-chart hyperplane section corresponding to a
        // Poincare-ball sphere center p0 / radius r:
        //   a = p0
        //   b = (1 - |p0|² + r²) / 2
        //   c = (1 + |p0|² - r²) / 2
        _ = atlas.addObject(0, 0, geo.vec3(-0.05, 0.00, 0.10), 0.4956, 0.5044, 0) // red
        _ = atlas.addObject(0, 0, geo.vec3( 0.12, 0.04, 0.15), 0.4832, 0.5168, 1) // green
        _ = atlas.addObject(0, 0, geo.vec3(-0.15,-0.06, 0.20), 0.4710, 0.5290, 2) // blue
        // _ = atlas.addObject(0, 0, geo.vec3( 0.00, 0.10, 0.22), 0.4732, 0.5268, 3) // yellow
        // _ = atlas.addObject(0, 0, geo.vec3( 0.00,-0.10, 0.18), 0.4806, 0.5194, 5) // magenta

        // Old H3 mirror sphere c=(0,0,2), r=√3 becomes disk plane z=0.5.
        // _ = atlas.addObject(0, 1, geo.vec3(0, 0, 1), 0.0, 0.5, 6)

        // mirror: normal (0,1,0), below all existing balls.
        _ = atlas.addObject(0, 1, geo.vec3(0, 1, 0), 0.0, -0.35, 6)
        _ = atlas.addObject(0, 1, geo.vec3(0, -1, 0), 0.0, -0.35, 6)

        // Colorful objects behind the camera, visible through the mirror.
        // _ = atlas.addObject(0, 0, geo.vec3( 0.10, 0.10,-0.30), 0.4563, 0.5438, 4) // cyan
        _ = atlas.addObject(0, 0, geo.vec3(-0.12,-0.08,-0.35), 0.4412, 0.5588, 5) // magenta
        _ = atlas.addObject(0, 0, geo.vec3( 0.00, 0.00,-0.45), 0.4150, 0.5850, 7) // orange

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
            6,
            0.05,
            0.25,
            0.95,
            2.0,
            0.0,
            0.0
        )

        // Initialize the special camera chart at the base position.
        let cameraChart = atlas.cameraChartAt(0, geo.vec3(0, 0, 0), Float.pi * 0.99 / 2)

        // Validate and flatten into the camera chart.
        let result = atlas.build(cameraChart, 64)
        if result != 0 {
            fatalError("build failed with code \(result)")
        }

        return cameraChart
    }
    /// Builds a hyperbolic honeycomb-cell test scene: one chart, one red ball
    /// at the origin, and six totally geodesic mirrors forming the faces of a
    /// {4,3,5} cell. A single point light is placed inside the enclosed region.
    @discardableResult
    static func honeycombCell(_ atlas: inout geo.Atlas) -> Int32 {
        // Face planes of a regular cube cell of the {4,3,5} honeycomb.
        // The cell inradius is d, and the six faces are
        //   x = ±tanh(d), y = ±tanh(d), z = ±tanh(d).
        // With d = 0.530637530952518 the cube dihedral angle is 72°.
        let faceOffset: Float = 0.4858682717566457

        atlas.start(0)   // H³
        _ = atlas.seed(Float.pi / 2)

        // Material 0: red ball. Material 1: silver mirror.
        _ = atlas.addMaterial(geo.vec4(1.0, 0.0, 0.0, 1.0), geo.vec4(0.3, 0.3, 0.3, 1.0))
        _ = atlas.addMaterial(geo.vec4(0.2, 0.2, 0.2, 1.0), geo.vec4(1.0, 1.0, 1.0, 1.0))

        // Single red ball at the origin.
        _ = atlas.addObject(0, 0, geo.vec3(0, 0, 0), 1.0, 0.98, 0)

        // Six mirror faces: x = ±faceOffset, y = ±faceOffset, z = ±faceOffset.
        _ = atlas.addObject(0, 1, geo.vec3(1, 0, 0), 0.0, faceOffset, 1)
        _ = atlas.addObject(0, 1, geo.vec3(-1, 0, 0), 0.0, faceOffset, 1)

        _ = atlas.addObject(0, 1, geo.vec3(0, 1, 0), 0.0, faceOffset, 1)
        _ = atlas.addObject(0, 1, geo.vec3(0, -1, 0), 0.0, faceOffset, 1)

        _ = atlas.addObject(0, 1, geo.vec3(0, 0, 1), 0.0, faceOffset, 1)
        _ = atlas.addObject(0, 1, geo.vec3(0, 0, -1), 0.0, faceOffset, 1)

        // Six point lights around the ball, inside the enclosed region.
        let lightRadius: Float = 0.32
        let warm = geo.vec3(1.00, 0.95, 0.80)
        let cool = geo.vec3(0.60, 0.70, 1.00)
        _ = atlas.addLight(0, geo.vec3( lightRadius, 0, 0), warm, 0.6)
        _ = atlas.addLight(0, geo.vec3(-lightRadius, 0, 0), cool, 0.6)
        _ = atlas.addLight(0, geo.vec3(0,  lightRadius, 0), warm, 0.6)
        _ = atlas.addLight(0, geo.vec3(0, -lightRadius, 0), cool, 0.6)
        _ = atlas.addLight(0, geo.vec3(0, 0,  lightRadius), warm, 0.6)
        _ = atlas.addLight(0, geo.vec3(0, 0, -lightRadius), cool, 0.6)

        atlas.setCamera(
            1.0,
            16.0 / 9.0,
            geo.vec3(-0.7071068, 0.7071068, 0.0),
            geo.vec3(-0.4082483, -0.4082483, 0.8164966),
            geo.vec3(0.5773503, 0.5773503, 0.5773503)
        )

        atlas.setControls(
            10,
            0.05,
            0.25,
            0.95,
            0.0,
            0.0,
            0.0
        )

        // Camera on the geodesic segment from the origin toward the
        // (1,1,1) vertex of the {4,3,5} cell, outside the central ball, looking
        // along the segment at that vertex.
        let cameraPos: Float = 0.2668035
        let cameraW: Float = 0.8868189
        let cameraChart = atlas.cameraChartAt(0, geo.vec3(cameraPos, cameraPos, cameraPos),
                                               cameraW, Float.pi * 0.99 / 2)
        let result = atlas.build(cameraChart, 64)
        if result != 0 {
            fatalError("build failed with code \(result)")
        }
        return cameraChart
    }
}
