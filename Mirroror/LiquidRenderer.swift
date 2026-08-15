import Foundation
import MetalKit
// M20 Part 3 Step 0: CACurrentMediaTime() lives in QuartzCore and NSScreen in
// AppKit. MetalKit almost certainly pulls both in transitively on macOS, but
// the dependency is stated rather than relied on.
import QuartzCore
import AppKit

// MARK: - Live Metal Renderer (Pull Model — two-pass since M3)
// The renderer PULLS a snapshot from ParamStore once per frame. Nothing in the
// UI layer pushes to it, and no SwiftUI update ever touches the render path.
// All time-based values use phase ACCUMULATORS: changing a rate slider changes
// the delta per frame, never the accumulated phase.
//
// M9 (complex LFO) adds a SECOND LFO oscillator, combined with the first into
// the one modulation bus every destination already reads. It is entirely
// CPU-side and touches no pass, no shader, and no ShaderParams field — the
// Global LFO has always been resolved here before the struct reaches the GPU,
// so a second oscillator costs nothing on the render side. See the LFO block
// in draw().
//
// M16 (modulation consolidation) reshapes that bus. Eleven flat
// per-destination LFO amounts collapse into FAMILIES — Rotation amplitude,
// Mirror amplitude, Mirror Center, Displacement amplitude, Keying — plus two
// standalone destinations (Radial Push, Luma Staging) and one global
// busSpread, the PHASE ANGLE between successive family members. busAt()
// below is the one rule this reduces to: the whole LFO chain re-evaluated at
// an arbitrary phase offset, which is a true phase shift for every waveform
// rather than a crossfade that only suits Sine.
//
// Two kinds of family. AMPLITUDE families (two scalars that belong together)
// read phase-shifted copies of one signal. CENTER families drive a genuine
// XY VECTOR and trace a path, with the second member taking the axes SWAPPED
// so the two move oppositely. Mirror Center is the first of those and cost
// zero pads — M14 Part 1 had already built its uniforms.
//
// All of it CPU-side, on uniforms; zero ShaderParams pads consumed. See the
// LFO block in draw().
//
// M3 (render-to-texture) split the frame into TWO passes inside ONE command
// buffer:
//   Pass 1 (synth)   — the full pipeline renders into `offscreenTexture`.
//   Pass 2 (present) — a trivial fullscreen blit copies that texture to the
//                      drawable.
// Nothing visible changed: same shader, same params, same pixel format, and the
// offscreen target is sized 1:1 with the drawable and sampled with nearest
// filtering, so pass 2 is an exact copy.
//
// M4.1 (screenshot) adds an OPTIONAL third encoder between the two passes: a
// blit copy of the offscreen texture into FrameCapture's staging surface. It is
// encoded ONLY on frames where a capture was actually requested. On every other
// frame the cost is a lock plus a Bool test inside acquireStagingTexture().
//
// M4.2 (long-form/cassette recording) generalizes that hook: the same blit now
// fires when EITHER a screenshot is pending OR a recording frame is due. "Due"
// is decided by a pacing ACCUMULATOR — `captureAccumulator` — living right next
// to the existing phase accumulators below, driven by the same `deltaTime`
// (never wall-clock, per house rule). FrameCapture.activeFrameInterval is 0
// whenever not actively recording, so the accumulator resets and the idle cost
// stays a lock + Bool test, same as 4.1. `notePotentialSize` is also called
// every frame (cheap — a lock plus two int comparisons) so FrameCapture knows
// the drawable's dimensions before the FIRST capture ever happens, which is
// what lets Record work correctly the very first time it's pressed.
//
// Why bother with the offscreen texture at all: `offscreenTexture` is the
// frame tap M4's recorder reads. We read OUR OWN texture, never the
// drawable, so the view stays `framebufferOnly` and keeps its fast path.
// Metal orders encoders within a command buffer, so writing the texture in
// pass 1 and reading it afterwards needs no explicit barrier.
//
// M5 (vignette edge glow) added three optional passes here and M12 removed
// them again, along with the glow shaders and the three render targets they
// needed. Two passes and one optional blit, as it was before M5.
//
// M5 also left behind a `finalTexture` local that both the capture blit and
// the present pass read. With glow gone it aliased `offscreenTexture` and
// nothing else, so M12 removed it too. What it was protecting is real and is
// now stated as a rule at the capture blit: any pass added after pass 1 that
// renders into its own texture must be wired into BOTH readers in the same
// edit, or recordings silently diverge from the screen.
//
// M18 (Output Resolution) decouples what pass 1 renders at from the
// drawable's own size. The whole fragment pipeline is normalized-UV — nothing
// in it has ever known a pixel count — so this needed no shader math at all;
// it is a CPU-side sizing decision plus a present-pass viewport:
//   - `targetRenderSize(drawable:mode:)` below is the ONE place render size
//     is decided, for both `ensureTextures` and `drawableSizeWillChange`.
//     Native (mode 0) still derives straight from the drawable — bit-
//     identical to pre-M18 — Native ÷2 (mode 1) halves it, and every other
//     mode is a fixed preset from `fixedResolutionSize(forMode:)`, the same
//     table `AppController.matchWindowAspect(toResolutionMode:)` reads to
//     reshape the window onto the matching aspect.
//   - The resize/auto-finalize check that used to live in
//     `drawableSizeWillChange` moved INTO `ensureTextures`, because after
//     M18 "the drawable resized" and "the render size changed" are no
//     longer the same question — only the latter should ever finalize a
//     take, and only `ensureTextures` actually knows which happened.
//   - The present pass gained a letterbox fit (viewport + scissor, computed
//     from the offscreen texture's size vs. the drawable's) and a sampler
//     CHOICE — nearest when the mapping is exactly 1:1 (Native), linear
//     otherwise — selected here and bound at encode time. `blitFragmentShader`
//     itself only changed by making that sampler an argument instead of a
//     baked-in constant; it does no new math.
// Recording and screenshots need no changes at all: they already read
// `offscreenTexture` at whatever size it currently is, which is exactly the
// render size now. See FrameCapture's `notedWidth`/`notedHeight` split for the
// one latent bug M18 surfaced and fixed along the way.
final class LiquidRenderer: NSObject, MTKViewDelegate {
    // M23: the one cadence target, read by AppController's MetalView
    // (preferredFramesPerSecond) and by the present pass below
    // (afterMinimumDuration) — one constant, two readers, so the two can
    // never disagree about what "locked" means. Not a UI control on purpose:
    // this is a fix, not a feature, and a picker here would put a diagnostic
    // knob in a performance instrument's sidebar.
    static let cadenceTargetFPS: Int = 60

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private var synthPipelineState: MTLRenderPipelineState?
    private var blitPipelineState: MTLRenderPipelineState?
    // M18: the present pass's two possible samplers, built once. Nearest is
    // used only when the offscreen texture is pixel-for-pixel the same size
    // as the drawable (Native) — everywhere else (any fixed preset, Native
    // ÷2, or plain letterbox bars) gets linear. Selected per-frame in draw(),
    // never per-user-setting — there is no Preview Filtering control.
    private var nearestSampler: MTLSamplerState?
    private var linearSampler: MTLSamplerState?
    private let sourceManager: VideoSourceManager
    private let store: ParamStore
    private let frameCapture: FrameCapture

    // M3: pass-1 render target. Rebuilt whenever the drawable size changes.
    // `private(set)` because M4's recorder reads it; nothing writes it but
    // this class.
    private(set) var offscreenTexture: MTLTexture?

    // M20 Part 3 Step 0: this was `Date()`. Date is the WALL clock — it is
    // NTP-adjustable and is not guaranteed to move forward, so a time sync
    // landing mid-take could in principle hand draw() a negative interval.
    // CACurrentMediaTime() is the monotonic clock and is the correct one for
    // measuring an interval.
    //
    // M24: `startTime` used to sit beside this, feeding `p.time` as a raw
    // elapsed-wall-clock difference. `p.time` is now integrated from
    // `virtualElapsed` instead, so `startTime` had no remaining reader and is
    // gone rather than kept alive.
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()

    // Phase accumulators. lfoPhaseAccumulator is seeded non-zero to avoid the
    // sin(0) startup hitch.
    private var m1PhaseAccumulator: Float = 0.0
    // M8 Phase A: one accumulator per displacement axis, same contract as the
    // mirror phases — the speed slider changes the per-frame delta only, never
    // the accumulated phase, so dragging it bends the motion instead of
    // restarting it.
    private var dispPhaseXAccumulator: Float = 0.0
    private var dispPhaseYAccumulator: Float = 0.0
    private var m2PhaseAccumulator: Float = 0.0
    private var m1AngleAccumulator: Float = 0.0
    private var m2AngleAccumulator: Float = 1.57079632679
    private var lfoPhaseAccumulator: Float = 0.5
    // M9: LFO 2's own accumulator. Seeded to the SAME value as LFO 1 so the
    // two start in coincidence — the beat cycle then begins at its swell rather
    // than somewhere arbitrary in the middle of it. Its rate is LFO 1's rate
    // plus an offset (see the LFO block in draw()), so it is a genuinely
    // independent integration, not a derived phase.
    private var lfo2PhaseAccumulator: Float = 0.5

    // M19 — the geared capture-clock tap.
    //
    // A SEPARATE ACCUMULATOR PAIR, integrating the same rates multiplied by
    // the ratio. This is the critical implementation detail and the reason
    // M19 is not a one-liner: multiplying the EXISTING accumulator by a ratio
    // would jump the phase the instant the ratio changed — precisely the
    // restart-glitch class architecture rule 2 exists to prevent. A rate
    // control changes the per-frame delta only. The ratio is a rate control.
    //
    // Seeded to the SAME 0.5 as the main pair. Reset LFO Phase re-seeds all
    // four together, so "restart the beat from coincidence" restarts the
    // capture tap in coincidence too rather than leaving it stranded.
    //
    // No wrap guard, deliberately, matching the main pair: S&H has period 1
    // while every other waveform has period 2π, so there is no single wrap
    // constant that is continuous for all five. The main accumulators have run
    // unwrapped since M9. At ×16 in Slow this reaches ~32 rad/s, where Float
    // resolution stays far below one frame's step for any session length worth
    // worrying about.
    private var captureLfoPhaseAccumulator: Float = 0.5
    private var captureLfo2PhaseAccumulator: Float = 0.5

    /// M19: the fixed gearing on the capture tap. Not a control — the LFO
    /// Rate slider and the Slow/Fast range already set the speed, and a second
    /// speed control would duplicate them.
    ///
    /// Chosen against the trigger clock it beats against: the auto-trigger
    /// tops out at 60 rad/s (~9.5 captures/sec) while the Global LFO in Slow
    /// tops out at 2 rad/s. ×16 brings the capture-point sweep to ~32 rad/s
    /// (~5.1 Hz) from Slow, and ~320 rad/s from Fast — the range the workflow
    /// actually needs, reachable with the LFO left wherever the IMAGE wants
    /// it. Confirmed on hardware at this value.
    private static let captureClockRatio: Float = 16.0

    // M9: one-shot "re-align the two LFOs" request, set from the UI thread by
    // the Reset Phase button and consumed once inside draw(). Two oscillators
    // drifting against each other have no way back into alignment otherwise.
    //
    // This is an EVENT, not a parameter, so it deliberately does not live in
    // ParamStore — same reasoning as FrameCapture's pending-screenshot flag,
    // and the same shape: lock, set Bool, consume on the render thread. The
    // lock is what makes it safe; assigning the accumulators directly from the
    // button's action closure would be a plain data race against draw().
    // Idle cost is a lock plus a Bool test once per frame, alongside the ones
    // M4 already pays.
    private var lfoResetPending = false
    private let lfoResetLock = NSLock()

    /// M28: the MIDI-only lag/smoothing stage. Owned here because this is
    /// the only object in the app that runs a frame clock — see
    /// MIDIGlide.swift for the full account. `let` because ControlSurface
    /// reaches it once, at init, as `renderer.midiGlide`, exactly the way it
    /// already reaches `requestLFOPhaseReset` through the same reference.
    let midiGlide = MIDIGlide()

    /// Re-aligns both LFO accumulators on the next drawn frame. Safe to call
    /// from the main thread. Scoped strictly to the two Global LFO phases —
    /// the M4.3b stop-motion trigger clock is a deliberately separate clock and
    /// is NOT touched here (see Q4 in the M9 plan).
    func requestLFOPhaseReset() {
        lfoResetLock.lock()
        lfoResetPending = true
        lfoResetLock.unlock()
    }

    private func consumeLFOResetRequest() -> Bool {
        lfoResetLock.lock()
        defer { lfoResetLock.unlock() }
        if lfoResetPending {
            lfoResetPending = false
            return true
        }
        return false
    }

    // M4.2: recording frame-pacing accumulator. Same shape as every other
    // accumulator here — accumulates deltaTime, never wall-clock — except its
    // "rate" (activeFrameInterval) comes from FrameCapture rather than a UI
    // slider, and it fires a one-shot event (capture this frame) instead of
    // feeding a continuous waveform. Reset to 0 whenever not actively
    // recording so a Pause/Resume or a fresh Record never inherits stale
    // accumulated time from a previous take.
    private var captureAccumulator: Float = 0.0

    // M4.3b: stop-motion auto-trigger clock. Its OWN phase accumulator with its
    // own rate (house rule: accumulate deltaTime, never sin(time*rate)), so
    // capture can run far faster than the Global LFO's ~0.3 Hz ceiling. Free-
    // running — it advances even when not recording, so the scope meter in the
    // Recording section animates while you dial the rate in before hitting
    // Record. `captureTriggerPosPrev` holds the previous position through the
    // cycle, measured RELATIVE to the (modulated) capture point; a wrap of that
    // relative position is one capture.
    private var captureTriggerAccumulator: Float = 0.0
    private var captureTriggerPosPrev: Float = 0.0

    // M24: the recorder phase clock's two pieces of state. See the long block
    // in draw() for the mechanism.
    //
    // `paidSinceCapture` is how much virtual time has been paid out since the
    // last captured frame — the charge on the bus. Reset to 0 whenever the
    // quantizer is not engaged, so idle, Pause/Resume, stop-motion and a fresh
    // Record never inherit a stale debt.
    //
    // `virtualElapsed` is the shader's free-running time base, integrated from
    // the same phase clock. Double for the accumulation and Float only at
    // assignment, matching exactly what `now - startTime` already did — a Float
    // accumulator would visibly lose resolution over a long session.
    private var paidSinceCapture: Float = 0.0
    private var virtualElapsed: Double = 0.0


    init(device: MTLDevice, sourceManager: VideoSourceManager, store: ParamStore, frameCapture: FrameCapture) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        self.sourceManager = sourceManager
        self.store = store
        self.frameCapture = frameCapture
        super.init()
        buildPipelineStates()
    }

    // Two pipelines now: the synth pass (unchanged fragment shader, targeting
    // the offscreen texture) and the present-pass blit. BOTH use the same
    // `vertexShader` — see the comment on blitFragmentShader in Shaders.metal
    // for why a second, flipping vertex shader would land the image upside-down.
    // Both target bgra8Unorm: the offscreen texture and the drawable share that
    // format, which is what keeps pass 2 a bit-exact copy.
    private func buildPipelineStates() {
        guard let library = device.makeDefaultLibrary() else { return }

        let synthDescriptor = MTLRenderPipelineDescriptor()
        synthDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        synthDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        synthDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        synthPipelineState = try? device.makeRenderPipelineState(descriptor: synthDescriptor)

        let blitDescriptor = MTLRenderPipelineDescriptor()
        blitDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        blitDescriptor.fragmentFunction = library.makeFunction(name: "blitFragmentShader")
        blitDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        blitPipelineState = try? device.makeRenderPipelineState(descriptor: blitDescriptor)

        // M18: blitFragmentShader's sampler is now an argument (see the
        // comment above it in Shaders.metal) rather than a baked-in
        // constexpr, so both possible samplers are built once, here, and
        // picked per-frame in draw()'s present pass.
        let nearestDescriptor = MTLSamplerDescriptor()
        nearestDescriptor.minFilter = .nearest
        nearestDescriptor.magFilter = .nearest
        nearestDescriptor.sAddressMode = .clampToEdge
        nearestDescriptor.tAddressMode = .clampToEdge
        nearestSampler = device.makeSamplerState(descriptor: nearestDescriptor)

        let linearDescriptor = MTLSamplerDescriptor()
        linearDescriptor.minFilter = .linear
        linearDescriptor.magFilter = .linear
        linearDescriptor.sAddressMode = .clampToEdge
        linearDescriptor.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: linearDescriptor)
    }

    // M18: fixed delivery resolutions. ONE table, shared with
    // AppController.matchWindowAspect(toResolutionMode:) — which reshapes the
    // window onto the matching aspect when one of these is picked — so the
    // render size and the window's target aspect can never drift apart.
    // Modes 0 (Native) and 1 (Native ÷2) have no fixed size; they derive from
    // the drawable, so they return nil here and are handled in
    // targetRenderSize below instead.
    static func fixedResolutionSize(forMode mode: Int) -> (width: Int, height: Int)? {
        switch mode {
        case 2: return (640, 480)
        case 3: return (1280, 720)
        case 4: return (1920, 1080)
        case 5: return (1080, 1080)
        case 6: return (1080, 1920)
        case 7: return (3840, 2160)
        default: return nil
        }
    }

    // M18: the single source of truth for what size pass 1 actually renders
    // at, read by BOTH draw() and drawableSizeWillChange so the two never
    // disagree. `mode` is LiveParams.outputResolution, rounded to its Int tag.
    private func targetRenderSize(drawable: CGSize, mode: Float) -> (width: Int, height: Int) {
        let dw = Int(drawable.width.rounded())
        let dh = Int(drawable.height.rounded())
        let modeInt = Int(mode.rounded())
        if let fixed = LiquidRenderer.fixedResolutionSize(forMode: modeInt) {
            return fixed
        }
        if modeInt == 1 {
            // Native ÷2. Forced even: H.264/HEVC require it, same reasoning
            // FrameCapture's writer already applies to the pool dimensions.
            return (max(2, (dw / 2) & ~1), max(2, (dh / 2) & ~1))
        }
        // Native (mode 0), or any out-of-range value — fail safe to Native
        // rather than to a fixed size nobody asked for.
        return (dw, dh)
    }

    // M3: (re)build the pass-1 render target when the RENDER size changes.
    // `.private` storage is the fast path — the CPU never touches these bytes.
    // M4 reads it by blitting into a CVPixelBuffer-backed staging texture only
    // on frames it actually captures, so readback cost is paid while capturing
    // rather than on every frame forever.
    //
    // M12: M5's three glow targets were built here too. Removing them takes
    // the footprint at 2560x1440 back from about 37 MB to about 14.7 MB.
    //
    // M18: this is now where the resize/auto-finalize check lives — it used
    // to live in drawableSizeWillChange, keyed off the DRAWABLE changing size,
    // but after M18 "the drawable resized" and "the render size changed" are
    // no longer the same question (a fixed preset is untouched by a window
    // resize; Native/Native÷2 still change together with the drawable exactly
    // as before). This is the one place that actually knows which happened,
    // for both callers (draw()'s defensive re-check and
    // drawableSizeWillChange), so the check moved here rather than being
    // duplicated at both call sites.
    private func ensureTextures(size: CGSize) {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return }

        if let existing = offscreenTexture {
            if existing.width == width, existing.height == height {
                return
            }
            // A genuine RENDER SIZE change (not merely "no texture built
            // yet" — that case is `existing == nil` and never reaches here).
            // M4.2's confirmed preference: auto-finalize cleanly rather than
            // continue with a cropped/letterboxed frame. The Output
            // Resolution picker is disabled during a take (see
            // RecordingSection), so in practice this now only fires from an
            // actual window resize while Native/Native÷2 is selected, or from
            // an out-of-take resolution switch (harmless — no take is active
            // to finalize).
            frameCapture.handleResizeDuringRecording()
        }

        func makeTarget(width: Int, height: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }

        offscreenTexture = makeTarget(width: width, height: height)
    }

    // M18: render size depends on the Output Resolution mode now, not just the
    // drawable, so this reads the mode directly (a single Float get, not a
    // full snapshot — cheap, and this can fire mid-drag on a window resize)
    // and resolves through the SAME targetRenderSize used in draw(), so a
    // fixed preset is correctly a no-op here regardless of how the drawable
    // itself just changed. The actual resize/auto-finalize decision now lives
    // inside ensureTextures — see the comment there.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let mode = store.get(\.outputResolution)
        let resolved = targetRenderSize(drawable: size, mode: mode)
        ensureTextures(size: CGSize(width: resolved.width, height: resolved.height))
    }

    private func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        return min(max(x, lo), hi)
    }

    // Curved rate response: position in [-1,1] -> sign(x)*x squared *maxRate.
    private func curvedRate(_ position: Float, _ maxRate: Float) -> Float {
        let sign: Float = position >= 0 ? 1.0 : -1.0
        return sign * position * position * maxRate
    }

    // CPU-side mirror of the shader's evaluateWaveform for the LFO.
    private func hash(_ x: Float) -> Float {
        let s = sin(x * 12.9898) * 43758.5453
        return (s - floor(s)) * 2.0 - 1.0
    }

    private func getSNH(_ x: Float, _ lag: Float) -> Float {
        let i = floor(x)
        let f = x - i
        let v1 = hash(i)
        if lag < 0.01 { return v1 }
        let v0 = hash(i - 1.0)
        if f < lag {
            let u = f / lag
            let t = u * u * (3.0 - 2.0 * u)
            return v0 + (v1 - v0) * t
        }
        return v1
    }

    private func evaluateWaveform(_ x: Float, _ type: Float, _ lag: Float) -> Float {
        let twoPi: Float = 2.0 * 3.14159265
        if type < 0.5 {
            return sin(x)
        } else if type < 1.5 {
            let t = x / twoPi - floor(x / twoPi)
            return abs(t * 2.0 - 1.0) * 2.0 - 1.0
        } else if type < 2.5 {
            let t = x / twoPi - floor(x / twoPi)
            return t * 2.0 - 1.0
        } else if type < 3.5 {
            return getSNH(x, lag)
        } else {
            let t = x / twoPi - floor(x / twoPi)
            return t < 0.5 ? 1.0 : -1.0
        }
    }

    // M9: combine the two LFOs into the single modulation bus. A straight port
    // of the shader's combineSpiralWaves, including the Multiply mode C.4
    // added, so the two oscillator pairs in this synth behave identically and
    // there is one set of mode semantics to learn rather than two.
    //
    //   Additive     — the two waves sum. This is what beats.
    //   Subtractive  — LFO 2 fights LFO 1; also beats, inverted.
    //   XOR          — abs(a-b): folds at every crossing, so it doubles the
    //                  apparent rate and is always positive. NOT an identity at
    //                  depth 0 (it yields abs(lfo1)) — see the note in
    //                  LiveParams.
    //   Multiply     — ring modulation on the modulation bus. This is where it
    //                  stops being a smooth LFO and becomes a rhythm generator.
    //                  As with any ring modulator, a dead input outputs
    //                  nothing: Multiply at lfo2Depth 0 SILENCES the entire
    //                  modulation bus. Expected, not a bug.
    private func combineLFO(_ a: Float, _ b: Float, _ mode: Float) -> Float {
        if mode < 0.5 {
            return a + b            // Additive
        } else if mode < 1.5 {
            return a - b            // Subtractive
        } else if mode < 2.5 {
            return abs(a - b)       // XOR
        } else {
            return a * b            // Multiply (ring mod)
        }
    }

    // M16: evaluate THE WHOLE LFO CHAIN — both oscillators, combined, clamped
    // — at an arbitrary phase offset. This is the one primitive every family
    // destination reads through.
    //
    // WHY A RE-EVALUATION RATHER THAN A CROSSFADE. The first cut of this
    // mixed toward a fixed 90-degree copy: mix(busX, busY, amount). That is a
    // true phase shift ONLY for a sine, and even there it dips in amplitude
    // at the midpoint (0.5*sin + 0.5*cos peaks at 0.707, not 1). For Square
    // it put edges in places the waveform never has one; for S&H it averaged
    // two steps into a value the sample-and-hold never held. Re-evaluating at
    // phase + offset is exact for every waveform, costs two more
    // evaluateWaveform calls per distinct offset (CPU-side, on uniforms, a
    // handful per frame), and makes busSpread mean one honest thing: the
    // ANGLE between family members.
    // M19: evaluate the whole LFO chain from an EXPLICIT pair of oscillator
    // phases. Extracted from busAt so the geared capture tap can reuse it
    // verbatim — same waveforms, same lag, same LFO 2 depth, same combine
    // mode, same load-bearing clamp. Two callers, one definition, so the
    // capture tap can never quietly diverge from the image bus in anything
    // except its rate.
    private func evaluateBus(_ phase1: Float, _ phase2: Float, _ live: LiveParams) -> Float {
        let a = evaluateWaveform(phase1, live.lfoWaveType, live.lfoLag)
        let b = evaluateWaveform(phase2, live.lfo2WaveType, live.lfo2Lag) * live.lfo2Depth
        // Every depth constant downstream assumes a +/-1 signal.
        return clamp(combineLFO(a, b, live.lfoCombineMode), -1.0, 1.0)
    }

    private func busAt(_ phaseOffset: Float, _ live: LiveParams) -> Float {
        return evaluateBus(
            lfoPhaseAccumulator + phaseOffset,
            lfo2PhaseAccumulator + live.lfo2PhaseOffset * 2.0 * 3.14159265 + phaseOffset,
            live
        )
    }

    // M16: the modulation value for family member `n` (0-indexed). Member 0
    // is the un-offset bus — bit-identical to the single flat bus every
    // destination read before M16, and exactly what busSpread == 0 reduces
    // EVERY member to. Each member after it is one more busSpread step
    // around the waveform, so a three-member family fans out evenly (member
    // 2 sits at twice member 1's angle) rather than needing a special case.
    private func busMember(_ n: Int, _ live: LiveParams) -> Float {
        if n == 0 || abs(live.busSpread) < 0.0001 { return busAt(0.0, live) }
        return busAt(Float(n) * live.busSpread * Float.pi, live)
    }

    func draw(in view: MTKView) {
        guard let queue = commandQueue,
              let synthPipeline = synthPipelineState,
              let blitPipeline = blitPipelineState,
              let nearestSampler = nearestSampler,
              let linearSampler = linearSampler else { return }

        // M18: the snapshot moves ABOVE ensureTextures now — targetRenderSize
        // needs live.outputResolution to know what size to build. snapshot()
        // is a lock-and-copy with no texture dependency, so this reordering is
        // safe; nothing below relied on the old ordering either.
        let live = store.snapshot()

        // M3/M5/M18: all render targets are rebuilt in drawableSizeWillChange,
        // but re-checked here as well. First-draw-vs-first-size-callback
        // ordering isn't worth depending on, and this also covers a move to a
        // display with a different backing scale. targetRenderSize resolves
        // the Output Resolution mode the SAME way drawableSizeWillChange does,
        // so the two can never disagree about what size pass 1 should be.
        let renderSize = targetRenderSize(drawable: view.drawableSize, mode: live.outputResolution)
        ensureTextures(size: CGSize(width: renderSize.width, height: renderSize.height))
        guard let offscreen = offscreenTexture else { return }

        // M4.2: report the current size every frame, unconditionally, so
        // FrameCapture knows the pool dimensions before the first capture
        // ever happens (needed for Record to work correctly the very first
        // time it's pressed). Cheap — see the doc comment on
        // notePotentialSize for why no lock is needed here.
        frameCapture.notePotentialSize(width: offscreen.width, height: offscreen.height)

        // M4.4 Part B: report whether the vignette is currently writing its
        // matte into alpha, so a PNG screenshot can preserve the alpha
        // channel instead of discarding it. Same place, shape, and cost as
        // the size report above — a lock plus one comparison — and read only
        // by writePNG. The RECORDING path needs nothing here: the alpha is
        // already in the pixels, and the codec decides whether the file can
        // carry it.
        //
        // Both conditions matter: alpha is only actually being written when
        // the vignette is on AND the toggle is up, which is exactly the gate
        // the shader itself applies.
        frameCapture.noteAlphaEnabled(live.vignetteShape > 0.5 && live.vignetteAlpha > 0.5)

        // M20 Part 3 Step 0 / M24: the REAL clock. `now` is CACurrentMediaTime(),
        // the monotonic clock — a Date is the WALL clock, NTP-adjustable, and
        // is not guaranteed to move forward.
        //
        // M24: `deltaTime` is still the real measured interval and is what
        // both CAPTURE-PACING accumulators integrate. The MOTION accumulators
        // do not read it directly — they read `phaseDelta`, computed just
        // below the capture block. Anything pacing keeps the real clock;
        // anything moving the picture gets the phase clock.
        let now = CACurrentMediaTime()
        var deltaTime = Float(now - lastFrameTime)
        lastFrameTime = now
        if deltaTime > 0.25 { deltaTime = 0.25 }
        // Monotonic in principle, but a negative interval here would silently
        // run every accumulator backwards, so it is floored rather than trusted.
        if deltaTime < 0.0 { deltaTime = 0.0 }

        // M28: advance any in-flight MIDI glides and write arrivals/
        // in-progress values straight to the store. Placed right after the
        // real clock is settled and before anything reads `store` again —
        // `live` above was already snapshotted this frame, so a value that
        // lands this frame is one frame (~16 ms) late to the picture,
        // exactly like every other write path relative to snapshot(). Idle
        // cost (no MIDI glide in flight) is a lock and an isEmpty test.
        midiGlide.advance(deltaTime: deltaTime, store: store)

        // M4.2/M4.3: recording frame-pacing. activeFrameInterval is 0 whenever
        // not actively recording (idle OR paused), so the idle hot path stays a
        // lock + Bool test in either mode. In LONG-FORM the pacing accumulator
        // (deltaTime-driven, never wall-clock) decides when a frame is due,
        // exactly as in 4.2. In STOP-MOTION the accumulator is held at 0 and
        // record frames instead come from discrete triggers: the manual Capture
        // Frame button (consumed inside FrameCapture) and the LFO auto-trigger
        // computed further below, AFTER the LFO phase advances — so
        // wantsRecordFrame is declared here and may be OR'd into down there.
        // When requested FPS exceeds render FPS the subtraction-and-clamp keeps
        // the long-form accumulator from growing without bound rather than
        // capturing more than one frame per draw.
        var wantsRecordFrame = false
        let captureInterval = frameCapture.activeFrameInterval
        let isStopMotion = live.recordMode > 0.5
        if captureInterval > 0 && !isStopMotion {
            captureAccumulator += deltaTime
            if captureAccumulator >= Float(captureInterval) {
                captureAccumulator = min(captureAccumulator - Float(captureInterval), Float(captureInterval))
                wantsRecordFrame = true
            }
        } else {
            captureAccumulator = 0
        }

        // =================================================================
        // M24 — THE RECORDER PHASE CLOCK
        // =================================================================
        //
        // THE FAULT THIS FIXES. A recorded frame's TIMESTAMP and its CONTENT
        // came from two clocks that were allowed to disagree. The timestamp is
        // `CMTime(value: frameIndex, timescale: lockedFPS)` — frame N sits at
        // exactly N/fps, evenly spaced by construction, no exceptions. The
        // content is whatever the accumulators had reached at the real moment
        // the frame was grabbed. So every wobble in `deltaTime` became uneven
        // content under perfectly even timestamps, and the file reproduced
        // every live hitch permanently. M23 shrank the wobble 3-4x but cannot
        // remove it, and one dropped render frame in a ten-minute take still
        // bakes a double-step in forever. A correctness gap, not a performance
        // one.
        //
        // THE FIX. While a long-form take is running, the motion accumulators
        // integrate the RECORDED timeline — exactly one frame-step of phase
        // per captured frame — instead of the wall clock.
        //
        // THE BUS ANALOGY. Think of `paidSinceCapture` as charge on a bus that
        // must read exactly one frame-step at the instant the recorder taps
        // it. Intermediate frames draw real time from the clock onto the bus;
        // the capture frame TOPS THE BUS UP to exactly one step and resets it.
        // The overshoot — the jitter — is discarded, and that discard is the
        // entire fix. Forward-only by construction: no accumulator can ever run
        // backwards, because every payment is floored at zero.
        //
        // WHY IT DOESN'T DRIFT. `captureAccumulator` above carries its
        // remainder forward, so captures fire at exactly `lockedFPS` per real
        // second on average. One frame-step per capture therefore averages to
        // real time exactly.
        //
        // THE RESERVE (see Q-note in the session log): the plain "pay real
        // time, top up on capture" rule has a hole at record rates CLOSE to
        // the render rate. At 60 fps record on M23's 59.0-60.5 fps lock, the
        // loop occasionally delivers one extra render frame inside a capture
        // period. That frame would spend nearly the whole step, leaving the
        // capture frame a ~0.07 ms crumb — a visibly frozen frame on screen
        // roughly twice a second. The file would still be exact, but the LIVE
        // view would gain a new micro-hitch, and live fluidity outranks every
        // feature in this instrument.
        //
        // So an intermediate frame never spends more than it can afford to:
        //
        //     pay = min(deltaTime, max(remaining - deltaTime, remaining * 0.5))
        //
        // In words: pay real time, but never leave the capture frame with less
        // than the smaller of one real frame's worth and half of what's left.
        // At 60/60 the awkward pair becomes an even 8.33/8.33 split instead of
        // 16.6/0.07. At 30 and 12 fps (clean divisors) it changes nothing at
        // all — the arithmetic already lands evenly there. At 24 it tightens
        // the repeating pattern from 16.67/16.67/8.33 to 16.67/12.5/12.5.
        //
        // This is NOT a model of the display. It reads only the measured
        // `deltaTime` and the budget remaining in the current capture period.
        // Nothing here predicts how many frames are coming.
        //
        // EXCLUSIONS, each deliberate:
        //  - STOP-MOTION keeps the real clock, permanently. Its whole point is
        //    that captures fire at IRREGULAR real intervals while the
        //    instrument moves continuously underneath — the irregular sampling
        //    IS the aesthetic. One step per capture would place every captured
        //    frame exactly one step from its neighbour, making the irregular
        //    trigger invisible and `lfoToCapturePhase` an inert control. M24
        //    would silently delete M4.3b.
        //  - RECORD RATES ABOVE THE RENDER LOCK are excluded. Above 60 the
        //    premise fails: one capture per 1/recFPS of real time is
        //    impossible, so the virtual clock would run proportionally slow —
        //    at 120 fps, half speed. The part that matters is that THE VIDEO
        //    SOURCE WOULD NOT SLOW WITH IT: AVFoundation playback and the
        //    camera run on their own real-time clock, so a 120 fps take would
        //    record slowed geometry over normal-speed footage. That's an image
        //    artifact, not a feel change. Today's behavior (everything slowed
        //    together on playback) is correct for slow-motion takes.
        //  - IDLE AND PAUSED are excluded because `activeFrameInterval` is
        //    already 0 in both, so `captureInterval > 0` covers them for free.
        //
        // ARCHITECTURE RULE 2 IS NOT VIOLATED. A rate control still changes
        // only the per-frame delta; no accumulated phase is ever recomputed,
        // scaled, or reset. M24 changes what the delta MEASURES, never the
        // phase itself.
        //
        // The step and the capture interval are the same number (both are
        // 1/lockedFPS), so `captureInterval` serves as both.
        let quantizePhase = captureInterval > 0
            && !isStopMotion
            && captureInterval >= (1.0 / Double(Self.cadenceTargetFPS)) - 1e-6

        var phaseDelta = deltaTime
        if quantizePhase {
            let step = Float(captureInterval)
            let remaining = max(0.0, step - paidSinceCapture)
            if wantsRecordFrame {
                // Top up to exactly one step and reset the bus.
                phaseDelta = remaining
                paidSinceCapture = 0.0
            } else {
                phaseDelta = min(deltaTime, max(remaining - deltaTime, remaining * 0.5))
                paidSinceCapture += phaseDelta
            }
        } else {
            paidSinceCapture = 0.0
        }

        var p = ShaderParams()

        // ---- Direct field mapping ----
        p.torsionFrequency = live.torsionFrequency
        p.lumaTorsion = live.lumaTorsion
        // M7 Phase 7.2: p.torsionFirst is no longer written — the fixed routing
        // branch it drove was replaced by the chain slots below, and index 3 is
        // frozen at its struct default. Do not reinstate this line.
        p.chainSlot0 = live.chainSlot0
        p.chainSlot1 = live.chainSlot1
        p.chainSlot2 = live.chainSlot2
        p.chainSlot3 = live.chainSlot3
        p.chainSlot4 = live.chainSlot4

        // M14 Part 2 / M16: luma source staging. WAS a static passthrough; is
        // now the Character family's second member (Radial Push leads).
        // p.lumaStageDepth is assigned in the Global LFO block below, beside
        // the rest of the destinations, since it needs the bus.
        p.torsionRadialMode = live.torsionRadialMode
        p.torsionWaveType = live.torsionWaveType
        p.torsionLag = live.torsionLag
        p.torsionOrbitDepth = live.torsionOrbitDepth

        // Spiral 2 (M7 Phase 7.1) — direct mapping, same pattern as Spiral 1
        // above. No new phase accumulator needed: Spiral 2 derives its wave
        // argument from params.time via spiral2FreqOffset (relative to
        // Spiral 1's frequency), inheriting Spiral 1's existing time base
        // rather than needing an independent one.
        // M16: WAS a static passthrough. Rotation 2 never had an LFO
        // destination before M16 — an oversight the survey turned up, not a
        // decision — and is now the Rotation family's second member
        // (Torsion Strength leads). Assigned in the Global LFO block below.
        p.spiral2FreqOffset = live.spiral2FreqOffset
        p.spiral2WaveType = live.spiral2WaveType
        p.spiral2Lag = live.spiral2Lag
        p.spiral2OrbitDepth = live.spiral2OrbitDepth
        p.spiral2OrbitPhase = live.spiral2OrbitPhase
        p.spiral2OrbitRatio = live.spiral2OrbitRatio
        p.spiral2RadialMode = live.spiral2RadialMode
        p.spiralCombineMode = live.spiralCombineMode

        p.mirror1On = live.mirror1On
        // M26: straight passthroughs, no resolve of any kind. The offset is
        // added to p.mirror1Angle INSIDE the shader, and p.mirror1Angle is
        // already resolved below from either the static angle slider or the
        // spin accumulator — so Spin works with no renderer change at all and
        // the fold pair stays rigidly opposed while it turns. No accumulator,
        // no bus, no clamp: architecture rule 2 is untouched by this milestone.
        p.mirror1DoubleOn = live.mirror1DoubleOn
        p.mirror1DoubleOffset = live.mirror1DoubleOffset
        p.mirror1RippleFreq = live.mirror1RippleFreq
        p.mirror1WaveType = live.mirror1WaveType
        p.mirror1Lag = live.mirror1Lag
        p.lumaMod1 = live.lumaMod1
        p.mirror1RadialMode = live.mirror1RadialMode
        // M14 Part 1 / M16: mirror fold centers. WERE static passthroughs;
        // are now the Mirror Center family — the first destination the bus
        // drives as a true XY VECTOR rather than a phase-shifted scalar
        // pair. Assigned in the Global LFO block below, where the vector is
        // in hand.

        p.mirror2On = live.mirror2On
        p.mirror2DoubleOn = live.mirror2DoubleOn
        p.mirror2DoubleOffset = live.mirror2DoubleOffset
        p.mirror2RippleFreq = live.mirror2RippleFreq
        p.mirror2WaveType = live.mirror2WaveType
        p.mirror2Lag = live.mirror2Lag
        p.lumaMod2 = live.lumaMod2
        p.mirror2RadialMode = live.mirror2RadialMode

        // M22: the UI parameter is ZOOM (higher magnifies); the shader's
        // `scale` is a coordinate-span multiplier (higher shrinks the
        // picture). One reciprocal here is the whole conversion, which is why
        // reversing the control needed no shader or struct edit at all. The
        // floor is belt-and-braces: the registry range bottoms out at 0.3333
        // and MIDI clamps to it, so a zero can't arrive, but a division is
        // not the place to rely on that.
        p.scale = 1.0 / max(live.zoom, 0.0001)
        p.edgeBehavior = live.edgeBehavior
        p.preCrop = (live.preCropOn > 0.5) ? live.preCropPixels : 0.0

        p.invertEntireHoleKey = live.invertEntireHoleKey
        p.negativeSpace = live.negativeSpace
        p.torsionInHoles = live.torsionInHoles
        p.keySoftness = live.keySoftness

        p.keyerPolarity = live.keyerPolarity
        p.keyerXOR1 = live.keyerXOR1
        p.keyerFeed1 = live.keyerFeed1

        p.keyerXOR2 = live.keyerXOR2
        p.keyerFeed2 = live.keyerFeed2

        p.keyerXOR3 = live.keyerXOR3
        p.keyerFeed3 = live.keyerFeed3

        // M15: p.lfoWaveType / p.lfoLag are gone. The Global LFO resolves
        // entirely CPU-side; the GPU only ever saw already-modulated values.

        // M1a: final output wet/dry mix (bypassed in-shader when >= ~1).
        p.outputMix = live.outputMix

        // M2: output vignette. Static passthrough — no LFO/accumulator; these
        // are direct screen-space shape params read straight from the store.
        p.vignetteShape = live.vignetteShape
        p.vignetteCenterX = live.vignetteCenterX
        p.vignetteCenterY = live.vignetteCenterY
        p.vignetteSize = live.vignetteSize
        p.vignetteAspect = live.vignetteAspect
        p.vignetteSoftness = live.vignetteSoftness
        // M4.4 Part B: route the vignette's coverage into the alpha channel as
        // well. Static passthrough like the rest of this block — no
        // modulation destination, and deliberately not one: this is an export
        // format decision, not an image control.
        p.vignetteAlpha = live.vignetteAlpha

        // M24 PART 2 — `p.time` moves onto the phase clock.
        //
        // This WAS `Float(now - startTime)`: a raw wall-clock difference, not
        // an accumulator. That made it a SECOND motion clock, and it drives
        // real, visible motion in the shader:
        //   - torsion drift on both spirals, in both radial modes
        //     (`twistArg = freq * r - params.time * 0.2`)
        //   - the second twist pair (`- params.time * 0.5`)
        //   - the ENTIRE Gradient Synth procedural source
        //     (`gradientSynthPattern(uv, params.time)`)
        //
        // Advancing only the eight accumulators would have left torsion drift
        // and the whole Gradient Synth source still baking live jitter into every
        // recording — M24 would have been half a fix. Integrating the same
        // `phaseDelta` closes that.
        //
        // NAMED SIDE EFFECT, intended and not hidden: this also corrects a
        // standing inconsistency. After an app-switch or an occlusion, every
        // accumulator held still (`deltaTime` is clamped to 0.25 s) while
        // `p.time` jumped forward by the FULL stall — torsion drift lurched
        // and nothing else did. It now behaves like the rest of the
        // instrument.
        virtualElapsed += Double(phaseDelta)
        p.time = Float(virtualElapsed)

        // ---- Global LFO (complex, two oscillators since M9) ----
        // Consume any pending Reset Phase request BEFORE integrating, so the
        // frame the button was pressed on is already re-aligned rather than one
        // frame late. Both are seeded back to the SAME value they start at,
        // which is what "restart the beat from coincidence" means. The value
        // itself is arbitrary — 0.5 rather than 0 only to match the startup
        // seed, which exists so the LFO doesn't begin parked exactly on a
        // waveform zero crossing.
        if consumeLFOResetRequest() {
            lfoPhaseAccumulator = 0.5
            lfo2PhaseAccumulator = 0.5
            // M19: the geared capture tap re-seeds with them. Re-aligning the
            // beat while leaving the capture clock stranded at an arbitrary
            // phase would make the button mean something different depending
            // on which ratio happened to be selected.
            captureLfoPhaseAccumulator = 0.5
            captureLfo2PhaseAccumulator = 0.5
        }

        // LFO 2's rate is LFO 1's rate PLUS an offset — a true frequency
        // difference in rad/s, which is what makes the beat period predictable
        // (period ≈ 2π / |Δω|). The offset is applied AFTER LFO 1's rate curve
        // on purpose: applying it before would make the beat period depend on
        // wherever LFO 1's slider happens to be sitting, which is exactly the
        // kind of cross-coupling that makes a control feel broken.
        //
        // The 0.5 constant is the whole tuning of this feature: at full offset
        // Δω = 0.5 rad/s, giving roughly a 12-second swell; near zero the swell
        // stretches into minutes. One constant, tunable in the hand if the
        // useful range turns out to sit elsewhere.
        //
        // Both accumulators integrate deltaTime and neither is ever recomputed
        // from elapsed time — the standing house rule, and the reason dragging
        // either rate control bends the motion instead of restarting it.
        // M16 revision: the rate RANGE scales both the maximum rate and LFO
        // 2's frequency offset together, so switching to Fast speeds the beat
        // up in proportion rather than leaving a 12-second swell under a
        // 3 Hz carrier. Slow (default) is 2.0 / 0.5 — exactly the constants
        // this instrument has always used, so every existing patch's Rate
        // position means precisely what it did before.
        let rateScale: Float = live.lfoRateRange > 0.5 ? 10.0 : 1.0
        let lfoRate = curvedRate(live.lfoRate, 2.0 * rateScale)
        let lfo2Rate = lfoRate + live.lfo2RateOffset * 0.5 * rateScale
        lfoPhaseAccumulator += phaseDelta * lfoRate
        lfo2PhaseAccumulator += phaseDelta * lfo2Rate

        // M19: the geared capture tap, integrated beside the main pair.
        //
        // It reads `deltaTime`, NOT `phaseDelta`, and that is deliberate. This
        // accumulator belongs to the CAPTURE-TIMING family — the same family
        // as `captureAccumulator` and `captureTriggerAccumulator`, both of
        // which M24 kept on the real clock — not to the motion family. It
        // moves nothing in the image; it only decides WHERE in each trigger
        // cycle a frame is grabbed. In practice the two values are equal
        // everywhere this is read anyway (it is only consumed inside the
        // `isStopMotion` branch, which M24's quantizer excludes), but the
        // intent should be legible without having to re-derive that.
        //
        // Both oscillators are geared together, so LFO 2's frequency OFFSET
        // scales with the ratio and the beat period stays proportional rather
        // than collapsing. Same treatment `lfoRateRange` already gives it.
        captureLfoPhaseAccumulator += deltaTime * lfoRate * Self.captureClockRatio
        captureLfo2PhaseAccumulator += deltaTime * lfo2Rate * Self.captureClockRatio

        let lfo1 = evaluateWaveform(lfoPhaseAccumulator, live.lfoWaveType, live.lfoLag)
        // Phase offset is added at EVALUATION time, not folded into the
        // accumulator, so dragging it slides LFO 2's waveform against LFO 1
        // without disturbing the integration or the beat that's already running.
        let lfo2 = evaluateWaveform(
            lfo2PhaseAccumulator + live.lfo2PhaseOffset * 2.0 * 3.14159265,
            live.lfo2WaveType,
            live.lfo2Lag
        ) * live.lfo2Depth

        // THE CLAMP IS LOAD-BEARING. Additive can reach ±2, and every
        // destination below multiplies lfoValue by a depth constant tuned for a
        // ±1 signal. Without this, turning up LFO 2 Depth would silently double
        // every modulation depth in the synth rather than adding a second
        // oscillator. With it, Additive at high depth soft-limits — visible as
        // the modulation flattening at its extremes, which is honest and is
        // what a real voltage-limited modulation bus does.
        let lfoValue = clamp(combineLFO(lfo1, lfo2, live.lfoCombineMode), -1.0, 1.0)

        // ---- M16: the bus vector, for CENTER destinations ----
        // Amplitude families read phase-shifted copies of one signal via
        // busMember(). CENTER families need a genuine XY VECTOR so their
        // destination traces a path: busVecX is the bus itself, busVecY the
        // same chain a fixed quarter cycle later. Fixed at 90 degrees on
        // purpose — that is what makes the pair trace a circle rather than a
        // diagonal line, and it is the vector's own definition, not a taste
        // control. busSpread rotates the SECOND member's copy of this vector
        // (swapVecX/Y below), which is where the adjustable angle belongs.
        let halfPi: Float = Float.pi / 2.0
        let busVecX = lfoValue
        let busVecY = busAt(halfPi, live)

        // The axis-SWAPPED vector every two-member CENTER family's second
        // member reads (Rotation 2, Mirror 2): X and Y traded, so the second
        // member's path is a reflection of the first's rather than a copy of
        // it, additionally rotated by busSpread. Computed once here and
        // shared by both families below — it is a property of "being the
        // second member of a 2D pair," not of which module is asking.
        let swapVecX = busMember(1, live)
        let swapVecY = busAt(halfPi + live.busSpread * Float.pi, live)

        // M4.3b: stop-motion auto-trigger. The trigger runs on its OWN clock
        // (captureTriggerAccumulator, its own rate) rather than the Global LFO
        // — that's what lifts capture speed past the LFO's ~0.3 Hz ceiling.
        // maxRate 60 rad/s ≈ 9.5 captures/sec at full slider, with the usual
        // curved response giving fine control down at the slow end.
        //
        // The Global LFO now participates ONLY by sweeping the capture POINT:
        // the phase within each clock cycle at which the frame is grabbed. The
        // trigger fires when the clock's playhead crosses that point, so moving
        // the point around changes the spacing between captures — which is the
        // irregular triggering that hand-dragging the slider produced, now
        // automatable. The modulated point WRAPS (fract) rather than clamping:
        // clamping would park it at an end and stop producing crossings.
        //
        // Detection is a wrap of the playhead's position measured relative to
        // that point — any jump larger than half a cycle. That happens exactly
        // once per cycle in EITHER direction, so a negative (bipolar) rate
        // still yields one capture per cycle with no |velocity| special case.
        // The clock and the relative position update EVERY frame for edge
        // continuity; we only ACT on a wrap while actually recording with the
        // toggle armed, so arming mid-cycle can't emit a stale burst.
        let twoPiTrigger: Float = 2.0 * 3.14159265
        captureTriggerAccumulator += deltaTime * curvedRate(live.stopMotionTriggerRate, 60.0)
        if captureTriggerAccumulator > twoPiTrigger * 1024.0 || captureTriggerAccumulator < -twoPiTrigger * 1024.0 {
            // Keep long takes from drifting into Float precision loss: wrap the
            // accumulator itself once it's far from zero. Wrapping on a whole
            // number of cycles keeps the phase continuous through the reset.
            captureTriggerAccumulator -= twoPiTrigger * 1024.0 * (captureTriggerAccumulator > 0 ? 1.0 : -1.0)
        }

        // M19: the capture point is swept by the GEARED tap, not the image
        // bus. `lfoValue` (used by every image destination above) is unchanged
        // and still reads the main accumulators, so gearing this costs the
        // image nothing.
        let captureBus = evaluateBus(
            captureLfoPhaseAccumulator,
            captureLfo2PhaseAccumulator + live.lfo2PhaseOffset * 2.0 * 3.14159265,
            live
        )
        let modCapturePoint = live.stopMotionCapturePhase + captureBus * live.lfoToCapturePhase * 0.5
        let capturePoint = modCapturePoint - floor(modCapturePoint)

        let playheadRaw = captureTriggerAccumulator / twoPiTrigger
        let playhead = playheadRaw - floor(playheadRaw)
        let relative = playheadRaw - capturePoint
        let relativePos = relative - floor(relative)
        let cycleWrapped = abs(relativePos - captureTriggerPosPrev) > 0.5
        captureTriggerPosPrev = relativePos

        if isStopMotion, live.stopMotionLFOTrigger > 0.5 {
            // Display-only, and only while the meter is actually on screen.
            frameCapture.noteTriggerScope(playhead: playhead, marker: capturePoint)
            if captureInterval > 0, cycleWrapped {
                wantsRecordFrame = true
            }
        }

        // ---- M16: family destinations ----
        // Member 0 of every family is the un-offset bus — bit-identical to
        // the single flat bus this replaces. Every other member is one more
        // busSpread step around the waveform. Every depth constant below is
        // carried over UNCHANGED from the slider it replaces.

        // Rotation AMPLITUDE. Torsion Strength leads (bipolar, no 0-floor, as
        // before); Rotation 2 Strength is new reach — it never had an LFO
        // destination before M16 — clamped into its own -3...3 slider range.
        p.torsionStrength = live.torsionStrength + busMember(0, live) * live.lfoToRotation * 1.5
        p.spiral2Strength = clamp(
            live.spiral2Strength + busMember(1, live) * live.lfoToRotation * 1.5,
            -3.0, 3.0
        )

        // ---- Rotation CENTER (2D) ----
        // Same structure as Mirror Center below: Rotation 1 takes the bus
        // vector straight (X, Y); Rotation 2 takes it axis-swapped (Y, X),
        // additionally rotated by busSpread. Both SUM on top of the hand
        // Center X/Y sliders, which is the CPU-side half of the contract —
        // the shader-side half is applyTorsion/applySpiral2 seeding their
        // orbit's `center` from these same uniforms and having Dynamic Orbit
        // ADD onto it rather than replace it, so orbit and bus-driven center
        // combine correctly whether Dynamic Orbit is on or off.
        let rotCenterDepth = live.lfoToRotationCenter * 0.5
        p.torsionCenterX = clamp(live.torsionCenterX + busVecX * rotCenterDepth, -1.0, 1.0)
        p.torsionCenterY = clamp(live.torsionCenterY + busVecY * rotCenterDepth, -1.0, 1.0)
        p.spiral2CenterX = clamp(live.spiral2CenterX + swapVecY * rotCenterDepth, -1.0, 1.0)
        p.spiral2CenterY = clamp(live.spiral2CenterY + swapVecX * rotCenterDepth, -1.0, 1.0)

        // Mirror AMPLITUDE. Unchanged depth and cubic-curve shaping; Mirror 2
        // now reads member 1, so at busSpread 1.0 the two seams counter-move
        // rather than only ever pulsing together.
        let modAmp1 = live.mirror1RippleAmpRaw + (busMember(0, live) * live.lfoToMirrors * 0.3)
        let modAmp2 = live.mirror2RippleAmpRaw + (busMember(1, live) * live.lfoToMirrors * 0.3)
        let sign1: Float = modAmp1 >= 0 ? 1.0 : -1.0
        let sign2: Float = modAmp2 >= 0 ? 1.0 : -1.0
        p.mirror1RippleAmp = sign1 * pow(abs(modAmp1), 3.0) * 0.4
        p.mirror2RippleAmp = sign2 * pow(abs(modAmp2), 3.0) * 0.4

        // ---- Mirror CENTER (2D) ----
        // Mirror 1 takes the bus vector straight: (X, Y). Mirror 2 takes
        // swapVecX/Y (hoisted above, shared with Rotation Center) — the same
        // vector AXIS-SWAPPED and rotated by busSpread. A swap is a
        // reflection about the diagonal, so wherever Mirror 1's center
        // travels, Mirror 2's travels the mirror image of that path — the
        // two seams pull apart and converge instead of sliding across the
        // frame together. This was M16's first true vector destination,
        // shipped the session before Rotation Center above joined it.
        //
        // Both SUM ON TOP of the hand-set center sliders — those stay an
        // offset, not a replacement, which is the M17 contract arriving early
        // for the one destination that already had its uniforms built (M14
        // Part 1). Clamped to the same +/-1 range the hand sliders use.
        // ZERO ShaderParams pads: these uniforms already exist.
        let centerDepth = live.lfoToMirrorCenter * 0.5
        p.mirror1CenterX = clamp(live.mirror1CenterX + busVecX * centerDepth, -1.0, 1.0)
        p.mirror1CenterY = clamp(live.mirror1CenterY + busVecY * centerDepth, -1.0, 1.0)
        p.mirror2CenterX = clamp(live.mirror2CenterX + swapVecY * centerDepth, -1.0, 1.0)
        p.mirror2CenterY = clamp(live.mirror2CenterY + swapVecX * centerDepth, -1.0, 1.0)

        // M16 revision: the Holes family is GONE. negativeSpaceThreshold and
        // rectification are plain passthroughs again — rectification's blip
        // low in its range reads as a hiccup under continuous modulation, so
        // both were withdrawn as destinations rather than papered over. The
        // hand controls are untouched.
        p.negativeSpaceThreshold = live.negativeSpaceThreshold
        p.rectification = live.rectification

        // Keying: three members, so Offset 3 sits at TWICE Offset 2's phase
        // angle. Threshold 1 leads and moves the whole three-keyer cluster as
        // a rigid group; the two offsets breathe the gaps, and because they
        // are one and two busSpread steps out they never move together.
        p.keyerThreshold1 = clamp(live.keyerThreshold1 + busMember(0, live) * live.lfoToKeying * 0.4, 0.0, 1.0)
        p.keyerOffset2 = clamp(live.keyerOffset2 + busMember(1, live) * live.lfoToKeying * 0.4, -1.0, 1.0)
        p.keyerOffset3 = clamp(live.keyerOffset3 + busMember(2, live) * live.lfoToKeying * 0.4, -1.0, 1.0)

        // M16's `lfoBusPrevious` write lived here, holding this frame's bus
        // vector for an M17 that was absorbed into M16 and never arrived. It
        // was written every frame and read by nothing. Removed under the
        // standing dead-code rule — an unused field is a claim about the
        // future that the roadmap does not support.

        // ---- Mirror oscillator phases ----
        let m1Speed = curvedRate(live.mirror1Speed, 5.0)
        let m2Speed = curvedRate(live.mirror2Speed, 5.0)
        m1PhaseAccumulator += phaseDelta * m1Speed
        m2PhaseAccumulator += phaseDelta * m2Speed
        p.mirror1Phase = m1PhaseAccumulator
        p.mirror2Phase = m2PhaseAccumulator

        // ---- Displacement mesh oscillator phases (M8 Phase A) ----
        dispPhaseXAccumulator += phaseDelta * curvedRate(live.dispSpeedX, 5.0)
        dispPhaseYAccumulator += phaseDelta * curvedRate(live.dispSpeedY, 5.0)
        p.dispPhaseX = dispPhaseXAccumulator
        p.dispPhaseY = dispPhaseYAccumulator

        // Displacement AMPLITUDE: X and Y amp, unchanged depth. At busSpread
        // 0.5 (quadrature) the two axes sit 90 degrees apart and the field
        // moves in CIRCLES rather than pulsing on a diagonal — a motion this
        // module could not reach at any amount setting before M16.
        p.dispAmpX = clamp(live.dispAmpX + busMember(0, live) * live.lfoToDisplacement * 0.25, -0.25, 0.25)
        p.dispFreqX = live.dispFreqX
        p.dispWaveTypeX = live.dispWaveTypeX
        p.dispLagX = live.dispLagX
        p.lumaModDispX = live.lumaModDispX

        p.dispAmpY = clamp(
            live.dispAmpY + busMember(1, live) * live.lfoToDisplacement * 0.25,
            -0.25, 0.25
        )
        p.dispFreqY = live.dispFreqY
        p.dispWaveTypeY = live.dispWaveTypeY
        p.dispLagY = live.dispLagY
        p.lumaModDispY = live.lumaModDispY

        p.dispRadialMode = live.dispRadialMode

        // ---- Displacement CENTER ----
        // Unlike Rotation and Mirror Center above, Displacement has only ONE
        // center — no second member to swap axes against or spread. Plain
        // single vector: X drives X, Y drives Y. Sums on top of the hand
        // Center X/Y sliders, same convention as the other two. This is the
        // one destination in the set with that asymmetry, and it comes from
        // the module having one anchor, not from a different rule.
        let dispCenterDepth = live.lfoToDispCenter * 0.5
        p.dispCenterX = clamp(live.dispCenterX + busVecX * dispCenterDepth, -1.0, 1.0)
        p.dispCenterY = clamp(live.dispCenterY + busVecY * dispCenterDepth, -1.0, 1.0)

        // M16 revision: Radial Push and Luma Source Staging are SEPARATE
        // destinations now, not one welded "Character" family. Both modulate
        // character rather than depth, which is true but was not a reason to
        // tie them together — Radial Push wants dialling in rarely and
        // deliberately, Luma Staging suits a slow constant drift. Each reads
        // the un-offset bus; neither has a partner to be spread against.
        //
        // Radial Push sweeps the displacement module between cartesian
        // shimmer and radial breathing.
        p.dispRadialPush = clamp(live.dispRadialPush + busMember(0, live) * live.lfoToRadialPush * 0.5, 0.0, 1.0)
        // Luma Source Staging sweeps every geometry module's luma modulator
        // between tracking the unwarped SOURCE and tracking the COMPOSITE
        // built so far. How much that drift is felt scales with how much luma
        // modulation the rest of the patch has dialled in — the depth is a
        // byproduct of the patch, not a separate number to tune.
        p.lumaStageDepth = clamp(live.lumaStageDepth + busMember(0, live) * live.lfoToLumaStage * 0.5, 0.0, 1.0)

        // ---- Hole-cutter modes (M8 Phase C.3 / C.4) ----
        // Collision (Displacement -> Holes) retired, M12 Part 7 cleanup.

        // M15: the five "carried for parity" writes are gone — parity is
        // positional, so pads at 105–109 hold the layout just as well. The
        // modulation itself all happens in the Global LFO block above.
        // ---- Mirror rotation ----
        if live.mirror1AutoSpinOn > 0.5 {
            m1AngleAccumulator += phaseDelta * curvedRate(live.mirror1AutoSpinSpeed, 2.0)
            p.mirror1Angle = m1AngleAccumulator
        } else {
            p.mirror1Angle = live.mirror1StaticAngle
            m1AngleAccumulator = live.mirror1StaticAngle
        }

        if live.mirror2AutoSpinOn > 0.5 {
            m2AngleAccumulator += phaseDelta * curvedRate(live.mirror2AutoSpinSpeed, 2.0)
            p.mirror2Angle = m2AngleAccumulator
        } else {
            p.mirror2Angle = live.mirror2StaticAngle
            m2AngleAccumulator = live.mirror2StaticAngle
        }

        // ---- Active source ----
        switch sourceManager.activeSource {
        case .procedural: p.sourceType = 0.0
        case .camera:     p.sourceType = 1.0
        case .videoFile:  p.sourceType = 2.0
        }

        // ---- Encode ----
        guard let buffer = queue.makeCommandBuffer() else { return }

        // M24: M20's per-frame GPU-timing completion handler used to sit here.
        // It has been REMOVED along with the GPU figure it fed. M23 answered
        // the question it existed for — and answered it against the theory
        // that motivated it: 640x480 at 0.9 ms GPU produced a worse
        // worst-frame than Native at 6.8 ms, which rules out render cost as a
        // factor in the residual and closes off "make it cheaper" as a
        // direction. Removing it also takes an unconditional per-frame closure
        // allocation back out of the loop.
        //
        // The capture blit's own completion handler further down is unrelated
        // and stays — it is added only on frames that actually capture, and it
        // is load-bearing for the staging pool, not diagnostic.

        // ---- PASS 1: synth -> offscreen texture ----
        // Identical to the old single pass in every respect except the render
        // target. Cleared to black rather than .dontCare: on this GPU the clear
        // is essentially free at tile-init, and it keeps undefined contents
        // from ever being a question for a pass that renders less than the
        // full frame.
        let synthPass = MTLRenderPassDescriptor()
        synthPass.colorAttachments[0].texture = offscreen
        synthPass.colorAttachments[0].loadAction = .clear
        synthPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        synthPass.colorAttachments[0].storeAction = .store

        if let encoder = buffer.makeRenderCommandEncoder(descriptor: synthPass) {
            encoder.setRenderPipelineState(synthPipeline)
            encoder.setFragmentBytes(&p, length: MemoryLayout<ShaderParams>.stride, index: 0)

            if let liveTexture = sourceManager.acquireFrameTexture() {
                encoder.setFragmentTexture(liveTexture, index: 0)
            } else {
                encoder.setFragmentTexture(nil, index: 0)
            }

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // ---- M4.1/M4.2: OPTIONAL CAPTURE BLIT (offscreen -> staging CVPixelBuffer) ----
        // Encoded when EITHER a screenshot was requested OR this draw's pacing
        // accumulator (above) decided a recording frame is due. acquireStagingTexture()
        // returns nil on every other frame after a lock + Bool test, so the
        // idle hot path — not recording, no pending screenshot — is untouched,
        // same cost as 4.1 alone.
        //
        // It lives HERE — after pass 1 (and after any future output pass,
        // active), before the drawable is acquired — rather than after
        // pass 2, so we never encode work into the command buffer after
        // present(drawable) has been called. Both orderings read the same
        // finished offscreen texture; this one keeps present semantics
        // unambiguous and doesn't extend how long we hold a drawable.
        //
        // IF YOU EVER ADD A PASS AFTER PASS 1 that renders into its own
        // texture: this blit and the present pass below must BOTH be pointed
        // at that new texture, in the same edit. M5's glow proved the failure
        // mode — the capture tap kept reading pass 1's target and silently
        // dropped the effect from every recording and screenshot while it
        // stayed visible on screen, which reads as a recorder regression
        // rather than an ordering mistake in the new stage. M12 removed glow
        // and, with it, a `finalTexture` alias that had stopped aliasing
        // anything; the requirement is a rule about edits, not a variable.
        //
        // It must be in THIS command buffer: the offscreen texture is overwritten by
        // the very next frame, so buffer ordering is what guarantees we copy
        // the frame the user actually asked for. A dropped recording frame
        // (pool exhausted, writer backed up) is handled INSIDE
        // acquireStagingTexture via FrameCapture's own drop counter — it
        // returns nil in that case just like "nothing pending", so no
        // special handling is needed here beyond the existing screenshot
        // failure path.
        if let staging = frameCapture.acquireStagingTexture(width: offscreen.width, height: offscreen.height, wantsRecordFrame: wantsRecordFrame) {
            if let blit = buffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: offscreen,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: offscreen.width, height: offscreen.height, depth: 1),
                    to: staging,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                // On Apple Silicon the IOSurface-backed staging texture is
                // .shared and this is a no-op path. On an Intel/discrete Mac it
                // can come back .managed, where skipping the synchronize means
                // the CPU reads stale bytes — a classic "works on my machine"
                // screenshot bug. Cheap insurance, only on captured frames.
                if staging.storageMode == .managed {
                    blit.synchronize(resource: staging)
                }
                blit.endEncoding()

                // File I/O happens on FrameCapture's serial queue, never here.
                buffer.addCompletedHandler { [weak frameCapture] _ in
                    frameCapture?.captureDidComplete()
                }
            } else {
                frameCapture.captureDidFail("Could not create the capture blit encoder.")
            }
        }

        // ---- PRESENT PASS: offscreen -> drawable ----
        // (Pass 2 of 2 — the numbering
        // shifts but this pass's own job never changes: a blit, letterbox-
        // fitted since M18, never the composite seat.) The drawable is
        // acquired HERE, after pass 1 is already encoded,
        // not at the top of draw(): holding a drawable longer than necessary
        // is a known stall source. If it comes back nil we still commit —
        // the render already happened and the offscreen texture is valid, so that's a
        // dropped DISPLAY frame, not a dropped render. That's also the
        // behavior M4 wants: the recorder taps the offscreen texture directly, not
        // the drawable, so a screenshot requested on a frame the display
        // missed still saves correctly.
        if let drawable = view.currentDrawable,
           let presentPass = view.currentRenderPassDescriptor,
           let encoder = buffer.makeRenderCommandEncoder(descriptor: presentPass) {
            encoder.setRenderPipelineState(blitPipeline)
            encoder.setFragmentTexture(offscreen, index: 0)

            // M18: aspect-fit the offscreen texture (render size) inside the
            // drawable (window size) — a viewport call, no shader math. This
            // is a no-op letterbox (full-drawable viewport) whenever the two
            // already match, which is the ONLY case that also selects the
            // nearest sampler below; everywhere else gets bars and linear
            // filtering. Origins/sizes are rounded to whole pixels so the
            // frame edge doesn't pick up a half-texel seam.
            let drawableSize = view.drawableSize
            let drawableW = drawableSize.width
            let drawableH = drawableSize.height
            let renderW = Double(offscreen.width)
            let renderH = Double(offscreen.height)

            let isExactFit = Int(drawableW.rounded()) == offscreen.width
                && Int(drawableH.rounded()) == offscreen.height

            if isExactFit {
                // Native's own case: full viewport, no scissor needed beyond
                // the drawable's own bounds, nearest sampler — bit-identical
                // to pre-M18.
                encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                                 width: Double(drawableW), height: Double(drawableH),
                                                 znear: 0, zfar: 1))
                encoder.setFragmentSamplerState(nearestSampler, index: 0)
            } else {
                let fitScale = min(Double(drawableW) / renderW, Double(drawableH) / renderH)
                let fitW = (renderW * fitScale).rounded()
                let fitH = (renderH * fitScale).rounded()
                let fitX = ((Double(drawableW) - fitW) / 2.0).rounded()
                let fitY = ((Double(drawableH) - fitH) / 2.0).rounded()

                encoder.setViewport(MTLViewport(originX: fitX, originY: fitY,
                                                 width: fitW, height: fitH,
                                                 znear: 0, zfar: 1))
                // Scissor matches the viewport so nothing outside the fit
                // rect is touched — belt-and-suspenders alongside the
                // viewport clip, and the same reasoning M2's vignette
                // comments already use for "don't depend on reading the clip
                // spec exactly right."
                encoder.setScissorRect(MTLScissorRect(x: Int(fitX), y: Int(fitY),
                                                       width: Int(fitW), height: Int(fitH)))
                encoder.setFragmentSamplerState(linearSampler, index: 0)
            }

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            // M23: this line is the actual fix — the only line that CHANGES
            // anything about presentation. The cadence meter that found the
            // bug was removed in M22 once it had nothing left to answer.
            //
            // Without a minimum duration, present(drawable) goes out on the
            // very next vsync after the buffer is ready — so once frames got
            // cheap enough in Release, some landed one panel slot after the
            // last present and some landed two, a live mix of 8.33ms/16.67ms
            // presentation intervals. Every phase accumulator in the
            // instrument integrates that measured interval, so a one-slot
            // frame advanced the picture HALF as far as a two-slot frame.
            // Presentation stayed perfectly on vsync throughout, which is
            // exactly why it looked clean and moved unevenly.
            //
            // afterMinimumDuration asks the system not to present sooner than
            // `holdDuration` after the last present.
            //
            // M23 REVISION — the first attempt subtracted HALF A PANEL SLOT
            // from the target period, on the theory that the system would
            // snap the present UP to the next vsync and the margin would stop
            // it sitting exactly on a slot boundary. Hardware said otherwise.
            // On this display the minimum is honoured LITERALLY and there is
            // no snap: a 12.5 ms hold produced 61-66 fps (an 80 fps cap), not
            // the intended 60. Proof from the readout's own figures — if
            // frames sat on whole 120 Hz slots then fps x cadence would read
            // 120.0, and across four takes it read 124, 133, 126 and 130.
            //
            // So the hold has to BE the target period; it cannot rely on
            // rounding to get there. The epsilon is float safety only —
            // enough to stay off an exact boundary if some other display DOES
            // snap, far too small to affect the rate (it caps at 60.4 rather
            // than 60.0).
            //
            //   holdDuration = targetPeriod - epsilon
            //
            // This also stopped depending on the panel's reported refresh
            // rate, which is `maximumFramesPerSecond` and is NOT what an
            // adaptive panel is necessarily running at moment to moment — a
            // dependency that was wrong in the same way the half-slot margin
            // was. M24 finished the job: the jitter meter was the last reader
            // of that reading, so with it gone the renderer no longer asks
            // the display anything at all.
            //
            // This alone can pace the loop by BLOCKING inside
            // view.currentDrawable on the next draw() if MTKView keeps
            // calling draw() faster than presents are allowed out — which is
            // why AppController's MetalView also sets
            // preferredFramesPerSecond = cadenceTargetFPS (M23) beside this.
            let targetPeriod = 1.0 / Double(Self.cadenceTargetFPS)
            let holdDuration = targetPeriod - 0.0001
            buffer.present(drawable, afterMinimumDuration: max(holdDuration, 0.0))
        }

        buffer.commit()
    }
}



















