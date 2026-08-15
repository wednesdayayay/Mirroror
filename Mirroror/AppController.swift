import SwiftUI
import MetalKit
import Combine
import AppKit
import UniformTypeIdentifiers


// MARK: - App State Controller
// Deliberately minimal: only rarely-changing UI state is @Published here
// (source selection + file name). ALL synth parameters live in ParamStore.
// Never add continuous slider values back onto this object.
//
// M4.1 adds `frameCapture`, which is a plain `let` — NOT @Published. Its own
// RecorderState is the observable object the Recording section watches, so
// capture status updates invalidate that one section and nothing else.
final class AppController: ObservableObject {
    @Published var sourceType: VideoSourceType = .procedural {
        didSet { sourceManager.switchSource(to: sourceType) }
    }
    @Published var activeVideoName: String = ""

    let store = ParamStore()
    let renderer: LiquidRenderer
    let frameCapture: FrameCapture
    private let sourceManager: VideoSourceManager

    // M27 Part 2: the MIDI engine. Built after renderer and frameCapture
    // exist, since it holds references to both (Reset LFO Phase and Capture
    // Frame are transport events it can trigger directly, per D8) alongside
    // the store every other mapped parameter goes through. Plain `let`, same
    // shape as frameCapture above — ControlSurface is ObservableObject only
    // so the mapping window can @ObservedObject it, not because anything on
    // it is @Published; every view that reads it does so by explicit poll
    // or generation bump, never by relying on Combine to fire. Owning it
    // here rather than inside MappingWindow itself means the MIDI engine is
    // live and receiving from launch, whether or not the window has ever
    // been opened — mappings work from cold start, the window is only for
    // editing them.
    let controlSurface: ControlSurface

    // M21: the camera diagnostic surface. Plain `let`, same shape as
    // frameCapture above and RecorderProgress/RecorderState in framecapture.swift
    // — CameraStatus publishes for itself, so AppController never needs to be
    // @Published for this. SourceSection reads it only to hand it to
    // CameraStatusLine, a leaf view containing no controls; SourceSection's
    // own body never observes it directly.
    var cameraStatus: CameraStatus { sourceManager.cameraStatus }

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac device.")
        }
        self.sourceManager = VideoSourceManager(device: device)
        self.frameCapture = FrameCapture(device: device)
        self.renderer = LiquidRenderer(
            device: device,
            sourceManager: sourceManager,
            store: store,
            frameCapture: frameCapture
        )
        self.controlSurface = ControlSurface(store: store, renderer: renderer, frameCapture: frameCapture)
    }

    // MARK: - M13: Reset All
    // Two published flags, both event-shaped and both changing only on an
    // explicit user action — never per frame, never on a slider drag. Adding
    // these does NOT reintroduce the observation-path regression: nothing
    // continuous touches them.
    //
    // `showResetConfirmation` is raised by the sidebar button AND the app menu
    // item, so both routes land in the same confirmation dialog rather than
    // one of them resetting silently.
    //
    // `controlGeneration` is the rebuild token — renamed from
    // `resetGeneration` in M27 Part 2 (Q7), since Reset All is no longer its
    // only caller. ParamSlider/ParamToggle/ParamPicker each read the store
    // exactly once, in onAppear behind a `loaded` flag — that one-shot read
    // is precisely what keeps drags off the SwiftUI observation path, and it
    // means resetting OR a MIDI/OSC move alone would leave a control
    // displaying its old number while the renderer used the new value.
    // ContentView hangs `.id(controller.controlGeneration)` on the sidebar
    // column, so bumping this rebuilds those rows once, onAppear runs again,
    // and every control re-reads the store. One rebuild per press; zero
    // per-frame cost; the render path is untouched (the renderer keeps
    // pulling its own snapshot exactly as before).
    //
    // Side effects of the rebuild, both acceptable and arguably correct on a
    // full reset or a manual refresh: collapsed/expanded section state
    // returns to default, and the sidebar scrolls back to the top.
    @Published var showResetConfirmation = false
    @Published private(set) var controlGeneration = 0

    /// Restores every synth parameter to its default and forces the control
    /// surface to re-read the store. Deliberately scoped to ParamStore only:
    /// it does NOT touch the renderer's phase accumulators (M9's Reset LFO
    /// Phase owns that, and conflating the two makes both less predictable),
    /// and it does NOT touch FrameCapture — a reset that silently ended an
    /// in-progress recording would be a genuinely bad surprise mid-take.
    func performResetAll() {
        // M28: flush any in-flight MIDI glide FIRST. Without this, a glide
        // already mid-arrival at the moment of the reset would keep writing
        // toward its old target on subsequent frames and visibly drag a
        // just-restored default off of itself.
        renderer.midiGlide.flush()
        store.resetToDefaults()
        controlGeneration += 1
    }

    /// M27 Part 2 (Q7/D2): a non-destructive rebuild for exactly the case D2
    /// names — after MIDI or OSC has moved a parameter, the sidebar's
    /// row-local @State is stale until that section is collapsed/expanded
    /// or this is pressed. Does not touch ParamStore at all, unlike
    /// performResetAll above; it only forces every control to re-read
    /// values that are already correct in the store.
    func refreshControls() {
        controlGeneration += 1
    }

    func importVideo() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        if openPanel.runModal() == .OK, let url = openPanel.url {
            activeVideoName = url.lastPathComponent
            sourceManager.loadVideoFile(url: url)
            sourceType = .videoFile
        }
    }

    // MARK: - M18: Output Resolution window matching
    //
    // Reshapes the app's window so the Metal viewport lands on the SAME
    // aspect ratio as a fixed Output Resolution preset — the confirmed
    // preference that letterboxing should be the FALLBACK case (a freehand
    // drag, or an aspect the screen genuinely can't fit) rather than the
    // normal one. Fires ONCE, in response to the Output Resolution picker's
    // own action — never on a window resize, never per frame, never for
    // Native/Native÷2 (their aspect already IS the window's, by definition,
    // so LiquidRenderer.fixedResolutionSize(forMode:) returns nil for them
    // and this is a no-op).
    //
    // Same shape as importVideo above: a one-shot AppKit action triggered by
    // an explicit user gesture, not touching ParamStore, not touching the
    // render path, not something updateNSView or the renderer ever calls.
    //
    // Reads the SAME table LiquidRenderer's targetRenderSize does
    // (fixedResolutionSize), so the window's target aspect and the
    // renderer's actual render size can never drift apart — one table, two
    // readers.
    func matchWindowAspect(toResolutionMode mode: Int) {
        guard let (renderWidth, renderHeight) = LiquidRenderer.fixedResolutionSize(forMode: mode) else {
            return // Native / Native ÷2 — nothing to match
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
        guard let screen = window.screen ?? NSScreen.main else { return }

        // Mirrors ContentView's own layout constants — the sidebar's fixed
        // width, the 1pt divider, and the MetalView/window minimums. If that
        // layout ever changes, these should move with it.
        let sidebarChrome: CGFloat = 331       // 330pt sidebar + 1pt divider
        let minViewport: CGFloat = 500         // MetalView's own minWidth/minHeight
        let minContentWidth: CGFloat = 830     // ContentView's window minWidth
        let minContentHeight: CGFloat = 550    // ContentView's window minHeight
        // Rough titlebar allowance so the reshaped window's FRAME (not just
        // its content) still fits on screen — a plain WindowGroup titlebar is
        // roughly 28pt; this leaves a small margin rather than chasing the
        // exact value.
        let titleBarAllowance: CGFloat = 40

        let aspect = CGFloat(renderWidth) / CGFloat(renderHeight)
        let visible = screen.visibleFrame

        let maxViewportWidth = max(minViewport, visible.width - sidebarChrome)
        let maxViewportHeight = max(minViewport, visible.height - titleBarAllowance)

        // Largest viewport of the target aspect that fits inside the
        // available box — NOT pixel-exact to the render size (a pixel-exact
        // 640×480 preview on a Retina display would be a 320×240pt viewport,
        // under MetalView's own 500pt minimum). Matching the SHAPE and
        // filling the available space is what makes the preview useful; the
        // present pass's own linear-filtered scale is what makes the file
        // exact regardless. Classic fit-inside-a-box: try width-limited, then
        // height-limited, keep whichever is smaller.
        var viewportWidth = maxViewportWidth
        var viewportHeight = viewportWidth / aspect
        if viewportHeight > maxViewportHeight {
            viewportHeight = maxViewportHeight
            viewportWidth = viewportHeight * aspect
        }
        viewportWidth = max(viewportWidth, minViewport)
        viewportHeight = max(viewportHeight, minViewport)

        let contentWidth = max(minContentWidth, viewportWidth + sidebarChrome)
        let contentHeight = max(minContentHeight, viewportHeight)

        window.setContentSize(NSSize(width: contentWidth, height: contentHeight))

        // Recenter on the same screen so a big reshape (e.g. into the
        // Vertical preset) doesn't leave the window straddling an edge.
        let newOrigin = NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.midY - window.frame.height / 2
        )
        window.setFrameOrigin(newOrigin)
    }
}

// MARK: - SwiftUI Metal Representable
// updateNSView is intentionally EMPTY. The renderer pulls state itself; if
// this ever pushes params again, the UI-thread bottleneck comes back.
struct MetalView: NSViewRepresentable {
    let renderer: LiquidRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer.device
        view.delegate = renderer
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // M23: was never set, which measurement showed was NOT the same as
        // sitting at the documented default of 60 on this hardware — Release
        // fps read 64-66. Caps how often draw() itself gets CALLED; paired
        // with afterMinimumDuration in LiquidRenderer's present pass, which
        // caps how often a drawable gets PRESENTED. Same constant, both
        // readers — see LiquidRenderer.cadenceTargetFPS.
        view.preferredFramesPerSecond = LiquidRenderer.cadenceTargetFPS
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}






