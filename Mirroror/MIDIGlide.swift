import Foundation

// M28 — MIDI GLIDE.
//
// A global lag/smoothing stage for MIDI input only (D per the plan — OSC
// carries full 32-bit floats and has no 7-bit stepping to smooth, and this
// class is never reachable from the OSC path at all). Owned by
// LiquidRenderer, which is the only object in this app that runs a frame
// clock; ControlSurface already holds a reference to the renderer
// (requestLFOPhaseReset uses it the same way), so this reuses that wiring
// rather than adding a new one.
//
// THE SHAPE: fixed-duration arrival, not a one-pole. A new target resets a
// countdown to `glideSeconds`; each frame the current value closes the
// remaining fraction of the distance in the remaining fraction of the time
// (current += (target - current) * (dt / remaining)), which is exactly
// "moves smoothly from the initial position to the end position over the
// glide time," restarting on every new value the way a MIDI fader streams
// them. A one-pole's stated time constant only reaches ~63% of the way and
// never actually arrives — wrong on both counts for what was asked for.
//
// LOCK DISCIPLINE (stated once, matches the plan's D3): this class's lock is
// never held at the same time as ParamStore's or ControlSurface's. The MIDI
// thread takes this lock, writes a target, releases it. The render thread
// takes this lock, copies out due writes into a reused scratch array,
// releases it, THEN writes each one to ParamStore. No thread ever holds two
// locks at once, so there is no ordering to reason about.
final class MIDIGlide {

    private struct Entry {
        var current: Float
        var target: Float
        var remaining: Float   // seconds left until arrival
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]          // paramID -> in-flight glide
    private var glideSeconds: Float = 0.0

    // Reused across frames so advance(deltaTime:) never allocates on the
    // common "table is empty" path — an empty array's capacity survives
    // removeAll(keepingCapacity:).
    private var dueScratch: [(paramID: String, value: Float)] = []

    // MARK: - Setting glide time (main thread — the mapping window's slider)

    func setGlideSeconds(_ seconds: Float) {
        lock.lock()
        glideSeconds = seconds.clamped(to: 0.0...3.0)
        // Dropping to (or through) 0 flushes immediately rather than leaving
        // an entry to be silently skipped by the `glideSeconds <= 0` guard
        // in setTarget — a parked glide with nothing driving it forward
        // would otherwise sit at a stale mid-glide value forever.
        if glideSeconds <= 0.0 {
            entries.removeAll()
        }
        lock.unlock()
    }

    func currentGlideSeconds() -> Float {
        lock.lock()
        defer { lock.unlock() }
        return glideSeconds
    }

    // MARK: - MIDI thread entry point

    /// Called from `ControlSurface.applyValue` for continuous parameters
    /// only (D5 — toggles and stepped parameters never glide; gliding a
    /// stepped value would audibly/visibly sweep every option in between).
    ///
    /// `currentStoreValue` is read by the CALLER, outside this lock, from
    /// ParamStore — this class never touches ParamStore directly, keeping
    /// the one-directional lock ordering in D3 intact. Passed in rather than
    /// read here so a brand-new glide starts from where the parameter
    /// actually is, not from a stale `current` left over from a previous
    /// glide that was flushed or never existed.
    ///
    /// Returns whether the value was actually queued to glide. `false`
    /// means glide is currently off (and any stale in-flight entry for this
    /// parameter — e.g. left over from glide being turned off mid-flight —
    /// has just been dropped) — the caller writes `value` straight to
    /// ParamStore itself in that case, exactly the pre-M28 path.
    @discardableResult
    func setTarget(paramID: String, value: Float, currentStoreValue: @autoclosure () -> Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard glideSeconds > 0.0 else {
            entries.removeValue(forKey: paramID)
            return false
        }

        if var existing = entries[paramID] {
            existing.target = value
            existing.remaining = glideSeconds
            entries[paramID] = existing
        } else {
            entries[paramID] = Entry(current: currentStoreValue(), target: value, remaining: glideSeconds)
        }
        return true
    }

    // MARK: - Render thread entry point

    /// Advances every in-flight glide by one frame and writes arrivals and
    /// in-progress values straight into `store`. Called once per frame from
    /// `LiquidRenderer.draw()`, immediately after `deltaTime` is computed —
    /// idle cost when the table is empty is a lock and an `isEmpty` test,
    /// the same shape as the capture blit's idle cost.
    func advance(deltaTime: Float, store: ParamStore) {
        lock.lock()
        if entries.isEmpty {
            lock.unlock()
            return
        }

        dueScratch.removeAll(keepingCapacity: true)

        for (paramID, entry) in entries {
            var entry = entry
            if deltaTime >= entry.remaining || entry.remaining <= 0.0001 {
                entries.removeValue(forKey: paramID)
                dueScratch.append((paramID, entry.target))
                continue
            }
            entry.current += (entry.target - entry.current) * (deltaTime / entry.remaining)
            entry.remaining -= deltaTime
            entries[paramID] = entry
            dueScratch.append((paramID, entry.current))
        }
        lock.unlock()

        for (paramID, value) in dueScratch {
            guard let entry = ParamRegistry.byID[paramID] else { continue }
            store.set(entry.keyPath, value)
        }
    }

    // MARK: - Flushes (D12)

    /// Drops an in-flight glide for one parameter WITHOUT writing a final
    /// value — used when a mapping is cleared (ControlSurface) so the
    /// parameter is left exactly where it stood, not snapped to a target
    /// that no longer means anything.
    func drop(paramID: String) {
        lock.lock()
        entries.removeValue(forKey: paramID)
        lock.unlock()
    }

    /// Drops every in-flight glide without writing final values — used
    /// before Reset All (AppController) so no glide drags a parameter back
    /// off its just-restored default on a later frame, and used when every
    /// mapping is cleared (ControlSurface).
    func flush() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
