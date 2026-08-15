import SwiftUI
import Combine

// M27 Part 2 — THE MAPPING WINDOW.
//
// A separate SwiftUI Window scene (see MirrororApp.swift), closed by
// default and closed during performance. Its own view tree, its own 10 Hz
// poll while open — see the honest cost note below and in the plan. Nothing
// in here is on the render path; closing the window ends every timer this
// file owns.
//
// D3: no text fields anywhere. CC and channel are set by Learn (primary) or
// a .menu Picker (fallback — 128 entries for CC, 16 plus Any for channel).
// Low/High are sliders. Port (Part 3) is a fixed picker. Nothing types.

struct MappingWindow: View {
    @ObservedObject var controlSurface: ControlSurface
    let store: ParamStore

    @State private var selectedSection: String = ParamRegistry.sectionsInOrder.first ?? ""
    @State private var selectedParamID: String? = nil
    @State private var showClearAllConfirmation = false
    /// Bumped after any edit (Learn landing, range change, clear) that
    /// should redraw the right pane's binding text — the window's own small
    /// analogue of controlGeneration, scoped to just this view tree.
    @State private var editGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sectionList
                    .frame(width: 200)

                Divider()

                VStack(spacing: 0) {
                    parameterList

                    if let selectedParamID {
                        Divider()
                        DetailStrip(
                            paramID: selectedParamID,
                            controlSurface: controlSurface,
                            editGeneration: $editGeneration
                        )
                    }
                }
            }

            Divider()
            DeviceList(controlSurface: controlSurface)
            Divider()
            MIDIGlideControl(controlSurface: controlSurface)
            Divider()
            StatusLine(controlSurface: controlSurface)
        }
        .frame(minWidth: 640, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Clear All Mappings…") {
                    showClearAllConfirmation = true
                }
            }
        }
        .confirmationDialog(
            "Clear every MIDI mapping?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Mappings", role: .destructive) {
                controlSurface.clearAllMappings()
                editGeneration += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every MIDI binding.")
        }
    }

    // MARK: - Left pane

    private var sectionList: some View {
        List(ParamRegistry.sectionsInOrder, id: \.self, selection: $selectedSection) { section in
            Text(section).tag(section)
        }
        .listStyle(.sidebar)
        .onChange(of: selectedSection) { _, _ in
            selectedParamID = nil
        }
    }

    // MARK: - Right pane

    private var parameterList: some View {
        let entries = (ParamRegistry.all + ParamRegistry.nonMappable)
            .filter { $0.section == selectedSection }

        return VStack(alignment: .leading, spacing: 0) {
            // M22: the detail strip below only appears once a row is
            // SELECTED, which is not discoverable on its own — the Low/High
            // range was reported as unfindable during M27 Part 2 testing.
            // One line of text rather than a control, so nothing moves.
            Text("Select a parameter to set its Low / High range.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

            List(entries, id: \.id, selection: $selectedParamID) { entry in
                ParameterRow(
                    entry: entry,
                    controlSurface: controlSurface,
                    editGeneration: editGeneration,
                    onLearnLanded: { editGeneration += 1 }
                )
                .tag(entry.id)
            }
            .id(selectedSection) // forces a fresh List per section — cheap, and
                                  // avoids stale row identity when switching
                                  // sections quickly.
        }
    }
}

// MARK: - One row in the right pane

private struct ParameterRow: View {
    let entry: ParamEntry
    @ObservedObject var controlSurface: ControlSurface
    let editGeneration: Int
    let onLearnLanded: () -> Void

    @State private var isLearningThisRow = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.body)
                    .foregroundStyle(entry.mappable ? .primary : .secondary)
                if let reason = entry.nonMappableReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.mappable {
                Text(bindingText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 90, alignment: .trailing)

                Button(isLearningThisRow ? "Listening…" : "Learn") {
                    if isLearningThisRow {
                        controlSurface.cancelLearn()
                        isLearningThisRow = false
                    } else {
                        controlSurface.beginLearn(paramID: entry.id)
                        isLearningThisRow = true
                    }
                }
                .buttonStyle(.bordered)
                .tint(isLearningThisRow ? .orange : .accentColor)

                Button("Clear") {
                    controlSurface.clearMapping(paramID: entry.id)
                    onLearnLanded()
                }
                .buttonStyle(.bordered)
                .disabled(controlSurface.mapping(for: entry.id) == nil)
            }
        }
        .opacity(entry.mappable ? 1.0 : 0.5)
        // D3 corollary: Learn resolves on the NEXT incoming message, off
        // this view entirely — this listens for that landing so the row's
        // own "Listening…" state clears and the binding text updates
        // without the row polling anything.
        .onReceive(NotificationCenter.default.publisher(for: .controlSurfaceDidLearn)) { note in
            guard let result = note.userInfo?["result"] as? LearnResult else { return }
            if result.paramID == entry.id {
                isLearningThisRow = false
                onLearnLanded()
            } else if isLearningThisRow {
                // A different row's Learn press landed while this one
                // thought it was still armed — can only happen if two rows
                // were mid-Learn at once, which the window doesn't allow,
                // but resetting here costs nothing and closes the gap if it
                // ever does.
                isLearningThisRow = false
            }
        }
    }

    private var bindingText: String {
        _ = editGeneration // read to force recomputation when it bumps
        guard let mapping = controlSurface.mapping(for: entry.id) else { return "—" }
        let channelText = mapping.channel.map { "Ch \($0 + 1)" } ?? "Any Ch"
        if entry.kind == .toggle {
            return "\(channelText) CC/Note \(mapping.cc)"
        }
        return "\(channelText) CC \(mapping.cc)"
    }
}

// MARK: - Detail strip — ONE range editor for the selected row, not one per
// row (per the plan: "One pair of range sliders in the window, not two per
// row").

private struct DetailStrip: View {
    let paramID: String
    @ObservedObject var controlSurface: ControlSurface
    @Binding var editGeneration: Int

    var body: some View {
        if let entry = ParamRegistry.byID[paramID], entry.mappable {
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.label)
                    .font(.headline)

                if let mapping = controlSurface.mapping(for: paramID) {
                    channelPicker(current: mapping.channel)

                    switch entry.kind {
                    case .continuous:
                        rangeSliders(mapping: mapping, entry: entry)
                    case .toggle:
                        Text("Toggles use the full 0/1 range — CC 64 and above is on, or Note On latches it. No Low/High to set.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .stepped(let options):
                        steppedRangeSliders(mapping: mapping, options: options)
                    }
                } else {
                    Text("No binding yet — press Learn in the row above, then send a CC or Note On from the controller.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // D3: channel is a .menu Picker, never typed. 16 entries plus Any (Q6).
    private func channelPicker(current: Int?) -> some View {
        Picker("Channel", selection: Binding<Int>(
            get: { current ?? -1 },
            set: { newValue in
                controlSurface.setChannel(paramID: paramID, channel: newValue == -1 ? nil : newValue)
                editGeneration += 1
            }
        )) {
            Text("Any").tag(-1)
            ForEach(0..<16, id: \.self) { ch in
                Text("Channel \(ch + 1)").tag(ch)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 220)
    }

    private func rangeSliders(mapping: MIDIMapping, entry: ParamEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            labeledSlider(title: "Low", value: mapping.low, range: entry.range) { newLow in
                controlSurface.setRange(paramID: paramID, low: newLow, high: mapping.high)
                editGeneration += 1
            }
            labeledSlider(title: "High", value: mapping.high, range: entry.range) { newHigh in
                controlSurface.setRange(paramID: paramID, low: mapping.low, high: newHigh)
                editGeneration += 1
            }
            if mapping.low > mapping.high {
                Text("Low is above High — the control is inverted.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func steppedRangeSliders(mapping: MIDIMapping, options: [String]) -> some View {
        let maxIndex = Float(options.count - 1)
        return VStack(alignment: .leading, spacing: 8) {
            labeledSlider(title: "Low", value: mapping.low, range: 0...maxIndex, valueLabel: { options[Int($0)] }) { newLow in
                controlSurface.setRange(paramID: paramID, low: newLow.rounded(), high: mapping.high)
                editGeneration += 1
            }
            labeledSlider(title: "High", value: mapping.high, range: 0...maxIndex, valueLabel: { options[Int($0)] }) { newHigh in
                controlSurface.setRange(paramID: paramID, low: mapping.low, high: newHigh.rounded())
                editGeneration += 1
            }
        }
    }

    private func labeledSlider(
        title: String,
        value: Float,
        range: ClosedRange<Float>,
        valueLabel: ((Float) -> String)? = nil,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
            Text(valueLabel?(value) ?? String(format: "%.3f", value))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 70, alignment: .trailing)
        }
    }
}

// MARK: - Device list — genuinely new this pass. Names every source
// CoreMIDI enumerates and lets each be individually enabled/disabled, so
// "1 MIDI source" (the previous, unhelpful count-only readout) becomes an
// actual answer to "is it talking to the RIGHT device" instead of a number
// with no way to check it. Not polled — the list only changes on a hot-plug
// event or an explicit toggle, both of which already call back through
// controlSurface, so a plain @State array refreshed on appear and after any
// edit is enough; no timer needed here the way the status line needs one.

private struct DeviceList: View {
    @ObservedObject var controlSurface: ControlSurface

    @State private var devices: [MIDISourceInfo] = []
    // Hot-plug arrives on CoreMIDI's own notification block, asynchronously,
    // with no signal into this view otherwise — a 1 Hz poll here is
    // deliberately slower than the status line's 10 Hz (this list changes
    // on "a cable was plugged in," not "a fader moved") and is cheap enough
    // that using a separate cadence rather than piggybacking on the status
    // line's timer isn't worth the coupling.
    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MIDI Devices")
                .font(.caption)
                .foregroundStyle(.secondary)

            if devices.isEmpty {
                Text("No MIDI sources found. Check the device is connected and appears in Audio MIDI Setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { device.enabled },
                            set: { newValue in
                                controlSurface.setSourceEnabled(uniqueID: device.uniqueID, enabled: newValue)
                                refresh()
                            }
                        )) {
                            Text(device.name)
                                .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onAppear { refresh() }
        .onReceive(refreshTimer) { _ in refresh() }
    }

    private func refresh() {
        devices = controlSurface.sourceList()
    }
}

// MARK: - MIDI Glide (M28) — one global control, footer area, away from the
// per-parameter detail strip since it applies to every mapped continuous
// parameter at once. Rule 1's pattern even though this is nowhere near the
// render path: local @State write-through, not a binding into an
// ObservableObject.
//
// SQUARED RESPONSE: seconds = position² × 3.0, inverted with sqrt for
// display/drag. The useful de-stepping range is a few hundred milliseconds;
// a linear 0–3 s track would hand that region roughly a tenth of its travel.
// Same convention the instrument's own rate sliders already use — curve on
// read, straight position on the track.

private struct MIDIGlideControl: View {
    @ObservedObject var controlSurface: ControlSurface
    @State private var position: Float = 0.0   // 0...1, slider's own domain
    @State private var loaded = false

    private static let maxSeconds: Float = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("MIDI Glide")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(seconds < 0.005 ? "Off" : String(format: "%.2f s", seconds))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $position,
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing {
                        // D9: persisted on release, not on every drag tick —
                        // the same reasoning D11 already applied to MIDI
                        // messages, applied here to a UI slider instead.
                        controlSurface.persistMappings()
                    }
                }
            )
            .onChange(of: position) { _, newPosition in
                controlSurface.setGlideSeconds(newPosition * newPosition * Self.maxSeconds)
            }
            Text("Smooths incoming MIDI only.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            position = sqrt(controlSurface.currentGlideSeconds() / Self.maxSeconds)
        }
    }

    private var seconds: Float { position * position * Self.maxSeconds }
}

// MARK: - Status line — polled at 10 Hz, per the plan's stated pattern
// (same shape as CaptureScopeMeter: a leaf view with its
// own @State and its own Timer, publishing nothing upward). Costs nothing
// once the window is closed — the Timer lives only as long as this view
// does.

private struct StatusLine: View {
    @ObservedObject var controlSurface: ControlSurface

    @State private var connectedCount = 0
    @State private var lastMessage = "—"
    @State private var lastError: String? = nil
    // Diagnostic counter — see ControlSurface's _rawPacketListCount. Shown
    // unconditionally so "is anything arriving at all" is a glance, not a
    // guess: this climbs on every packet CoreMIDI delivers, whether or not
    // this engine understands or acts on it. If a controller is being
    // played and this number does not move, the fault is upstream of this
    // app — the port never received a connection, the sandbox is blocking
    // delivery, or the wrong device is enabled — not in the parser, Learn,
    // or the mapping table below.
    @State private var rawPacketCount = 0

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 16) {
            Label("\(connectedCount) MIDI source\(connectedCount == 1 ? "" : "s") connected", systemImage: "pianokeys")
                .font(.caption)
            Text("Packets received: \(rawPacketCount)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(rawPacketCount > 0 ? .primary : .secondary)
            Text(lastMessage)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onReceive(timer) { _ in
            let snapshot = controlSurface.statusSnapshot()
            connectedCount = snapshot.connectedCount
            lastMessage = snapshot.lastMessage
            lastError = snapshot.lastError
            rawPacketCount = snapshot.rawPacketCount
        }
    }
}




