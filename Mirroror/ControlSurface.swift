import Foundation
import CoreMIDI
import Combine

// M27 Part 2 — THE MAPPING ENGINE.
//
// D1, stated once here because everything below bends around it: input never
// touches the main thread or SwiftUI. A MIDI callback fires on CoreMIDI's own
// thread. Every store write from it is `store.set(keyPath, value)` — the
// exact same lock-guarded, one-float-assignment call a slider makes, which
// is the whole reason ParamStore didn't need to change for this milestone.
//
// LOCK ORDERING (one-directional, so there is no cycle to deadlock on):
//   MIDI thread   → takes `lock` (this file's), then ParamStore's lock.
//   Main thread   → takes only `lock` (reading/editing the mapping table).
//   Render thread → takes only ParamStore's lock (snapshot()).
// The two locks are never held by the same thread in the opposite order, so
// this is safe with no further reasoning required each time a call is added.

// MARK: - A single binding

/// One row of the mapping table. `channel == nil` means "Any channel" (Q6).
/// Low/High are in the PARAMETER's own units (D5) — for a stepped param,
/// Low/High are indices into its option list, so a fader can be range-locked
/// to a subset of positions (e.g. just Sine and Tri).
struct MIDIMapping: Codable, Equatable {
    var paramID: String
    var channel: Int?      // 0...15, or nil for Any
    var cc: Int             // 0...127
    var low: Float
    var high: Float
}

/// What Learn actually captured, so the caller can show it without a second
/// lookup — "Learned Ch 3 CC 74 → VCO Amplitude" reads directly off this.
struct LearnResult {
    let paramID: String
    let channel: Int
    let cc: Int
    let stoleFrom: String?   // paramID of a mapping that lost this CC, if any
}

// MARK: - The engine

final class ControlSurface: ObservableObject {

    // MARK: State under `lock`

    private let lock = NSLock()
    private var mappings: [String: MIDIMapping] = [:]              // paramID -> mapping
    private var reverseIndex: [ChannelCC: String] = [:]            // (channel, cc) -> paramID
    private var learnArmedFor: String? = nil

    /// The store this engine writes into. `let`, set once at init, never
    /// reassigned — matches the shape every other subsystem uses to reach
    /// ParamStore (LiquidRenderer, MIDI, and eventually OSC all hold the
    /// same reference, never a copy).
    private let store: ParamStore
    private let renderer: LiquidRenderer
    private let frameCapture: FrameCapture

    // MARK: State under `activityLock` — display only, read by a polling
    // leaf view (D per the plan's "polled at 10 Hz" convention already used
    // elsewhere), never read back by anything that acts on it. A second lock
    // rather than folding this into `lock` because the mapping-table lock is
    // on the MIDI thread's hot path for every message; the activity line
    // updates on the SAME hot path but a UI poll must never block a mapping
    // edit or vice versa.

    private let activityLock = NSLock()
    private var _lastMessageDescription: String = "—"
    private var _lastErrorDescription: String? = nil
    // Diagnostic-only counter, unconditional — increments on every packet
    // list CoreMIDI hands the input port, BEFORE any parsing, filtering, or
    // Learn logic runs. This exists to answer one question directly instead
    // of by inference: is anything arriving at all? If this stays at 0
    // while a controller is being played, the fault is upstream of this
    // engine entirely — sandbox/entitlement/connection — and no amount of
    // fixing the parser or the mapping table would show a symptom. If it
    // climbs, the fault is downstream (parsing, Learn, or the mapping
    // itself), and the difference is diagnosable in seconds from the status
    // line instead of guessed at.
    private var _rawPacketListCount: Int = 0

    // MARK: State under `lock` — the source list
    //
    // Genuinely new in this pass: previously the engine connected to every
    // enumerated source and reported only a COUNT, with no way to tell
    // which device that count actually was — "1 MIDI source" gave no way to
    // confirm the app had grabbed the right one versus some other endpoint
    // (an IAC bus, a phantom Bluetooth MIDI entry, anything else CoreMIDI
    // enumerates alongside real hardware). Every source is now named and
    // individually enabled/disabled, defaulting to enabled so existing
    // behavior (everything connected) is unchanged until a person actually
    // narrows it down.
    private var sources: [MIDISourceInfo] = []

    // MARK: CoreMIDI handles

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var virtualDestination = MIDIEndpointRef()
    private var connectedSourceRefs: [MIDIUniqueID: MIDIEndpointRef] = [:]

    // MARK: - Init

    init(store: ParamStore, renderer: LiquidRenderer, frameCapture: FrameCapture) {
        self.store = store
        self.renderer = renderer
        self.frameCapture = frameCapture
        loadMappings()
        // M28: loadMappings() populates pendingLoadedGlideSeconds (0 if
        // the file was missing, legacy-shaped, or unreadable) — applied here
        // rather than inside loadMappings itself since renderer.midiGlide is
        // this class's only path to the glide state, same as every other
        // renderer-owned thing this class reaches.
        renderer.midiGlide.setGlideSeconds(pendingLoadedGlideSeconds)
        setUpMIDI()
    }

    deinit {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if virtualDestination != 0 { MIDIEndpointDispose(virtualDestination) }
        if client != 0 { MIDIClientDispose(client) }
    }

    // MARK: - CoreMIDI setup (D10 — every failure path is visible)

    private func setUpMIDI() {
        // MIDIClientCreateWithBlock's notification block is how hot-plug
        // works (D per the plan): CoreMIDI calls it on ANY setup change, so
        // a controller plugged in after launch is caught here rather than
        // needing a relaunch — the exact failure shape the M21 camera bug
        // had, avoided on purpose this time.
        let clientName = "Mirroror" as CFString
        let status = MIDIClientCreateWithBlock(clientName, &client) { [weak self] _ in
            self?.connectAllSources()
        }
        guard status == noErr else {
            reportError("MIDI client creation failed (status \(status)). Check Settings ➔ Privacy & Security ➔ Automation/Input Monitoring, and that the app's entitlements include MIDI.")
            return
        }

        let portName = "Mirroror Input" as CFString
        let portStatus = MIDIInputPortCreateWithBlock(client, portName, &inputPort) { [weak self] packetList, _ in
            self?.handle(packetList: packetList)
        }
        guard portStatus == noErr else {
            reportError("MIDI input port creation failed (status \(portStatus)).")
            return
        }

        // Virtual destination — lets software (a DAW, a controller app that
        // routes through IAC, TouchOSC's own MIDI bridge if ever used that
        // way) address "Mirroror" directly as a destination, same as any
        // hardware port.
        let destName = "Mirroror" as CFString
        let destStatus = MIDIDestinationCreateWithBlock(client, destName, &virtualDestination) { [weak self] packetList, _ in
            self?.handle(packetList: packetList)
        }
        if destStatus != noErr {
            // Not fatal — physical/IAC sources still work — but named,
            // per D10, rather than silently missing.
            reportError("Virtual MIDI destination \"Mirroror\" could not be created (status \(destStatus)). Hardware and IAC sources are unaffected.")
        }

        connectAllSources()
    }

    /// Enumerates every currently-available MIDI source, names it, and
    /// connects the input port to whichever ones are enabled. Called at
    /// setup and again from the hot-plug notification block, so a
    /// controller connected after launch is picked up without a relaunch —
    /// and so a controller that DISAPPEARS (unplugged) drops out of the
    /// list rather than lingering as a stale "connected" entry.
    private func connectAllSources() {
        let count = MIDIGetNumberOfSources()
        var discovered: [MIDISourceInfo] = []
        var stillPresent: Set<MIDIUniqueID> = []

        lock.lock()
        let previouslyEnabled = Dictionary(uniqueKeysWithValues: sources.map { ($0.uniqueID, $0.enabled) })
        lock.unlock()

        for i in 0..<count {
            let source = MIDIGetSource(i)

            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            stillPresent.insert(uniqueID)

            var displayName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &displayName)
            let name = (displayName?.takeRetainedValue() as String?) ?? "Unknown MIDI Source"

            // A source keeps whatever enabled/disabled state it already had
            // (so toggling one off in the window survives a later hot-plug
            // notification for an UNRELATED device); a source seen for the
            // first time defaults to enabled, matching this engine's
            // original connect-everything behavior.
            let enabled = previouslyEnabled[uniqueID] ?? true
            discovered.append(MIDISourceInfo(uniqueID: uniqueID, name: name, endpoint: source, enabled: enabled))

            let alreadyConnected = connectedSourceRefs[uniqueID] != nil
            if enabled && !alreadyConnected {
                let connectStatus = MIDIPortConnectSource(inputPort, source, nil)
                if connectStatus == noErr {
                    connectedSourceRefs[uniqueID] = source
                } else {
                    reportError("Could not connect to \(name) (status \(connectStatus)).")
                }
            } else if !enabled && alreadyConnected {
                MIDIPortDisconnectSource(inputPort, source)
                connectedSourceRefs.removeValue(forKey: uniqueID)
            }
        }

        // Sources that disappeared (unplugged) drop their connection
        // tracking so a later replug with the same unique ID reconnects
        // cleanly rather than being treated as still-connected. Collecting
        // the stale keys first, then removing them in a second pass, avoids
        // mutating connectedSourceRefs while iterating its own keys.
        let staleIDs = connectedSourceRefs.keys.filter { !stillPresent.contains($0) }
        for staleID in staleIDs {
            connectedSourceRefs.removeValue(forKey: staleID)
        }

        lock.lock()
        sources = discovered
        lock.unlock()
    }

    /// A snapshot for the window's device list — one array copy, read on
    /// each status poll (10 Hz while the window is open) and after any
    /// enable/disable edit. Not on the MIDI hot path at all.
    func sourceList() -> [MIDISourceInfo] {
        lock.lock()
        defer { lock.unlock() }
        return sources
    }

    /// Main-thread call from the mapping window's device list. Flips one
    /// source's enabled flag and re-runs the connect pass, which will
    /// connect or disconnect the port from exactly that source depending on
    /// the new state — everything else already connected is left alone.
    func setSourceEnabled(uniqueID: MIDIUniqueID, enabled: Bool) {
        lock.lock()
        guard let index = sources.firstIndex(where: { $0.uniqueID == uniqueID }) else {
            lock.unlock()
            return
        }
        sources[index].enabled = enabled
        lock.unlock()
        connectAllSources()
    }

    // MARK: - The read block (D1, in full, four steps)

    private func handle(packetList: UnsafePointer<MIDIPacketList>) {
        // Diagnostic first, before anything else — see _rawPacketListCount's
        // declaration for why this specific ordering matters.
        activityLock.lock()
        _rawPacketListCount += 1
        activityLock.unlock()

        // FIXED: earlier versions of this function copied `packetPtr.pointee`
        // out into a local `let packet = packetPtr.pointee` before reading
        // `packet.length` — a full-struct copy taken OUTSIDE the scope that
        // was supposed to guarantee the pointer's validity. A temporary
        // raw-bytes panel confirmed the result directly at the time — every
        // one of 1,358 real packets from the 16n read back as zero-length,
        // which is why nothing ever parsed downstream, since
        // `Array(raw.prefix(0))` is always empty regardless of what CoreMIDI
        // actually delivered. That panel was removed in M22 once it had
        // nothing left to answer; the account is kept here because it is the
        // reason this function is shaped the way it is.
        //
        // This version matches the pattern used in published, working
        // CoreMIDI-in-Swift code (confirmed against an existing open-source
        // implementation rather than reasoned out from scratch a third
        // time): take ONE withUnsafePointer(to:) on the packet field,
        // convert it to a mutable pointer immediately inside that same
        // closure, and do ALL the walking — every `.pointee` read AND every
        // MIDIPacketNext call — inside that one closure's scope, so nothing
        // derived from it is ever touched after the guarantee expires.
        withUnsafePointer(to: packetList.pointee.packet) { firstPacketPtr in
            var mutablePacketPtr = UnsafeMutablePointer(mutating: firstPacketPtr)
            for _ in 0..<packetList.pointee.numPackets {
                let length = Int(mutablePacketPtr.pointee.length)
                let bytes = withUnsafeBytes(of: mutablePacketPtr.pointee.data) { raw -> [UInt8] in
                    Array(raw.prefix(length))
                }
                parseAndHandle(bytes: bytes)
                mutablePacketPtr = MIDIPacketNext(mutablePacketPtr)
            }
        }
    }

    /// Step 1: parse. A single MIDIPacket's data can contain MULTIPLE
    /// complete MIDI messages back to back — this is normal, not an edge
    /// case, and a fast-updating controller like a 16n (eight-plus faders,
    /// each capable of sending a CC on every scheduler tick) hits it
    /// constantly. Reading only the first 3 bytes of `bytes` and discarding
    /// the rest, which the original version of this function did, silently
    /// dropped every message after the first in a coalesced packet — Learn
    /// would occasionally catch one message and then go quiet, and a fader
    /// sweep would arrive as a fraction of its actual CC stream. This walks
    /// the whole byte range as a sequence of messages instead of one.
    ///
    /// Running status (a status byte omitted because it matches the
    /// previous message) is technically part of the MIDI spec but is rare
    /// over USB — CoreMIDI's own USB MIDI driver normally expands it back
    /// out before delivery. Not handled here on purpose: adding running-
    /// status tracking speculatively, for a case that hasn't actually been
    /// observed, is exactly the kind of complexity this milestone exists to
    /// avoid. If a specific controller turns out to need it, that is a
    /// concrete, reportable bug rather than a guess.
    private func parseAndHandle(bytes: [UInt8]) {
        var index = 0
        while index < bytes.count {
            let statusByte = bytes[index]
            // A real status byte has its high bit set. Anything else at
            // this position is data without a status byte we understand
            // (e.g. unhandled running status) — skip it rather than
            // mis-parse it as one, so a confusing stream degrades to
            // "some messages missed" instead of "garbage CC numbers."
            guard statusByte & 0x80 != 0 else {
                index += 1
                continue
            }

            let messageType = statusByte & 0xF0
            let channel = Int(statusByte & 0x0F)

            switch messageType {
            case 0xB0: // Control Change — 2 data bytes
                guard index + 2 < bytes.count else { return }
                let cc = Int(bytes[index + 1])
                let value = Int(bytes[index + 2])
                handleCC(channel: channel, cc: cc, value7Bit: value)
                index += 3

            case 0x90: // Note On — 2 data bytes
                guard index + 2 < bytes.count else { return }
                let note = Int(bytes[index + 1])
                let velocity = Int(bytes[index + 2])
                if velocity > 0 {
                    handleNoteOn(channel: channel, note: note)
                }
                // velocity == 0 is a Note Off in disguise (running status
                // convention) — discarded, same as an explicit 0x80.
                index += 3

            case 0x80, 0xA0, 0xE0: // Note Off, Poly Aftertouch, Pitch Bend — 2 data bytes, discarded
                index += 3

            case 0xC0, 0xD0: // Program Change, Channel Aftertouch — 1 data byte, discarded
                index += 2

            default: // System messages and anything else — not a channel
                      // voice message this engine acts on. Advancing by 1
                      // rather than trying to guess a length keeps a
                      // stray/unsupported byte from desyncing the rest of
                      // the packet's real messages.
                index += 1
            }
        }
    }

    /// Step 2/3/4 for a CC message.
    private func handleCC(channel: Int, cc: Int, value7Bit: Int) {
        lock.lock()

        // Step 2: Learn armed — record and return, nothing else happens on
        // this message. Learn always captures the ACTUAL channel it saw
        // (Q6), never "Any" — the person can widen it to Any afterward from
        // the mapping window if they want that.
        if let armedParamID = learnArmedFor {
            learnArmedFor = nil
            let key = ChannelCC(channel: channel, cc: cc)
            let stolenFrom = reverseIndex[key]

            // D4: one CC to one parameter. Stealing removes the OLD
            // mapping's table entry before installing the new one, so the
            // reverse index never points two paramIDs at the same key.
            if let stolenFrom, let stolenMapping = mappings[stolenFrom] {
                mappings.removeValue(forKey: stolenFrom)
                reverseIndex.removeValue(forKey: ChannelCC(channel: stolenMapping.channel ?? channel, cc: stolenMapping.cc))
            }

            let entry = ParamRegistry.byID[armedParamID]
            let newMapping = MIDIMapping(
                paramID: armedParamID,
                channel: channel,
                cc: cc,
                low: entry?.range.lowerBound ?? 0.0,
                high: entry?.range.upperBound ?? 1.0
            )
            mappings[armedParamID] = newMapping
            reverseIndex[key] = armedParamID
            lock.unlock()

            persistMappings()
            noteActivity("Learned Ch \(channel + 1) CC \(cc) ➔ \(entry?.label ?? armedParamID)")

            // BUG FIX: this fires on CoreMIDI's own callback thread, not the
            // main thread. NotificationCenter itself is thread-safe to POST
            // from anywhere, but the observer on the other end
            // (ParameterRow's .onReceive in MappingWindow.swift) mutates
            // SwiftUI @State in response — isLearningThisRow = false, and a
            // call into onLearnLanded() that bumps editGeneration. Both are
            // UI-thread-only. Posted from a background thread, that update
            // is undefined behavior for SwiftUI: sometimes it appears to
            // work, often it silently does nothing, which is exactly the
            // "Listening..." that never clears symptom — the mapping WAS
            // recorded (the lock/dictionary work above is thread-safe and
            // already complete), but the row never found out.
            let result = LearnResult(paramID: armedParamID, channel: channel, cc: cc, stoleFrom: stolenFrom)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .controlSurfaceDidLearn, object: nil, userInfo: ["result": result])
            }
            return
        }

        // Step 3: copy out the one matching mapping. Checks the exact
        // channel first, then falls back to an Any-channel mapping — one
        // dictionary lookup each, no array, no allocation.
        let exact = reverseIndex[ChannelCC(channel: channel, cc: cc)]
        let anyChannel = reverseIndex[ChannelCC(channel: nil, cc: cc)]
        guard let paramID = exact ?? anyChannel, let mapping = mappings[paramID] else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Step 4: compute and write. Outside the lock — ParamStore has its
        // own, and holding two at once here would be the one place lock
        // ordering could get confused, so the mapping lock is released
        // first every time.
        guard let entry = ParamRegistry.byID[paramID] else { return }
        applyValue(mapping: mapping, entry: entry, value7Bit: value7Bit)
        noteActivity("Ch \(channel + 1) CC \(cc) = \(value7Bit)")
    }

    /// Note On path — Learn for a toggle or a transport event, and latching
    /// playback for toggles per D6/Q3.
    private func handleNoteOn(channel: Int, note: Int) {
        lock.lock()
        if let armedParamID = learnArmedFor {
            learnArmedFor = nil
            lock.unlock()
            // Note On can only be learned for toggles and transport events —
            // the mapping window only offers Learn-by-note for those rows,
            // so reaching here with a continuous/stepped param id would be
            // a caller bug rather than a message to handle silently.
            noteActivity("Note On Learn is only used for toggles and transport actions.")
            return
        }
        lock.unlock()

        // Transport events (D8, Q4) — Capture Frame and Reset LFO Phase
        // only, both fixed to specific notes rather than mapped through the
        // table, exactly like the two are excluded from ParamRegistry
        // entirely: they are not parameters, so they do not belong in a
        // parameter-keyed table. Fixed at note 0 and 1 on any channel for
        // now — Learn support for transport notes is a natural Part 2.x
        // follow-up if a specific note ever needs to move, not something to
        // build speculatively ahead of a real request.
        if note == Self.captureFrameNote {
            frameCapture.requestStopMotionFrame()
            noteActivity("Capture Frame (Note On, Ch \(channel + 1))")
            return
        }
        if note == Self.resetLFOPhaseNote {
            renderer.requestLFOPhaseReset()
            noteActivity("Reset LFO Phase (Note On, Ch \(channel + 1))")
            return
        }

        // Toggle mappings latch on Note On (D6/Q3) rather than acting
        // momentary — flips the stored value between 0 and 1 rather than
        // reading a velocity. Reuses the same reverse index as CC, keyed on
        // note number in the cc slot: a toggle can be Learned from EITHER a
        // CC (>= 64 = on, per D6) or a Note On (latches), and both paths
        // write into the same one-CC-or-note-per-parameter table.
        lock.lock()
        let paramID = reverseIndex[ChannelCC(channel: channel, cc: note)] ?? reverseIndex[ChannelCC(channel: nil, cc: note)]
        lock.unlock()

        guard let paramID, let entry = ParamRegistry.byID[paramID], entry.kind == .toggle else { return }
        let current = store.get(entry.keyPath)
        store.set(entry.keyPath, current > 0.5 ? 0.0 : 1.0)
        noteActivity("Ch \(channel + 1) Note \(note) toggled \(entry.label)")
    }

    /// D6 applied per control kind, D5's Low/High lerp underneath all three.
    private func applyValue(mapping: MIDIMapping, entry: ParamEntry, value7Bit: Int) {
        let normalized = Float(value7Bit) / 127.0

        switch entry.kind {
        case .continuous:
            let value = mapping.low + (mapping.high - mapping.low) * normalized
            // M28: glide > 0 routes through MIDIGlide instead of writing
            // straight to the store. Glide == 0 is the pre-M28 path,
            // completely untouched. setTarget reports back whether it
            // actually queued the glide (one lock, one lookup) rather than
            // this call site checking glide state separately and racing its
            // own answer against setTarget's.
            let queued = renderer.midiGlide.setTarget(paramID: mapping.paramID, value: value, currentStoreValue: store.get(entry.keyPath))
            if !queued {
                store.set(entry.keyPath, value)
            }

        case .toggle:
            // CC path: >= 64 is on, matching the plan's stated threshold.
            // (Note On latching is handled separately, in handleNoteOn.)
            store.set(entry.keyPath, value7Bit >= 64 ? 1.0 : 0.0)

        case .stepped(let options):
            // Quantizes across the Low/High SUBRANGE of option indices, so
            // range-locking a stepped param to (e.g.) just Sine and Tri
            // (Low 0, High 1) is exactly D6's promise — Low/High still
            // apply to stepped params, not just continuous ones.
            let lowIndex = mapping.low
            let highIndex = mapping.high
            let span = highIndex - lowIndex
            let steppedValue: Float
            if span == 0 {
                steppedValue = lowIndex
            } else {
                let raw = lowIndex + span * normalized
                steppedValue = raw.rounded().clamped(to: 0...Float(options.count - 1))
            }
            store.set(entry.keyPath, steppedValue)
        }
    }

    // MARK: - Learn mode (main thread callers)

    /// Arms Learn for one parameter. The NEXT CC or Note On this engine
    /// sees, from any source, becomes that parameter's mapping. Call again
    /// with a different ID to re-arm for a different row; call
    /// `cancelLearn()` to arm nothing.
    func beginLearn(paramID: String) {
        lock.lock()
        learnArmedFor = paramID
        lock.unlock()
        noteActivity("Learning ➔ \(ParamRegistry.byID[paramID]?.label ?? paramID)…")
    }

    func cancelLearn() {
        lock.lock()
        learnArmedFor = nil
        lock.unlock()
    }

    var isLearning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return learnArmedFor != nil
    }

    // MARK: - Manual edits (main thread — the mapping window's fallback
    // pickers, D3: CC and channel by Learn or a .menu Picker, never typed)

    func setChannel(paramID: String, channel: Int?) {
        lock.lock()
        guard var mapping = mappings[paramID] else { lock.unlock(); return }
        let oldKey = ChannelCC(channel: mapping.channel, cc: mapping.cc)
        mapping.channel = channel
        let newKey = ChannelCC(channel: channel, cc: mapping.cc)
        reverseIndex.removeValue(forKey: oldKey)
        reverseIndex[newKey] = paramID
        mappings[paramID] = mapping
        lock.unlock()
        persistMappings()
    }

    func setRange(paramID: String, low: Float, high: Float) {
        lock.lock()
        guard var mapping = mappings[paramID] else { lock.unlock(); return }
        mapping.low = low
        mapping.high = high
        mappings[paramID] = mapping
        lock.unlock()
        persistMappings()
    }

    func clearMapping(paramID: String) {
        lock.lock()
        guard let mapping = mappings.removeValue(forKey: paramID) else { lock.unlock(); return }
        reverseIndex.removeValue(forKey: ChannelCC(channel: mapping.channel, cc: mapping.cc))
        lock.unlock()
        // M28 D12: drop rather than let an in-flight glide finish arriving
        // at a target for a mapping that no longer exists. Leaves the
        // parameter exactly where it stands.
        renderer.midiGlide.drop(paramID: paramID)
        persistMappings()
    }

    /// Q9 — behind a confirmation in the window, same pattern as Reset All.
    func clearAllMappings() {
        lock.lock()
        mappings.removeAll()
        reverseIndex.removeAll()
        lock.unlock()
        renderer.midiGlide.flush()
        persistMappings()
        noteActivity("All mappings cleared.")
    }

    // MARK: - MIDI Glide (M28) — thin pass-through to the renderer's
    // integrator, so the mapping window only ever talks to ControlSurface,
    // matching every other control it already exposes.

    func setGlideSeconds(_ seconds: Float) {
        renderer.midiGlide.setGlideSeconds(seconds)
        persistMappings()
    }

    func currentGlideSeconds() -> Float {
        renderer.midiGlide.currentGlideSeconds()
    }

    func mapping(for paramID: String) -> MIDIMapping? {
        lock.lock()
        defer { lock.unlock() }
        return mappings[paramID]
    }

    /// A snapshot for the window's right pane — one dictionary copy, called
    /// only when the window is open and the section selection changes, not
    /// on a timer and not on a MIDI message.
    func allMappings() -> [String: MIDIMapping] {
        lock.lock()
        defer { lock.unlock() }
        return mappings
    }

    // MARK: - Status line (polled at 10 Hz by a leaf view, per the plan)
    //
    // Source count now derives from `sourceList()` (connected AND enabled)
    // rather than a separately-tracked counter — one source of truth for
    // "how many are actually live" instead of two numbers that could drift
    // apart.

    func statusSnapshot() -> (connectedCount: Int, lastMessage: String, lastError: String?, rawPacketCount: Int) {
        let connectedCount = sourceList().filter { $0.enabled }.count
        activityLock.lock()
        defer { activityLock.unlock() }
        return (connectedCount, _lastMessageDescription, _lastErrorDescription, _rawPacketListCount)
    }

    private func noteActivity(_ description: String) {
        activityLock.lock()
        _lastMessageDescription = description
        activityLock.unlock()
    }

    private func reportError(_ description: String) {
        activityLock.lock()
        _lastErrorDescription = description
        activityLock.unlock()
    }

    // MARK: - Persistence (D11)

    private static var mappingsFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mirroror", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("midi_mappings.json")
    }

    /// M28 D9: the on-disk shape gained a version wrapper so glide time can
    /// live beside the mappings without a second file. `glideSeconds`
    /// defaults to 0 via Codable's own decode-missing-key behavior being
    /// unavailable for a non-optional Float, so it's explicit here instead.
    private struct MappingsFile: Codable {
        var version: Int
        var glideSeconds: Float
        var mappings: [MIDIMapping]
    }

    /// Loaded once, at init. A saved paramID that no longer exists in the
    /// registry is dropped with a note in the status line rather than
    /// silently — same discipline as the struct parity check, aimed at a
    /// file on disk instead of the GPU (D11).
    ///
    /// M28: tries the current wrapped shape first; falls back to the
    /// pre-M28 bare `[MIDIMapping]` array so an existing file loads with no
    /// migration step and adopts glide = 0. Nothing on disk is ever deleted
    /// by this — the next edit rewrites it in the current shape.
    private func loadMappings() {
        guard let data = try? Data(contentsOf: Self.mappingsFileURL) else { return }

        let saved: [MIDIMapping]
        if let wrapped = try? JSONDecoder().decode(MappingsFile.self, from: data) {
            saved = wrapped.mappings
            pendingLoadedGlideSeconds = wrapped.glideSeconds
        } else if let legacy = try? JSONDecoder().decode([MIDIMapping].self, from: data) {
            saved = legacy
            pendingLoadedGlideSeconds = 0.0
        } else {
            reportError("MIDI mapping file could not be read — starting with no mappings. The old file was not deleted.")
            return
        }

        var loadedCount = 0
        var droppedCount = 0
        for mapping in saved {
            guard ParamRegistry.byID[mapping.paramID] != nil else {
                droppedCount += 1
                continue
            }
            mappings[mapping.paramID] = mapping
            reverseIndex[ChannelCC(channel: mapping.channel, cc: mapping.cc)] = mapping.paramID
            loadedCount += 1
        }

        if droppedCount > 0 {
            noteActivity("Loaded \(loadedCount) mappings, dropped \(droppedCount) referring to parameters that no longer exist.")
        }
    }

    /// M28: `loadMappings()` runs at `init`, before `renderer` (and so
    /// `renderer.midiGlide`) can be told anything — this class doesn't own
    /// the glide value, the renderer does. Held here just long enough for
    /// `init` to apply it to `renderer.midiGlide` right after `loadMappings`
    /// returns; not read anywhere else.
    private var pendingLoadedGlideSeconds: Float = 0.0

    /// Written when the mapping window closes and at quit — NEVER on a MIDI
    /// message (D11). Every edit path above (Learn, setChannel, setRange,
    /// clearMapping, clearAllMappings, setGlideSeconds) already calls this,
    /// so the window closing and app quitting both just need to make sure
    /// the last write has landed — which, since this is synchronous, it
    /// already has by the time any of those calls return.
    ///
    /// M28: a slider DRAG does not call this on every tick (see
    /// setGlideSeconds's own call site in the mapping window) — only on
    /// release, same reasoning D11 already applied to MIDI messages.
    func persistMappings() {
        let snapshot = allMappings()
        let file = MappingsFile(version: 1, glideSeconds: renderer.midiGlide.currentGlideSeconds(), mappings: Array(snapshot.values))
        guard let data = try? JSONEncoder().encode(file) else {
            reportError("Could not encode MIDI mappings for saving.")
            return
        }
        do {
            try data.write(to: Self.mappingsFileURL, options: .atomic)
        } catch {
            reportError("Could not save MIDI mappings: \(error.localizedDescription)")
        }
    }

    // MARK: - Fixed transport notes (see handleNoteOn)

    static let captureFrameNote = 0
    static let resetLFOPhaseNote = 1
}

// MARK: - Reverse index key

private struct ChannelCC: Hashable {
    let channel: Int?
    let cc: Int
}

/// One row of the mapping window's device list. Not `Codable` — sources are
/// re-enumerated fresh every launch from CoreMIDI itself, never persisted
/// (a unique ID from a previous session pointing at a device that isn't
/// plugged in would just be a dead row). `enabled` is the only thing this
/// engine ever reasons about; `name` and `uniqueID` exist so a person can
/// actually tell the 16n apart from an IAC bus or anything else CoreMIDI
/// enumerates alongside it.
struct MIDISourceInfo: Identifiable {
    let uniqueID: MIDIUniqueID
    let name: String
    let endpoint: MIDIEndpointRef
    var enabled: Bool

    var id: MIDIUniqueID { uniqueID }
}

extension Notification.Name {
    static let controlSurfaceDidLearn = Notification.Name("ControlSurfaceDidLearn")
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}



