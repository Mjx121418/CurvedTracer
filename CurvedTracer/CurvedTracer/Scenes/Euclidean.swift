import GeometryCore

enum EuclideanScene {
    private static func identity() -> [Float] { [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] }
    private static func configure(_ atlas: inout geo.Atlas) {
        atlas.start(2)
        _ = atlas.seed(2.0)
        _ = atlas.addMaterial(geo.vec4(0.95, 0.18, 0.08, 1), geo.vec4(0.3, 0.3, 0.3, 1))
        _ = atlas.addMaterial(geo.vec4(0.08, 0.55, 1, 1), geo.vec4(0.3, 0.3, 0.3, 1))
        // Mirror material: cyan base tint plus a cyan-white reflected component.
        _ = atlas.addMaterial(geo.vec4(0.0, 0.8, 0.9, 1), geo.vec4(0.45, 0.95, 1.0, 0.9))
        _ = atlas.addBall(0, geo.vec4(0.28, -0.2, 0.12, 1), 0.15, 0)
        _ = atlas.addBall(0, geo.vec4(-0.4, 0.16, -0.24, 1), 0.22, 1)
        _ = atlas.addBall(0, geo.vec4(0.05, 0.32, 0.38, 1), 0.11, 0)
        _ = atlas.addLight(0, geo.vec4(-0.2, 0.25, 0.3, 1), geo.vec3(1, 0.9, 0.7), 1)
        atlas.setCamera(0.85, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
        atlas.setControls(6, 0.05, 0.16, 0.9, 2, 0, 0.0)
    }
    @discardableResult static func finite(_ atlas: inout geo.Atlas) -> Int32 {
        configure(&atlas)
        for u in [
            geo.vec3(1, 0, 0), geo.vec3(-1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, -1, 0),
            geo.vec3(0, 0, 1), geo.vec3(0, 0, -1),
        ] { _ = atlas.addMirrorPlane(0, u, 1.0, 2) }
        let c = atlas.cameraChartAt(0, geo.vec4(0.05, 0.03, -0.08, 1), 10)
        let r = atlas.build(c, 64)
        if r != 0 { fatalError("R³ flat build failed: \(r)") }
        return c
    }
    @discardableResult static func torus(_ atlas: inout geo.Atlas) -> Int32 {
        configure(&atlas)
        // Use the previous exponential-fog strength for the multi-cell horizon.
        // Fog distance is accumulated continuously across portal crossings.
        atlas.setControls(6, 0.05, 0.16, 0.9, 2, 0, 0.0)
        var tx = identity()
        var ty = identity()
        var tz = identity()
        tx[12] = -2
        ty[13] = -2
        tz[14] = -2
        _ = atlas.addPortalPair(0, geo.vec3(1, 0, 0), 1, 0, geo.vec3(-1, 0, 0), 1, tx)
        _ = atlas.addPortalPair(0, geo.vec3(0, 1, 0), 1, 0, geo.vec3(0, -1, 0), 1, ty)
        _ = atlas.addPortalPair(0, geo.vec3(0, 0, 1), 1, 0, geo.vec3(0, 0, -1), 1, tz)
        let c = atlas.cameraChartAt(0, geo.vec4(0.12, -0.08, 0.1, 1), 12)
        let r = atlas.buildAtlas(c, 128, 2, 64)
        if r != 0 { fatalError("R³ torus build failed: \(r)") }
        return c
    }
}
