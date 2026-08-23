import GeometryCore
import XCTest

final class GeometryCoreTests: XCTestCase {
  func testPacketLayoutAndNativePoints() {
    XCTAssertEqual(geo.geometryCoreName(), "Geometry Core v10")
    XCTAssertEqual(MemoryLayout<geo.Camera>.size, 96)
    XCTAssertEqual(MemoryLayout<geo.RenderControls>.size, 48)
    XCTAssertEqual(MemoryLayout<geo.Counts>.size, 32)
    XCTAssertEqual(MemoryLayout<geo.ScenePacketHeader>.size, 192)
    XCTAssertEqual(MemoryLayout<geo.Object>.size, 32)
    XCTAssertEqual(MemoryLayout<geo.GPUChart>.size, 32)
    XCTAssertEqual(MemoryLayout<geo.GPUPortal>.size, 96)

    var atlas = geo.Atlas()
    atlas.start(2)
    XCTAssertEqual(atlas.seed(4), 0)
    let point = atlas.pointFromOriginTangent(geo.vec3(1, 2, 3))
    XCTAssertEqual(point.w, 1)
    XCTAssertEqual(point.z, 3)
  }

  func testTypedSceneAndUnifiedBuilds() {
    var atlas = geo.Atlas()
    atlas.start(0)
    XCTAssertEqual(atlas.seed(3), 0)
    XCTAssertEqual(atlas.addMaterial(geo.vec4(1, 0, 0, 1), geo.vec4(0.2, 0.2, 0.2, 1)), 0)
    let center = atlas.pointFromOriginTangent(geo.vec3(0.3, 0, 0))
    XCTAssertEqual(atlas.addBall(0, center, 0.2, 0), 0)
    XCTAssertEqual(atlas.addMirrorPlane(0, geo.vec3(0, 2, 0), 1, 0), 1)
    XCTAssertEqual(
      atlas.addLight(0, atlas.pointFromOriginTangent(geo.vec3(-0.2, 0, 0)), geo.vec3(1, 1, 1), 1), 0
    )
    atlas.setCamera(0.8, 1.6, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
    XCTAssertEqual(atlas.cameraChartAt(0, geo.vec4(0, 0, 0, 1), 2.5), 0)

    XCTAssertEqual(atlas.build(0, 64), 0)
    let flat = [UInt8](atlas.packetBytes())
    XCTAssertEqual(flat.count, 192 + 32 + 2 * 32 + 32 + 32)
    XCTAssertEqual(flat[4], 10)

    XCTAssertEqual(atlas.buildAtlas(0, 64, 1, 32), 0)
    let authored = [UInt8](atlas.packetBytes())
    XCTAssertEqual(authored.count, flat.count)
    XCTAssertNotNil(atlas.packetData())
  }

  func testEuclideanPortalWrapping() {
    var atlas = geo.Atlas()
    atlas.start(2)
    XCTAssertEqual(atlas.seed(2), 0)
    var translation = [Float](repeating: 0, count: 16)
    translation[0] = 1
    translation[5] = 1
    translation[10] = 1
    translation[15] = 1
    translation[12] = -2
    XCTAssertGreaterThanOrEqual(
      atlas.addPortalPair(
        0, geo.vec3(1, 0, 0), 1,
        0, geo.vec3(-1, 0, 0), 1,
        translation), 0)
    XCTAssertEqual(atlas.portalCount(), 2)
    XCTAssertEqual(atlas.cameraChartAt(0, geo.vec4(0.99, 0, 0, 1), 5), 0)
    XCTAssertEqual(atlas.cameraMove(geo.vec3(0.03, 0, 0)), 0)
    XCTAssertEqual(atlas.buildAtlas(0, 64, 1, 32), 0)
  }
}
