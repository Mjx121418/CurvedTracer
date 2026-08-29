import GeometryCore
import XCTest

final class GeometryCoreTests: XCTestCase {
  func testGenericGeodesicInterop() {
    var geodesic = geo.Geodesic(
      geo.vec4(0, 0, 0, 1),
      geo.vec4(0.6, -0.3, 0.2, 0)
    )
    XCTAssertTrue(geo.canonicalizeGeodesic(&geodesic, 1))
    let point = geo.geodesicPointAt(geodesic, 0.4, 1)
    let tangent = geo.geodesicTangentAt(geodesic, 0.4, 1)
    XCTAssertEqual(point.x * tangent.x + point.y * tangent.y +
                   point.z * tangent.z + point.w * tangent.w,
                   0, accuracy: 0.0001)
    XCTAssertTrue(geo.advanceGeodesic(&geodesic, 0.4, 1))
    XCTAssertEqual(geodesic.point.x, point.x, accuracy: 0.0001)
    XCTAssertEqual(geodesic.point.w, point.w, accuracy: 0.0001)
  }

  func testPacketLayoutAndNativePoints() {
    XCTAssertEqual(geo.geometryCoreName(), "Geometry Core v16")
    XCTAssertEqual(MemoryLayout<geo.Camera>.size, 96)
    XCTAssertEqual(MemoryLayout<geo.RenderControls>.size, 48)
    XCTAssertEqual(MemoryLayout<geo.Counts>.size, 32)
    XCTAssertEqual(MemoryLayout<geo.ScenePacketHeader>.size, 192)
    XCTAssertEqual(MemoryLayout<geo.Object>.size, 48)
    XCTAssertEqual(MemoryLayout<geo.Quadric>.size, 64)
    XCTAssertEqual(MemoryLayout<geo.PrimitiveClip>.size, 32)
    XCTAssertEqual(MemoryLayout<geo.GPUChart>.size, 32)
    XCTAssertEqual(MemoryLayout<geo.GPUPortal>.size, 112)
    XCTAssertEqual(MemoryLayout<geo.Material>.size, 48)
    XCTAssertEqual(MemoryLayout<geo.PointLight>.size, 48)

    var atlas = geo.Atlas()
    atlas.start(2)
    XCTAssertEqual(atlas.seed(), 0)
    let point = atlas.pointFromOriginTangent(geo.vec3(1, 2, 3))
    XCTAssertEqual(point.w, 1)
    XCTAssertEqual(point.z, 3)
  }

  func testTypedSceneAndUnifiedBuilds() {
    var atlas = geo.Atlas()
    atlas.start(0)
    XCTAssertEqual(atlas.seed(), 0)
    XCTAssertEqual(
      atlas.addMaterial(
        geo.vec4(1, 0, 0, 1), 0, 0, 1.5, 0, geo.vec3()), 0
    )
    XCTAssertEqual(
      atlas.addMaterial(
        geo.vec4(0.8, 0.7, 0.6, 1), 0.35, 0.2, 1.45, 0.1,
        geo.vec3(2, 1, 0.5)), 1
    )
    let center = atlas.pointFromOriginTangent(geo.vec3(0.3, 0, 0))
    XCTAssertEqual(atlas.addBall(0, center, 0.2, 0), 0)
    XCTAssertEqual(atlas.addPlane(0, geo.vec3(0, 2, 0), 1, 0), 1)
    XCTAssertEqual(
      atlas.addLight(0, atlas.pointFromOriginTangent(geo.vec3(-0.2, 0, 0)), geo.vec3(1, 1, 1), 1), 0
    )
    XCTAssertEqual(
      atlas.addSphericalAreaLight(
        0, atlas.pointFromOriginTangent(geo.vec3(0.1, 0.1, 0)), 0.1,
        geo.vec3(0.8, 0.7, 0.6), 4), 1
    )
    atlas.setCamera(0.8, 1.6, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
    XCTAssertEqual(atlas.cameraChartAt(0, geo.vec4(0, 0, 0, 1), 2.5), 0)

    XCTAssertEqual(atlas.build(0, 64), 0)
    let flat = [UInt8](atlas.packetBytes())
    XCTAssertEqual(flat.count, 192 + 32 + 2 * 48 + 2 * 48 + 2 * 48)
    XCTAssertEqual(flat[4], 16)

    XCTAssertEqual(atlas.buildAtlas(0, 64, 1, 32), 0)
    let authored = [UInt8](atlas.packetBytes())
    XCTAssertEqual(authored.count, 192 + 32 + 2 * 48 + 2 * 48 + 2 * 48)
    XCTAssertNotNil(atlas.packetData())
  }

  func testEuclideanPortalWrapping() {
    var atlas = geo.Atlas()
    atlas.start(2)
    XCTAssertEqual(atlas.seed(), 0)
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

  func testCappedTubePortalAuthoring() {
    var atlas = geo.Atlas()
    atlas.start(2)
    XCTAssertEqual(atlas.seed(), 0)
    var identity = [Float](repeating: 0, count: 16)
    identity[0] = 1
    identity[5] = 1
    identity[10] = 1
    identity[15] = 1
    XCTAssertEqual(atlas.addChart(0, identity, true), 1)
    XCTAssertEqual(
      atlas.addCappedTubePortal(
        0, 1, geo.vec3(0, 0, 1), 0.2, -0.3, 0.3, identity, 0.01),
      0
    )
    XCTAssertEqual(atlas.portalCount(), 6)
    let entered = atlas.resolveCameraPlacement(
      0, geo.vec4(0.3, 0, 0, 1), geo.vec3(-0.2, 0, 0))
    XCTAssertEqual(entered.chartId, 1)
    XCTAssertEqual(atlas.cameraChartAt(0, geo.vec4(0.3, 0, 0, 1), 2.5), 0)
    XCTAssertEqual(atlas.buildAtlas(0, 64, 1, 32), 0)
  }

  func testGeodesicBallPortalAuthoring() {
    var atlas = geo.Atlas()
    atlas.start(2)
    XCTAssertEqual(atlas.seed(), 0)
    var identity = [Float](repeating: 0, count: 16)
    identity[0] = 1
    identity[5] = 1
    identity[10] = 1
    identity[15] = 1
    XCTAssertEqual(atlas.addChart(0, identity, true), 1)
    XCTAssertEqual(
      atlas.addGeodesicBallPortal(
        0, 1, geo.vec4(0, 0, 0.1, 1), 0.3, identity, 0.01),
      0
    )
    XCTAssertEqual(atlas.portalCount(), 2)
    XCTAssertEqual(atlas.cameraChartAt(0, geo.vec4(0.5, 0, 0.1, 1), 2.5), 0)
    XCTAssertEqual(atlas.buildAtlas(0, 64, 1, 32), 0)
  }

  func testQuadricObjectClip() {
    var atlas = geo.Atlas()
    atlas.start(2)
    XCTAssertEqual(atlas.seed(), 0)
    XCTAssertEqual(
      atlas.addMaterial(
        geo.vec4(1, 1, 1, 1), 0, 0, 1.5, 0, geo.vec3()), 0
    )
    XCTAssertEqual(atlas.addPlane(0, geo.vec3(1, 0, 0), 0, 0), 0)
    var sphere = [Float](repeating: 0, count: 16)
    sphere[0] = 1
    sphere[5] = 1
    sphere[10] = 1
    sphere[15] = -1
    XCTAssertEqual(atlas.addObjectClipQuadric(0, sphere, false), 0)
    XCTAssertEqual(atlas.cameraChartAt(0, geo.vec4(0, 0, 0, 1), 2.5), 0)
    XCTAssertEqual(atlas.build(0, 64), 0)
  }
}
