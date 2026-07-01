// PostFalliOSApp.swift — iOS SwiftUI application entry point.

import SwiftUI

@main
struct PostFalliOSApp: App {
    var body: some Scene {
        WindowGroup {
            iOSContentView()
        }
    }
}

struct iOSContentView: View {
    @StateObject private var stats = EngineStats()

    var body: some View {
        ZStack(alignment: .topLeading) {
            iOSMetalGameView(stats: stats)
                .ignoresSafeArea()
            iOSDebugOverlayView(stats: stats)
                .padding(.top, 50)
                .padding(.leading, 8)
        }
    }
}
