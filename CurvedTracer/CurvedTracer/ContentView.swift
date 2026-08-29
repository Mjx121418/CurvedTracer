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
  @State private var euclideanFlatSceneVariant: EuclideanFlatSceneVariant = .objectDemo
  @State private var sphericalFlatSceneVariant: SphericalFlatSceneVariant = .cell600
  @State private var hyperbolicFlatSceneVariant: HyperbolicFlatSceneVariant = .honeycombCell
  @State private var sphericalAtlasVariant: SphericalAtlasVariant = .lensSpace
  @State private var euclideanAtlasVariant: EuclideanAtlasVariant = .torus
  @State private var hyperbolicAtlasVariant: HyperbolicAtlasVariant = .oneChart
  @State private var renderingMode: RenderingMode = .realtime
  @State private var exposure = 2.0
  @State private var photoMaximumBounces = Int(
    PhotoConvergenceSettings.default.maximumBounces)
  @State private var photoGuaranteedBounces = Int(
    PhotoConvergenceSettings.default.guaranteedBounces)
  @StateObject private var performanceStats = PerformanceStats()
  private let renderResolution: RenderResolution = .qhd540

  var body: some View {
    ZStack {
      MetalView(
        ambientSpace: $ambienSpace,
        traversalMode: $traversalMode,
        euclideanFlatSceneVariant: $euclideanFlatSceneVariant,
        sphericalFlatSceneVariant: $sphericalFlatSceneVariant,
        hyperbolicFlatSceneVariant: $hyperbolicFlatSceneVariant,
        sphericalAtlasVariant: $sphericalAtlasVariant,
        euclideanAtlasVariant: $euclideanAtlasVariant,
        hyperbolicAtlasVariant: $hyperbolicAtlasVariant,
        renderingMode: $renderingMode,
        exposure: $exposure,
        photoMaximumBounces: $photoMaximumBounces,
        photoGuaranteedBounces: $photoGuaranteedBounces,
        performanceStats: performanceStats,
        renderResolution: renderResolution
      )
      .aspectRatio(renderResolution.aspectRatio, contentMode: .fit)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .ignoresSafeArea()

      if showsPerformanceOverlay {
        PerformanceOverlay(
          stats: performanceStats,
          showsPhotoConvergence: renderingMode == .photo)
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
          if traversalMode == .flat && ambienSpace == .euclidean {
            Picker("R³ Scene", selection: $euclideanFlatSceneVariant) {
              ForEach(EuclideanFlatSceneVariant.allCases) { variant in
                Text(variant.rawValue).tag(variant)
              }
            }
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
          if traversalMode == .atlas && ambienSpace == .sphere {
            Picker("S³ Atlas", selection: $sphericalAtlasVariant) {
              ForEach(SphericalAtlasVariant.allCases) { variant in
                Text(variant.rawValue).tag(variant)
              }
            }
          }
          if traversalMode == .atlas && ambienSpace == .euclidean {
            Picker("R³ Atlas", selection: $euclideanAtlasVariant) {
              ForEach(EuclideanAtlasVariant.allCases) { variant in
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

        VStack(alignment: .trailing, spacing: 4) {
          Stepper(
            "Photo max bounces: \(photoMaximumBounces)",
            value: Binding(
              get: { photoMaximumBounces },
              set: { value in
                photoMaximumBounces = min(
                  max(value, 1),
                  Int(PhotoConvergenceSettings.maximumSupportedBounces))
                photoGuaranteedBounces = min(
                  photoGuaranteedBounces,
                  photoMaximumBounces)
              }),
            in: 1...Int(PhotoConvergenceSettings.maximumSupportedBounces))
          .accessibilityIdentifier("photo-max-bounces-control")
          .help(
            "Maximum rays continued after surface scattering in Photo Mode")

          Stepper(
            "Guaranteed bounces: \(photoGuaranteedBounces)",
            value: Binding(
              get: { photoGuaranteedBounces },
              set: { value in
                photoGuaranteedBounces = min(
                  max(value, 0),
                  min(
                    photoMaximumBounces,
                    Int(PhotoConvergenceSettings.maximumGuaranteedBounces)))
              }),
            in: 0...min(
              photoMaximumBounces,
              Int(PhotoConvergenceSettings.maximumGuaranteedBounces)))
          .accessibilityIdentifier("photo-guaranteed-bounces-control")
          .help(
            "Number of continuations completed before Russian roulette begins")
        }
        .disabled(renderingMode == .photo)

        HStack {
          Text("Exposure")
          Slider(value: $exposure, in: 0.0...8.0, step: 0.1)
            .frame(width: 120)
          Text(exposure, format: .number.precision(.fractionLength(1)))
            .monospacedDigit()
            .frame(width: 28, alignment: .trailing)
        }
        .accessibilityIdentifier("exposure-control")
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
  let showsPhotoConvergence: Bool

  var body: some View {
    let value = stats.snapshot
    let tracingText = String(
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
    let convergenceText = showsPhotoConvergence
    ? String(
        format:
          "\nDepth avg %5.2f   max %2u   RR %5.1f%%   Bound %5.2f%%",
        value.averageScatteringDepth,
        value.maximumScatteringDepth,
        100 * value.rouletteTerminationFraction,
        100 * value.depthBoundTerminationFraction)
    : ""
    Text(tracingText + convergenceText)
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
