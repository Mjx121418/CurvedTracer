// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GeometryCore",
    products: [
        .library(name: "GeometryCore", targets: ["GeometryCore"]),
        .executable(name: "geometry_tests", targets: ["geometry_tests"]),
    ],
    targets: [
        .target(
            name: "GeometryCore",
            path: "Sources",
            sources: [
                "src/Isometry.cpp",
                "src/Chart.cpp",
                "src/ChartMaterials.cpp",
                "src/ChartPortals.cpp",
                "src/ChartPacket.cpp",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        .executableTarget(
            name: "geometry_tests",
            dependencies: ["GeometryCore"],
            path: "Tests/Cpp",
            sources: [
                "test_main.cpp",
                "test_math.cpp",
                "test_stereo.cpp",
                "test_isometry.cpp",
                "test_intersect.cpp",
                "test_atlas.cpp",
            ],
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .linkedLibrary("m")
            ]
        ),
        .testTarget(
            name: "GeometryCoreTests",
            dependencies: ["GeometryCore"],
            path: "Tests/SwiftGeometryCoreTests",
            swiftSettings: [
                .interoperabilityMode(.Cxx)
            ]
        ),
    ]
)
