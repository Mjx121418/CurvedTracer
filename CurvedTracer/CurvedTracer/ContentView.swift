//
//  ContentView.swift
//  CurvedTracer
//

import GeometryCore
import SwiftUI

struct ContentView: View {
  @Binding var showsPerformanceOverlay: Bool
  @State private var ambienSpace: AmbientSpace = .sphere
  @State private var traversalMode: TraversalMode = .flat
  @State private var sphericalFlatSceneVariant: SphericalFlatSceneVariant = .cell600
  @State private var hyperbolicFlatSceneVariant: HyperbolicFlatSceneVariant = .honeycombCell
  @State private var hyperbolicAtlasVariant: HyperbolicAtlasVariant = .oneChart
  @State private var renderingMode: RenderingMode = .realtime
  @StateObject private var performanceStats = PerformanceStats()
  private let renderResolution: RenderResolution = .hd720

  var body: some View {
    ZStack {
      MetalView(
        ambientSpace: $ambienSpace,
        traversalMode: $traversalMode,
        sphericalFlatSceneVariant: $sphericalFlatSceneVariant,
        hyperbolicFlatSceneVariant: $hyperbolicFlatSceneVariant,
        hyperbolicAtlasVariant: $hyperbolicAtlasVariant,
        renderingMode: $renderingMode,
        performanceStats: performanceStats,
        renderResolution: renderResolution
      )
      .aspectRatio(renderResolution.aspectRatio, contentMode: .fit)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .ignoresSafeArea()

      if showsPerformanceOverlay {
        PerformanceOverlay(stats: performanceStats)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .padding(12)
      }

      VStack(alignment: .trailing) {
        Group {
          Picker("Traversal", selection: $traversalMode) {
            ForEach(TraversalMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
          }
          Picker("Ambient Space", selection: $ambienSpace) {
            ForEach(AmbientSpace.allCases) { space in Text(space.rawValue).tag(space) }
          }
          if traversalMode == .flat && ambienSpace == .sphere {
            Picker("S³ Scene", selection: $sphericalFlatSceneVariant) {
              ForEach(SphericalFlatSceneVariant.allCases) { variant in
                Text(variant.rawValue).tag(variant)
              }
            }
          }
          if traversalMode == .flat && ambienSpace == .hyperbolic {
            Picker("H³ Scene", selection: $hyperbolicFlatSceneVariant) {
              ForEach(HyperbolicFlatSceneVariant.allCases) { variant in
                Text(variant.rawValue).tag(variant)
              }
            }
          }
          if traversalMode == .atlas && ambienSpace == .hyperbolic {
            Picker("H^3 Atlas", selection: $hyperbolicAtlasVariant) {
              ForEach(HyperbolicAtlasVariant.allCases) { variant in
                Text(variant.rawValue).tag(variant)
              }
            }
          }
        }
        .disabled(renderingMode == .photo)

        Button(
          renderingMode == .photo ? "Stop Photo Mode" : "Start Photo Mode"
        ) {
          renderingMode = renderingMode == .photo ? .realtime : .photo
        }
        .accessibilityIdentifier("photo-mode-toggle")
      }
      .pickerStyle(.menu)
      .fixedSize()
      .padding(12)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
  }
}

private struct PerformanceOverlay: View {
  @ObservedObject var stats: PerformanceStats

  var body: some View {
    let value = stats.snapshot
    Text(
      String(
        format:
          "FPS %5.1f   Frame %6.2f ms   GPU %6.2f ms\n"
          + "Hops/ray %6.3f   Max %2u   Capped %u\n"
          + "Compound/ray %7.4f   Portal tests/ray %6.2f",
        value.framesPerSecond,
        value.frameMilliseconds,
        value.gpuMilliseconds,
        value.portalHopsPerRay,
        value.maximumPortalHops,
        value.hopLimitRays,
        value.compoundHopsPerRay,
        value.portalTestsPerRay
      )
    )
    .font(.system(size: 12, weight: .medium, design: .monospaced))
    .foregroundStyle(.white)
    .padding(8)
    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    .allowsHitTesting(false)
  }
}

#Preview {
  ContentView(showsPerformanceOverlay: .constant(true))
}
