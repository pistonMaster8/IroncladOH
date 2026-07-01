// GameView.swift — MTKView-backed SwiftUI view that drives the C++ engine.

import SwiftUI
import MetalKit

// MARK: - Metal View (NSView)

final class GameMTKView: MTKView {

    var engineHost: EngineHost?
    private var eventMonitor: Any?

    deinit { removeEventMonitor() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window {
            w.makeFirstResponder(self)
            w.acceptsMouseMovedEvents = true
            installEventMonitor()
        } else {
            removeEventMonitor()
        }
    }

    // NSHostingView intercepts mouse events before they reach embedded NSViews via
    // the standard mouseDown override path. A local monitor fires at the app dispatch
    // level — before SwiftUI's gesture system — and bypasses that interception.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown,
            .leftMouseUp,   .rightMouseUp,
            .mouseMoved,    .leftMouseDragged, .rightMouseDragged,
            .scrollWheel,   .magnify
        ]) { [weak self] event in
            self?.routeMouseEvent(event)
            return event
        }
    }

    private func removeEventMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    private func routeMouseEvent(_ event: NSEvent) {
        guard let engineHost,
              let eventWindow = event.window, eventWindow == window else { return }
        let pt = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pt) else { return }
        let nx = Double(pt.x / bounds.width)
        let ny = Double(1.0 - pt.y / bounds.height)
        switch event.type {
        case .leftMouseDown:
            engineHost.mouseDown(x: nx, y: ny, button: 0)
        case .rightMouseDown:
            engineHost.mouseDown(x: nx, y: ny, button: 1)
        case .leftMouseUp:
            engineHost.mouseUp(x: nx, y: ny, button: 0)
        case .rightMouseUp:
            engineHost.mouseUp(x: nx, y: ny, button: 1)
        case .mouseMoved, .leftMouseDragged:
            engineHost.mouseMoved(x: nx, y: ny, deltaX: event.deltaX, deltaY: event.deltaY)
        case .rightMouseDragged:
            // Update cursor position for debug overlay, then pan the camera.
            engineHost.mouseMoved(x: nx, y: ny, deltaX: 0, deltaY: 0)
            engineHost.panDelta(deltaX: event.deltaX, deltaY: event.deltaY)
        case .scrollWheel:
            engineHost.orbitDelta(deltaX: event.deltaX, deltaY: event.deltaY)
        case .magnify:
            engineHost.magnifyDelta(event.magnification)
        default: break
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { engineHost?.keyDown(Int32(event.keyCode)) }
    override func keyUp(with event: NSEvent)   { engineHost?.keyUp(Int32(event.keyCode)) }
}

// MARK: - Coordinator (MTKViewDelegate)

final class GameCoordinator: NSObject, MTKViewDelegate {

    // Optional so SwiftUI can create it before the host exists.
    // Set in makeNSView via context.coordinator — this instance is
    // the one SwiftUI retains for the view's lifetime.
    var host: EngineHost?
    var stats: EngineStats?
    var lastTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    override init() { super.init() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard let host else { return }
        let scale = view.window?.backingScaleFactor ?? 1.0
        host.setDisplayScale(scale)
        host.resize(width: UInt(size.width), height: UInt(size.height))
    }

    func draw(in view: MTKView) {
        guard let host else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = min(now - lastTime, 0.05)
        lastTime = now
        host.renderFrame(dt)
        stats?.fps             = Int(host.fps)
        stats?.frameTimeMs     = host.frameTimeMs
        stats?.drawCalls       = Int(host.drawCalls)
        stats?.visibleEntities = Int(host.visibleEntities)
        stats?.projectileCount = Int(host.projectileCount)
        stats?.gpuTimeMs       = host.gpuTimeMs
        stats?.lastClickBtn    = Int(host.lastClickBtn)
        stats?.mouseMoveCount  = Int(host.mouseMoveCount)
        stats?.cursorNormX     = host.cursorNormX
        stats?.cursorNormY     = host.cursorNormY
        stats?.cursorFloorX    = host.cursorFloorX
        stats?.cursorFloorZ    = host.cursorFloorZ
        stats?.dModeActive     = host.dModeActive
        stats?.gModeActive     = host.gModeActive
        stats?.tModeActive     = host.tModeActive
        stats?.treePullActive  = host.treePullActive
        stats?.aModeActive     = host.aModeActive

        // Animation params: populate labels + values from the host once.
        if let s = stats, s.animLabels.isEmpty {
            let n = Int(host.animParamCount)
            s.animLabels = (0..<n).map { host.animParamLabel($0) }
            s.animParams = (0..<n).map { host.animParamValue($0) }
            s.animParamsText = s.animParams.map { String(format: "%g", $0) }
            s.animPhases = (0..<n).map { host.animPhaseValue($0) }
            s.animPhasesText = s.animPhases.map { String(format: "%g", $0) }
        }

        // On first frame after load: pull saved values from host into stats before
        // the push below overwrites them.
        if host.stateJustLoaded, let s = stats {
            s.terraceNoiseStrength  = host.terraceNoiseStrength
            s.terraceNoiseScale     = host.terraceNoiseScale
            s.shellGrassVisible     = host.shellGrassVisible
            s.shellGrassDensity     = host.shellGrassDensity
            s.shellColorBaseR       = host.shellColorBaseR
            s.shellColorBaseG       = host.shellColorBaseG
            s.shellColorBaseB       = host.shellColorBaseB
            s.shellColorTipR        = host.shellColorTipR
            s.shellColorTipG        = host.shellColorTipG
            s.shellColorTipB        = host.shellColorTipB
            s.longGrassVisible      = host.longGrassVisible
            s.longGrassDensity      = host.longGrassDensity
            s.longStepEdgeDensity   = host.longStepEdgeDensity
            s.longColorBaseR        = host.longColorBaseR
            s.longColorBaseG        = host.longColorBaseG
            s.longColorBaseB        = host.longColorBaseB
            s.longColorTipR         = host.longColorTipR
            s.longColorTipG         = host.longColorTipG
            s.longColorTipB         = host.longColorTipB
            s.treesVisible  = host.treesVisible
            s.treeDensity   = host.treeDensity
            s.treeColorR    = host.treeColorR
            s.treeColorG    = host.treeColorG
            s.treeColorB    = host.treeColorB
            s.treeLeanMin   = host.treeLeanMin
            s.treeLeanMax   = host.treeLeanMax
            s.treeDeadDensity = host.treeDeadDensity
            s.treeDeadLeanMin = host.treeDeadLeanMin
            s.treeDeadLeanMax = host.treeDeadLeanMax
            s.treeHeightMin = host.treeHeightMin
            s.treeHeightMax = host.treeHeightMax
            s.treeThickness = host.treeThickness
            s.treePull      = host.treePull
            s.treeDeadPull  = host.treeDeadPull
            let step   = host.savedErosionStep
            let height = host.savedErosionHeight
            let angle  = host.savedErosionAngle
            s.erosionStep   = step   == 0 ? "" : String(format: "%g", step)
            s.erosionHeight = height == 0 ? "" : String(format: "%g", height)
            s.erosionAngle  = angle  == 90 ? "" : String(format: "%g", angle)
            // Pull loaded animation params back into the panel.
            let n = Int(host.animParamCount)
            s.animParams = (0..<n).map { host.animParamValue($0) }
            s.animParamsText = s.animParams.map { String(format: "%g", $0) }
            s.animPhases = (0..<n).map { host.animPhaseValue($0) }
            s.animPhasesText = s.animPhases.map { String(format: "%g", $0) }
            host.stateJustLoaded = false
        }

        // Push G panel values to host
        if let s = stats {
            host.terraceNoiseStrength = s.terraceNoiseStrength
            host.terraceNoiseScale    = s.terraceNoiseScale
            host.shellGrassVisible  = s.shellGrassVisible
            host.shellGrassDensity  = s.shellGrassDensity
            host.shellColorBaseR    = s.shellColorBaseR
            host.shellColorBaseG    = s.shellColorBaseG
            host.shellColorBaseB    = s.shellColorBaseB
            host.shellColorTipR     = s.shellColorTipR
            host.shellColorTipG     = s.shellColorTipG
            host.shellColorTipB     = s.shellColorTipB
            host.longGrassVisible       = s.longGrassVisible
            host.longGrassDensity       = s.longGrassDensity
            host.longStepEdgeDensity    = s.longStepEdgeDensity
            host.longColorBaseR     = s.longColorBaseR
            host.longColorBaseG     = s.longColorBaseG
            host.longColorBaseB     = s.longColorBaseB
            host.longColorTipR      = s.longColorTipR
            host.longColorTipG      = s.longColorTipG
            host.longColorTipB      = s.longColorTipB
            host.grassGenerationMode = Int32(s.grassGenerationMode)
            host.grassOptimizationMode = Int32(s.grassOptimizationMode)
            host.grassOptStartDistance = s.grassOptStartDistance
            host.grassOptEndDistance = s.grassOptEndDistance
            host.grassOptDensityScale = s.grassOptDensityScale
            host.grassOptStrength = s.grassOptStrength
            host.grassOptCurve = Int32(s.grassOptCurve)
            host.treesVisible  = s.treesVisible
            host.treeDensity   = s.treeDensity
            host.treeColorR    = s.treeColorR
            host.treeColorG    = s.treeColorG
            host.treeColorB    = s.treeColorB
            host.treeLeanMin   = s.treeLeanMin
            host.treeLeanMax   = s.treeLeanMax
            host.treeDeadDensity = s.treeDeadDensity
            host.treeDeadLeanMin = s.treeDeadLeanMin
            host.treeDeadLeanMax = s.treeDeadLeanMax
            host.treeHeightMin = s.treeHeightMin
            host.treeHeightMax = s.treeHeightMax
            host.treeThickness = s.treeThickness
            host.treePull         = s.treePull
            host.treeDeadPull     = s.treeDeadPull
            host.treePullPlaceMode = s.treePullPlaceMode
            // Push animation params + phases (host ignores unchanged values).
            for i in 0..<s.animParams.count {
                host.setAnimParam(i, value: s.animParams[i])
            }
            for i in 0..<s.animPhases.count {
                host.setAnimPhase(i, value: s.animPhases[i])
            }
            host.animPreviewWalk = s.animPreviewWalk
        }
        host.terrainNodePlaceMode = stats?.terrainNodePlaceMode ?? false
        host.constructionPlaneVisible = stats?.constructionPlaneVisible ?? true
        host.autoNode = stats?.autoNode ?? false
        host.autoNodeDensity = stats?.autoNodeDensity ?? 6.0
        if stats?.requestGenerate == true {
            let step   = Float(stats?.erosionStep ?? "") ?? 1.0
            let height = Float(stats?.erosionHeight ?? "") ?? 0.0
            let angle  = Float(stats?.erosionAngle ?? "") ?? 90.0
            host.generateTerrain(step: step, height: height, angle: angle)
            stats?.requestGenerate = false
        }
        if stats?.requestPreset == true, let s = stats {
            let step   = Float(s.erosionStep)  ?? 1.0
            let height = Float(s.erosionHeight) ?? 0.0
            let angle  = Float(s.erosionAngle)  ?? 90.0
            host.applyTerrainPreset(s.presetIndex, step: step, height: height,
                                    angle: angle, groundScale: s.groundScale)
            s.requestPreset = false
        }
        if stats?.requestCopyWalkToRun == true, let s = stats {
            host.copyAnimWalkToRun()
            // Pull the now-updated run values back into the panel.
            let n = Int(host.animParamCount)
            s.animParams = (0..<n).map { host.animParamValue($0) }
            s.animParamsText = s.animParams.map { String(format: "%g", $0) }
            s.animPhases = (0..<n).map { host.animPhaseValue($0) }
            s.animPhasesText = s.animPhases.map { String(format: "%g", $0) }
            s.requestCopyWalkToRun = false
        }
    }
}

// MARK: - NSViewRepresentable wrapper

struct MetalGameView: NSViewRepresentable {
    @ObservedObject var stats: EngineStats

    func makeCoordinator() -> GameCoordinator {
        GameCoordinator()
    }

    func makeNSView(context: Context) -> GameMTKView {
        let view = GameMTKView()
        view.colorPixelFormat         = .bgra8Unorm
        view.depthStencilPixelFormat  = .depth32Float
        view.clearColor               = MTLClearColorMake(0.08, 0.09, 0.11, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay    = false
        view.isPaused                 = false

        let host  = EngineHost()
        let layer = view.layer as! CAMetalLayer

        let w = max(UInt(view.drawableSize.width),  1)
        let h = max(UInt(view.drawableSize.height), 1)

        guard host.setup(layer: layer, width: w, height: h) else {
            print("[PostFall] EngineHost setup failed")
            return view
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        host.setDisplayScale(scale)

        // Wire the real host into the coordinator SwiftUI already retains.
        // Never create a second coordinator — MTKView.delegate is weak and
        // a locally-created coordinator would be deallocated immediately.
        context.coordinator.host  = host
        context.coordinator.stats = stats
        view.engineHost           = host
        view.delegate             = context.coordinator

        return view
    }

    func updateNSView(_ nsView: GameMTKView, context: Context) {}
}

// MARK: - Stats observable (drives debug overlay)

final class EngineStats: ObservableObject {
    @Published var fps: Int = 0
    @Published var frameTimeMs: Double = 0
    @Published var drawCalls: Int = 0
    @Published var visibleEntities: Int = 0
    @Published var projectileCount: Int = 0
    @Published var gpuTimeMs: Double = 0
    // Input debug
    @Published var lastClickBtn: Int = -1
    @Published var mouseMoveCount: Int = 0
    @Published var cursorNormX: Double = 0
    @Published var cursorNormY: Double = 0
    @Published var cursorFloorX: Double = 0
    @Published var cursorFloorZ: Double = 0
    // Terrain editor
    @Published var dModeActive: Bool = false
    @Published var terrainNodePlaceMode: Bool = false
    @Published var erosionStep: String = ""
    @Published var erosionHeight: String = ""
    @Published var erosionAngle: String = ""
    @Published var requestGenerate: Bool = false
    @Published var constructionPlaneVisible: Bool = true
    @Published var autoNode: Bool = false
    @Published var autoNodeDensity: Float = 6.0
    // Terrain presets (cycled in the D panel)
    @Published var presetIndex: Int = 0
    @Published var requestPreset: Bool = false
    @Published var groundScale: Float = 1.0
    // Animation editor (A panel)
    @Published var aModeActive: Bool = false
    @Published var animParams: [Float] = []      // committed values, pushed to host
    @Published var animParamsText: [String] = [] // editable text, committed on Enter
    @Published var animPhases: [Float] = []       // committed phase offsets (deg)
    @Published var animPhasesText: [String] = []  // editable phase text
    @Published var animLabels: [String] = []
    @Published var animPreviewWalk: Bool = false
    @Published var requestCopyWalkToRun: Bool = false
    // Tree editor (T panel)
    @Published var tModeActive: Bool = false
    @Published var treesVisible: Bool = true
    @Published var treeDensity: Float = 0.55
    @Published var treeColorR: Float = 0.26
    @Published var treeColorG: Float = 0.17
    @Published var treeColorB: Float = 0.10
    @Published var treeLeanMin: Float = 0.0
    @Published var treeLeanMax: Float = 6.0
    @Published var treeDeadDensity: Float = 0.0
    @Published var treeDeadLeanMin: Float = 0.0
    @Published var treeDeadLeanMax: Float = 6.0
    @Published var treeHeightMin: Float = 9.0
    @Published var treeHeightMax: Float = 17.0
    @Published var treeThickness: Float = 1.0
    @Published var treePullPlaceMode: Bool = false
    @Published var treePullActive: Bool = false
    @Published var treePull: Float = 0.0
    @Published var treeDeadPull: Float = 0.0
    // Grass editor (G panel)
    @Published var gModeActive: Bool = false
    @Published var shellGrassVisible: Bool = true
    @Published var shellGrassDensity: Float = 1.0
    @Published var shellColorBaseR: Float = 0.002
    @Published var shellColorBaseG: Float = 0.008
    @Published var shellColorBaseB: Float = 0.001
    @Published var shellColorTipR:  Float = 0.020
    @Published var shellColorTipG:  Float = 0.063
    @Published var shellColorTipB:  Float = 0.007
    @Published var terraceNoiseStrength: Float = 0.0
    @Published var terraceNoiseScale:    Float = 1.0
    @Published var longGrassVisible: Bool = true
    @Published var longGrassDensity: Float = 1.0
    @Published var longStepEdgeDensity: Float = 1.0
    @Published var longColorBaseR: Float = 0.055
    @Published var longColorBaseG: Float = 0.075
    @Published var longColorBaseB: Float = 0.022
    @Published var longColorTipR:  Float = 0.200
    @Published var longColorTipG:  Float = 0.260
    @Published var longColorTipB:  Float = 0.070
    @Published var grassGenerationMode: Int = 0
    @Published var grassOptimizationMode: Int = 0
    @Published var grassOptStartDistance: Float = 46.0
    @Published var grassOptEndDistance: Float = 58.0
    @Published var grassOptDensityScale: Float = 0.0
    @Published var grassOptStrength: Float = 2.0
    @Published var grassOptCurve: Int = 0
}
