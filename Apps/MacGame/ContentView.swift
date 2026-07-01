// ContentView.swift — Root SwiftUI layout with start menu, workspace list, and scene.

import SwiftUI

struct ContentView: View {
    enum Route {
        case startMenu
        case comparisonWorkspaces
        case grassWorkspace
    }

    @State private var route: Route = .startMenu

    var body: some View {
        switch route {
        case .startMenu:
            StartMenuView(
                onStressTesting: {},
                onComparisonWorkspaces: { route = .comparisonWorkspaces }
            )
        case .comparisonWorkspaces:
            ComparisonWorkspaceListView(
                onGrass: { route = .grassWorkspace }
            )
        case .grassWorkspace:
            WorkspaceSceneView()
        }
    }
}

private struct StartMenuView: View {
    let onStressTesting: () -> Void
    let onComparisonWorkspaces: () -> Void

    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.06)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("Ironclad Optimization Helper")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Version \(versionText)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 34)

                Spacer()

                VStack(spacing: 14) {
                    Button(action: onStressTesting) {
                        Text("stress testing")
                            .frame(width: 260, height: 44)
                    }
                    .buttonStyle(StartMenuButtonStyle())

                    Button(action: onComparisonWorkspaces) {
                        Text("comparison workspaces")
                            .frame(width: 260, height: 44)
                    }
                    .buttonStyle(StartMenuButtonStyle())
                }

                Spacer()
            }
            .foregroundStyle(.white)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

private struct ComparisonWorkspaceListView: View {
    let onGrass: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.06)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Comparison Workspaces")
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.top, 34)

                Spacer()

                Button(action: onGrass) {
                    Text("Grass")
                        .frame(width: 260, height: 44)
                }
                .buttonStyle(StartMenuButtonStyle())

                Spacer()
            }
            .foregroundStyle(.white)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

private struct StartMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed
                          ? Color(red: 0.58, green: 0.13, blue: 0.12)
                          : Color(red: 0.76, green: 0.17, blue: 0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }
}

private struct WorkspaceSceneView: View {

    @StateObject private var stats = EngineStats()

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalGameView(stats: stats)
                .ignoresSafeArea()

            DebugOverlayView(stats: stats)
                .padding(10)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - Debug Overlay

struct DebugOverlayView: View {
    @ObservedObject var stats: EngineStats

    // Terrain presets (index must match the engine's ApplyTerrainPreset order).
    private let presetNames = ["Flat", "Hill", "Bowl", "Ridge", "Dunes", "Procedural"]
    private var proceduralPreset: Int { presetNames.count - 1 }

    private func cyclePreset(_ dir: Int) {
        let n = presetNames.count
        stats.presetIndex = (stats.presetIndex + dir + n) % n
        stats.requestPreset = true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statsPanel
            if stats.dModeActive { dPanel }
            if stats.gModeActive { gPanel }
            if stats.aModeActive { aPanel }
            if stats.tModeActive { tPanel }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    // MARK: Stats panel (always visible, green)

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                statRow("FPS",         "\(stats.fps)")
                statRow("Frame",       String(format: "%.2f ms", stats.frameTimeMs))
                statRow("GPU",         String(format: "%.2f ms", stats.gpuTimeMs))
                statRow("Draw calls",  "\(stats.drawCalls)")
                statRow("Entities",    "\(stats.visibleEntities)")
                statRow("Projectiles", "\(stats.projectileCount)")
            }
            .allowsHitTesting(false)
            Divider().background(.green.opacity(0.4))
            Group {
                statRow("Last click",  stats.lastClickBtn < 0 ? "—"
                                       : stats.lastClickBtn == 0 ? "LEFT" : "RIGHT")
                statRow("Move events", "\(stats.mouseMoveCount)")
                statRow("Cursor",      String(format: "%.3f  %.3f",
                                              stats.cursorNormX, stats.cursorNormY))
                statRow("Floor",       String(format: "%.1f, %.1f",
                                              stats.cursorFloorX, stats.cursorFloorZ))
            }
            .allowsHitTesting(false)
        }
        .padding(6)
        .background(.black.opacity(0.55))
        .foregroundStyle(.green)
        .cornerRadius(5)
    }

    // MARK: D panel (terrain editor, yellow)

    private var dPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Erosion Editor")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.yellow)
                .allowsHitTesting(false)
            dRow("Erosion step",   placeholder: "0",    text: $stats.erosionStep)
            dRow("Erosion height", placeholder: "auto", text: $stats.erosionHeight)
            dRow("Step angle",     placeholder: "90",   text: $stats.erosionAngle)
            toggleRow("Place node",  active: stats.terrainNodePlaceMode,
                      color: .yellow) { stats.terrainNodePlaceMode.toggle() }
            toggleRow("Auto node",   active: stats.autoNode,
                      color: .yellow) { stats.autoNode.toggle() }
            if stats.autoNode {
                dFloatRow("Node density", value: $stats.autoNodeDensity)
            }
            toggleRow("Show plane",  active: stats.constructionPlaneVisible,
                      color: .yellow) { stats.constructionPlaneVisible.toggle() }

            // Preset cycle: ◀ name ▶ — applies on change.
            HStack(spacing: 6) {
                Button(action: { cyclePreset(-1) }) { Text("◀") }.buttonStyle(.plain)
                Text(presetNames[stats.presetIndex])
                    .frame(maxWidth: .infinity)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Button(action: { cyclePreset(1) }) { Text("▶") }.buttonStyle(.plain)
            }
            .foregroundStyle(.yellow)
            if stats.presetIndex == proceduralPreset {
                dFloatRow("Ground scale", value: $stats.groundScale)
                    .onChange(of: stats.groundScale) { stats.requestPreset = true }
            }

            Button(action: { stats.requestGenerate = true }) {
                Text("GENERATE")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.85))
                    .foregroundStyle(.black)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .padding(6)
        .background(.black.opacity(0.55))
        .foregroundStyle(.yellow)
        .cornerRadius(5)
    }

    // MARK: G panel (grass editor, blue)

    private var gPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Grass Editor")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.blue)
                .allowsHitTesting(false)

            Text("TERRACE FACES")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.blue.opacity(0.7))
                .allowsHitTesting(false)
            grassRow("Roughness",   value: $stats.terraceNoiseStrength)
            grassRow("Noise scale", value: $stats.terraceNoiseScale)

            Divider().background(.blue.opacity(0.3))

            Text("SHELL")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.blue.opacity(0.7))
                .allowsHitTesting(false)
            toggleRow("Visible", active: stats.shellGrassVisible, color: .blue) {
                stats.shellGrassVisible.toggle()
            }
            grassRow("Density", value: $stats.shellGrassDensity)
            grassRow("Base R",  value: $stats.shellColorBaseR)
            grassRow("Base G",  value: $stats.shellColorBaseG)
            grassRow("Base B",  value: $stats.shellColorBaseB)
            grassRow("Tip R",   value: $stats.shellColorTipR)
            grassRow("Tip G",   value: $stats.shellColorTipG)
            grassRow("Tip B",   value: $stats.shellColorTipB)

            Divider().background(.blue.opacity(0.3))

            Text("LONG")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.blue.opacity(0.7))
                .allowsHitTesting(false)
            toggleRow("Visible", active: stats.longGrassVisible, color: .blue) {
                stats.longGrassVisible.toggle()
            }
            grassRow("Density",    value: $stats.longGrassDensity)
            grassRow("Step edge",  value: $stats.longStepEdgeDensity)
            grassRow("Base R",  value: $stats.longColorBaseR)
            grassRow("Base G",  value: $stats.longColorBaseG)
            grassRow("Base B",  value: $stats.longColorBaseB)
            grassRow("Tip R",   value: $stats.longColorTipR)
            grassRow("Tip G",   value: $stats.longColorTipG)
            grassRow("Tip B",   value: $stats.longColorTipB)
        }
        .padding(6)
        .background(.black.opacity(0.55))
        .foregroundStyle(.blue)
        .cornerRadius(5)
    }

    // MARK: A panel (animation editor, orange)

    private var aPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Animation Editor")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.orange)
                .allowsHitTesting(false)
            Text("WALK / RUN gait — S saves")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange.opacity(0.7))
                .allowsHitTesting(false)
            toggleRow("Walk in place", active: stats.animPreviewWalk, color: .orange) {
                stats.animPreviewWalk.toggle()
            }
            Button(action: { stats.requestCopyWalkToRun = true }) {
                Text("COPY W → R")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.85))
                    .foregroundStyle(.black)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            HStack(spacing: 6) {
                Text("").frame(width: 96, alignment: .leading)
                Text("value").frame(width: 56, alignment: .leading)
                Text("φ shift°").frame(width: 48, alignment: .leading)
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.orange.opacity(0.6))
            .allowsHitTesting(false)
            Divider().background(.orange.opacity(0.3))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(stats.animParams.indices, id: \.self) { i in
                        if i == 12 { Divider().background(.orange.opacity(0.3)) }
                        animRow(i)
                    }
                }
            }
            .frame(maxHeight: 460)
        }
        .padding(6)
        .background(.black.opacity(0.55))
        .foregroundStyle(.orange)
        .cornerRadius(5)
    }

    private func animRow(_ i: Int) -> some View {
        let label = i < stats.animLabels.count ? stats.animLabels[i] : "\(i)"
        // Edit free-form text; commit to the model only on Enter (onSubmit).
        let valBinding = Binding<String>(
            get: { i < stats.animParamsText.count ? stats.animParamsText[i] : "" },
            set: { if i < stats.animParamsText.count { stats.animParamsText[i] = $0 } }
        )
        let phaseBinding = Binding<String>(
            get: { i < stats.animPhasesText.count ? stats.animPhasesText[i] : "" },
            set: { if i < stats.animPhasesText.count { stats.animPhasesText[i] = $0 } }
        )
        return HStack(spacing: 6) {
            Text(label)
                .frame(width: 96, alignment: .leading)
                .foregroundStyle(.orange.opacity(0.7))
            TextField("", text: valBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .colorScheme(.dark)
                .foregroundStyle(.orange)
                .onSubmit { commitAnimParam(i) }
            TextField("φ°", text: phaseBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .colorScheme(.dark)
                .foregroundStyle(.orange.opacity(0.85))
                .onSubmit { commitAnimPhase(i) }
        }
    }

    // Parse the edited text into the committed value on Enter. Invalid text reverts.
    private func commitAnimParam(_ i: Int) {
        guard i < stats.animParamsText.count, i < stats.animParams.count else { return }
        if let v = Float(stats.animParamsText[i]) {
            stats.animParams[i] = v
        } else {
            stats.animParamsText[i] = String(format: "%g", stats.animParams[i])
        }
    }

    private func commitAnimPhase(_ i: Int) {
        guard i < stats.animPhasesText.count, i < stats.animPhases.count else { return }
        if let v = Float(stats.animPhasesText[i]) {
            stats.animPhases[i] = v
        } else {
            stats.animPhasesText[i] = String(format: "%g", stats.animPhases[i])
        }
    }

    // MARK: Helpers

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.green.opacity(0.7))
            Text(value)
                .frame(width: 60, alignment: .trailing)
        }
    }

    private func dRow(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.yellow.opacity(0.7))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .colorScheme(.dark)
                .foregroundStyle(.yellow)
        }
    }

    private func dFloatRow(_ label: String, value: Binding<Float>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.yellow.opacity(0.7))
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .colorScheme(.dark)
                .foregroundStyle(.yellow)
        }
    }

    // MARK: T panel (tree editor, brown)

    private var tPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tree Editor")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.brown)
                .allowsHitTesting(false)
            toggleRow("Visible", active: stats.treesVisible, color: .brown) {
                stats.treesVisible.toggle()
            }
            grassRow("Density",    value: $stats.treeDensity)
            grassRow("Lean min°",  value: $stats.treeLeanMin)
            grassRow("Lean max°",  value: $stats.treeLeanMax)
            grassRow("Height min", value: $stats.treeHeightMin)
            grassRow("Height max", value: $stats.treeHeightMax)
            grassRow("Thickness",  value: $stats.treeThickness)

            Divider().background(.brown.opacity(0.3))
            Text("DEAD TREES")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.gray)
                .allowsHitTesting(false)
            grassRow("Dead dens.", value: $stats.treeDeadDensity)
            grassRow("Dead lean−", value: $stats.treeDeadLeanMin)
            grassRow("Dead lean+", value: $stats.treeDeadLeanMax)

            Divider().background(.brown.opacity(0.3))
            Text("PULL NODE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.green.opacity(0.8))
                .allowsHitTesting(false)
            toggleRow(stats.treePullActive ? "Place node (set)" : "Place node",
                      active: stats.treePullPlaceMode, color: .green) {
                stats.treePullPlaceMode.toggle()
            }
            grassRow("Pull",  value: $stats.treePull)

            Divider().background(.brown.opacity(0.3))
            Text("WOOD COLOR")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.brown.opacity(0.7))
                .allowsHitTesting(false)
            grassRow("Base R", value: $stats.treeColorR)
            grassRow("Base G", value: $stats.treeColorG)
            grassRow("Base B", value: $stats.treeColorB)
        }
        .padding(6)
        .background(.black.opacity(0.6))
        .foregroundStyle(.brown)
        .cornerRadius(5)
    }

    private func grassRow(_ label: String, value: Binding<Float>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .frame(width: 60, alignment: .leading)
                .foregroundStyle(.blue.opacity(0.7))
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .colorScheme(.dark)
                .foregroundStyle(.blue)
        }
    }

    private func toggleRow(_ label: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(active ? color : color.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(label)
                    .foregroundStyle(active ? color : color.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
