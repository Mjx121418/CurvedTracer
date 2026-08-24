# Repository Guidelines

## Project Structure & Module Organization

`CurvedTracer/CurvedTracer/` contains the macOS SwiftUI application. Scene definitions live in `Scenes/`, Metal kernels in `Shaders/`, and catalog-managed resources in `Assets.xcassets/`. App unit and UI tests are in the adjacent `CurvedTracerTests/` and `CurvedTracerUITests/` directories. `GeometryCore/` is a Swift Package wrapping the C++17 geometry implementation: public headers are under `Sources/include/GeometryCore/`, implementations under `Sources/src/`, and C++ and Swift interoperability tests under `Tests/`. Keep screenshots and documentation images in `Images/`. Read `CONTRACT.md` before changing GPU packet layouts, coordinate conventions, or portal behavior.

## Build, Test, and Development Commands

Run the portable geometry checks from the package directory:

```sh
cd GeometryCore
swift build                 # compile the library and C++ test executable
swift test                  # run Swift/XCTest interoperability tests
swift run geometry_tests    # run the standalone C++ test suite
```

On a compatible macOS/Xcode installation, open `CurvedTracer/CurvedTracer.xcodeproj`, or use:

```sh
xcodebuild -project CurvedTracer/CurvedTracer.xcodeproj \
  -scheme CurvedTracer -destination 'platform=macOS' test
```

The app requires Metal 4. `Dockerfile` and `run_container.sh` provide a Linux Swift development environment for `GeometryCore`, not the Metal UI.

## Coding Style & Naming Conventions

Follow the surrounding style: four-space indentation in app Swift and C++, and two spaces in the existing Swift package tests. Use `UpperCamelCase` for Swift types and scenes, `lowerCamelCase` for Swift functions and properties, and the established lowercase C++ math types (`vec3`, `mat4`). Name public headers after their primary type. No formatter or linter is configured, so keep diffs focused and preserve local formatting. Do not duplicate CPU/GPU geometry constants; maintain the packet contract shared with Metal.

## Testing Guidelines

Add C++ cases as `GeometryCore/Tests/Cpp/test_<area>.cpp` and register new suites with the C++ runner and `Package.swift`. Name XCTest methods `test...`. Cover packet sizes, native-space invariants, transforms, intersections, and portal traversal when those areas change. Run both GeometryCore test commands before submitting; run the Xcode test scheme for app, input, rendering, or shader changes.

## Commit & Pull Request Guidelines

History uses concise, imperative subjects such as `Add GPU atlas portal traversal`; follow that pattern and keep each commit cohesive. Pull requests should explain the behavior changed, identify affected space forms or traversal modes, list test commands and results, and link relevant issues. Include screenshots or recordings for visible rendering/UI changes and call out any `CONTRACT.md` or packet-layout changes explicitly.
