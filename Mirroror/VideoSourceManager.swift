import Foundation
import MetalKit
import AVFoundation
import Combine

enum VideoSourceType: String, CaseIterable, Identifiable {
    case procedural = "Gradient Synth"
    case camera = "Live Camera"
    case videoFile = "Video File"
    var id: String { self.rawValue }
}

// MARK: - M21: camera diagnostic surface
//
// Not a control (rule 1 is intact — nothing here is continuous, nothing feeds
// the render path, and it is never read by the renderer). It is a status
// LINE, edge-triggered only: every publish corresponds to a real transition
// in camera state, never a clock. Owned by VideoSourceManager, exposed on
// AppController as a plain `let` — same shape as RecorderProgress/RecorderState
// — so this object publishes for itself and nothing else observes it.
//
// Where the line STICKS tells you which defect you have; see M21_PLAN.md for
// the full table. This is the diagnosis surface that replaces an
// instrumented build: the app reports it, nobody runs MTL_HUD_ENABLED.
final class CameraStatus: ObservableObject {
    @Published private(set) var line: String = ""
    @Published private(set) var isFault: Bool = false

    func update(_ text: String, fault: Bool = false) {
        // All publishes happen on entry to this method; callers are
        // responsible for hopping to main first (see the DispatchQueue.main
        // wrappers below). Keeping the hop at the call site rather than
        // burying it here makes every publish site visibly a main-thread one.
        line = text
        isFault = fault
    }
}

// MARK: - Video & Camera Source Manager
//
// M21 REWRITE. Five defects fixed in this pass (see M21_PLAN.md D1-D9 for the
// full diagnosis this closed):
//
//   D1/D5 — texture lifetime + unsynchronized handoff. The CVMetalTexture
//   WRAPPER (not just the MTLTexture it vends) now lives in a three-slot
//   release ring behind textureLock. A wrapper isn't released until two more
//   have arrived after it — at 30 fps delivery that's ~66 ms of slack against
//   a command buffer that completes in ~16 ms, so the backing IOSurface
//   can't be recycled while the GPU might still be reading it. In synth terms
//   this is a short delay line on the release path: nothing reads out of the
//   ring, it exists purely so the tail doesn't get cut. The MTLTexture handed
//   to the renderer is read from behind the same lock, closing D5's race.
//
//   D2/D9 — sandbox entitlement + swallowed error. try? is gone; the thrown
//   NSError from AVCaptureDeviceInput is captured and surfaced verbatim in
//   the status line, which is exactly the string that distinguishes "no
//   entitlement" from "device busy" from "device unplugged mid-configure."
//
//   D3 — every failure path now updates CameraStatus instead of returning
//   silently.
//
//   D4/D7 — session lifecycle (build, start, stop) moves entirely onto
//   `sessionQueue`, a private serial queue. Nothing session-related touches
//   main again. Construction also moves from init to first selection of Live
//   Camera (D7's other half) — see switchSource — so the permission prompt
//   arrives attached to the gesture that caused it, not at launch.
//
//   D6 — captureOutput early-outs if the active source is no longer camera,
//   so a late sample buffer straddling a switch away never touches
//   textureCache from the camera queue while the video-file path might be
//   touching it from main.
//
//   D8 — canSetSessionPreset(.hd1280x720) is checked; falls back to .high and
//   names the resolution actually obtained in the status line.
class VideoSourceManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let device: MTLDevice
    var textureCache: CVMetalTextureCache?

    let cameraStatus = CameraStatus()

    // MARK: Thread discipline
    //
    // sessionQueue: owns the ENTIRE AVCaptureSession lifecycle — build,
    // startRunning, stopRunning, teardown. Serial, so session mutations from
    // different call sites (a rapid switch back and forth) can't interleave.
    //
    // textureLock: guards the release ring, the current MTLTexture, and
    // activeSource. Held for a pointer swap only — two acquisitions per frame
    // in the camera case (captureOutput's write, acquireFrameTexture's read),
    // none in the other two sources. Same house pattern as ParamStore's lock.
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let textureLock = NSLock()

    private var cameraSession: AVCaptureSession?
    private var sessionBuilt = false

    // Part A: the release ring. Three CVMetalTexture wrappers, written
    // round-robin. A wrapper is only released (by being overwritten) after
    // two newer ones have landed, so its backing surface can't be recycled
    // out from under a command buffer that's still reading it.
    private var textureRing: [CVMetalTexture?] = [nil, nil, nil]
    private var ringIndex = 0
    private var currentCameraTexture: MTLTexture?

    // Guarded by textureLock alongside the ring — the field the render
    // thread's acquireFrameTexture() and the camera queue's captureOutput()
    // both touch is exactly the field that was unsynchronized before (D5).
    private(set) var activeSource: VideoSourceType = .procedural

    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var videoTexture: MTLTexture?
    private var playerLooper: NSObjectProtocol?

    // Edge-trigger guard for the first-sample-buffer status publish — a Bool
    // on the camera queue, so every subsequent frame skips the hop to main
    // entirely rather than dispatching and no-op'ing there.
    private var reportedFirstFrame = false

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        // D7: no setupCamera() here. Session construction is deferred to the
        // first Live Camera selection — see switchSource.
    }

    // MARK: - Source switching

    func switchSource(to source: VideoSourceType) {
        textureLock.lock()
        activeSource = source
        textureLock.unlock()

        if source == .camera {
            player?.pause()
            startCameraPath()
        } else if source == .videoFile {
            stopCameraPath()
            player?.play()
        } else {
            stopCameraPath()
            player?.pause()
        }
    }

    /// D7 + Part D: builds the session on first use, or re-drives the whole
    /// authorization → discovery → configure → start path on every
    /// subsequent selection. This IS the retry: re-selecting Live Camera
    /// after a denial or a missing entitlement re-checks everything rather
    /// than replaying a cached failure. No separate retry control (rule 1;
    /// Q5 in the plan).
    private func startCameraPath() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.sessionBuilt, let session = self.cameraSession {
                self.beginRunning(session)
            } else {
                self.buildAndStartSession()
            }
        }
    }

    private func stopCameraPath() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if let session = self.cameraSession, session.isRunning {
                session.stopRunning() // D4: off main now, so no hitch on switch.
            }
            self.textureLock.lock()
            // Q6: clear the ring on stop, releasing the held surfaces rather
            // than letting them sit retained until the next camera session.
            self.textureRing = [nil, nil, nil]
            self.ringIndex = 0
            self.currentCameraTexture = nil
            self.textureLock.unlock()
            self.reportedFirstFrame = false
        }
    }

    // MARK: - Session construction (sessionQueue only)

    private func buildAndStartSession() {
        publish("Requesting access...")

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            // requestAccess's completion fires on an arbitrary queue; hop
            // back onto sessionQueue to keep session work serialized there.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                self.sessionQueue.async {
                    if granted {
                        self.configureAndStart()
                    } else {
                        self.publish("Access denied. System Settings > Privacy & Security > Camera", fault: true)
                    }
                }
            }
        case .denied, .restricted:
            publish("Access denied. System Settings > Privacy & Security > Camera", fault: true)
        @unknown default:
            publish("Access denied. System Settings > Privacy & Security > Camera", fault: true)
        }
    }

    private func configureAndStart() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        // Q8: discovery-first ordering unchanged — external preferred over
        // built-in — and the chosen device is now named in the status line.
        guard let camera = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            publish("No camera found", fault: true)
            return
        }

        let input: AVCaptureDeviceInput
        do {
            // D9: the thrown error, no longer discarded.
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            publish("Cannot open \(camera.localizedName): \(error.localizedDescription)", fault: true)
            return
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        // D8: check before assigning rather than assuming support.
        let resolutionLabel: String
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
            resolutionLabel = "1280x720"
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
            resolutionLabel = "device default"
        } else {
            session.sessionPreset = .high
            resolutionLabel = "unknown"
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            publish("Cannot open \(camera.localizedName): input rejected by session", fault: true)
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        // Q3: .userInteractive dropped to .userInitiated. Fluidity is
        // priority one, and .userInteractive put frame delivery in
        // contention with the render loop for no benefit — the callback is a
        // texture-cache create and a locked pointer swap, not user input.
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.queue", qos: .userInitiated))

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            publish("Cannot open \(camera.localizedName): output rejected by session", fault: true)
            return
        }
        session.addOutput(output)

        session.commitConfiguration()

        self.cameraSession = session
        self.sessionBuilt = true
        self.pendingDeviceName = camera.localizedName
        self.pendingResolutionLabel = resolutionLabel

        beginRunning(session)
    }

    // Named at configure time, reported once the session actually starts —
    // startRunning can still fail to produce frames (the "Running - no
    // frames" case in the plan's table), so these are held rather than
    // folded into the "Starting..." message.
    private var pendingDeviceName: String = ""
    private var pendingResolutionLabel: String = ""

    private func beginRunning(_ session: AVCaptureSession) {
        guard !session.isRunning else { return }
        publish("Starting...")

        // Remove-then-add rather than add alone: beginRunning can be called
        // more than once on the SAME session object (e.g. Live Camera
        // re-selected while already running fine — an early return above
        // catches that, but re-selected right after a stop is still the same
        // object). Without the removal first, retries would accumulate
        // duplicate observers and each real event would publish N times.
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionDidStartRunning, object: session)
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionRuntimeError, object: session)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionStarted),
            name: .AVCaptureSessionDidStartRunning,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionRuntimeError(_:)),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )

        session.startRunning()
    }

    @objc private func handleSessionStarted() {
        publish("Live - \(pendingDeviceName) - \(pendingResolutionLabel)")
    }

    @objc private func handleSessionRuntimeError(_ note: Notification) {
        let message = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown error"
        publish("Cannot open \(pendingDeviceName): \(message)", fault: true)
        // A runtime error leaves the session in a state re-calling
        // startRunning() on won't reliably recover (device unplugged
        // mid-run, etc.). Mark it unbuilt so the retry gesture (re-selecting
        // Live Camera) rebuilds from discovery rather than retrying a
        // session that already failed once — Part D's "re-runs discovery,
        // rebuilds the session" promise, honoured on this path too.
        sessionQueue.async { [weak self] in
            self?.sessionBuilt = false
            self?.cameraSession = nil
        }
    }

    /// Hops to main because CameraStatus is @Published and this can be
    /// called from sessionQueue, the requestAccess callback, or NotificationCenter's
    /// delivery queue (main, for these two names, but not guaranteed by contract).
    private func publish(_ text: String, fault: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.cameraStatus.update(text, fault: fault)
        }
    }

    // MARK: - Video file (unchanged from prior behavior)

    func loadVideoFile(url: URL) {
        if let looper = playerLooper {
            NotificationCenter.default.removeObserver(looper)
        }

        let playerItem = AVPlayerItem(url: url)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        playerItem.add(output)
        self.videoOutput = output

        let player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .none
        self.player = player

        playerLooper = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        player.play()
    }

    // MARK: - Camera frame delivery (camera.queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // D6: early-out if camera is no longer the active source, so a late
        // buffer straddling a switch never touches textureCache concurrently
        // with the video-file path on main.
        textureLock.lock()
        let isCameraActive = (activeSource == .camera)
        textureLock.unlock()
        guard isCameraActive else { return }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let textureCache = textureCache else { return }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            imageBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture = cvTexture else { return }

        // Part A: write into the ring rather than a bare var. The slot being
        // overwritten held a wrapper from two deliveries ago, which by now
        // has had roughly two frame periods (~66 ms at 30 fps) for any
        // command buffer referencing it to have completed.
        textureLock.lock()
        textureRing[ringIndex] = cvTexture
        ringIndex = (ringIndex + 1) % textureRing.count
        currentCameraTexture = CVMetalTextureGetTexture(cvTexture)
        textureLock.unlock()

        if !reportedFirstFrame {
            reportedFirstFrame = true
            publish("Live - \(pendingDeviceName) - \(pendingResolutionLabel)")
        }
    }

    // MARK: - Frame acquisition (render thread / main)

    func acquireFrameTexture() -> MTLTexture? {
        textureLock.lock()
        let source = activeSource
        textureLock.unlock()

        switch source {
        case .procedural:
            return nil
        case .camera:
            textureLock.lock()
            defer { textureLock.unlock() }
            return currentCameraTexture
        case .videoFile:
            // `player` is no longer bound here — nothing in this branch reads
            // it since the itemTime change below. The guard still requires a
            // player to EXIST, because a videoOutput without one is not
            // playing anything.
            guard player != nil,
                  let videoOutput = videoOutput,
                  let textureCache = textureCache else { return nil }

            // M22: this was `player.currentTime()`, a synchronous round-trip
            // to the player object on the render thread, every frame, whether
            // or not a new frame was actually ready. `itemTime(forHostTime:)`
            // asks the output itself what item time corresponds to a host
            // clock reading — no round trip, and it is the call AVFoundation
            // documents for exactly this "am I due a frame" pattern.
            //
            // CACurrentMediaTime() is the monotonic clock, the same one
            // LiquidRenderer.draw() reads. A Date would be the wall clock and
            // NTP-adjustable, which is the M20 Part 3 Step 0 lesson.
            let time = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
            if videoOutput.hasNewPixelBuffer(forItemTime: time),
               let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {

                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                var cvTexture: CVMetalTexture?

                let status = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault,
                    textureCache,
                    buffer,
                    nil,
                    .bgra8Unorm,
                    width,
                    height,
                    0,
                    &cvTexture
                )
                if status == kCVReturnSuccess, let cvTexture = cvTexture {
                    self.videoTexture = CVMetalTextureGetTexture(cvTexture)
                }
            }
            return videoTexture
        }
    }
}


