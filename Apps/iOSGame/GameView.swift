// GameView.swift (iOS) — UIKit MTKView + SwiftUI wrapper for the C++ engine.
// Identical engine backend as macOS; only the shell changes.

import SwiftUI
import MetalKit
import UIKit

// MARK: - Metal View (UIView)

final class iOSGameMTKView: MTKView {

    var engineHost: EngineHost?

    override var canBecomeFirstResponder: Bool { true }

    // ─── Touch input
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let pt  = touch.location(in: self)
        let np  = normalise(pt)
        engineHost?.onMouseDown(atX: np.x, y: np.y, button: 0)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let pt = touch.location(in: self)
        let np = normalise(pt)
        engineHost?.onMouseUp(atX: np.x, y: np.y, button: 0)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let pt  = touch.location(in: self)
        let prev = touch.previousLocation(in: self)
        let np   = normalise(pt)
        let dx   = Double(pt.x - prev.x) / Double(bounds.width)
        let dy   = Double(pt.y - prev.y) / Double(bounds.height)
        engineHost?.onMouseMoved(toX: np.x, y: np.y, deltaX: dx, deltaY: dy)
    }

    private func normalise(_ pt: CGPoint) -> (x: Double, y: Double) {
        (x: Double(pt.x / bounds.width), y: Double(pt.y / bounds.height))
    }
}

// MARK: - Coordinator

final class iOSGameCoordinator: NSObject, MTKViewDelegate {
    let host: EngineHost
    var lastTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    init(host: EngineHost) {
        self.host = host
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        host.resize(width: UInt(size.width), height: UInt(size.height))
        let scale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        host.setDisplayScale(Double(scale))
    }

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt  = min(now - lastTime, 0.05)
        lastTime = now
        host.renderFrame(dt)
    }
}

// MARK: - UIViewRepresentable

struct iOSMetalGameView: UIViewRepresentable {
    @ObservedObject var stats: EngineStats

    func makeUIView(context: Context) -> iOSGameMTKView {
        let view = iOSGameMTKView()
        view.colorPixelFormat         = .bgra8Unorm_sRGB
        view.clearColor               = MTLClearColorMake(0.08, 0.09, 0.11, 1)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay    = false
        view.isPaused                 = false

        let host  = EngineHost()
        let layer = view.layer as! CAMetalLayer

        guard host.init(with: layer,
                        width: UInt(view.drawableSize.width),
                        height: UInt(view.drawableSize.height)) else {
            print("[PostFall] EngineHost init failed")
            return view
        }

        view.engineHost = host
        view.delegate   = context.coordinator
        return view
    }

    func updateUIView(_ uiView: iOSGameMTKView, context: Context) {}

    func makeCoordinator() -> iOSGameCoordinator {
        iOSGameCoordinator(host: EngineHost())
    }
}

// MARK: - iOS-specific Stats + Overlay (reuses same EngineStats class)

struct iOSDebugOverlayView: View {
    @ObservedObject var stats: EngineStats

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statRow("FPS",     "\(stats.fps)")
            statRow("GPU ms",  String(format: "%.1f", stats.gpuTimeMs))
            statRow("Draws",   "\(stats.drawCalls)")
            statRow("Ents",    "\(stats.visibleEntities)")
            statRow("Projs",   "\(stats.projectileCount)")
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(5)
        .background(.black.opacity(0.6))
        .foregroundStyle(.green)
        .cornerRadius(4)
        .allowsHitTesting(false)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).frame(width: 55, alignment: .leading).foregroundStyle(.green.opacity(0.7))
            Text(value).frame(width: 50, alignment: .trailing)
        }
    }
}
