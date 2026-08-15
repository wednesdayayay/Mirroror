import Foundation
import Combine
import Metal
import CoreVideo
import CoreGraphics
import CoreMedia
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import AppKit

// MARK: - Recorder UI State
// Event-driven only, per the M4.1 rule: nothing here is a continuous value, so
// @Published invalidation is confined to the Recording section and never
// fires mid-slider-drag. recordFPS is NOT here; it's a continuous,
// render-thread-read value and lives in ParamStore per the established rule.
//
// M20 Part 2 SPLIT THIS OBJECT IN TWO, and the reason is worth stating
// plainly because the original reasoning was wrong in a way that cost real
// frames. Everything left on RecorderState publishes ONLY on a user action —
// picking a folder, pressing a transport button, switching Output Resolution.
// The five PERIODIC counters (elapsed, frames, and the three drop figures)
// moved to RecorderProgress below.
//
// The old note here said the once-per-second publish was safe because it was
// "confined to the Recording section." That confinement is real, and it is
// not sufficient: MTKView calls draw() on the MAIN THREAD, so anything that
// re-lays-out that section — two AppKit-backed .menu Pickers, two segmented
// Pickers, a TextField, the transport, and in stop-motion two ParamSliders —
// is subtracted directly from the render loop's frame budget. Measured at
// Native, a periodic full-section invalidation was producing ~50 ms frames
// and costing about 4 fps. Confining a publish to one section is only worth
// anything if that section is small.
final class RecorderState: ObservableObject {
    @Published var outputDirectoryName: String = ""
    @Published var status: String = ""
    @Published var lastSavedName: String = ""

    @Published var transport: TransportState = .idle

    // M18: live "what size am I actually working at" readout, e.g.
    // "1280 × 720". Published on CHANGE only by notePotentialSize — never a
    // per-frame publisher, matching every other field on this object. Empty
    // until the first draw() call reports a size, same startup window
    // recordFPS's "→ N fps" caption already has.
    @Published var frameSizeText: String = ""
}

// MARK: - Recorder progress (M20 Part 2)
//
// The counters that tick DURING a take, on their own object so that the only
// thing observing them can be a leaf view. Nothing that lays out a control
// may observe this object.
//
// Publish cadence is unchanged from before the split — long-form still
// publishes at most once per second, on the elapsed-second change; stop-motion
// still publishes per captured frame because captures there are sparse. What
// changed is the blast radius of each publish: one HStack of Text instead of
// the whole Recording section.
final class RecorderProgress: ObservableObject {
    @Published var elapsedSeconds: Int = 0
    @Published var recordedFrameCount: Int = 0
    @Published var dropCount: Int = 0

    // M4.4 Part C1: the same drops, SPLIT BY REASON. dropCount above stays
    // the total (nothing that reads it needs changing); these two say which
    // half of the pipeline gave up, which is the whole point — before this,
    // every drop looked identical no matter where it came from.
    //
    //   dropsPool   — dequeuePooledTexture returned nil. The pool had no free
    //                 buffer. The GPU side is producing frames faster than the
    //                 writer is releasing them; raising pool depth is the
    //                 lever.
    //   dropsWriter — the AVAssetWriterInput wasn't ready for more data, or
    //                 append() refused. The encoder or the DISK is the
    //                 bottleneck; codec settings or a faster volume is the
    //                 lever.
    //
    // Published on the same main-thread hop the total already used, so this
    // adds no new publish traffic — it widens an existing one.
    @Published var dropsPool: Int = 0
    @Published var dropsWriter: Int = 0
}

enum TransportState {
    case idle
    case recording
    case paused
    case finishing
}

// MARK: - Frame Capture (M4 Phase 4.1 screenshot + Phase 4.2 long-form/cassette)
//
// 4.1 kept exactly one staging CVPixelBuffer behind an `inFlight` bool — fine
// for a single screenshot, a real data race at 30-60 captures/sec (the GPU
// could start writing frame N+1 into the surface AVAssetWriter is still
// reading frame N from). 4.2 replaces that with a CVPixelBufferPool sized to
// the offscreen texture, shared by BOTH the screenshot path and the recording
// path. A screenshot requested on a frame that's also a recording frame
// shares the same pooled buffer with both consumers — one blit, one copy.
//
// Presentation timestamps are a captured-frame COUNT, never wall-clock (house
// rule, and the entire cassette pause/resume behavior falls out of it for
// free): pause stops the counter from advancing, so resume continues the same
// clip with no seam. A dropped frame (writer backed up / pool exhausted)
// still advances the counter, leaving a PTS gap — AVFoundation holds the
// previous frame over that gap, so total clip duration stays true to the real
// performance instead of speeding up.
final class FrameCapture {
    let device: MTLDevice
    let state = RecorderState()

    // M20 Part 2: the periodic counters, on their own observable so a publish
    // during a take reaches only RecordingIndicator and not the section that
    // owns the pickers. See the comment on RecorderProgress.
    let progress = RecorderProgress()

    // MARK: Screenshot request (unchanged shape from 4.1)
    private let lock = NSLock()
    private var screenshotPending = false
    private var screenshotInFlight = false

    // MARK: Stop-motion manual trigger (new in 4.3)
    // A one-shot request set on the main thread by the Capture Frame button and
    // CONSUMED atomically inside acquireStagingTexture — checked and cleared in
    // the SAME locked section that begins acting on it, the exact shape the 4.2
    // runaway-screenshot bug taught (check-without-clear is what let one press
    // refire forever). Additive to the LFO auto-trigger.
    private var stopMotionCapturePending = false

    // MARK: Recording transport (new in 4.2)
    private var transportState: TransportState = .idle
    private var lockedFPS: Double = 30.0
    // Snapshotted at Record (like lockedFPS). Used ONLY for the progress-publish
    // throttle in noteProgress — stop-motion captures are sparse, so they
    // publish every frame for feedback rather than being throttled to 1/sec.
    // The capture-trigger PATH itself is chosen by the renderer from the live
    // store value, not from this — this exists purely for display cadence.
    private var lockedStopMotion: Bool = false
    private var frameIndex: Int64 = 0
    private var dropCounter: Int = 0
    // M4.4 Part C1: the same total, split by cause. See RecorderProgress's
    // dropsPool/dropsWriter for what each one means.
    private var dropCounterPool: Int = 0
    private var dropCounterWriter: Int = 0
    private var recordingSize: (width: Int, height: Int) = (0, 0)

    /// M4.4 Part A: the codec locked in for the current take, snapshotted at
    /// Record exactly like `lockedFPS`. 0 = H.264, 1 = ProRes 422 HQ,
    /// 2 = ProRes 4444. Nothing reads the live store value after Record — the
    /// UI also disables the picker mid-take as a second line of defense, the
    /// same belt-and-braces treatment Frame Rate and Output Resolution get.
    private var lockedCodec: Int = 0

    /// M4.4 Part B / Q3: whether the vignette matte is currently being written
    /// into alpha. Reported every frame by the renderer via
    /// `noteAlphaEnabled` (change-only, same shape as notePotentialSize) and
    /// read ONLY by writePNG, to decide whether a screenshot preserves the
    /// alpha channel or discards it exactly as it always has.
    ///
    /// Deliberately NOT part of the take snapshot: the recording path doesn't
    /// consult it at all (the alpha either is or isn't in the pixels the
    /// shader produced, and the codec decides whether the file can carry it),
    /// and a screenshot is a one-frame event that should reflect the state of
    /// the instrument at the instant it was pressed.
    private var alphaEnabled = false

    /// Read by LiquidRenderer's pacing accumulator every frame. 0 unless
    /// actively recording — paused returns 0 too, so the renderer's
    /// accumulator simply stops accumulating rather than needing its own
    /// pause awareness.
    var activeFrameInterval: Double {
        lock.lock()
        defer { lock.unlock() }
        return transportState == .recording ? (1.0 / lockedFPS) : 0.0
    }

    // MARK: Shared staging pool
    private var textureCache: CVMetalTextureCache?
    private var pixelBufferPool: CVPixelBufferPool?

    // M18: the size the CURRENT POOL was actually built at. Written ONLY by
    // rebuildPool. Before M18 this doubled as "the renderer's current render
    // size" too, since the two were always the same number — see
    // notedWidth/notedHeight below, which now own that role exclusively.
    // dequeuePooledTexture's rebuild-vs-reuse decision is the only thing that
    // should ever read these two.
    private var poolWidth = 0
    private var poolHeight = 0

    // M18: the render size the RENDERER is currently reporting, via
    // notePotentialSize, every frame. This is what record(fps:)'s readiness
    // check and beginWriterSession's writer configuration read — NEVER
    // poolWidth/poolHeight above, which can lag behind whenever the Output
    // Resolution setting changes but no capture has happened yet at the new
    // size to force a pool rebuild. Before M18 that lag was invisible because
    // render size never changed independent of a capture; M18 makes it
    // possible, and this split is what fixes the latent bug (see the M18
    // plan, §3): notePotentialSize used to stop updating anything at all once
    // a pool existed, so a resolution switch after the first capture would
    // silently configure the writer at the OLD size.
    private var notedWidth = 0
    private var notedHeight = 0

    // Buffer most recently dequeued from the pool. Written and read only
    // within a single acquireStagingTexture call on the render thread, so it
    // needs no lock of its own — it exists purely to hand the buffer from
    // dequeuePooledTexture's out-of-band CVPixelBuffer back to its caller
    // without changing that helper's MTLTexture-only return type.
    private var lastDequeuedBuffer: CVPixelBuffer?

    // Capture work handed from acquireStagingTexture (render thread) to
    // captureDidComplete (Metal's completion-handler thread, which may not be
    // the render thread and is NOT guaranteed to serialize against the next
    // draw() call). A frame N+1 draw() can dequeue a new buffer before frame
    // N's completion handler has consumed the previous entry, so this is a
    // lock-protected FIFO queue rather than bare overwritable ivars — the
    // bug the first pass at this file had.
    private struct PendingCaptureWork {
        var screenshotBuffer: CVPixelBuffer?
        var recordBuffer: CVPixelBuffer?
        var recordIndex: Int64?
    }
    private var pendingWork: [PendingCaptureWork] = []

    // MARK: AVFoundation writer (recording only)
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var finalizeGroup: DispatchGroup?
    private var currentTakeURL: URL?

    // MARK: Progress publishing throttle + elapsed-time bookkeeping
    // `pausedAccumulatedSeconds` holds the whole-second count banked from all
    // PRIOR recording segments in this take (i.e. before the most recent
    // Resume). `recordingStartWallClock` is the wall-clock instant the
    // CURRENT segment began (Record, or the most recent Resume); nil while
    // paused. Elapsed = banked + (now - segmentStart) while recording, or
    // just banked while paused/idle. This is display-only bookkeeping — it
    // never touches presentation timestamps, which come solely from
    // frameIndex.
    private var lastPublishedSecond: Int = -1
    private var recordingStartWallClock: Date?
    private var pausedAccumulatedSeconds: Int = 0

    private let ioQueue = DispatchQueue(label: "com.mirroror.capture.io", qos: .utility)

    // MARK: - Trigger scope (M4.3b): renderer -> UI display channel
    //
    // Deliberately behind its OWN lock, not the transport `lock` above. This is
    // written every frame while stop-motion auto-trigger is armed and read on a
    // ~15Hz UI timer; routing that through the transport lock would add steady
    // contention to the capture-critical path for what is purely cosmetic data.
    // A separate lock has no ordering relationship with the other one (neither
    // is ever taken while holding the other), so there is nothing to deadlock.
    //
    // This is display-only and must stay that way: NOTHING in the render path
    // or the writer reads it back. It is also the reverse direction of
    // ParamStore (renderer -> UI rather than UI -> renderer), which is why it
    // lives here rather than being bolted onto ParamStore's contract.
    private let scopeLock = NSLock()
    private var scopePlayhead: Float = 0.0
    private var scopeMarker: Float = 0.0

    /// Called from the render thread, only while stop-motion auto-trigger is
    /// armed (cost is nil otherwise — the renderer skips the call entirely).
    /// `playhead` is the trigger clock's position through its cycle (0...1);
    /// `marker` is the LFO-modulated capture point it fires on.
    func noteTriggerScope(playhead: Float, marker: Float) {
        scopeLock.lock()
        scopePlayhead = playhead
        scopeMarker = marker
        scopeLock.unlock()
    }

    /// Read by the Recording section's local scope-meter timer.
    var triggerScope: (playhead: Float, marker: Float) {
        scopeLock.lock()
        defer { scopeLock.unlock() }
        return (scopePlayhead, scopeMarker)
    }

    private let bookmarkKey = "MirrororOutputDirectoryBookmark"
    private var outputDirectory: URL?
    private var scopedDirectory: URL?

    private let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        restoreOutputDirectory()
    }

    deinit {
        scopedDirectory?.stopAccessingSecurityScopedResource()
    }

    // =====================================================================
    // MARK: - UI-facing API (main thread)
    // =====================================================================

    func requestScreenshot() {
        if outputDirectory == nil {
            chooseOutputDirectory()
            guard outputDirectory != nil else {
                post(status: "Pick an output folder first.")
                return
            }
        }

        lock.lock()
        screenshotPending = true
        lock.unlock()

        post(status: "Capturing…")
    }

    /// M4.3: main-thread one-shot for a single stop-motion frame. Only arms the
    /// flag while a take is actually recording — a press while idle/paused/
    /// finishing is a no-op (the UI also disables the button unless recording),
    /// so a stale press can never fire into a later take. The flag is consumed
    /// and cleared atomically inside acquireStagingTexture.
    func requestStopMotionFrame() {
        lock.lock()
        if transportState == .recording { stopMotionCapturePending = true }
        lock.unlock()
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Mirroror saves screenshots and recordings."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(directory: url)
        persistBookmark(for: url)
    }

    /// Locks in `fps` for the whole take. The renderer reads
    /// `activeFrameInterval` (derived from `lockedFPS`), never the live store
    /// value, so changing the picker mid-recording cannot desync
    /// already-written timestamps — the UI also disables the picker while
    /// recording as a second line of defense.
    /// M4.4 Part A: `codec` joins fps and stopMotion as take-scoped state read
    /// once, here, and snapshotted for the life of the take. 0 = H.264,
    /// 1 = ProRes 422 HQ, 2 = ProRes 4444.
    func record(fps: Double, stopMotion: Bool, codec: Int) {
        guard transportState == .idle else { return }

        guard let directory = outputDirectory else {
            post(status: "Pick an output folder first.")
            return
        }

        // Pre-flight write test. Given the confirmed TCC constraint (writes to
        // folders inside Desktop/Documents/Downloads can fail at the OS level
        // even with a valid security-scoped bookmark — see M4.1 notes), we
        // refuse to start rather than discover the failure at finalize and
        // lose the whole take.
        let probeURL = directory.appendingPathComponent(".mirroror_write_probe")
        do {
            try Data().write(to: probeURL)
            try FileManager.default.removeItem(at: probeURL)
        } catch {
            post(status: "Can't write to this folder (\(directory.lastPathComponent)). " +
                 "Folders inside Desktop, Documents, or Downloads are sometimes blocked by " +
                 "macOS even when permitted — try a different folder.")
            return
        }

        // M18: read the RENDERER's reported size, not the pool's — see the
        // note at notedWidth's declaration. The pool itself is allowed to
        // still be at a stale size here; dequeuePooledTexture rebuilds it on
        // the first capture of the take regardless.
        lock.lock()
        let sizeReady = notedWidth > 0 && notedHeight > 0
        lock.unlock()
        guard sizeReady else {
            post(status: "Not ready yet — try again in a moment.")
            return
        }

        lock.lock()
        lockedFPS = min(max(fps, 1.0), 120.0)
        lockedStopMotion = stopMotion
        // M4.4: clamped to the three known tags rather than trusted, so a bad
        // value fails safe to H.264 (the codec that has always worked) rather
        // than into an AVFoundation error at writer-init time.
        lockedCodec = (codec >= 0 && codec <= 2) ? codec : 0
        frameIndex = 0
        dropCounter = 0
        dropCounterPool = 0
        dropCounterWriter = 0
        lastPublishedSecond = -1
        pausedAccumulatedSeconds = 0
        recordingStartWallClock = Date()
        lock.unlock()

        guard beginWriterSession(in: directory) else {
            post(status: "Could not start the recording file.")
            lock.lock()
            recordingStartWallClock = nil
            lock.unlock()
            return
        }

        lock.lock()
        transportState = .recording
        lock.unlock()

        DispatchQueue.main.async {
            self.state.transport = .recording
            self.progress.recordedFrameCount = 0
            self.progress.elapsedSeconds = 0
            self.progress.dropCount = 0
            self.progress.dropsPool = 0
            self.progress.dropsWriter = 0
            self.state.status = "Recording…"
        }
    }

    func pause() {
        lock.lock()
        guard transportState == .recording else { lock.unlock(); return }
        transportState = .paused
        if let start = recordingStartWallClock {
            pausedAccumulatedSeconds += Int(Date().timeIntervalSince(start).rounded(.down))
        }
        recordingStartWallClock = nil
        lock.unlock()

        DispatchQueue.main.async {
            self.state.transport = .paused
            self.state.status = "Paused"
        }
    }

    func resume() {
        lock.lock()
        guard transportState == .paused else { lock.unlock(); return }
        transportState = .recording
        recordingStartWallClock = Date()
        lock.unlock()

        DispatchQueue.main.async {
            self.state.transport = .recording
            self.state.status = "Recording…"
        }
    }

    func stop() {
        lock.lock()
        guard transportState == .recording || transportState == .paused else { lock.unlock(); return }
        transportState = .finishing
        lock.unlock()

        DispatchQueue.main.async {
            self.state.transport = .finishing
            self.state.status = "Finishing…"
        }

        finalizeTake(reason: nil)
    }

    /// Called from LiquidRenderer.mtkView(_:drawableSizeWillChange:) when the
    /// window resizes during an active take. Auto-finalizes cleanly rather
    /// than continuing with a cropped/letterboxed frame (confirmed
    /// preference).
    func handleResizeDuringRecording() {
        lock.lock()
        let wasActive = (transportState == .recording || transportState == .paused)
        if wasActive { transportState = .finishing }
        lock.unlock()

        guard wasActive else { return }

        DispatchQueue.main.async {
            self.state.transport = .finishing
            self.state.status = "Finishing…"
        }
        finalizeTake(reason: "Recording stopped: window resized")
    }

    /// Called from the app-termination hook (MirrororApp.swift) if a take is
    /// in progress. Blocks the caller briefly on the finalize group so the
    /// file is flushed before the process actually exits.
    func finalizeForTermination() {
        lock.lock()
        let wasActive = (transportState == .recording || transportState == .paused)
        if wasActive { transportState = .finishing }
        lock.unlock()

        guard wasActive else { return }

        let waitGroup = DispatchGroup()
        waitGroup.enter()
        finalizeTake(reason: "Recording stopped: app quit") {
            waitGroup.leave()
        }
        // Runs on the main thread during applicationWillTerminate, so this
        // must be bounded rather than an unconditional wait.
        _ = waitGroup.wait(timeout: .now() + 3.0)
    }

    // =====================================================================
    // MARK: - Renderer-facing API (render thread, inside draw())
    // =====================================================================

    /// Called every frame with the offscreen texture's current size — NOT
    /// gated behind a pending screenshot/recording request. This is what lets
    /// Record work correctly the very first time it's pressed, before any
    /// capture has ever happened, AND (M18) the first time after an Output
    /// Resolution change, before any new capture has forced the pool to
    /// rebuild at the new size. Unlike the pre-M18 version, this now updates
    /// notedWidth/notedHeight EVERY time they change, for the life of the
    /// app — not just "until a pool first exists," which was the latent bug
    /// (see the M18 plan, §3, and the note at notedWidth's declaration). Cost
    /// when size hasn't changed is a lock plus two int comparisons.
    func notePotentialSize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }

        lock.lock()
        let changed = notedWidth != width || notedHeight != height
        if changed {
            notedWidth = width
            notedHeight = height
        }
        lock.unlock()

        // M18: publish the live "→ W × H" readout — change-only, matching
        // every other publish on RecorderState, so a window-resize drag in
        // Native mode (which can call this every frame while dragging) still
        // can't turn into a per-frame SwiftUI publisher.
        guard changed else { return }
        let text = "\(width) × \(height)"
        DispatchQueue.main.async {
            self.state.frameSizeText = text
        }
    }

    /// M4.4 Part B (Q3): called every frame from draw(), right beside
    /// notePotentialSize, reporting whether the vignette is currently writing
    /// its matte into alpha. Same shape and same near-zero cost as its
    /// neighbour — a lock plus one Bool comparison, with no publish at all
    /// (nothing in the UI needs to observe this; only writePNG reads it).
    ///
    /// This is the ONLY thing the screenshot path needs in order to preserve
    /// alpha, which is why it's a single Bool rather than a snapshot: the
    /// pixels already carry the matte by the time they reach the pool.
    func noteAlphaEnabled(_ enabled: Bool) {
        lock.lock()
        if alphaEnabled != enabled { alphaEnabled = enabled }
        lock.unlock()
    }

    /// Lock + Bool test shape, matching 4.1: nearly free when nothing is
    /// pending. Returns a staging texture to blit into, or nil if there's
    /// nothing to capture this frame. `wantsRecordFrame` is computed by the
    /// renderer's pacing accumulator; this function does not re-derive timing.
    func acquireStagingTexture(width: Int, height: Int, wantsRecordFrame: Bool) -> MTLTexture? {
        lock.lock()
        let doScreenshot = screenshotPending && !screenshotInFlight
        let recording = transportState == .recording
        // Consume the manual stop-motion one-shot in the SAME critical section
        // that acts on it: check AND clear atomically, never check under one
        // lock and clear under another (the 4.2 runaway-screenshot lesson). A
        // frame triggered by the LFO edge (wantsRecordFrame) and a manual press
        // landing together still produce exactly ONE record frame — the OR
        // collapses them, so frameIndex bumps once.
        let manualStopMotion = recording && stopMotionCapturePending
        if manualStopMotion { stopMotionCapturePending = false }
        let doRecordFrame = recording && (wantsRecordFrame || manualStopMotion)
        if doScreenshot {
            // Atomically CONSUME the request: clear pending AND set in-flight
            // in the same critical section. Without the `screenshotPending = false`
            // step, captureDidComplete's later clearScreenshotInFlight() would
            // leave pending still true — and the very next draw would fire
            // another capture, then another, forever. That was the runaway
            // screenshot bug (~292 files from one button press).
            screenshotPending = false
            screenshotInFlight = true
        }
        lock.unlock()

        guard doScreenshot || doRecordFrame else { return nil }

        guard let texture = dequeuePooledTexture(width: width, height: height) else {
            // No pendingWork entry exists yet for this attempt — nothing was
            // queued, so this is a plain flag reset + status post, NOT the
            // pop-and-release path captureDidFail(_:) below uses. Calling
            // that here would incorrectly pop and misinterpret a DIFFERENT,
            // legitimately-queued entry from an earlier frame.
            if doScreenshot { failScreenshotBeforeQueued("Could not allocate the capture buffer.") }
            // Pool exhaustion: dequeuePooledTexture returned nil.
            if doRecordFrame { noteDroppedFrame(.pool) }
            return nil
        }

        var work = PendingCaptureWork()
        work.screenshotBuffer = doScreenshot ? lastDequeuedBuffer : nil

        var shouldEnterFinalizeGroup = false
        lock.lock()
        if doRecordFrame {
            work.recordBuffer = lastDequeuedBuffer
            work.recordIndex = frameIndex
            frameIndex += 1
            shouldEnterFinalizeGroup = true
        }
        pendingWork.append(work)
        lock.unlock()

        // finalizeGroup is only ever replaced (new take) from the main thread
        // while transportState == .idle, and we've just confirmed .recording
        // under the lock, so reading it here without the lock is safe — the
        // group reference itself can't change out from under an
        // active take.
        if shouldEnterFinalizeGroup {
            finalizeGroup?.enter()
        }

        return texture
    }

    /// Called from acquireStagingTexture ONLY, when dequeuePooledTexture
    /// itself returned nil for a pending screenshot — i.e. BEFORE any
    /// PendingCaptureWork was appended to the queue for this attempt. Just
    /// resets the in-flight flag and posts a status message; does NOT touch
    /// pendingWork, unlike captureDidFail below, because there is nothing of
    /// this attempt's to pop — popping here would incorrectly consume and
    /// misinterpret a different, legitimately-queued entry from an earlier
    /// frame.
    private func failScreenshotBeforeQueued(_ message: String) {
        clearScreenshotInFlight()
        post(status: message)
    }

    /// Called once per captured frame, after the capture blit (and optional
    /// .managed synchronize) has been encoded, from that frame's command
    /// buffer completion handler. Pops the oldest pending entry — completion
    /// handlers for buffers submitted to the same queue fire in submission
    /// order, so FIFO matches each handler to the work it actually produced.
    func captureDidComplete() {
        lock.lock()
        let work = pendingWork.isEmpty ? nil : pendingWork.removeFirst()
        lock.unlock()

        guard let work = work else { return }

        ioQueue.async { [weak self] in
            guard let self = self else { return }

            if let buffer = work.screenshotBuffer {
                self.writePNG(pixelBuffer: buffer)
                self.clearScreenshotInFlight()
            }

            if let buffer = work.recordBuffer, let index = work.recordIndex {
                self.appendToWriter(pixelBuffer: buffer, frameIndex: index)
                self.finalizeGroup?.leave()
            }
        }
    }

    /// Called ONLY from LiquidRenderer, when the blit itself could not even
    /// be encoded (e.g. makeBlitCommandEncoder returned nil) AFTER
    /// acquireStagingTexture already succeeded and queued a PendingCaptureWork
    /// entry for this frame. Distinct from failScreenshotBeforeQueued above
    /// (which handles the BEFORE-queued case), and from a dropped frame
    /// (handled inline inside acquireStagingTexture/dequeuePooledTexture,
    /// never reaching this path). This is rare (severe resource exhaustion),
    /// but still must pop the entry that was already queued and release the
    /// finalizeGroup token that was already entered, or a stray entry would
    /// strand the queue and a future Stop would hang waiting on a group that
    /// can never reach zero.
    func captureDidFail(_ message: String) {
        lock.lock()
        let work = pendingWork.isEmpty ? nil : pendingWork.removeFirst()
        lock.unlock()

        if work?.screenshotBuffer != nil {
            clearScreenshotInFlight()
        }
        if work?.recordBuffer != nil {
            finalizeGroup?.leave()
        }

        post(status: message)
    }

    // =====================================================================
    // MARK: - Shared staging pool
    // =====================================================================

    private func dequeuePooledTexture(width: Int, height: Int) -> MTLTexture? {
        guard let cache = textureCache, width > 0, height > 0 else { return nil }

        lock.lock()
        let needsRebuild = pixelBufferPool == nil || poolWidth != width || poolHeight != height
        lock.unlock()

        if needsRebuild {
            guard rebuildPool(width: width, height: height) else { return nil }
        }

        lock.lock()
        let pool = pixelBufferPool
        lock.unlock()
        guard let pool = pool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let auxAttributes: [String: Any] = [
            // M4.4 Part C2: 6 -> 10, raised alongside the pool's minimum
            // buffer count. This is the ceiling at which the pool refuses to
            // allocate rather than growing without bound; leaving it at 6
            // while the minimum went to 6 would mean the pool could never
            // hold a working margin above its own floor.
            kCVPixelBufferPoolAllocationThresholdKey as String: 10
        ]
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pool,
            auxAttributes as CFDictionary,
            &pixelBuffer
        )

        guard result == kCVReturnSuccess, let buffer = pixelBuffer else {
            // Pool exhausted (writer/IO falling behind) or a genuine
            // allocation failure. Either way: no blocking — caller treats
            // this as a drop.
            return nil
        }

        var cvTexture: CVMetalTexture?
        let wrapped = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            buffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard wrapped == kCVReturnSuccess,
              let cvTex = cvTexture,
              let texture = CVMetalTextureGetTexture(cvTex) else { return nil }

        lastDequeuedBuffer = buffer
        return texture
    }

    /// poolWidth/poolHeight/pixelBufferPool are written here under `lock`
    /// even though this only ever runs on the render thread, to match the
    /// locking discipline used for the main-thread reads of these same
    /// fields in record(fps:) and beginWriterSession(in:) — a torn read
    /// across threads is the failure mode being guarded against, not a race
    /// between two render-thread calls (which can't happen; draw() is
    /// serial).
    private func rebuildPool(width: Int, height: Int) -> Bool {
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        // M4.4 Part C2: 3 -> 6. Three buffers is thin once the writer holds
        // one for longer than a frame, which is exactly what happens as
        // resolution climbs — and pool exhaustion is a DROPPED FRAME, not a
        // stall. Memory cost is real and worth stating: about 8.3 MB per
        // buffer at 1080p and 33 MB at 4K, so the 4K ceiling moves from
        // roughly 200 MB to roughly 330 MB. On 24 GB that is not the
        // constraint. Part C1's dropsPool counter is what will say whether
        // this was the right lever.
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 6
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let created = pool else {
            lock.lock()
            pixelBufferPool = nil
            lock.unlock()
            return false
        }

        lock.lock()
        pixelBufferPool = created
        poolWidth = width
        poolHeight = height
        lock.unlock()
        return true
    }

    private func clearScreenshotInFlight() {
        lock.lock()
        screenshotInFlight = false
        lock.unlock()
    }

    /// M4.4 Part C1: why a frame was dropped, so the Recording section can
    /// say which half of the pipeline gave up instead of showing one
    /// undifferentiated number.
    enum DropReason {
        /// The staging pool had no free buffer. The GPU side is producing
        /// frames faster than the writer is releasing them.
        case pool
        /// The writer input wasn't ready, or append() refused. The encoder or
        /// the disk is the bottleneck.
        case writer
    }

    private func noteDroppedFrame(_ reason: DropReason) {
        lock.lock()
        dropCounter += 1
        switch reason {
        case .pool:   dropCounterPool += 1
        case .writer: dropCounterWriter += 1
        }
        let count = dropCounter
        let poolCount = dropCounterPool
        let writerCount = dropCounterWriter
        lock.unlock()

        DispatchQueue.main.async {
            self.progress.dropCount = count
            self.progress.dropsPool = poolCount
            self.progress.dropsWriter = writerCount
        }
    }

    // =====================================================================
    // MARK: - PNG encoding (screenshot path, unchanged from 4.1)
    // =====================================================================

    private func writePNG(pixelBuffer: CVPixelBuffer) {
        guard let directory = outputDirectory else {
            post(status: "No output folder selected.")
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            post(status: "Could not read the captured frame.")
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // M4.4 Part B (Q3): preserve the alpha channel in the PNG when — and
        // only when — the vignette is actually routing its matte there.
        //
        //   OFF: .noneSkipFirst, exactly as since 4.1. Alpha is discarded and
        //        the file is opaque. This is still the path for every
        //        screenshot taken without the toggle, so the default
        //        behaviour is untouched.
        //   ON:  .premultipliedFirst — matching the shader, which multiplies
        //        rgb by coverage before writing that same coverage to alpha.
        //        Declaring premultiplied here is not a conversion; it is
        //        telling CoreGraphics the truth about bytes that are already
        //        in that form. Declaring .first (rather than .last) keeps the
        //        BGRA byte order the pool produces.
        lock.lock()
        let wantsAlpha = alphaEnabled
        lock.unlock()

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = wantsAlpha ? .premultipliedFirst : .noneSkipFirst
        let bitmapInfo = CGBitmapInfo(rawValue:
            alphaInfo.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ), let image = context.makeImage() else {
            post(status: "Could not build the image.")
            return
        }

        let url = uniqueURL(in: directory, ext: "png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            post(status: "Could not create \(url.lastPathComponent).")
            return
        }

        CGImageDestinationAddImage(destination, image, nil)

        if CGImageDestinationFinalize(destination) {
            let name = url.lastPathComponent
            DispatchQueue.main.async {
                self.state.lastSavedName = name
                self.state.status = "Saved \(name) (\(width)×\(height))"
            }
        } else {
            post(status: "Failed to write \(url.lastPathComponent).")
        }
    }

    private func uniqueURL(in directory: URL, ext: String) -> URL {
        let base = nameFormatter.string(from: Date())
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    // =====================================================================
    // MARK: - AVAssetWriter (recording path, new in 4.2)
    // =====================================================================

    private func beginWriterSession(in directory: URL) -> Bool {
        let url = uniqueURL(in: directory, ext: "mov")

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            return false
        }

        // Optional insurance (confirmed wanted, Q6-adjacent): an unexpected
        // quit/crash mid-take still leaves a playable partial file instead of
        // an unopenable stub.
        // M4.4 Part C3: 1s -> 5s. This exists as crash insurance (an
        // unexpected quit mid-take still leaves a playable partial file
        // instead of an unopenable stub). At a 1-second interval it forces a
        // fragment flush every second, which at 4K ProRes is a large periodic
        // write landing right inside the capture path — a plausible
        // contributor to the dropout at higher resolutions. Five seconds
        // keeps the insurance and cuts the flush rate 5x. Worst case on an
        // unexpected quit: up to 5 seconds lost instead of up to 1.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        // Even dimensions: H.264/HEVC require it, and a resized drawable can
        // easily be odd. We copy the even top-left region; worst case is a
        // one-row/column crop. notedWidth/notedHeight are guaranteed > 0 here
        // because record(fps:) checks that before calling this — read under
        // lock since the render thread can write them concurrently via
        // notePotentialSize. M18: these are the RENDERER's reported size, not
        // the pool's (see the note at notedWidth's declaration) — this is the
        // exact fix for the stale-writer-size bug a resolution switch could
        // otherwise cause.
        // M4.4: lockedCodec is folded into this SAME critical section rather
        // than read bare. It is only ever written by record() just above this
        // call, on the main thread, so a torn read isn't actually reachable —
        // but the file's discipline is that take-scoped state is read under
        // the lock, and adding a field that quietly opts out of that is how
        // the next person learns the wrong rule.
        lock.lock()
        let width = notedWidth & ~1
        let height = notedHeight & ~1
        let lockedCodec = self.lockedCodec
        lock.unlock()
        guard width > 0, height > 0 else { return false }
        recordingSize = (width, height)

        // M4.4 Part A: codec-dependent output settings.
        //
        // THE H.264 BRANCH IS UNCHANGED FROM M4.2 AND MUST STAY THAT WAY. Its
        // settings deliberately do NOT include AVVideoColorPropertiesKey:
        // AVFoundation rejects that key for avc1 in this settings shape on
        // this macOS version, crashing with NSInvalidArgumentException at
        // AVAssetWriterInput init. That is a shipped, confirmed finding from
        // M4.2, not a theoretical risk. The H.264 file is untagged, which
        // matches what QuickTime Screen Recording produces and plays back
        // correctly everywhere tested.
        //
        // PROPER Rec.709 TAGGING RETURNS HERE, on the ProRes branches only —
        // exactly as M4.2 promised it would. ProRes accepts these keys
        // cleanly. The offscreen texture is .bgra8Unorm (NOT _srgb), so the
        // shader's output values are written raw and are already
        // display-referred; tagging them 709 says "these are finished display
        // values in the 709 space," which is the honest description and is
        // what makes ProRes files land correctly in an NLE instead of
        // drifting.
        //
        // EXPECT A VISIBLE DIFFERENCE, and know which file is wrong: a tagged
        // ProRes take may look slightly different from an untagged H.264 take
        // of the same material in some players, because the untagged one is
        // being GUESSED at. The tagged one is the correct one. That is not a
        // regression in this change.
        //
        // ProRes is intra-only and encodes in the M-series media engine, so
        // per frame it is generally easier on the machine than H.264 — but
        // far heavier on DISK (roughly 24 MB/s for 422 HQ at 1080p30, ~150
        // MB/s for 4444 at 4K30). A slow external or network volume at 4K
        // will back the writer up and drop frames; Part C1's split drop
        // counters are what will say so plainly.
        let videoSettings: [String: Any]
        switch lockedCodec {
        case 1, 2:
            let codecType: AVVideoCodecType = (lockedCodec == 2) ? .proRes4444 : .proRes422HQ
            videoSettings = [
                AVVideoCodecKey: codecType,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ]
            ]
        default:
            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let adaptorAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: adaptorAttributes
        )

        guard writer.canAdd(input) else { return false }
        writer.add(input)

        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        assetWriter = writer
        writerInput = input
        pixelBufferAdaptor = adaptor
        finalizeGroup = DispatchGroup()
        currentTakeURL = url
        return true
    }

    /// Runs on ioQueue, called from captureDidComplete.
    private func appendToWriter(pixelBuffer: CVPixelBuffer, frameIndex: Int64) {
        guard let input = writerInput, let adaptor = pixelBufferAdaptor else { return }

        guard input.isReadyForMoreMediaData else {
            // Writer side: the encoder/disk hasn't kept up.
            noteDroppedFrame(.writer)
            return
        }

        lock.lock()
        let fps = lockedFPS
        lock.unlock()

        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
            // Writer side: append refused outright.
            noteDroppedFrame(.writer)
            return
        }

        noteProgress(frameIndex: frameIndex)
    }

    /// All reads/writes of the elapsed-time bookkeeping and the publish
    /// throttle go through `lock`: appendToWriter/noteProgress run on
    /// ioQueue, while pause()/resume() write the same fields from the main
    /// thread.
    private func noteProgress(frameIndex: Int64) {
        let count = Int(frameIndex) + 1

        lock.lock()
        let elapsed: Int
        if let start = recordingStartWallClock {
            elapsed = pausedAccumulatedSeconds + Int(Date().timeIntervalSince(start).rounded(.down))
        } else {
            elapsed = pausedAccumulatedSeconds
        }
        // LONG-FORM: publish AT MOST once per second, and only on the
        // elapsed-second CHANGE — this is what keeps RecorderProgress event-driven
        // at 30-60fps capture rates instead of becoming a 30-60Hz SwiftUI
        // publisher. STOP-MOTION: captures are sparse (one per press or per LFO
        // cycle), so publish every captured frame for immediate feedback —
        // otherwise the frame counter would lag rapid Capture Frame presses.
        let stopMotion = lockedStopMotion
        let shouldPublish = stopMotion || (elapsed != lastPublishedSecond)
        if !stopMotion { lastPublishedSecond = elapsed }
        lock.unlock()

        guard shouldPublish else { return }

        DispatchQueue.main.async {
            self.progress.recordedFrameCount = count
            self.progress.elapsedSeconds = elapsed
        }
    }

    /// Ordered against in-flight GPU/writer work via finalizeGroup: every
    /// acquireStagingTexture call that starts a record-frame capture calls
    /// group.enter(), matched by group.leave() in captureDidComplete. Waiting
    /// on the group before calling markAsFinished guarantees no frame is
    /// still mid-flight when we finalize — without this, Stop during a
    /// mid-flight frame either loses that frame or appends after
    /// markAsFinished and fails the whole file.
    private func finalizeTake(reason: String?, completion: (() -> Void)? = nil) {
        guard let writer = assetWriter, let input = writerInput, let group = finalizeGroup else {
            lock.lock(); transportState = .idle; lock.unlock()
            DispatchQueue.main.async { self.state.transport = .idle }
            completion?()
            return
        }

        group.notify(queue: ioQueue) { [weak self] in
            guard let self = self else { completion?(); return }

            input.markAsFinished()
            writer.finishWriting {
                let finalURL = self.currentTakeURL
                let finalReason = reason
                let drops = self.dropCounter
                // M4.4 Part C1: carry the split out to the status line too,
                // so the number that actually gets read after a take says
                // WHERE the frames went.
                let dropsPool = self.dropCounterPool
                let dropsWriter = self.dropCounterWriter

                // M24: the take-drift pair. The one number that says whether
                // the recorder phase clock held.
                //
                //   clip = frameIndex / lockedFPS — the file's real duration,
                //          straight out of the same counter its PTS values are
                //          built from.
                //   real = wall-clock time the take actually ran.
                //
                // On a clean long-form take these should sit within a few
                // tenths of each other. A clip figure meaningfully SHORT of
                // real means the loop did not deliver the requested captures
                // per second, which is the one condition under which the
                // quantized clock runs slow.
                //
                // Read here rather than at the top of finalizeTake because
                // this runs after group.notify — every in-flight frame has
                // landed, so `frameIndex` is final. `drops` is read here for
                // the same reason.
                //
                // Long-form only: in stop-motion, clip duration is frames /
                // playback fps and is DELIBERATELY unrelated to how long you
                // stood there pressing the button, so the comparison would be
                // meaningless rather than merely uninteresting.
                //
                // Pause/Resume banks whole seconds into
                // `pausedAccumulatedSeconds`, so a paused take can carry up to
                // about a second of rounding per pause. Unpaused takes — which
                // is what this figure is for — are exact.
                self.lock.lock()
                let takeClipSeconds = Double(self.frameIndex) / max(self.lockedFPS, 1.0)
                let takeRealSeconds = Double(self.pausedAccumulatedSeconds)
                    + (self.recordingStartWallClock.map { Date().timeIntervalSince($0) } ?? 0.0)
                let takeWasStopMotion = self.lockedStopMotion
                self.lock.unlock()

                self.assetWriter = nil
                self.writerInput = nil
                self.pixelBufferAdaptor = nil
                self.finalizeGroup = nil
                self.currentTakeURL = nil

                self.lock.lock()
                self.transportState = .idle
                self.lock.unlock()

                DispatchQueue.main.async {
                    self.state.transport = .idle
                    let name = finalURL?.lastPathComponent ?? "recording"
                    let dropSuffix = drops > 0
                        ? " (\(drops) dropped frame\(drops == 1 ? "" : "s") — \(dropsWriter) writer, \(dropsPool) pool)"
                        : ""
                    // M24: clip/real pair, long-form takes only.
                    let clockSuffix = (!takeWasStopMotion && takeRealSeconds > 0.05)
                        ? String(format: " (clip %.1fs / real %.1fs)", takeClipSeconds, takeRealSeconds)
                        : ""
                    if let reason = finalReason {
                        self.state.status = "\(reason) — saved \(name)\(clockSuffix)\(dropSuffix)"
                    } else {
                        self.state.status = "Saved \(name)\(clockSuffix)\(dropSuffix)"
                    }
                    self.state.lastSavedName = name
                }

                completion?()
            }
        }
    }

    // =====================================================================
    // MARK: - Output directory persistence (unchanged from 4.1, minus the
    // temporary debug prints)
    // =====================================================================

    private func adopt(directory url: URL) {
        scopedDirectory?.stopAccessingSecurityScopedResource()
        let started = url.startAccessingSecurityScopedResource()
        scopedDirectory = started ? url : nil

        outputDirectory = url
        let name = url.lastPathComponent
        DispatchQueue.main.async {
            self.state.outputDirectoryName = name
        }
    }

    private func persistBookmark(for url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            return
        }
        if let data = try? url.bookmarkData(options: [],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    private func restoreOutputDirectory() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }

        var stale = false
        if let url = try? URL(resolvingBookmarkData: data,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            adopt(directory: url)
            if stale { persistBookmark(for: url) }
            return
        }

        if let url = try? URL(resolvingBookmarkData: data,
                              options: [],
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            adopt(directory: url)
            if stale { persistBookmark(for: url) }
        }
    }

    private func post(status: String) {
        DispatchQueue.main.async {
            self.state.status = status
        }
    }
}






