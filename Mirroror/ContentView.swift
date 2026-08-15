import SwiftUI
import Combine    // Timer.publish returns a Combine publisher — needed by the REC dot blink

// MARK: - Control Layout
// The sidebar is built from small section views wrapped in CollapsibleSection.
// Each section only holds local @State for its own conditional UI; all values
// write straight into the ParamStore. The sidebar and canvas are both
// hard-clipped so neither can bleed into the other.
//
// M4.2: `controller` is now passed in (ObservedObject) rather than owned here
// (StateObject) — MirrororApp holds the single AppController instance for the
// app's lifetime so it can register `controller.frameCapture` with the
// NSApplicationDelegateAdaptor for finalize-on-quit (Q6). ContentView's own
// behavior is otherwise unchanged; this is purely an ownership move, not a
// new source of truth.
struct ContentView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow

    private let sidebarWidth: CGFloat = 330

    var body: some View {
        HStack(spacing: 0) {
            MetalView(renderer: controller.renderer)
                .frame(minWidth: 500, minHeight: 500)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .background(Color.black)
                .clipped()

            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Mirroror")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.accentColor)

                        Spacer()

                        // M27 Part 2: quiet, same weight as Reset All beside
                        // it, same reasoning for living here rather than
                        // inside a CollapsibleSection — a setup control you
                        // have to expand a section to reach defeats the
                        // point of it being quick to get to between takes.
                        Button("MIDI...") {
                            openWindow(id: "midi-osc-mapping")
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .help("Open the MIDI mapping window (⌘⌥M)")

                        // M13: deliberately quiet, and deliberately at the very
                        // top rather than inside a CollapsibleSection — a reset
                        // you have to expand to reach defeats the point. It
                        // raises a confirmation rather than firing immediately,
                        // since it destroys a patch that may have taken a while
                        // to dial in and this app is headed for other people's
                        // hands. Same action is available from the app menu and
                        // its keyboard shortcut.
                        Button("Reset All") {
                            controller.showResetConfirmation = true
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .help("Restore every parameter to its default (⌘⌥R)")
                    }

                    SourceSection(controller: controller)
                    CanvasSection(store: controller.store)
                    RoutingSection(store: controller.store)
                    TorsionSection(store: controller.store)
                    Spiral2Section(store: controller.store)
                    MirrorSection(store: controller.store, config: .mirror1)
                    MirrorSection(store: controller.store, config: .mirror2)
                    DisplacementSection(store: controller.store)
                    HoleKeyerSection(store: controller.store)
                    LFOSection(store: controller.store, renderer: controller.renderer)
                    OutputMixSection(store: controller.store)
                    OutputVignetteSection(store: controller.store)
                    RecordingSection(store: controller.store, capture: controller.frameCapture, controller: controller, state: controller.frameCapture.state)

                    Spacer(minLength: 40)
                }
                .padding()
                .frame(width: sidebarWidth, alignment: .leading)
                // M13: the rebuild token. Every control reads the store once in
                // onAppear behind a `loaded` flag (that one-shot read is what
                // keeps drags off the observation path), so a reset MUST force
                // these rows to rebuild or they would keep showing stale
                // numbers while the renderer used the defaults. Bumping the
                // generation rebuilds them once; nothing here runs per frame.
                .id(controller.controlGeneration)
            }
            .frame(width: sidebarWidth)
            .frame(maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
            .clipped()
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 830, minHeight: 550)
        .confirmationDialog(
            "Reset all parameters to their defaults?",
            isPresented: $controller.showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                controller.performResetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the current patch. Recording and video source are not affected.")
        }
    }
}

// MARK: - Collapsible wrapper
// Collapse state is purely local view @State — it never touches the ParamStore
// or the render path, so toggling it has no effect on synthesis or performance.
private struct CollapsibleSection<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    let content: () -> Content

    init(_ title: String, startExpanded: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._expanded = State(initialValue: startExpanded)
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(title).font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content()
            }
            Divider()
        }
    }
}

// MARK: - Sections

private struct CanvasSection: View {
    let store: ParamStore
    @State private var preCropOn = false
    @State private var loaded = false

    var body: some View {
        CollapsibleSection("Canvas") {
            VStack(alignment: .leading, spacing: 10) {
                ParamSlider(\.zoom, store: store)

                ParamPicker(\.edgeBehavior, store: store, style: .radio)

                Toggle("Edge Pre-Crop (Raw Input)", isOn: Binding(
                    get: { preCropOn },
                    set: { preCropOn = $0; store.set(\.preCropOn, $0 ? 1.0 : 0.0) }
                ))
                if preCropOn {
                    ParamSlider(\.preCropPixels, store: store)
                }
            }
            .onAppear {
                if !loaded {
                    preCropOn = store.get(\.preCropOn) > 0.5
                    loaded = true
                }
            }
        }
    }
}

private struct SourceSection: View {
    @ObservedObject var controller: AppController

    var body: some View {
        CollapsibleSection("Source") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $controller.sourceType) {
                    ForEach(VideoSourceType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if controller.sourceType == .videoFile {
                    Button(action: { controller.importVideo() }) {
                        HStack {
                            Image(systemName: "doc.badge.plus")
                            Text(controller.activeVideoName.isEmpty ? "Load Video..." : controller.activeVideoName)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                // M21 Q4: camera-only, same conditional shape the video-file
                // Load button above already uses. SourceSection's own body
                // does NOT observe CameraStatus — the segmented Picker above
                // is a real control, so a publish landing on this section
                // would re-lay-out it. It lands on the leaf view instead.
                if controller.sourceType == .camera {
                    CameraStatusLine(status: controller.cameraStatus)
                }
            }
        }
    }
}

// MARK: - M21: camera status line
//
// A leaf view containing no controls — the M20 rule applied directly.
// SourceSection holds the segmented source Picker, so a publish landing on
// the section itself would re-lay-out a control; this observes CameraStatus
// on its own and SourceSection's body never touches it. No timer: every
// publish on CameraStatus is edge-triggered (selection, permission result,
// device resolution, input creation, session start, first sample buffer,
// runtime error), so a plain @ObservedObject is the whole mechanism — unlike
// CaptureScopeMeter, there is no periodic refresh here to quarantine.
//
// This is the diagnosis surface, not decoration: where the line STICKS says
// which of D1-D9 is present, per the table in M21_PLAN.md.
private struct CameraStatusLine: View {
    @ObservedObject var status: CameraStatus

    var body: some View {
        Text(status.line)
            .font(.caption2.monospacedDigit())
            .foregroundColor(status.isFault ? .red : .secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// M7 Phase 7.2: the four warp modules that can be placed in the routing chain.
// Raw values are the module IDs stored in chainSlot0...chainSlot4 and MUST stay
// in sync with the CHAIN_MODULE_* defines at the top of Shaders.metal.
private enum ChainModule: Int, CaseIterable, Identifiable {
    case mirror1 = 0
    case mirror2 = 1
    case rotation1 = 2
    case rotation2 = 3
    case displacement = 4
    case empty = 5

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .mirror1:   return "Mirror 1"
        case .mirror2:   return "Mirror 2"
        case .rotation1: return "Rotation 1"
        case .rotation2:    return "Rotation 2"
        case .displacement: return "Displacement"
        case .empty:        return "Empty"
        }
    }

    var shortLabel: String {
        switch self {
        case .mirror1:   return "M1"
        case .mirror2:   return "M2"
        case .rotation1: return "Rot 1"
        case .rotation2:    return "Rot 2"
        case .displacement: return "Disp"
        case .empty:        return ""
        }
    }
}

// M7 Phase 7.2: the geometry routing chain builder, replacing the old fixed
// three-entry "Pipeline Configuration" picker. Each slot names which warp module
// runs at that position, so every ordering of the four modules is reachable —
// including the interleavings the picker could not express. Per-slot pickers
// rather than drag-to-reorder: reordering by drag inside a ScrollView in a
// narrow sidebar is gesture-conflict-prone, and per-slot pickers are plain
// discrete controls that fit the local-@State write-through convention exactly.
//
// Duplicates across slots are deliberately allowed (listing a module twice
// applies its warp twice in sequence — a legitimate look), and so is dropping a
// module out of the chain entirely; the caption below reports that rather than
// preventing it.
private struct RoutingSection: View {
    let store: ParamStore

    // Discrete state driving conditional UI, so local @State write-through —
    // never ParamPicker. Defaults match the ShaderParams/LiveParams defaults,
    // which reproduce the old Rotations➔Mirrors routing.
    @State private var slots: [Int] = [2, 3, 0, 1, 5]
    @State private var loaded = false

    // M8 Phase A revealed the fifth slot. It defaults to Empty, so Displacement
    // is opt-in and the shipped default look is unchanged.
    private static let slotKeyPaths: [WritableKeyPath<LiveParams, Float>] = [
        \.chainSlot0, \.chainSlot1, \.chainSlot2, \.chainSlot3, \.chainSlot4
    ]

    private struct ChainPreset: Identifiable {
        let id: Int
        let label: String
        let order: [Int]
    }

    // M13: every preset is written SOURCE ➔ OUTPUT, matching the slot
    // numbering. The first three are the M13 reversals of the pre-M13 presets
    // and produce identical pictures — note that this SWAPS two of the names,
    // because the old labels described coordinate-application order rather
    // than what was on screen. "Mir➔Rot" is the shipped default.
    //
    // Each preset names all five slots so it is an exact state, never
    // inheriting whatever was sitting in a slot it does not mention.
    private static let presets: [ChainPreset] = [
        // Chains.
        ChainPreset(id: 0, label: "Mir➔Rot",   order: [5, 1, 0, 3, 2]),
        ChainPreset(id: 1, label: "Rot➔Mir",   order: [5, 3, 2, 1, 0]),
        ChainPreset(id: 2, label: "M2➔Rot➔M1", order: [5, 1, 3, 2, 0]),
        ChainPreset(id: 3, label: "Disp last", order: [1, 0, 3, 2, 4]),
        // Starting points: one module, everything else Empty. Position is
        // visually irrelevant for a solo module (Empty is a no-op), so slot 0
        // is chosen by convention — the patch then grows upward into the empty
        // slots above it rather than needing to be inserted underneath.
        ChainPreset(id: 4, label: "Disp 1st",  order: [4, 1, 0, 3, 2]),
        ChainPreset(id: 5, label: "M1 only",   order: [0, 5, 5, 5, 5]),
        ChainPreset(id: 6, label: "Rot1 only", order: [2, 5, 5, 5, 5]),
        ChainPreset(id: 7, label: "Disp only", order: [4, 5, 5, 5, 5])
    ]

    // M13: slots now read source ➔ output, so joining them in slot order is
    // the honest signal path. The Source/Output bookends are there to make the
    // direction unambiguous at a glance, since this is exactly the thing that
    // was silently backwards before M13.
    private var chainSummary: String {
        let parts = slots
            .compactMap { ChainModule(rawValue: $0) }
            .filter { $0 != .empty }
            .map { $0.shortLabel }
        return parts.isEmpty
            ? "Source passes through unwarped"
            : "Source ➔ " + parts.joined(separator: " ➔ ") + " ➔ Output"
    }

    private var missingModules: [String] {
        let present = Set(slots)
        return [ChainModule.mirror1, .mirror2, .rotation1, .rotation2, .displacement]
            .filter { !present.contains($0.rawValue) }
            .map { $0.label }
    }

    private func setSlot(_ index: Int, _ value: Int) {
        slots[index] = value
        store.set(Self.slotKeyPaths[index], Float(value))
    }

    private func applyPreset(_ order: [Int]) {
        for i in 0..<order.count { setSlot(i, order[i]) }
    }

    var body: some View {
        CollapsibleSection("Geometry Order Routing") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Signal order: slot 1 acts on the source, slot 5 is seen last")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(0..<5, id: \.self) { i in
                    Picker("Slot \(i + 1)", selection: Binding(
                        get: { slots[i] },
                        set: { setSlot(i, $0) }
                    )) {
                        ForEach(ChainModule.allCases) { module in
                            Text(module.label).tag(module.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Text(chainSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !missingModules.isEmpty {
                    Text("Not in chain: " + missingModules.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // M14 Part 2. One global control, sitting here rather than in
                // any module's section because it is about how the chain
                // composes, not about any one module. At 0 every module's luma
                // modulator reads the source video, as it always has; at 1 each
                // one reads what the chain has already built by the time it
                // runs, so a module late in the chain tracks the composite
                // instead of the source.
                ParamSlider(\.lumaStageDepth, store: store)
                Text("0 = modules read the source video, 1 = each reads the chain so far")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                Text("Presets")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Two rows of four: chains on top, single-module starting
                // points below. One row of eight does not fit the 330pt column.
                VStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(Self.presets.filter { $0.id / 4 == row }) { preset in
                                Button(preset.label) { applyPreset(preset.order) }
                                    .font(.caption2)
                                    .buttonStyle(.bordered)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .onAppear {
                if !loaded {
                    slots = Self.slotKeyPaths.map { Int(store.get($0)) }
                    loaded = true
                }
            }
        }
    }
}

private struct TorsionSection: View {
    let store: ParamStore
    @State private var waveType = 0
    @State private var radial = true
    @State private var loaded = false

    var body: some View {
        CollapsibleSection("Rotation 1") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Oscillator Type", selection: Binding(
                    get: { waveType },
                    set: { waveType = $0; store.set(\.torsionWaveType, Float($0)) }
                )) {
                    Text("Sine").tag(0)
                    Text("Tri").tag(1)
                    Text("Saw").tag(2)
                    Text("Sqr").tag(4)
                    Text("S&H").tag(3)
                }
                .pickerStyle(.segmented)

                if waveType == 3 {
                    ParamSlider(\.torsionLag, store: store)
                }

                Picker("Oscillator Mode", selection: Binding(
                    get: { radial },
                    set: { radial = $0; store.set(\.torsionRadialMode, $0 ? 1.0 : 0.0) }
                )) {
                    Text("Normal").tag(false)
                    Text("Radial").tag(true)
                }
                .pickerStyle(.segmented)

                ParamSlider(\.torsionStrength, store: store)
                ParamSlider(\.torsionFrequency, store: store)
                ParamSlider(\.lumaTorsion, store: store)

                ParamSlider(\.torsionOrbitDepth, store: store)

                // M16 Part 2: where this spiral stands. Sums with Dynamic
                // Orbit above rather than being overridden by it — both can
                // be dialled in together, and this one still moves the twist
                // origin with Orbit Depth at 0.
                ParamSlider(\.torsionCenterX, store: store)
                ParamSlider(\.torsionCenterY, store: store)
            }
            .onAppear {
                if !loaded {
                    waveType = Int(store.get(\.torsionWaveType))
                    radial = store.get(\.torsionRadialMode) > 0.5
                    loaded = true
                }
            }
        }
    }
}

// M7 Phase 7.1: Spiral 2 — nested inside Spiral 1's already-warped output
// (planetary epicycle). Mirrors TorsionSection's structure exactly: discrete
// state (wave type, radial mode) as local @State write-through, VCO controls
// grouped at top, placement (orbit depth) at bottom, per the established
// oscillator-module convention.
private struct Spiral2Section: View {
    let store: ParamStore
    @State private var waveType = 0
    @State private var radial = true
    @State private var loaded = false

    var body: some View {
        CollapsibleSection("Rotation 2") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Oscillator Type", selection: Binding(
                    get: { waveType },
                    set: { waveType = $0; store.set(\.spiral2WaveType, Float($0)) }
                )) {
                    Text("Sine").tag(0)
                    Text("Tri").tag(1)
                    Text("Saw").tag(2)
                    Text("Sqr").tag(4)
                    Text("S&H").tag(3)
                }
                .pickerStyle(.segmented)

                if waveType == 3 {
                    ParamSlider(\.spiral2Lag, store: store)
                }

                Picker("Oscillator Mode", selection: Binding(
                    get: { radial },
                    set: { radial = $0; store.set(\.spiral2RadialMode, $0 ? 1.0 : 0.0) }
                )) {
                    Text("Normal").tag(false)
                    Text("Radial").tag(true)
                }
                .pickerStyle(.segmented)

                ParamSlider(\.spiral2Strength, store: store)
                ParamSlider(\.spiral2FreqOffset, store: store)

                ParamSlider(\.spiral2OrbitDepth, store: store)
                ParamSlider(\.spiral2OrbitPhase, store: store)
                ParamSlider(\.spiral2OrbitRatio, store: store)

                // M16 Part 2: independent of Rotation 1's center, same as its
                // orbit is independent — sums with Dynamic Orbit above.
                ParamSlider(\.spiral2CenterX, store: store)
                ParamSlider(\.spiral2CenterY, store: store)
            }
            .onAppear {
                if !loaded {
                    waveType = Int(store.get(\.spiral2WaveType))
                    radial = store.get(\.spiral2RadialMode) > 0.5
                    loaded = true
                }
            }
        }
    }
}

private struct MirrorSection: View {
    struct Config {
        let title: String
        let defaultAngle: Float
        let onKP, waveTypeKP, lagKP, spinOnKP, spinSpeedKP, staticAngleKP: WritableKeyPath<LiveParams, Float>
        let ampKP, freqKP, speedKP, lumaModKP, radialKP: WritableKeyPath<LiveParams, Float>
        // M14 Part 1: fold center. The section is config-driven, so two key
        // paths and two slider rows cover both mirrors with no duplication.
        let centerXKP, centerYKP: WritableKeyPath<LiveParams, Float>
        // M26: the doubled fold — flag plus angle offset, per module.
        // DECLARED LAST, AFTER centerXKP/centerYKP, because the memberwise
        // initializer takes its arguments in declaration order and both call
        // sites below pass the center pair first. Declaring these above the
        // centers while passing them below is a compile error, not a silent
        // mis-wire — but it is a compile error I shipped, so it is worth a
        // comment: any field added to this Config must be declared in the same
        // position it is passed.
        let doubleOnKP, doubleOffsetKP: WritableKeyPath<LiveParams, Float>

        static let mirror1 = Config(
            title: "Mirror 1", defaultAngle: 0.0,
            onKP: \.mirror1On, waveTypeKP: \.mirror1WaveType, lagKP: \.mirror1Lag,
            spinOnKP: \.mirror1AutoSpinOn, spinSpeedKP: \.mirror1AutoSpinSpeed, staticAngleKP: \.mirror1StaticAngle,
            ampKP: \.mirror1RippleAmpRaw, freqKP: \.mirror1RippleFreq, speedKP: \.mirror1Speed, lumaModKP: \.lumaMod1,
            radialKP: \.mirror1RadialMode,
            centerXKP: \.mirror1CenterX, centerYKP: \.mirror1CenterY,
            doubleOnKP: \.mirror1DoubleOn, doubleOffsetKP: \.mirror1DoubleOffset
        )
        static let mirror2 = Config(
            title: "Mirror 2", defaultAngle: 1.5707963,
            onKP: \.mirror2On, waveTypeKP: \.mirror2WaveType, lagKP: \.mirror2Lag,
            spinOnKP: \.mirror2AutoSpinOn, spinSpeedKP: \.mirror2AutoSpinSpeed, staticAngleKP: \.mirror2StaticAngle,
            ampKP: \.mirror2RippleAmpRaw, freqKP: \.mirror2RippleFreq, speedKP: \.mirror2Speed, lumaModKP: \.lumaMod2,
            radialKP: \.mirror2RadialMode,
            centerXKP: \.mirror2CenterX, centerYKP: \.mirror2CenterY,
            doubleOnKP: \.mirror2DoubleOn, doubleOffsetKP: \.mirror2DoubleOffset
        )
    }

    let store: ParamStore
    let config: Config

    @State private var mirrorOn = true
    @State private var waveType = 0
    @State private var spinOn = false
    @State private var radial = false
    @State private var doubledOn = false
    @State private var loaded = false

    var body: some View {
        CollapsibleSection(config.title) {
            VStack(alignment: .leading, spacing: 10) {
                // M26: one header line carrying both toggles. Doubled on the
                // left in the default checkbox style — the same style the Spin
                // toggle uses in the placement block, deliberately NOT a second
                // .switch, so the module's own on/off stays the only switch in
                // the section and reads as the more consequential control.
                // Enabled moved right to sit beside its switch, which stays
                // hard right where it has always been.
                HStack {
                    Toggle("Doubled", isOn: Binding(
                        get: { doubledOn },
                        set: { doubledOn = $0; store.set(config.doubleOnKP, $0 ? 1.0 : 0.0) }
                    ))
                    Spacer()
                    Text("Enabled").font(.caption).foregroundColor(.secondary)
                    Toggle("", isOn: Binding(
                        get: { mirrorOn },
                        set: { mirrorOn = $0; store.set(config.onKP, $0 ? 1.0 : 0.0) }
                    )).toggleStyle(.switch)
                }

                // ---- VCO block ----
                Picker("Oscillator Type", selection: Binding(
                    get: { waveType },
                    set: { waveType = $0; store.set(config.waveTypeKP, Float($0)) }
                )) {
                    Text("Sine").tag(0)
                    Text("Tri").tag(1)
                    Text("Saw").tag(2)
                    Text("Sqr").tag(4)
                    Text("S&H").tag(3)
                }
                .pickerStyle(.segmented)

                if waveType == 3 {
                    ParamSlider(config.lagKP, store: store)
                }

                Picker("Oscillator Mode", selection: Binding(
                    get: { radial },
                    set: { radial = $0; store.set(config.radialKP, $0 ? 1.0 : 0.0) }
                )) {
                    Text("Normal").tag(false)
                    Text("Radial").tag(true)
                }
                .pickerStyle(.segmented)

                ParamSlider(config.ampKP, store: store)
                ParamSlider(config.freqKP, store: store)
                ParamSlider(config.speedKP, store: store)
                // M12 Part 1: range narrowed from ±2 to ±1.5 alongside the shader fix.
                // Full deflection is now ±0.75 in uv space — the seam pushed just
                // past the frame edge, not six frames away. The whole slider is
                // usable travel; it used to go dead somewhere past a third.
                ParamSlider(config.lumaModKP, store: store)

                // ---- Placement block (bottom) ----
                Toggle("Spin", isOn: Binding(
                    get: { spinOn },
                    set: { spinOn = $0; store.set(config.spinOnKP, $0 ? 1.0 : 0.0) }
                ))

                // M26: the two angle rows are wrapped in a Group so this VStack's
                // top-level child count stays exactly where it was before this
                // milestone. The section already sat above the classic 10-child
                // ViewBuilder ceiling and compiled — parameter-pack ViewBuilder
                // handles it — but the roadmap flags that ceiling as live for
                // RecordingSection, and a Group here is free. Same pattern
                // RecordingSection uses for the same reason.
                Group {
                    if spinOn {
                        ParamSlider(config.spinSpeedKP, store: store)
                    } else {
                        ParamSlider(config.staticAngleKP, store: store)
                    }

                    // M26. Placement block, directly under the angle it is
                    // measured against, per the standing oscillator-top /
                    // placement-bottom convention — it is an angle relative to
                    // that angle, so it belongs beside it rather than up next
                    // to its own toggle. Same 0...2pi range as Mirror Angle so
                    // the two read against each other; theta and 2pi-theta are
                    // genuinely different folds, not redundant, so the full
                    // turn earns its travel.
                    //
                    // NO NULL DETENT, on purpose. The detent exists to help a
                    // slider land on its home value, and here the home value is
                    // pi (opposed — the full-frame mirror), not 0. A detent at
                    // 0 would put the catch on the one end of the travel that
                    // does the least. The per-slider reset button returns to pi.
                    //
                    // Turning this away from pi swings the partner's reflection
                    // line away from the base line, which turns the pair from a
                    // mirror into a wedge.
                    if doubledOn {
                        ParamSlider(config.doubleOffsetKP, store: store)
                    }
                }

                // M14 Part 1. Placement block, per the standing VCO layout
                // convention: oscillator controls at the top, placement at the
                // bottom. Both carry the null detent — 0 is the shipped state
                // and the one you most often want to get back to by hand.
                // Past roughly +/-0.6 the seam starts leaving the frame at
                // scale 1, which is a real state rather than wasted travel:
                // whatever the seam has left stops being folded at all.
                ParamSlider(config.centerXKP, store: store)
                ParamSlider(config.centerYKP, store: store)
            }
            .onAppear {
                if !loaded {
                    mirrorOn = store.get(config.onKP) > 0.5
                    waveType = Int(store.get(config.waveTypeKP))
                    spinOn = store.get(config.spinOnKP) > 0.5
                    radial = store.get(config.radialKP) > 0.5
                    doubledOn = store.get(config.doubleOnKP) > 0.5
                    loaded = true
                }
            }
        }
    }
}

// M8 Phase A: Displacement Mesh. Placed after the mirrors in the sidebar because
// that is where it sits conceptually — the fourth geometry module — even though
// its position in the actual signal path is now whatever the routing chain says.
//
// Layout follows the established oscillator-module convention: mode controls at
// the top where they frame everything below, then the two axis blocks, each
// running VCO controls first and modulation last.
private struct DisplacementSection: View {
    let store: ParamStore
    @State private var waveTypeX = 0
    @State private var waveTypeY = 0
    @State private var radial = false
    @State private var loaded = false

    var body: some View {
        CollapsibleSection("Displacement") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Oscillator Mode", selection: Binding(
                    get: { radial },
                    set: { radial = $0; store.set(\.dispRadialMode, $0 ? 1.0 : 0.0) }
                )) {
                    Text("Normal").tag(false)
                    Text("Radial").tag(true)
                }
                .pickerStyle(.segmented)

                ParamSlider(\.dispRadialPush, store: store)

                Text("At 0, X pushes horizontally and Y vertically. At 1, X pushes outward from center and Y swirls around it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // M16 Part 2: where this module stands — moves the wave
                // arguments AND the radial push basis together, so the
                // pattern and the push direction re-anchor as one move. A
                // whole-module property like Radial Push above, not
                // per-axis, so it sits here rather than in either axis block
                // below. High VCO Frequency turns a small move into a
                // fast-looking scroll — matches the mirrors' own center at
                // high ripple frequency, not a defect.
                ParamSlider(\.dispCenterX, store: store)
                ParamSlider(\.dispCenterY, store: store)

                Divider()

                Text("X Axis")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Oscillator Type", selection: Binding(
                    get: { waveTypeX },
                    set: { waveTypeX = $0; store.set(\.dispWaveTypeX, Float($0)) }
                )) {
                    Text("Sine").tag(0)
                    Text("Tri").tag(1)
                    Text("Saw").tag(2)
                    Text("Sqr").tag(4)
                    Text("S&H").tag(3)
                }
                .pickerStyle(.segmented)

                if waveTypeX == 3 {
                    ParamSlider(\.dispLagX, store: store)
                }

                ParamSlider(\.dispAmpX, store: store)
                // Range opened way up for finer folds, with a curved response so
                // it stays playable: the bottom quarter of the track covers
                // roughly 0.5-3.5, the top quarter roughly 46-60, and the middle
                // moves fast. See SliderResponse.tails.
                ParamSlider(\.dispFreqX, store: store)
                ParamSlider(\.dispSpeedX, store: store)
                ParamSlider(\.lumaModDispX, store: store)

                Divider()

                Text("Y Axis")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Oscillator Type", selection: Binding(
                    get: { waveTypeY },
                    set: { waveTypeY = $0; store.set(\.dispWaveTypeY, Float($0)) }
                )) {
                    Text("Sine").tag(0)
                    Text("Tri").tag(1)
                    Text("Saw").tag(2)
                    Text("Sqr").tag(4)
                    Text("S&H").tag(3)
                }
                .pickerStyle(.segmented)

                if waveTypeY == 3 {
                    ParamSlider(\.dispLagY, store: store)
                }

                ParamSlider(\.dispAmpY, store: store)
                ParamSlider(\.dispFreqY, store: store)
                ParamSlider(\.dispSpeedY, store: store)
                ParamSlider(\.lumaModDispY, store: store)
            }
            .onAppear {
                if !loaded {
                    waveTypeX = Int(store.get(\.dispWaveTypeX))
                    waveTypeY = Int(store.get(\.dispWaveTypeY))
                    radial = store.get(\.dispRadialMode) > 0.5
                    loaded = true
                }
            }
        }
    }
}

private struct HoleKeyerSection: View {
    let store: ParamStore
    @State private var keyingOn = false
    @State private var loaded = false

    var body: some View {
        CollapsibleSection("Keying") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Enabled").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { keyingOn },
                        set: { keyingOn = $0; store.set(\.negativeSpace, $0 ? 1.0 : 0.0) }
                    )).toggleStyle(.switch)
                }

                // M12: the Pre-FX / Post-FX toggle sat here. Pre-FX keyed off a
                // private copy of both mirrors run on the unwarped uv, so the
                // key could describe geometry that was not on screen. Post-FX
                // was the shipped default and is now the only behavior.
                //
                // M12 Part 7C: Key Polarity now governs all three keyers,
                // replacing the two per-key "Invert Key" toggles that used to
                // live inside Luma Key 1 / 2 — which, confusingly, shared a
                // label with the toggle below even though they did different
                // jobs. Polarity flips which side of each keyer's threshold
                // gets kept (Brights above / Darks below); Invert Key
                // soft-NOTs the finished composite. Two orthogonal controls,
                // sharing one row as compact checkboxes rather than each
                // claiming a full-width switch line to itself.
                HStack(spacing: 8) {
                    ParamToggle(\.invertEntireHoleKey, store: store)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ParamToggle(\.keyerPolarity, store: store)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.checkbox)

                // M12 Part 4: the two whole-section controls come first, then
                // the per-module ones. Softness moved above Collision Threshold
                // because it now governs every threshold below it, including
                // that one.
                //
                // Range is 0...0.35, not the old 0...0.5. One slider drives
                // every key edge in the section now, and the top of the old
                // range was a feather so wide the threshold stopped reading as
                // a threshold at all.
                ParamSlider(\.keySoftness, store: store)
                ParamSlider(\.negativeSpaceThreshold, store: store)
                ParamSlider(\.rectification, store: store)
                // M12: the Rotation ➔ Holes mode picker is gone. Multiply is
                // the only surviving behavior and is always active, so what
                // was "Rotation Wave Mix" (the depth of that one mode) is now
                // simply the control, under its own name.
                //
                // Multiply survives the cut because it is not a keying mode:
                // it ring-modulates the rotation wave against the mirror
                // interference upstream of the composite. Threshold gave
                // concentric rings, and AND / XOR needed a partner picker and
                // the consumption machinery behind it to be visible at all.
                ParamSlider(\.torsionInHoles, store: store)

                // M7 Phase 7.1: how Spiral 1's and Spiral 2's twist waves
                // combine into the signal the slider above injects. It belongs
                // directly beneath that slider — verified in M12 that
                // combineSpiralWaves has exactly one caller, rotationHoleWave,
                // so this is a KEYING control and not a geometry one, despite
                // naming two geometry modules.
                //
                // Multiply here is ring modulation and, unlike the other three,
                // does NOT reduce to Spiral 1 alone when Spiral 2 is silent —
                // it reduces to nothing, because a ring mod with a dead input
                // outputs nothing. Give Rotation 2 some amplitude before
                // expecting it to do anything.
                ParamPicker(\.spiralCombineMode, store: store)

                // M8 Phase C.3 built Displacement's own route into the holes
                // here (Collision), keyed on how hard the field is pushing
                // rather than on what it's pointing at. Retired, M12 Part 7
                // cleanup: Keyer 3's Displacement feed (below) already keys on
                // displacement, and a second, narrower signal wasn't earning
                // its slider.

                // M12 Part 7C — THE THREE-KEYER RESTRUCTURE. Seven feed taps
                // and two seven-way menus become three keyers fixed to the
                // instrument's own module families, each with a two-way feed
                // (its family, or Warped Final). Raw / Source Input is
                // dropped — Warped Final on every keyer already reaches the
                // unwarped source by emptying the routing chain.
                //
                // Keyer 1's threshold is absolute. Keyers 2 and 3 are bipolar
                // OFFSETS from Keyer 1, with a null detent at zero — the rest
                // position, and exactly a difference key: two keyers at the
                // same threshold on different taps, XOR'd. Dragging Threshold
                // 1 sweeps all three keyers as a rigid group; the offsets
                // breathe the gap between them.
                //
                // "Silencing" one keyer while another stays live: push its
                // offset far enough positive that Threshold 1 + offset clamps
                // to 1.0. That clamp is forgiving — any offset past the exact
                // silencing point lands on the same 1.0, so there is no needle
                // to thread. Keyer 1 alone, at any threshold, is reachable the
                // same way: offset the other two by roughly (1.0 − Threshold
                // 1) or more. The offset range (±1.0) always covers this,
                // since Threshold 1 never exceeds 1.0.
                //
                // Each keyer collapsed from 6 UI lines to 3 this pass: the
                // group header IS the slider's label row (ParamSlider already
                // puts reset + value on that same line, so passing the
                // section title as the slider's label merges them for free,
                // no separate header Text needed); the Feed picker dropped its
                // own redundant label (showLabel: false) and now shares a row
                // with a compact XOR checkbox instead of a full-width switch
                // on its own line. Thin dividers replace the old bold Text
                // headers as the thing that tells the three groups apart —
                // enough to stop them melting into one wall of controls
                // without opening a gap in the flow.
                Divider().padding(.vertical, 2)

                ParamSlider(\.keyerThreshold1, store: store)
                HStack(spacing: 10) {
                    ParamPicker(\.keyerFeed1, store: store, showLabel: false)
                    ParamToggle(label: "XOR", store: store, keyPath: \.keyerXOR1)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                }

                Divider().padding(.vertical, 2)

                ParamSlider(\.keyerOffset2, store: store)
                HStack(spacing: 10) {
                    ParamPicker(\.keyerFeed2, store: store, showLabel: false)
                    ParamToggle(label: "XOR", store: store, keyPath: \.keyerXOR2)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                }

                Divider().padding(.vertical, 2)

                ParamSlider(\.keyerOffset3, store: store)
                HStack(spacing: 10) {
                    ParamPicker(\.keyerFeed3, store: store, showLabel: false)
                    ParamToggle(label: "XOR", store: store, keyPath: \.keyerXOR3)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                }
            }
            .onAppear {
                if !loaded {
                    keyingOn = store.get(\.negativeSpace) > 0.5
                    loaded = true
                }
            }
        }
    }
}

private struct LFOSection: View {
    let store: ParamStore
    // M9: needed only for the Reset Phase button, which re-aligns the two LFO
    // accumulators. A plain `let` reference to a non-observed class — nothing
    // here reads or publishes renderer state, so this cannot invalidate
    // anything on a slider drag.
    let renderer: LiquidRenderer

    @State private var waveType = 0
    // M9: discrete state gating conditional UI (LFO 2's slew slider), so local
    // @State write-through per the house rule, same as waveType above.
    @State private var lfo2WaveType = 0
    @State private var combineMode = 0
    // M16: discrete state gating the LFO's rate range, local @State
    // write-through per the house rule, same as waveType above.
    @State private var rateRange = 0
    @State private var loaded = false

    var body: some View {
        CollapsibleSection("Global LFO") {
            VStack(alignment: .leading, spacing: 10) {
                ParamSlider(\.lfoRate, store: store)

                // M16 revision: the Rate slider's RANGE. Slow is the range
                // this instrument has always had (~0.32 Hz at full), so every
                // existing patch's Rate position still means what it did.
                // Fast multiplies it by 10 (~3.2 Hz) for modulation that
                // reads as motion rather than drift. Discrete on purpose:
                // flipping this is the only thing that ever rescales what a
                // given Rate position means, which is why it is not simply a
                // wider slider. LFO 2's rate offset scales with it, so the
                // beat stays proportional instead of crawling in Fast.
                Picker("LFO Rate Range", selection: Binding(
                    get: { rateRange },
                    set: { rateRange = $0; store.set(\.lfoRateRange, Float($0)) }
                )) {
                    Text("Slow").tag(0)
                    Text("Fast").tag(1)
                }
                .pickerStyle(.segmented)

                Picker("LFO Waveform", selection: Binding(
                    get: { waveType },
                    set: { waveType = $0; store.set(\.lfoWaveType, Float($0)) }
                )) {
                    Text("Sine").tag(0)
                    Text("Tri").tag(1)
                    Text("Saw").tag(2)
                    Text("Sqr").tag(4)
                    Text("S&H").tag(3)
                }
                .pickerStyle(.segmented)

                if waveType == 3 {
                    ParamSlider(\.lfoLag, store: store)
                }

                // ---- M9: second oscillator ----
                // Sits BETWEEN LFO 1's controls and the destination list on
                // purpose: everything below this divider reads the COMBINED
                // bus, so the reading order matches the signal order.
                Divider()

                Text("Second Oscillator")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ParamSlider(\.lfo2Depth, store: store)
                ParamSlider(\.lfo2RateOffset, store: store)

                Picker("LFO 2 Waveform", selection: Binding(
                    get: { lfo2WaveType },
                    set: { lfo2WaveType = $0; store.set(\.lfo2WaveType, Float($0)) }
                )) {
                    Text("Sine").tag(0)
                    Text("Tri").tag(1)
                    Text("Saw").tag(2)
                    Text("Sqr").tag(4)
                    Text("S&H").tag(3)
                }
                .pickerStyle(.segmented)

                if lfo2WaveType == 3 {
                    ParamSlider(\.lfo2Lag, store: store)
                }

                ParamSlider(\.lfo2PhaseOffset, store: store)

                // Additive is the default because it is the only mode (with
                // Subtractive) that is an exact identity at Depth 0. Multiply
                // is a ring modulator, so at Depth 0 it silences the whole
                // modulation bus — expected behavior for a ring mod with a
                // dead input, not a bug.
                Picker("LFO Combine", selection: Binding(
                    get: { combineMode },
                    set: { combineMode = $0; store.set(\.lfoCombineMode, Float($0)) }
                )) {
                    Text("Add").tag(0)
                    Text("Sub").tag(1)
                    Text("XOR").tag(2)
                    Text("Mult").tag(3)
                }
                .pickerStyle(.segmented)

                // An event, not a parameter — it goes straight to the renderer
                // rather than through ParamStore. Scoped to the two Global LFO
                // phases only; the stop-motion trigger clock is a separate
                // clock and stays where it is.
                Button("Reset LFO Phase") {
                    renderer.requestLFOPhaseReset()
                }
                .help("Re-align both LFO oscillators so the beat cycle restarts from coincidence")

                Divider()

                // ---- M16: the one global bus control ----
                // A PHASE ANGLE between successive members of every family
                // below, not a blend. 0 = all members in step (the default,
                // and pre-M16 behavior). 0.5 = 90 degrees apart, which is
                // what makes a center path circle and an amplitude pair roll.
                // 1.0 = 180 degrees, exact counter-motion. The negative half
                // is the same angles the other way round, which reverses the
                // direction a center path travels.
                ParamSlider(\.busSpread, store: store)
                    .help("Phase angle between family members. 0 = in step. 0.5 = quadrature (circular). 1.0 = antiphase (counter-move).")

                Divider()

                // ---- Amplitude families ----
                // Rotation 1 + Rotation 2 strength. At Bus Spread 1.0 the two
                // spirals counter-wind, one tightening as the other unwinds.
                ParamSlider(\.lfoToRotation, store: store)

                // Mirror 1 + Mirror 2 ripple amplitude.
                ParamSlider(\.lfoToMirrors, store: store)

                // Displace X + Y amplitude. At Bus Spread 0.5 the two axes
                // reach quadrature and the field moves in circles rather than
                // pulsing along a diagonal.
                ParamSlider(\.lfoToDisplacement, store: store)

                Divider()

                // ---- Center families: the bus as a true XY vector ----
                // Rotation 1's twist origin takes the bus as (X, Y);
                // Rotation 2's takes it axis-swapped as (Y, X), tracing a
                // mirror-image path — same structure as Mirror Center below.
                // SUMS with Dynamic Orbit in each Rotation section rather
                // than fighting it: both can be dialled in together.
                ParamSlider(\.lfoToRotationCenter, store: store)
                    .help("Drives both twist origins as an XY path. Rotation 2 takes the axes swapped. Sums with each module's own Dynamic Orbit.")

                // Mirror 1's fold center takes the bus as (X, Y); Mirror 2's
                // takes it axis-swapped as (Y, X), so the two seams trace
                // mirror-image paths and pull apart rather than sliding
                // across the frame together. Sums on top of each Mirror
                // section's own center sliders, which stay a hand offset.
                ParamSlider(\.lfoToMirrorCenter, store: store)
                    .help("Drives both fold centers as an XY path. Mirror 2 takes the axes swapped, so the two centers move oppositely.")

                // Displacement has only ONE center — no second member to
                // swap axes against or spread. Plain XY: X drives X, Y
                // drives Y. Moves the pattern and the radial push direction
                // together.
                ParamSlider(\.lfoToDispCenter, store: store)
                    .help("Drives the displacement anchor as an XY path. No second member — Bus Spread has nothing to angle this one against.")

                Divider()

                // ---- Keying: the three-member family ----
                // Threshold 1 moves the whole three-keyer cluster as a rigid
                // group; Offsets 2 and 3 sit one and two Bus Spread steps
                // out, so the two gaps never breathe together.
                ParamSlider(\.lfoToKeying, store: store)

                Divider()

                // ---- Standalone destinations ----
                // Deliberately NOT paired with anything: each drives one
                // parameter and has no partner to be spread against.
                // Radial Push sweeps displacement between cartesian shimmer
                // and radial breathing — best dialled in sparingly.
                ParamSlider(\.lfoToRadialPush, store: store)
                // Luma Staging drifts every geometry module's luma modulator
                // between tracking the source and tracking the composite.
                // Slow rates suit it best.
                ParamSlider(\.lfoToLumaStage, store: store)

                // M4.3b: unlike every destination above, this one modulates a
                // TRANSPORT control rather than the image — it sweeps where in
                // each stop-motion trigger cycle the frame is grabbed. Audible
                // (visible) only while recording in Stop-motion mode with the
                // auto-trigger armed; see the Recording section.
                ParamSlider(\.lfoToCapturePhase, store: store)
            }
            .onAppear {
                if !loaded {
                    waveType = Int(store.get(\.lfoWaveType))
                    lfo2WaveType = Int(store.get(\.lfo2WaveType))
                    combineMode = Int(store.get(\.lfoCombineMode))
                    rateRange = Int(store.get(\.lfoRateRange))
                    loaded = true
                }
            }
        }
    }
}

// M1a: final wet/dry blend for the whole chain. Lives near the end of the
// sidebar to mirror its position as the final color op in the shader (before
// the M2 output vignette, which shape-crops this mixed result).
private struct OutputMixSection: View {
    let store: ParamStore

    var body: some View {
        CollapsibleSection("Mix") {
            ParamSlider(\.outputMix, store: store)
        }
    }
}

// M2: end-of-chain screen-space shape matte. Mattes the already-mixed output
// (runs AFTER the M1a mix in the shader). Placed right after Output Mix in the
// sidebar to mirror its position as the final output-shaping stage. The shape
// picker is local @State so the conditional sliders can be gated; it writes
// through to the store like every other control. Aspect is a single bipolar
// stretch knob that also serves as the Rect's width/height ratio, so there are
// no separate rect W/H sliders.
//
// M5 appended an Edge Glow block below a Divider() here; M12 removed it along
// with the rest of the glow. The vignette is the only output-shaping stage
// again.
private struct OutputVignetteSection: View {
    let store: ParamStore
    @State private var shape = 0
    @State private var loaded = false

    var body: some View {
        CollapsibleSection("Vignette") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Shape", selection: Binding(
                    get: { shape },
                    set: { shape = $0; store.set(\.vignetteShape, Float($0)) }
                )) {
                    Text("Off").tag(0)
                    Text("Circle").tag(1)
                    Text("Rect").tag(2)
                }
                .pickerStyle(.segmented)

                if shape != 0 {
                    ParamSlider(\.vignetteCenterX, store: store)
                    ParamSlider(\.vignetteCenterY, store: store)
                    ParamSlider(\.vignetteSize, store: store)
                    ParamSlider(\.vignetteAspect, store: store)
                    ParamSlider(\.vignetteSoftness, store: store)

                    // M4.4 Part B: route the matte into the alpha channel.
                    //
                    // Lives HERE rather than in Recording for two reasons: it
                    // is a property of the matte, and RecordingSection is at
                    // SwiftUI's 10-child ViewBuilder limit (M18 already had to
                    // wrap its picker in a Group to fit).
                    //
                    // This is the one control in the instrument whose effect
                    // is invisible on screen — the present pass forces the
                    // window opaque on purpose — so the caption states where
                    // it actually shows up rather than leaving that to be
                    // remembered.
                    Divider()
                    ParamToggle(\.vignetteAlpha, store: store)
                    Text("Recorded only in ProRes 4444. Also preserved in PNG screenshots.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // M12: the Edge Glow block sat below a Divider() here — an
                // on/off, an Edge/Bloom mode picker, radius and gain. Removed
                // with the rest of M5.
            }
            .onAppear {
                if !loaded {
                    shape = Int(store.get(\.vignetteShape))
                    loaded = true
                }
            }
        }
    }
}

// M4.1/M4.2: Recording. This section observes RecorderState for its own
// content, and after M20 Part 2 that is safe for a specific reason: every
// field LEFT on RecorderState publishes only on a user action (folder choice,
// transport press, resolution switch). The counters that tick during a take
// moved to RecorderProgress, observed solely by RecordingIndicator.
//
// The old note here said a once-per-second publish was fine because the
// invalidation was "confined to this section." Measurement says otherwise:
// MTKView draws on the main thread, so re-laying-out this section — two
// AppKit .menu Pickers, two segmented Pickers, a TextField (M25 removed
// that one), the transport —
// was producing ~50 ms frames and costing about 4 fps for the whole take.
// Confinement to a section only helps if the section is cheap. This one
// isn't. Keep periodic publishers off any object this view observes.
//
// recordFPS lives in ParamStore rather than on RecorderState, per the
// established rule for anything a control writes: local @State
// write-through, same as every picker here. It's read
// exactly once per take, at the moment Record is pressed (below) — the
// renderer itself never touches it directly, only FrameCapture's locked
// snapshot of it. Do not add future continuous controls (e.g. a bitrate or
// resolution slider) to RecorderState as this section grows further — they
// belong in ParamStore.
//
// The REC dot is a plain on/off indicator with no timer and no animation —
// solid while recording, dimmed while paused. It was a 0.6 s blink; that
// blink was the single largest contributor to the frame loss above, because
// its @State lived on this section rather than on a leaf.
// M4.3b: stop-motion trigger scope. A one-cycle track with a moving playhead
// (the trigger clock) and a marker (the LFO-modulated capture point). A frame is
// grabbed each time the playhead crosses the marker, so watching the two
// converge tells you exactly when the next capture lands — and with "LFO ➔
// Capture Phase" up, you can see the marker drifting and the captures going
// uneven.
//
// PERFORMANCE: this is the ONLY per-frame-ish redraw in the app, and it is
// deliberately quarantined. It's its own View, so SwiftUI creates it only when
// the auto-trigger is armed and destroys it (and its timer with it) when
// disarmed — nothing ticks while it's off screen. It refreshes at 15Hz, not
// render rate, reads two Floats behind FrameCapture's separate display-only
// scopeLock (never the transport lock, never ParamStore), and invalidates
// nothing but itself. Do not lift this @State up into the section: that would
// redraw the whole Recording section 15 times a second.
private struct CaptureScopeMeter: View {
    let capture: FrameCapture

    @State private var playhead: Float = 0
    @State private var marker: Float = 0

    private let refresh = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trigger Scope")
                .font(.caption)
                .foregroundColor(.secondary)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 6)

                    // Capture point — the frame is grabbed as the playhead
                    // passes this line.
                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 2, height: 14)
                        .offset(x: CGFloat(marker) * w - 1)

                    // Trigger clock playhead.
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 9, height: 9)
                        .offset(x: CGFloat(playhead) * w - 4.5)
                }
                .frame(height: 14)
            }
            .frame(height: 14)
        }
        .onReceive(refresh) { _ in
            let scope = capture.triggerScope
            playhead = scope.playhead
            marker = scope.marker
        }
    }
}

// MARK: - M20 Part 2: recording indicator
//
// The REC dot and the during-a-take counters, quarantined into their own leaf
// view for the same reason CaptureScopeMeter is: this
// is the only thing in the sidebar that updates while a take runs, and
// MTKView calls draw() on the MAIN THREAD, so whatever a publish invalidates
// comes straight out of the render loop's frame budget.
//
// Before this split, the counters lived on RecorderState — which the whole
// Recording section observed — and the REC dot's blink @State lived on the
// section itself. Either one re-laid-out two AppKit .menu Pickers, two
// segmented Pickers, a TextField and the transport, and measurement put that
// at ~50 ms frames and about 4 fps lost for the entire take, at every
// resolution and with zero frames actually being captured. The work being
// invalidated had nothing to do with recording; it just happened to share a
// view body with something that ticked.
//
// So: this view observes RecorderProgress and NOTHING else does. It contains
// no control, so a publish here lays out three Text views.
//
// The blink is gone entirely — a plain on/off indicator, per the confirmed
// preference. That also removes the 0.6 s timer and its 0.3 s animation
// outright rather than merely quarantining them: a solid dot needs no
// recurring event at all, which is strictly better than a cheap one. Paused
// dims it instead of blinking it.
private struct RecordingIndicator: View {
    @ObservedObject var progress: RecorderProgress
    let store: ParamStore
    let isPaused: Bool
    let recordMode: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(isPaused ? 0.4 : 1.0)

            if recordMode == 0 {
                Text(timeString(progress.elapsedSeconds))
                    .font(.caption.monospacedDigit())
                Text("·").foregroundColor(.secondary)
                Text("\(progress.recordedFrameCount) frames")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Stop-motion: frame COUNT is the meaningful figure; the
                // clip's real duration is frames / playback fps, not
                // wall-clock elapsed.
                Text("\(progress.recordedFrameCount) frames")
                    .font(.caption.monospacedDigit())
                Text("·").foregroundColor(.secondary)
                Text("clip \(timeString(stopMotionClipSeconds))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if progress.dropCount > 0 {
                Text("· \(progress.dropCount) dropped")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer()
        }
    }

    /// Assembled stop-motion clip length = frames / playback fps. recordFPS in
    /// the store equals the locked take FPS here because the picker is
    /// disabled while recording, so this matches the file's real duration.
    /// A one-shot store READ, not an observation — it can't invalidate
    /// anything.
    private var stopMotionClipSeconds: Int {
        let fps = max(store.get(\.recordFPS), 1)
        return Int(Float(progress.recordedFrameCount) / fps)
    }

    private func timeString(_ totalSeconds: Int) -> String {
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct RecordingSection: View {
    let store: ParamStore
    let capture: FrameCapture
    // M18: plain `let`, not @ObservedObject — this section only ever CALLS
    // controller.matchWindowAspect(toResolutionMode:) once per picker change;
    // it has no reason to observe AppController's own @Published properties
    // (source selection, Reset All state) and re-render on their account.
    let controller: AppController
    @ObservedObject var state: RecorderState

    // M25: eight fixed presets, no custom entry. See the Frame Rate picker
    // below for why. Ints, not Floats — the tag type is what the segmented
    // Picker matches on, and Int tags are exact by construction.
    private let fpsPresets: [Int] = [5, 7, 10, 12, 14, 24, 30, 60]

    // Local mirror of the selected frame rate. Discrete state driving a
    // control that's locked during a take, written through to the store —
    // same shape as recordMode, outputResolutionMode and recordCodecMode
    // below. Replaces M4.1's FPSMode enum, which existed only to distinguish
    // presets from custom text entry.
    @State private var fpsSelection: Int = 30
    // Local mirror of recordMode (0 = Long-form, 1 = Stop-motion). Discrete
    // state that drives the conditional transport layout, so per rule #4 it's a
    // local @State write-through (same shape as fpsMode), never a binding into
    // an observable object. Locked while a take is active.
    @State private var recordMode: Int = 0
    // M18: local mirror of outputResolution, same shape as recordMode —
    // discrete state driving a locked-during-a-take control, written through
    // to the store. See the picker below for the tag <-> size mapping.
    @State private var outputResolutionMode: Int = 0
    // M4.4 Part A: local mirror of recordCodec, same shape as recordMode and
    // outputResolutionMode — discrete state driving a control that's locked
    // during a take, written through to the store. 0 = H.264,
    // 1 = ProRes 422 HQ, 2 = ProRes 4444.
    @State private var recordCodecMode: Int = 0
    // Gates the scope meter's existence, so it's section-owned @State per the
    // conditional-UI rule rather than living inside a ParamToggle.
    @State private var autoTriggerOn: Bool = false
    @State private var loaded = false

    private var isRecording: Bool { state.transport == .recording }
    private var isPaused: Bool { state.transport == .paused }
    private var isActive: Bool { isRecording || isPaused }
    private var isFinishing: Bool { state.transport == .finishing }

    var body: some View {
        CollapsibleSection("Recording") {
            VStack(alignment: .leading, spacing: 8) {

                // ---- Output Resolution (M18) ----
                // What size PASS 1 actually renders at. Governs the live
                // preview AND exactly what recordings/screenshots come out
                // at — there is no separate "recording resolution" (M18
                // plan, D6). Picking a fixed size also reshapes the window
                // onto the matching aspect (matchWindowAspect below), so
                // letterboxing stays the fallback case (a freehand drag, or
                // an aspect the screen can't fit) rather than the normal one.
                // Locked during a take for the same reason Mode and Frame
                // Rate are — none of the three "what shape is this take"
                // controls should move mid-recording.
                //
                // Wrapped in a Group (matching the pattern already used
                // further down this VStack) so the picker + its Divider count
                // as ONE child of the section's outer VStack rather than two
                // — this section was already at the edge of SwiftUI's
                // 10-child ViewBuilder limit before adding a new control.
                Group {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output Resolution").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: Binding(
                            get: { outputResolutionMode },
                            set: { newValue in
                                outputResolutionMode = newValue
                                store.set(\.outputResolution, Float(newValue))
                                controller.matchWindowAspect(toResolutionMode: newValue)
                            }
                        )) {
                            Text("Native").tag(0)
                            Text("Native ÷ 2").tag(1)
                            Text("640 × 480").tag(2)
                            Text("1280 × 720").tag(3)
                            Text("1920 × 1080").tag(4)
                            Text("1080 × 1080").tag(5)
                            Text("1080 × 1920").tag(6)
                            Text("3840 × 2160").tag(7)
                        }
                        .pickerStyle(.menu)
                        .disabled(isActive || isFinishing)

                        // Live readout of what the renderer is actually
                        // producing right now — reads FrameCapture's own live
                        // report, not the store, so it's always the truth
                        // even the instant after a switch, before any window
                        // resize settles.
                        Text("→ \(state.frameSizeText)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // ---- Codec (M4.4 Part A) ----
                    // What the NEXT take is written with. H.264 is the
                    // default and is byte-for-byte the pre-M4.4 path. The two
                    // ProRes options are intra-only masters and additionally
                    // carry proper Rec.709 color tagging, which M4.2 had to
                    // defer because AVFoundation rejects those keys for
                    // H.264.
                    //
                    // Locked during a take alongside Mode, Frame Rate, and
                    // Output Resolution — the codec is snapshotted at Record
                    // regardless, so this is about not suggesting a change
                    // that wouldn't take effect.
                    //
                    // Deliberately inside the SAME Group as Output Resolution
                    // above: this section is at SwiftUI's 10-child
                    // ViewBuilder limit, so the two pickers plus their
                    // dividers must count as one child between them.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Codec").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: Binding(
                            get: { recordCodecMode },
                            set: { newValue in
                                recordCodecMode = newValue
                                store.set(\.recordCodec, Float(newValue))
                            }
                        )) {
                            Text("H.264").tag(0)
                            Text("ProRes 422 HQ").tag(1)
                            Text("ProRes 4444").tag(2)
                        }
                        .pickerStyle(.menu)
                        .disabled(isActive || isFinishing)

                        // The one cross-section dependency in M4.4, stated at
                        // the point of use rather than left to memory: only
                        // 4444 can actually carry the vignette's alpha
                        // matte, and the toggle that produces it lives in the
                        // Vignette section.
                        Text(recordCodecMode == 2
                             ? "Alpha: carries the vignette matte if Matte to Alpha is on."
                             : "Alpha: not carried by this codec.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Divider()
                }

                // ---- Mode ----
                // Long-form = continuous capture at the frame rate below.
                // Stop-motion = single frames accumulated into one clip, the
                // frame rate below becoming that clip's PLAYBACK rate. Locked
                // once a take starts.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mode").font(.caption).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { recordMode },
                        set: { newValue in
                            recordMode = newValue
                            store.set(\.recordMode, Float(newValue))
                        }
                    )) {
                        Text("Long-form").tag(0)
                        Text("Stop-motion").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .disabled(isActive || isFinishing)
                }

                Divider()

                // ---- FPS selection ----
                // Locked (disabled) once a take starts — activeFrameInterval
                // is snapshotted into FrameCapture's own lockedFPS at Record,
                // so this is purely to stop the picker from suggesting a
                // change that wouldn't do anything mid-take.
                //
                // M25: THE CUSTOM FPS TEXT FIELD IS GONE AND IS NOT COMING
                // BACK. A focused NSTextField cost the render loop roughly
                // half its frames — measured at 38.0 fps / frames to 200 ms
                // long-form, and 33.7 fps / 231 ms in stop-motion with the
                // trigger scope running, against a 60.0 fps / 15.7-17.6 ms
                // baseline in the same session. Focus ALONE did it: nothing
                // typed, caret merely sitting in the box. M25 Part 1 had
                // already moved the field's state row-local, which removed
                // the keystroke path and changed nothing about the readings —
                // proving the cost is AppKit's field editor holding first
                // responder in the same window as the MTKView, not SwiftUI
                // invalidation. Fifth instance of "something harmless-looking
                // on the main thread steals the render loop's budget," and
                // the first one with no code-side fix available.
                //
                // A segmented Picker never takes first responder, so eight
                // fixed presets make the whole class of problem unreachable
                // rather than mitigated. 5/7/10/14 join the original
                // 12/24/30/60 to cover the slow stop-motion playback rates
                // the text field was actually being used for.
                //
                // Same write-through Binding shape as Mode, Output Resolution
                // and Codec — no onChange, no commit function, no clamp (the
                // reachable set IS the valid set now).
                VStack(alignment: .leading, spacing: 6) {
                    Text("Frame Rate").font(.caption).foregroundColor(.secondary)

                    Picker("", selection: Binding(
                        get: { fpsSelection },
                        set: { newValue in
                            fpsSelection = newValue
                            store.set(\.recordFPS, Float(newValue))
                        }
                    )) {
                        ForEach(fpsPresets, id: \.self) { fps in
                            Text("\(fps)").tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isActive || isFinishing)
                }

                Divider()

                // ---- Transport ----
                // Long-form keeps Record / Pause·Resume / Stop. Stop-motion
                // drops Pause (there's no continuous capture to pause) and adds
                // a Capture Frame button plus the LFO auto-trigger controls. The
                // transport STATE MACHINE underneath is identical — only the
                // trigger source and this button layout differ.
                if recordMode == 0 {
                    HStack(spacing: 8) {
                        if !isActive {
                            recordButton
                        } else {
                            if isRecording {
                                Button(action: { capture.pause() }) {
                                    HStack {
                                        Image(systemName: "pause.fill")
                                        Text("Pause")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button(action: { capture.resume() }) {
                                    HStack {
                                        Image(systemName: "play.fill")
                                        Text("Resume")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                            }

                            stopButton
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        if !isActive {
                            recordButton
                        } else {
                            stopButton
                        }
                    }

                    // Manual one-shot: grabs exactly one frame into the take.
                    // Enabled only while recording; the flag is consumed
                    // atomically inside FrameCapture so a press can't refire.
                    Button(action: { capture.requestStopMotionFrame() }) {
                        HStack {
                            Image(systemName: "camera.badge.clock")
                            Text("Capture Frame")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isRecording)
                    .help("Add one frame to the stop-motion take")

                    // Auto-trigger: its own clock (Trigger Rate), independent of
                    // the Global LFO so it can run fast. Capture Phase sets
                    // where in each cycle the grab lands; the Global LFO can
                    // sweep that via "LFO ➔ Capture Phase" in the LFO section.
                    // All stay live/performable mid-take (none of them affect
                    // written timestamps).
                    // Local @State write-through rather than ParamToggle: this
                    // now gates conditional UI (the scope meter), and per the
                    // house rule discrete state driving conditional layout is
                    // owned by the section, not hidden inside a control.
                    Toggle("LFO Auto-Trigger", isOn: Binding(
                        get: { autoTriggerOn },
                        set: { newValue in
                            autoTriggerOn = newValue
                            store.set(\.stopMotionLFOTrigger, newValue ? 1.0 : 0.0)
                        }
                    ))
                    ParamSlider(\.stopMotionTriggerRate, store: store)
                    ParamSlider(\.stopMotionCapturePhase, store: store)

                    // Scope meter. Created ONLY while the auto-trigger is armed,
                    // so its refresh timer exists only when it's on screen and
                    // doing something.
                    if autoTriggerOn {
                        CaptureScopeMeter(capture: capture)
                    }
                }

                // ---- REC indicator ----
                // M20 Part 2: this is now ONE child holding a leaf view that
                // observes RecorderProgress on its own. Publish cadence is
                // unchanged inside FrameCapture (long-form at most once per
                // second on the elapsed-second change, stop-motion per
                // captured frame) — what changed is that a publish no longer
                // reaches the pickers above. Do NOT move these counters back
                // into this body; see the comment on RecordingIndicator for
                // what that cost when measured.
                if isActive {
                    RecordingIndicator(
                        progress: capture.progress,
                        store: store,
                        isPaused: isPaused,
                        recordMode: recordMode
                    )
                }

                Divider()

                // Grouped so the section body VStack stays under SwiftUI's
                // 10-child ViewBuilder limit as this section keeps growing
                // (Mode + Stop-motion controls pushed it right to the edge). A
                // Group is layout-transparent in a VStack — identical output.
                Group {
                    // ---- Screenshot (unchanged from 4.1) ----
                    Button(action: { capture.requestScreenshot() }) {
                        HStack {
                            Image(systemName: "camera")
                            Text("Screenshot")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Save the current frame as a PNG")

                    Button(action: { capture.chooseOutputDirectory() }) {
                        HStack {
                            Image(systemName: "folder")
                            Text(state.outputDirectoryName.isEmpty ? "Choose Output Folder..." : state.outputDirectoryName)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Where screenshots and recordings are saved")
                }

                if !state.status.isEmpty {
                    Text(state.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onAppear {
                if !loaded {
                    // M25: any stored recordFPS that isn't one of the eight
                    // presets is now unreachable from the UI — a leftover
                    // custom value from before, or a future default change.
                    // Snap to the nearest preset and write it back, so the
                    // picker and the store can't disagree about what the next
                    // take will run at.
                    let current = store.get(\.recordFPS)
                    let nearest = fpsPresets.min(by: {
                        abs(Float($0) - current) < abs(Float($1) - current)
                    }) ?? 30
                    fpsSelection = nearest
                    if abs(Float(nearest) - current) > 0.001 {
                        store.set(\.recordFPS, Float(nearest))
                    }
                    recordMode = Int(store.get(\.recordMode))
                    outputResolutionMode = Int(store.get(\.outputResolution))
                    recordCodecMode = Int(store.get(\.recordCodec))
                    autoTriggerOn = store.get(\.stopMotionLFOTrigger) > 0.5
                    loaded = true
                }
            }
        }
    }

    // Record/Stop buttons are shared verbatim between the two mode layouts, so
    // they live here rather than being duplicated in each branch. Record passes
    // the current mode so FrameCapture can set its progress-publish cadence.
    private var recordButton: some View {
        // M4.4: the codec joins fps and mode as take-scoped state read ONCE,
        // here, at the press. FrameCapture snapshots all three; nothing reads
        // the live store values again for the life of the take.
        Button(action: {
            capture.record(
                fps: Double(store.get(\.recordFPS)),
                stopMotion: recordMode == 1,
                codec: recordCodecMode
            )
        }) {
            HStack {
                Image(systemName: "record.circle")
                Text("Record")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(isFinishing)
    }

    private var stopButton: some View {
        Button(action: { capture.stop() }) {
            HStack {
                Image(systemName: "stop.fill")
                Text("Stop")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    // M20 Part 2: stopMotionClipSeconds moved to RecordingIndicator along
    // with the counter it reads. It referenced state.recordedFrameCount,
    // which no longer exists on RecorderState.

    // M25: fpsCaptionDiffers, commitFPS, commitTypedFPS and the FPSMode enum
    // are all deleted, not relocated. They existed only to service custom
    // text entry — the clamp had nothing left to clamp once the reachable set
    // became the valid set.

    // M20 Part 2: timeString moved to RecordingIndicator, the only place that
    // formatted a duration.
}




















