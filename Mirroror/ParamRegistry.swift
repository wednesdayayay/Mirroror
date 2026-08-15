import Foundation

// M27 Part 1 — THE PARAMETER REGISTRY.
//
// Before this file, a parameter's identity was scattered: storage in
// LiveParams, on-screen label/range/default/curve/detent as literals at a
// ParamSlider call site in ContentView.swift, no stable name anywhere. MIDI
// needs one table that answers "what is the full range of VCO Amplitude on
// Mirror 2" — so does a .tosc generator, so would a preset manager.
//
// THE ID IS A CONTRACT. Once a mapping file or a generated layout exists on
// disk, it references entries by `id`. Renaming an id silently breaks that
// file, exactly the way renaming a ShaderParams field mid-struct would break
// the GPU side. IDs below are settled at write time and are not edited later
// — if a parameter is ever renamed on screen, the `id` stays put and only
// `label` changes.
//
// THE CENSUS. `LiveParams` has exactly 128 Float fields today. Every one of
// them is accounted for below: either it has a registry entry, or it is
// named in `ParamRegistry.excludedFieldNames` with a one-line reason. See
// `ParamRegistry.runCensus()`, called once at launch in DEBUG, which is this
// file's answer to the struct's positional parity check — aimed at the
// mapping surface instead of the GPU.
//
// This file is where a control's range, default, curve, and null detent are
// DEFINED — the sidebar reads them from here rather than carrying its own
// copy. Change one here and the sidebar, the mapping window, and any
// generated layout all move together; that single-source property is the
// whole point of the registry.
//
// M22 is the first milestone to use that on purpose: Zoom's range, default,
// and response are set here alone, and nothing in ContentView.swift needed
// touching to reverse the control.

enum ParamKind: Equatable {
    case continuous
    case toggle
    case stepped(options: [String])
}

struct ParamEntry {
    let id: String
    let section: String
    let label: String
    let keyPath: WritableKeyPath<LiveParams, Float>
    let range: ClosedRange<Float>
    let defaultValue: Float
    let response: SliderResponse
    let nullDetent: Bool
    let kind: ParamKind
    let mappable: Bool
    /// Populated only when mappable is false — shown in the mapping window
    /// beside the greyed row (D7).
    let nonMappableReason: String?

    init(
        id: String,
        section: String,
        label: String,
        keyPath: WritableKeyPath<LiveParams, Float>,
        range: ClosedRange<Float> = 0.0...1.0,
        defaultValue: Float,
        response: SliderResponse = .linear,
        nullDetent: Bool = false,
        kind: ParamKind = .continuous,
        mappable: Bool = true,
        nonMappableReason: String? = nil
    ) {
        self.id = id
        self.section = section
        self.label = label
        self.keyPath = keyPath
        self.range = range
        self.defaultValue = defaultValue
        self.response = response
        self.nullDetent = nullDetent
        self.kind = kind
        self.mappable = mappable
        self.nonMappableReason = nonMappableReason
    }
}

enum ParamRegistry {

    // MARK: - The table

    // Ordered to match the sidebar, section by section, top to bottom, and
    // within a section in on-screen reading order. Order has no functional
    // meaning (lookup is by keyPath and by id, both dictionaries) but keeping
    // it sidebar-shaped makes this file readable against ContentView.swift.
    static let all: [ParamEntry] = [

        // ---- Canvas ----
        ParamEntry(id: "canvas.scale", section: "Canvas", label: "Zoom",
                   keyPath: \.zoom, range: 0.3333...10.0, defaultValue: 1.0,
                   response: .geometric),
        ParamEntry(id: "canvas.edgeBehavior", section: "Canvas", label: "Border Behavior",
                   keyPath: \.edgeBehavior, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Black Border", "Bleed Lines", "Tile Screen", "Tile Reflect", "Gradient Synth BG"])),
        ParamEntry(id: "canvas.preCropOn", section: "Canvas", label: "Edge Pre-Crop (Raw Input)",
                   keyPath: \.preCropOn, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "canvas.preCropPixels", section: "Canvas", label: "Pre-Crop Pixels",
                   keyPath: \.preCropPixels, range: 1.0...5.0, defaultValue: 3.0),

        // ---- Geometry Order Routing ----
        // The five chain slots are discrete routing, deliberately excluded —
        // see D7 and the exclusion list below. Luma Source Staging is the
        // one continuous control in this section.
        ParamEntry(id: "routing.lumaStageDepth", section: "Geometry Order Routing", label: "Luma Source Staging",
                   keyPath: \.lumaStageDepth, defaultValue: 0.0),

        // ---- Rotation 1 ----
        ParamEntry(id: "rotation1.waveType", section: "Rotation 1", label: "Oscillator Type",
                   keyPath: \.torsionWaveType, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Sine", "Tri", "Saw", "S&H", "Sqr"])),
        ParamEntry(id: "rotation1.lag", section: "Rotation 1", label: "S&H Slew / Lag Time",
                   keyPath: \.torsionLag, defaultValue: 0.0),
        ParamEntry(id: "rotation1.radialMode", section: "Rotation 1", label: "Oscillator Mode",
                   keyPath: \.torsionRadialMode, defaultValue: 1.0, kind: .toggle),
        ParamEntry(id: "rotation1.vcoAmplitude", section: "Rotation 1", label: "VCO Amplitude",
                   keyPath: \.torsionStrength, range: -3.0...3.0, defaultValue: 0.5),
        ParamEntry(id: "rotation1.vcoFrequency", section: "Rotation 1", label: "VCO Frequency",
                   keyPath: \.torsionFrequency, range: 1.0...15.0, defaultValue: 5.0),
        ParamEntry(id: "rotation1.lumaToTwist", section: "Rotation 1", label: "Luma ➔ Twist Modulator",
                   keyPath: \.lumaTorsion, range: -0.30...0.30, defaultValue: 0.0, nullDetent: true),
        ParamEntry(id: "rotation1.orbitDepth", section: "Rotation 1", label: "Dynamic Orbit Depth",
                   keyPath: \.torsionOrbitDepth, defaultValue: 0.0),
        ParamEntry(id: "rotation1.centerX", section: "Rotation 1", label: "Center X",
                   keyPath: \.torsionCenterX, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "rotation1.centerY", section: "Rotation 1", label: "Center Y",
                   keyPath: \.torsionCenterY, range: -1.0...1.0, defaultValue: 0.0),

        // ---- Rotation 2 ----
        ParamEntry(id: "rotation2.waveType", section: "Rotation 2", label: "Oscillator Type",
                   keyPath: \.spiral2WaveType, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Sine", "Tri", "Saw", "S&H", "Sqr"])),
        ParamEntry(id: "rotation2.lag", section: "Rotation 2", label: "S&H Slew / Lag Time",
                   keyPath: \.spiral2Lag, defaultValue: 0.0),
        ParamEntry(id: "rotation2.radialMode", section: "Rotation 2", label: "Oscillator Mode",
                   keyPath: \.spiral2RadialMode, defaultValue: 1.0, kind: .toggle),
        ParamEntry(id: "rotation2.vcoAmplitude", section: "Rotation 2", label: "VCO Amplitude",
                   keyPath: \.spiral2Strength, range: -3.0...3.0, defaultValue: 0.0),
        ParamEntry(id: "rotation2.freqOffset", section: "Rotation 2", label: "Frequency Offset (vs. Rotation 1)",
                   keyPath: \.spiral2FreqOffset, range: -15.0...15.0, defaultValue: 0.0),
        ParamEntry(id: "rotation2.orbitDepth", section: "Rotation 2", label: "Dynamic Orbit Depth",
                   keyPath: \.spiral2OrbitDepth, defaultValue: 0.0),
        ParamEntry(id: "rotation2.orbitPhase", section: "Rotation 2", label: "Orbit Phase Offset",
                   keyPath: \.spiral2OrbitPhase, defaultValue: 0.0),
        ParamEntry(id: "rotation2.orbitRatio", section: "Rotation 2", label: "Orbit Lissajous Ratio",
                   keyPath: \.spiral2OrbitRatio, range: 0.25...4.0, defaultValue: 1.0),
        ParamEntry(id: "rotation2.centerX", section: "Rotation 2", label: "Center X",
                   keyPath: \.spiral2CenterX, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "rotation2.centerY", section: "Rotation 2", label: "Center Y",
                   keyPath: \.spiral2CenterY, range: -1.0...1.0, defaultValue: 0.0),

        // ---- Mirror 1 ----
        ParamEntry(id: "mirror1.doubleOn", section: "Mirror 1", label: "Doubled",
                   keyPath: \.mirror1DoubleOn, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "mirror1.enabled", section: "Mirror 1", label: "Enabled",
                   keyPath: \.mirror1On, defaultValue: 1.0, kind: .toggle),
        ParamEntry(id: "mirror1.waveType", section: "Mirror 1", label: "Oscillator Type",
                   keyPath: \.mirror1WaveType, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Sine", "Tri", "Saw", "S&H", "Sqr"])),
        ParamEntry(id: "mirror1.lag", section: "Mirror 1", label: "S&H Slew / Lag Time",
                   keyPath: \.mirror1Lag, defaultValue: 0.0),
        ParamEntry(id: "mirror1.radialMode", section: "Mirror 1", label: "Oscillator Mode",
                   keyPath: \.mirror1RadialMode, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "mirror1.vcoAmplitude", section: "Mirror 1", label: "VCO Amplitude",
                   keyPath: \.mirror1RippleAmpRaw, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "mirror1.vcoFrequency", section: "Mirror 1", label: "VCO Frequency",
                   keyPath: \.mirror1RippleFreq, range: 0.2...12.0, defaultValue: 5.0),
        ParamEntry(id: "mirror1.vcoPhase", section: "Mirror 1", label: "Phase Speed",
                   keyPath: \.mirror1Speed, range: -1.0...1.0, defaultValue: 0.44721),
        ParamEntry(id: "mirror1.lumaToPivot", section: "Mirror 1", label: "Luma ➔ Pivot",
                   keyPath: \.lumaMod1, range: -1.5...1.5, defaultValue: 0.0, nullDetent: true),
        ParamEntry(id: "mirror1.spin", section: "Mirror 1", label: "Spin",
                   keyPath: \.mirror1AutoSpinOn, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "mirror1.spinSpeed", section: "Mirror 1", label: "Spin Speed (Bipolar)",
                   keyPath: \.mirror1AutoSpinSpeed, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "mirror1.staticAngle", section: "Mirror 1", label: "Mirror Angle",
                   keyPath: \.mirror1StaticAngle, range: 0.0...(Float.pi * 2.0), defaultValue: 0.0),
        ParamEntry(id: "mirror1.doubleOffset", section: "Mirror 1", label: "Doubled Angle Offset",
                   keyPath: \.mirror1DoubleOffset, range: 0.0...(Float.pi * 2.0), defaultValue: .pi),
        ParamEntry(id: "mirror1.centerX", section: "Mirror 1", label: "Center X",
                   keyPath: \.mirror1CenterX, range: -1.0...1.0, defaultValue: 0.0, nullDetent: true),
        ParamEntry(id: "mirror1.centerY", section: "Mirror 1", label: "Center Y",
                   keyPath: \.mirror1CenterY, range: -1.0...1.0, defaultValue: 0.0, nullDetent: true),

        // ---- Mirror 2 ----
        ParamEntry(id: "mirror2.doubleOn", section: "Mirror 2", label: "Doubled",
                   keyPath: \.mirror2DoubleOn, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "mirror2.enabled", section: "Mirror 2", label: "Enabled",
                   keyPath: \.mirror2On, defaultValue: 1.0, kind: .toggle),
        ParamEntry(id: "mirror2.waveType", section: "Mirror 2", label: "Oscillator Type",
                   keyPath: \.mirror2WaveType, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Sine", "Tri", "Saw", "S&H", "Sqr"])),
        ParamEntry(id: "mirror2.lag", section: "Mirror 2", label: "S&H Slew / Lag Time",
                   keyPath: \.mirror2Lag, defaultValue: 0.0),
        ParamEntry(id: "mirror2.radialMode", section: "Mirror 2", label: "Oscillator Mode",
                   keyPath: \.mirror2RadialMode, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "mirror2.vcoAmplitude", section: "Mirror 2", label: "VCO Amplitude",
                   keyPath: \.mirror2RippleAmpRaw, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "mirror2.vcoFrequency", section: "Mirror 2", label: "VCO Frequency",
                   keyPath: \.mirror2RippleFreq, range: 0.2...12.0, defaultValue: 5.0),
        ParamEntry(id: "mirror2.vcoPhase", section: "Mirror 2", label: "Phase Speed",
                   keyPath: \.mirror2Speed, range: -1.0...1.0, defaultValue: 0.44721),
        ParamEntry(id: "mirror2.lumaToPivot", section: "Mirror 2", label: "Luma ➔ Pivot",
                   keyPath: \.lumaMod2, range: -1.5...1.5, defaultValue: 0.0, nullDetent: true),
        ParamEntry(id: "mirror2.spin", section: "Mirror 2", label: "Spin",
                   keyPath: \.mirror2AutoSpinOn, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "mirror2.spinSpeed", section: "Mirror 2", label: "Spin Speed (Bipolar)",
                   keyPath: \.mirror2AutoSpinSpeed, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "mirror2.staticAngle", section: "Mirror 2", label: "Mirror Angle",
                   keyPath: \.mirror2StaticAngle, range: 0.0...(Float.pi * 2.0), defaultValue: 1.5707963),
        ParamEntry(id: "mirror2.doubleOffset", section: "Mirror 2", label: "Doubled Angle Offset",
                   keyPath: \.mirror2DoubleOffset, range: 0.0...(Float.pi * 2.0), defaultValue: .pi),
        ParamEntry(id: "mirror2.centerX", section: "Mirror 2", label: "Center X",
                   keyPath: \.mirror2CenterX, range: -1.0...1.0, defaultValue: 0.0, nullDetent: true),
        ParamEntry(id: "mirror2.centerY", section: "Mirror 2", label: "Center Y",
                   keyPath: \.mirror2CenterY, range: -1.0...1.0, defaultValue: 0.0, nullDetent: true),

        // ---- Displacement ----
        ParamEntry(id: "displacement.radialMode", section: "Displacement", label: "Oscillator Mode",
                   keyPath: \.dispRadialMode, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "displacement.radialPush", section: "Displacement", label: "Radial Push Direction",
                   keyPath: \.dispRadialPush, defaultValue: 0.0),
        ParamEntry(id: "displacement.centerX", section: "Displacement", label: "Center X",
                   keyPath: \.dispCenterX, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "displacement.centerY", section: "Displacement", label: "Center Y",
                   keyPath: \.dispCenterY, range: -1.0...1.0, defaultValue: 0.0),
        // NOTE: the on-screen label for every one of the eight X/Y entries
        // below is genuinely just "Oscillator Type" / "S&H Slew / Lag Time" /
        // "VCO Amplitude" / "VCO Frequency" / "Phase Speed" — identical text
        // for both axes, disambiguated on screen only by the "X Axis" / "Y
        // Axis" Text header above each block, not by the control's own
        // label. The `id` carries the X/Y distinction (.ampX vs .ampY) so
        // the mapping window and any generated layout can still tell them
        // apart; `label` matches the sidebar exactly, per Part 1's rule.
        //
        // M22: "Phase Speed" is now also the mirrors' label for the same
        // control, so the mapping window relies on `section` to tell a
        // mirror's from a displacement axis's. It already displays it.
        ParamEntry(id: "displacement.waveTypeX", section: "Displacement", label: "Oscillator Type",
                   keyPath: \.dispWaveTypeX, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Sine", "Tri", "Saw", "S&H", "Sqr"])),
        ParamEntry(id: "displacement.lagX", section: "Displacement", label: "S&H Slew / Lag Time",
                   keyPath: \.dispLagX, defaultValue: 0.0),
        ParamEntry(id: "displacement.ampX", section: "Displacement", label: "VCO Amplitude",
                   keyPath: \.dispAmpX, range: -0.25...0.25, defaultValue: 0.0),
        ParamEntry(id: "displacement.freqX", section: "Displacement", label: "VCO Frequency",
                   keyPath: \.dispFreqX, range: 0.5...60.0, defaultValue: 5.0, response: .tails(skew: 1.6)),
        ParamEntry(id: "displacement.speedX", section: "Displacement", label: "Phase Speed",
                   keyPath: \.dispSpeedX, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "displacement.lumaToDisplaceX", section: "Displacement", label: "Luma ➔ Displace X",
                   keyPath: \.lumaModDispX, range: -0.30...0.30, defaultValue: 0.0, nullDetent: true),
        ParamEntry(id: "displacement.waveTypeY", section: "Displacement", label: "Oscillator Type",
                   keyPath: \.dispWaveTypeY, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Sine", "Tri", "Saw", "S&H", "Sqr"])),
        ParamEntry(id: "displacement.lagY", section: "Displacement", label: "S&H Slew / Lag Time",
                   keyPath: \.dispLagY, defaultValue: 0.0),
        ParamEntry(id: "displacement.ampY", section: "Displacement", label: "VCO Amplitude",
                   keyPath: \.dispAmpY, range: -0.25...0.25, defaultValue: 0.0),
        ParamEntry(id: "displacement.freqY", section: "Displacement", label: "VCO Frequency",
                   keyPath: \.dispFreqY, range: 0.5...60.0, defaultValue: 5.0, response: .tails(skew: 1.6)),
        ParamEntry(id: "displacement.speedY", section: "Displacement", label: "Phase Speed",
                   keyPath: \.dispSpeedY, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "displacement.lumaToDisplaceY", section: "Displacement", label: "Luma ➔ Displace Y",
                   keyPath: \.lumaModDispY, range: -0.30...0.30, defaultValue: 0.0, nullDetent: true),

        // ---- Keying ----
        ParamEntry(id: "keying.enabled", section: "Keying", label: "Enabled",
                   keyPath: \.negativeSpace, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "keying.invertKey", section: "Keying", label: "Invert Key",
                   keyPath: \.invertEntireHoleKey, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "keying.darks", section: "Keying", label: "Darks",
                   keyPath: \.keyerPolarity, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "keying.softnessGlobal", section: "Keying", label: "Key Softness (Global)",
                   keyPath: \.keySoftness, range: 0.0...0.35, defaultValue: 0.0),
        ParamEntry(id: "keying.collisionThreshold", section: "Keying", label: "Collision Threshold",
                   keyPath: \.negativeSpaceThreshold, range: 0.05...0.95, defaultValue: 0.7),
        ParamEntry(id: "keying.waveFolding", section: "Keying", label: "Wave Folding",
                   keyPath: \.rectification, range: 0.0...2.0, defaultValue: 0.0),
        ParamEntry(id: "keying.rotationToHoles", section: "Keying", label: "Rotation ➔ Holes",
                   keyPath: \.torsionInHoles, defaultValue: 0.0),
        ParamEntry(id: "keying.rotationCombine", section: "Keying", label: "Rotation 1 + 2 Combine",
                   keyPath: \.spiralCombineMode, range: 0...3, defaultValue: 0.0,
                   kind: .stepped(options: ["Additive", "Subtractive", "XOR", "Multiply"])),
        ParamEntry(id: "keying.threshold1", section: "Keying", label: "Keyer 1 — Mirrors",
                   keyPath: \.keyerThreshold1, defaultValue: 1.0),
        ParamEntry(id: "keying.feed1", section: "Keying", label: "Keyer 1 Feed",
                   keyPath: \.keyerFeed1, range: 0...1, defaultValue: 0.0,
                   kind: .stepped(options: ["Mirrors", "Warped Final"])),
        // NOTE on the three XOR toggles and three Feed pickers: on screen the
        // XOR checkbox's own text is just "XOR" (×3, disambiguated by
        // position under each keyer, not by its own label) and the Feed
        // pickers render with showLabel: false — no header text at all, just
        // the segmented options. Registry `label` is a fuller "Keyer N ..."
        // form here since nothing on screen needs it to match verbatim (an
        // absent or generic on-screen label imposes no constraint), and the
        // fuller form is what the mapping window and .tosc generator
        // actually want to disambiguate three otherwise-identical rows.
        ParamEntry(id: "keying.xor1", section: "Keying", label: "Keyer 1 XOR",
                   keyPath: \.keyerXOR1, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "keying.offset2", section: "Keying", label: "Keyer 2 — Rotation",
                   keyPath: \.keyerOffset2, range: -1.0...1.0, defaultValue: 0.0, nullDetent: true),
        ParamEntry(id: "keying.feed2", section: "Keying", label: "Keyer 2 Feed",
                   keyPath: \.keyerFeed2, range: 0...1, defaultValue: 0.0,
                   kind: .stepped(options: ["Rotation", "Warped Final"])),
        ParamEntry(id: "keying.xor2", section: "Keying", label: "Keyer 2 XOR",
                   keyPath: \.keyerXOR2, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "keying.offset3", section: "Keying", label: "Keyer 3 — Displacement",
                   keyPath: \.keyerOffset3, range: -1.0...1.0, defaultValue: 0.0, nullDetent: true),
        ParamEntry(id: "keying.feed3", section: "Keying", label: "Keyer 3 Feed",
                   keyPath: \.keyerFeed3, range: 0...1, defaultValue: 0.0,
                   kind: .stepped(options: ["Displacement", "Warped Final"])),
        ParamEntry(id: "keying.xor3", section: "Keying", label: "Keyer 3 XOR",
                   keyPath: \.keyerXOR3, defaultValue: 0.0, kind: .toggle),

        // ---- Global LFO ----
        ParamEntry(id: "lfo.rate", section: "Global LFO", label: "LFO Rate",
                   keyPath: \.lfoRate, range: -1.0...1.0, defaultValue: 0.27386),
        ParamEntry(id: "lfo.rateRange", section: "Global LFO", label: "LFO Rate Range",
                   keyPath: \.lfoRateRange, defaultValue: 0.0, kind: .toggle),
        ParamEntry(id: "lfo.waveType", section: "Global LFO", label: "LFO Waveform",
                   keyPath: \.lfoWaveType, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Sine", "Tri", "Saw", "S&H", "Sqr"])),
        ParamEntry(id: "lfo.lag", section: "Global LFO", label: "LFO S&H Slew / Lag Time",
                   keyPath: \.lfoLag, defaultValue: 0.0),
        ParamEntry(id: "lfo.lfo2Depth", section: "Global LFO", label: "LFO 2 Depth",
                   keyPath: \.lfo2Depth, defaultValue: 0.0),
        ParamEntry(id: "lfo.lfo2RateOffset", section: "Global LFO", label: "LFO 2 Rate Offset (vs. LFO 1)",
                   keyPath: \.lfo2RateOffset, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.lfo2WaveType", section: "Global LFO", label: "LFO 2 Waveform",
                   keyPath: \.lfo2WaveType, range: 0...4, defaultValue: 0.0,
                   kind: .stepped(options: ["Sine", "Tri", "Saw", "S&H", "Sqr"])),
        ParamEntry(id: "lfo.lfo2Lag", section: "Global LFO", label: "LFO 2 S&H Slew / Lag Time",
                   keyPath: \.lfo2Lag, defaultValue: 0.0),
        ParamEntry(id: "lfo.lfo2PhaseOffset", section: "Global LFO", label: "LFO 2 Phase Offset",
                   keyPath: \.lfo2PhaseOffset, defaultValue: 0.0),
        ParamEntry(id: "lfo.combineMode", section: "Global LFO", label: "LFO Combine",
                   keyPath: \.lfoCombineMode, range: 0...3, defaultValue: 0.0,
                   kind: .stepped(options: ["Add", "Sub", "XOR", "Mult"])),
        ParamEntry(id: "lfo.busSpread", section: "Global LFO", label: "Bus Spread",
                   keyPath: \.busSpread, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toRotationAmp", section: "Global LFO", label: "LFO ➔ Rotation Amp",
                   keyPath: \.lfoToRotation, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toMirrorAmp", section: "Global LFO", label: "LFO ➔ Mirror Amp",
                   keyPath: \.lfoToMirrors, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toDisplaceAmp", section: "Global LFO", label: "LFO ➔ Displace Amp",
                   keyPath: \.lfoToDisplacement, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toRotationCenter", section: "Global LFO", label: "LFO ➔ Rotation Center",
                   keyPath: \.lfoToRotationCenter, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toMirrorCenter", section: "Global LFO", label: "LFO ➔ Mirror Center",
                   keyPath: \.lfoToMirrorCenter, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toDisplaceCenter", section: "Global LFO", label: "LFO ➔ Displace Center",
                   keyPath: \.lfoToDispCenter, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toKeying", section: "Global LFO", label: "LFO ➔ Keying",
                   keyPath: \.lfoToKeying, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toRadialPush", section: "Global LFO", label: "LFO ➔ Radial Push",
                   keyPath: \.lfoToRadialPush, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toLumaStage", section: "Global LFO", label: "LFO ➔ Luma Staging",
                   keyPath: \.lfoToLumaStage, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "lfo.toCapturePhase", section: "Global LFO", label: "LFO ➔ Capture Phase",
                   keyPath: \.lfoToCapturePhase, range: -1.0...1.0, defaultValue: 0.0),

        // ---- Mix ----
        ParamEntry(id: "mix.dryEffected", section: "Mix", label: "Dry / Effected",
                   keyPath: \.outputMix, defaultValue: 1.0),

        // ---- Vignette ----
        ParamEntry(id: "vignette.shape", section: "Vignette", label: "Shape",
                   keyPath: \.vignetteShape, range: 0...2, defaultValue: 0.0,
                   kind: .stepped(options: ["Off", "Circle", "Rect"])),
        ParamEntry(id: "vignette.centerX", section: "Vignette", label: "Center X",
                   keyPath: \.vignetteCenterX, range: -0.5...0.5, defaultValue: 0.0),
        ParamEntry(id: "vignette.centerY", section: "Vignette", label: "Center Y",
                   keyPath: \.vignetteCenterY, range: -0.5...0.5, defaultValue: 0.0),
        ParamEntry(id: "vignette.size", section: "Vignette", label: "Size",
                   keyPath: \.vignetteSize, range: 0.05...1.0, defaultValue: 0.5),
        ParamEntry(id: "vignette.aspect", section: "Vignette", label: "Aspect Stretch (Wide / Tall)",
                   keyPath: \.vignetteAspect, range: -1.0...1.0, defaultValue: 0.0),
        ParamEntry(id: "vignette.softness", section: "Vignette", label: "Edge Softness",
                   keyPath: \.vignetteSoftness, range: 0.0...0.5, defaultValue: 0.0),
        ParamEntry(id: "vignette.matteToAlpha", section: "Vignette", label: "Matte to Alpha",
                   keyPath: \.vignetteAlpha, defaultValue: 0.0, kind: .toggle),

        // ---- Recording ----
        // Only Stop-motion's two performance-gesture knobs are mappable —
        // both are live/performable mid-take by design (see ParamStore's own
        // comments on stopMotionTriggerRate/stopMotionCapturePhase). Every
        // other Recording control is take-scoped, locked during a take, or
        // outright transport, and lives in the exclusion list below.
        ParamEntry(id: "recording.stopMotionTriggerRate", section: "Recording", label: "Trigger Rate",
                   keyPath: \.stopMotionTriggerRate, range: -1.0...1.0, defaultValue: 0.3),
        ParamEntry(id: "recording.stopMotionCapturePhase", section: "Recording", label: "Capture Phase",
                   keyPath: \.stopMotionCapturePhase, defaultValue: 0.5),
        ParamEntry(id: "recording.lfoAutoTrigger", section: "Recording", label: "LFO Auto-Trigger",
                   keyPath: \.stopMotionLFOTrigger, defaultValue: 0.0, kind: .toggle),
    ]

    // MARK: - Non-mappable fields, named with their reason (D7)
    //
    // These ARE registered — they appear in `all` above is wrong for them
    // specifically, so instead they get their own entries here with
    // mappable: false, which the mapping window shows greyed with the
    // reason attached. This is what makes "why isn't X in the list" a
    // non-question.

    static let nonMappable: [ParamEntry] = [
        ParamEntry(id: "recording.outputResolution", section: "Recording", label: "Output Resolution",
                   keyPath: \.outputResolution, range: 0...7, defaultValue: 0.0,
                   kind: .stepped(options: ["Native", "Native ÷ 2", "640×480", "1280×720", "1920×1080", "1080×1080", "1080×1920", "3840×2160"]),
                   mappable: false,
                   nonMappableReason: "Every distinct value reallocates the offscreen texture and invalidates the capture pixel-buffer pool — a fader would do that dozens of times a second."),
        ParamEntry(id: "recording.frameRate", section: "Recording", label: "Frame Rate",
                   keyPath: \.recordFPS, range: 5...60, defaultValue: 30.0,
                   mappable: false,
                   nonMappableReason: "Read once when Record is pressed and locked for the take. A control that does nothing most of the time is worse than no control."),
        ParamEntry(id: "recording.codec", section: "Recording", label: "Codec",
                   keyPath: \.recordCodec, range: 0...2, defaultValue: 0.0,
                   kind: .stepped(options: ["H.264", "ProRes 422 HQ", "ProRes 4444"]),
                   mappable: false,
                   nonMappableReason: "Read once when Record is pressed and locked for the take. A control that does nothing most of the time is worse than no control."),
        ParamEntry(id: "recording.mode", section: "Recording", label: "Mode",
                   keyPath: \.recordMode, defaultValue: 0.0, kind: .toggle,
                   mappable: false,
                   nonMappableReason: "Read once when Record is pressed and locked for the take. A control that does nothing most of the time is worse than no control."),
        ParamEntry(id: "routing.chainSlot0", section: "Geometry Order Routing", label: "Slot 1",
                   keyPath: \.chainSlot0, range: 0...5, defaultValue: 5.0,
                   kind: .stepped(options: ["Mirror 1", "Mirror 2", "Rotation 1", "Rotation 2", "Displacement", "Empty"]),
                   mappable: false,
                   nonMappableReason: "Discrete routing. A fader sweeping the chain order is not a gesture — the preset row exists for reordering."),
        ParamEntry(id: "routing.chainSlot1", section: "Geometry Order Routing", label: "Slot 2",
                   keyPath: \.chainSlot1, range: 0...5, defaultValue: 1.0,
                   kind: .stepped(options: ["Mirror 1", "Mirror 2", "Rotation 1", "Rotation 2", "Displacement", "Empty"]),
                   mappable: false,
                   nonMappableReason: "Discrete routing. A fader sweeping the chain order is not a gesture — the preset row exists for reordering."),
        ParamEntry(id: "routing.chainSlot2", section: "Geometry Order Routing", label: "Slot 3",
                   keyPath: \.chainSlot2, range: 0...5, defaultValue: 0.0,
                   kind: .stepped(options: ["Mirror 1", "Mirror 2", "Rotation 1", "Rotation 2", "Displacement", "Empty"]),
                   mappable: false,
                   nonMappableReason: "Discrete routing. A fader sweeping the chain order is not a gesture — the preset row exists for reordering."),
        ParamEntry(id: "routing.chainSlot3", section: "Geometry Order Routing", label: "Slot 4",
                   keyPath: \.chainSlot3, range: 0...5, defaultValue: 3.0,
                   kind: .stepped(options: ["Mirror 1", "Mirror 2", "Rotation 1", "Rotation 2", "Displacement", "Empty"]),
                   mappable: false,
                   nonMappableReason: "Discrete routing. A fader sweeping the chain order is not a gesture — the preset row exists for reordering."),
        ParamEntry(id: "routing.chainSlot4", section: "Geometry Order Routing", label: "Slot 5",
                   keyPath: \.chainSlot4, range: 0...5, defaultValue: 2.0,
                   kind: .stepped(options: ["Mirror 1", "Mirror 2", "Rotation 1", "Rotation 2", "Displacement", "Empty"]),
                   mappable: false,
                   nonMappableReason: "Discrete routing. A fader sweeping the chain order is not a gesture — the preset row exists for reordering."),
    ]

    // MARK: - Fields excluded from the registry entirely
    //
    // Every field that reaches this point is neither in `all` nor in
    // `nonMappable` — both already cover every discrete/take-scoped/routing
    // field with its own entry and reason, shown greyed in the mapping
    // window. Nothing in LiveParams needs a THIRD bucket today, so this map
    // is empty. It stays here, checked by the census below, as the place a
    // future field lands if it turns out to need excluding without a greyed
    // row — e.g. something that isn't meaningfully a "parameter" at all.
    static let excludedFieldNames: [String: String] = [:]

    // MARK: - Lookup

    /// Built once, lazily, on first access. KeyPaths are Hashable, so this is
    /// a dictionary hit — the cost ParamSlider's new convenience init pays
    /// per control is one hash lookup, once, in onAppear.
    static let byKeyPath: [WritableKeyPath<LiveParams, Float>: ParamEntry] = {
        var map: [WritableKeyPath<LiveParams, Float>: ParamEntry] = [:]
        for entry in all + nonMappable {
            map[entry.keyPath] = entry
        }
        return map
    }()

    static let byID: [String: ParamEntry] = {
        var map: [String: ParamEntry] = [:]
        for entry in all + nonMappable {
            map[entry.id] = entry
        }
        return map
    }()

    /// Sidebar-order section list, for the mapping window's left pane (D-
    /// section of Part 2). Derived from `all`'s own order rather than
    /// hand-duplicated, so the two can't drift apart.
    static var sectionsInOrder: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for entry in all + nonMappable {
            if !seen.contains(entry.section) {
                seen.insert(entry.section)
                order.append(entry.section)
            }
        }
        return order
    }

    // MARK: - The census — the parity check's analogue
    //
    // At launch, in DEBUG only: every Float field of LiveParams is either in
    // the registry (mappable or not) or on excludedFieldNames, and every id
    // is unique. Mirror(reflecting:) enumerates LiveParams' field names at
    // runtime, so a field added later that nobody registers trips this
    // instead of quietly being unmappable and undiscoverable forever.
    static func runCensus() {
        #if DEBUG
        let mirror = Mirror(reflecting: LiveParams())
        var fieldNames = Set<String>()
        for child in mirror.children {
            guard let name = child.label else { continue }
            fieldNames.insert(name)
        }

        // There is no direct KeyPath -> String reflection in Swift, so
        // per-field coverage (every LiveParams field has an entry) can't be
        // checked by name inside this function without hand-listing all 128
        // names a second time — which would itself be exactly the kind of
        // duplicated list this file exists to avoid. What CAN be checked
        // cheaply and meaningfully at launch:
        var registeredIDs = Set<String>()
        for entry in all + nonMappable {
            assert(registeredIDs.insert(entry.id).inserted,
                   "ParamRegistry: duplicate id '\(entry.id)' — ids must be unique, they are the contract with saved mapping files.")
        }

        let registeredCount = all.count + nonMappable.count + excludedFieldNames.count
        assert(fieldNames.count == 128,
               "ParamRegistry census: LiveParams has \(fieldNames.count) Float fields, expected 128. A field was added or removed — update this expected count once you've confirmed every field is still registered or excluded.")
        assert(registeredCount == fieldNames.count,
               "ParamRegistry census: LiveParams has \(fieldNames.count) fields; the registry accounts for \(registeredCount) (all: \(all.count), nonMappable: \(nonMappable.count), excluded: \(excludedFieldNames.count)). A field was added to LiveParams without a matching registry entry or exclusion reason.")
        #endif
    }
}


