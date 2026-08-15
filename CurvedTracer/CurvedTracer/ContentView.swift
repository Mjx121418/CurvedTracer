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
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world! \(String(geo.geometryCoreName()))")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
