//
//  CurvedTracerApp.swift
//  CurvedTracer
//

import SwiftUI

@main
struct CurvedTracerApp: App {
    @State private var showsPerformanceOverlay = true

    var body: some Scene {
        WindowGroup {
            ContentView(showsPerformanceOverlay: $showsPerformanceOverlay)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Toggle(
                    "Performance Overlay",
                    isOn: $showsPerformanceOverlay)
            }
        }
    }
}
