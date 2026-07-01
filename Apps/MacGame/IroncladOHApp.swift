// IroncladOHApp.swift — macOS SwiftUI application entry point (Ironclad-OH optimization bench).

import SwiftUI

@main
struct IroncladOHApp: App {
    var body: some Scene {
        WindowGroup("Ironclad-OH") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
