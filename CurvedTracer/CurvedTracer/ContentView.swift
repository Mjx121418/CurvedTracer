//
//  ContentView.swift
//  CurvedTracer
//

import SwiftUI
import GeometryCore

struct ContentView: View {
    @State private var ambienSpace: AmbientSpace = .sphere
    @State private var traversalMode: TraversalMode = .flat
    private let renderResolution: RenderResolution = .hd720

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MetalView(ambientSpace: $ambienSpace,
                      traversalMode: $traversalMode,
                      renderResolution: renderResolution)
                .ignoresSafeArea()
                .aspectRatio(renderResolution.aspectRatio, contentMode: .fit)
            
            VStack(alignment: .trailing) {
                Picker("Traversal", selection: $traversalMode) {
                    ForEach(TraversalMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                Picker("Ambient Space", selection: $ambienSpace) {
                    ForEach(AmbientSpace.allCases) { space in Text(space.rawValue).tag(space) }
                }
                .disabled(traversalMode == .atlas)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .padding(12)
        }
        .onChange(of: traversalMode) { _, mode in
            if mode == .atlas {
                ambienSpace = .hyperbolic
            }
        }
    }
}

#Preview {
    ContentView()
}
