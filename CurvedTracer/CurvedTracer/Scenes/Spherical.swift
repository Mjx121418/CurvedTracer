import Foundation
import GeometryCore

enum SphericalScene {
  private static func configure(_ atlas: inout geo.Atlas) {
    atlas.start(1)
    _ = atlas.seed(Float.pi * 0.94)
    let colors: [geo.vec4] = [
      geo.vec4(0.95, 0.12, 0.08, 1), geo.vec4(0.10, 0.65, 1, 1),
      geo.vec4(0.96, 0.72, 0.10, 1), geo.vec4(0.42, 0.90, 0.32, 1),
    ]
    for color in colors { _ = atlas.addMaterial(color, geo.vec4(0.3, 0.3, 0.3, 1)) }
    // Mirrors keep a visible cyan tint while retaining a strong reflection.
    _ = atlas.addMaterial(geo.vec4(0.0, 0.8, 0.9, 1), geo.vec4(0.45, 0.95, 1.0, 0.9))

    // A deterministic, asymmetric sample of the 600-cell directions.
    let phi: Float = (1 + sqrt(5)) / 2
    let directions: [SIMD3<Float>] = [
      [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1],
      [1, phi, 1 / phi], [-phi, 1, -1 / phi], [1 / phi, -phi, 1], [-1 / phi, -1, -phi],
    ]
    for (index, raw) in directions.enumerated() {
      let d =
        raw / sqrt(raw.x * raw.x + raw.y * raw.y + raw.z * raw.z)
        * (0.55 + 0.12 * Float(index % 3))
      let p = atlas.pointFromOriginTangent(geo.vec3(d.x, d.y, d.z))
      _ = atlas.addBall(0, p, 0.11 + 0.015 * Float(index % 2), Int32(index % 4))
    }
    _ = atlas.addMirrorPlane(0, geo.vec3(0, -1, 0), 1.25, 4)
    _ = atlas.addLight(
      0, atlas.pointFromOriginTangent(geo.vec3(-0.4, 0.25, -0.15)), geo.vec3(1, 0.92, 0.74), 1)
    _ = atlas.addLight(
      0, atlas.pointFromOriginTangent(geo.vec3(0.3, -0.1, 0.5)), geo.vec3(0.5, 0.7, 1), 0.55)
    atlas.setCamera(0.85, 16.0 / 9.0, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
    atlas.setControls(6, 0.05, 0.18, 0.92, 2, 0, 0.18)
  }

  @discardableResult static func cell600(_ atlas: inout geo.Atlas) -> Int32 {
    configure(&atlas)
    let camera = atlas.cameraChartAt(
      0, atlas.pointFromOriginTangent(geo.vec3(0.12, 0.08, -0.1)), 2.6)
    let result = atlas.build(camera, 64)
    if result != 0 { fatalError("S³ flat build failed: \(result)") }
    return camera
  }

  @discardableResult static func singleChartAtlas(_ atlas: inout geo.Atlas) -> Int32 {
    configure(&atlas)
    let camera = atlas.cameraChartAt(
      0, atlas.pointFromOriginTangent(geo.vec3(0.12, 0.08, -0.1)), 2.6)
    let result = atlas.buildAtlas(camera, 64, 1, 32)
    if result != 0 { fatalError("S³ atlas build failed: \(result)") }
    return camera
  }
}
