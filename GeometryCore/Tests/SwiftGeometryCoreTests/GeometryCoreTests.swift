import XCTest
import GeometryCore

final class GeometryCoreTests: XCTestCase {

    func testGeometryCoreName() {
        XCTAssertEqual(String(geo.geometryCoreName()), "Geometry Core")
    }

    func testResolveCameraPlacementSwiftInterop() {
        var atlas = geo.Atlas()
        atlas.start(0)
        _ = atlas.seed(1.0)
        let placement = atlas.resolveCameraPlacement(0, geo.vec3(0, 0, 0), geo.vec3(0.1, 0, 0))
        XCTAssertEqual(placement.chartId, 0)
        XCTAssertEqual(placement.localPosition.x, 0.1)

        let cameraChart = atlas.cameraChartAt(0, geo.vec3(0.1, 0, 0), 1.0)
        XCTAssertEqual(cameraChart, 1)
        XCTAssertEqual(atlas.build(Int32(cameraChart), 64), 0)

        let movedChart = atlas.cameraMove(geo.vec3(0.05, 0, 0))
        XCTAssertEqual(movedChart, atlas.cameraChartId())
        XCTAssertEqual(atlas.build(Int32(movedChart), 64), 0)
    }

    func testPacketStructSizes() {
        XCTAssertEqual(MemoryLayout<geo.PacketMeta>.size, 16)
        XCTAssertEqual(MemoryLayout<geo.Camera>.size, 64)
        XCTAssertEqual(MemoryLayout<geo.RenderControls>.size, 32)
        XCTAssertEqual(MemoryLayout<geo.Counts>.size, 16)
        XCTAssertEqual(MemoryLayout<geo.Object>.size, 32)
        XCTAssertEqual(MemoryLayout<geo.Material>.size, 32)
        XCTAssertEqual(MemoryLayout<geo.PointLight>.size, 32)
        XCTAssertEqual(MemoryLayout<geo.ScenePacketHeader>.size, 128)
    }

    func testAtlasBuildsAndFlattensThroughCxxInterop() throws {
        var atlas = geo.Atlas()
        atlas.start(0)   // H3; `start` is the Swift-visible alias for C++ `begin`

        XCTAssertEqual(atlas.seed(1.0), 0)

        // Add a second chart linked by an identity Mobius transition.
        let identity: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
        XCTAssertEqual(atlas.add(1.0, 0, identity, true), 1)

        // Author an H3 OPAQUE sphere (w=0.8), a material, and a point light.
        let a = geo.vec3(0.0, 0.0, 0.0)
        XCTAssertEqual(atlas.addObject(0, 0, a, 1.0, 0.8, 0), 0)
        XCTAssertEqual(atlas.addMaterial(geo.vec4(1.0, 0.5, 0.25, 1.0), geo.vec4(0.1, 0.1, 0.1, 1.0)), 0)
        XCTAssertEqual(atlas.addLight(0, geo.vec3(0.0, 0.0, -0.4), geo.vec3(1.0, 1.0, 0.9), 0.8), 0)

        // Camera and controls are data, not shader edits.
        atlas.setCamera(0.8, 1.6, geo.vec3(1, 0, 0), geo.vec3(0, 1, 0), geo.vec3(0, 0, 1))
        atlas.cameraRotate(geo.vec3(0, 1, 0), 0.0)   // smoke-test the Swift-visible camera rotation API
        atlas.cameraRoll(0.0)                        // smoke-test the Swift-visible roll API
        atlas.setControls(5, 0.1, 0.2, 0.7)

        // Build the packet from camera chart 0; 0 means success.
        XCTAssertEqual(atlas.build(0, 64), 0)

        // Swift-visible packet byte vector (std::vector<UInt8> by value).
        let packet = atlas.packetBytes()
        XCTAssertEqual(packet.size(), 128 + 32 + 32 + 32)
        XCTAssertEqual(atlas.packetSize(), packet.size())

        // Swift-visible direct byte pointer for MTLBuffer upload.
        XCTAssertNotNil(atlas.packetData())

        // Packet magic and contract version are the first two int32 fields.
        let bytes = [UInt8](packet)
        XCTAssertEqual(bytes.count, 128 + 32 + 32 + 32)
        XCTAssertEqual(bytes[0], 0x43)
        XCTAssertEqual(bytes[1], 0x52)
        XCTAssertEqual(bytes[2], 0x54)
        XCTAssertEqual(bytes[3], 0x4E)
    }
}
