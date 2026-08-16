//
//  ContentView.swift
//  CurvedTracer
//
//

import SwiftUI
import GeometryCore

struct ContentView: View {
    @State private var ambienSpace: AmbientSpace = .sphere
    var body: some View {
        ZStack(alignment: .topTrailing) {
            MetalView(ambientSpace: $ambienSpace)
                .ignoresSafeArea()
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            
            Picker("Ambient Space", selection: $ambienSpace) {
                ForEach(AmbientSpace.allCases) { space in
                    Text(space.rawValue)
                        .tag(space)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .padding(12)
        }
    }
}

#Preview {
    ContentView()
}
