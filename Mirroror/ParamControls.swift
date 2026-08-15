import SwiftUI

// PERFORMANCE-CRITICAL PATTERN:
// Each control owns its displayed value as row-local @State and writes through
// to the ParamStore. Dragging a slider therefore invalidates ONLY that row —
// never the sidebar, never ContentView, never the Metal view. Do not replace
// these with bindings into an ObservableObject.

// Optional slider response curve. The slider TRACK is always normalized 0...1;
// the curve decides where in the value range each point on the track lands. The
// stored param is always the real value — nothing downstream knows or cares that
// the travel is nonlinear.
enum SliderResponse {
    /// Position maps straight to value. Identical to the pre-curve behavior, and
    /// the default, so every existing slider is untouched.
    case linear

    /// Fine control at BOTH ends, coarse through the middle, skewed so the low
    /// end gets the most travel of all.
    ///
    /// Two stages. Smoothstep flattens the response at both extremes — its
    /// derivative goes to zero at 0 and 1 and peaks in the middle, which is
    /// exactly "spend travel at the ends, rush through the middle." Then raising
    /// the result to `skew` drags the whole curve downward, handing even more of
    /// the track to small values. skew = 1 is symmetric; higher favors the low
    /// end harder.
    case tails(skew: Float)

    /// Equal travel anywhere on the track means an equal RATIO change in value.
    ///
    /// For a range that spans a reciprocal — a zoom factor, where 0.5 and 2.0
    /// are the same amount of change in opposite directions — a linear track
    /// jams everything below 1.0 into the first few percent of travel. This
    /// spaces the range by ratio instead, so each half of the control gets the
    /// travel its range of magnification deserves.
    ///
    /// Requires a range entirely above zero; falls back to linear if given one
    /// that crosses or touches it, rather than returning NaN from the log.
    case geometric
}

struct ParamSlider: View {
    let label: String
    let store: ParamStore
    let keyPath: WritableKeyPath<LiveParams, Float>
    let range: ClosedRange<Float>
    let defaultValue: Float
    var response: SliderResponse = .linear

    /// M14: a NULL DETENT at zero, for bipolar sliders where landing exactly on
    /// 0 by hand matters. Off by default, so every existing slider is untouched.
    ///
    /// A small band of track either side of zero's position reads out as exactly
    /// 0.0, giving the thumb something to catch on. Crucially this does NOT
    /// discard any of the range: the two remaining stretches of track are
    /// REMAPPED to still cover the full negative and full positive halves. The
    /// travel either side is compressed by about 5%, which is imperceptible in
    /// the hand; no reachable value is lost.
    ///
    /// Only meaningful on `.linear` with a range that straddles zero. On any
    /// other combination it is ignored rather than doing something surprising.
    var nullDetent: Bool = false

    @State private var value: Float = 0
    @State private var loaded = false

    // M27 Part 1: the explicit initializer above stays exactly as it was —
    // MirrorSection and everything else that already passes key paths keeps
    // compiling unchanged. This is the SECOND reader the registry exists
    // for: look the entry up by keyPath instead of restating its range,
    // default, response and null detent at the call site. Anything not in
    // the registry (mappable: false or absent entirely) still works here —
    // this initializer doesn't care whether a parameter is MIDI-mappable,
    // only that ParamRegistry knows its display shape.
    init(_ keyPath: WritableKeyPath<LiveParams, Float>, store: ParamStore) {
        guard let entry = ParamRegistry.byKeyPath[keyPath] else {
            fatalError("ParamSlider(_:store:) called with a keyPath not in ParamRegistry. Either add it to ParamRegistry.all/.nonMappable, or use the explicit ParamSlider(label:store:keyPath:range:defaultValue:) initializer for anything that genuinely isn't a registry parameter.")
        }
        self.label = entry.label
        self.store = store
        self.keyPath = keyPath
        self.range = entry.range
        self.defaultValue = entry.defaultValue
        self.response = entry.response
        self.nullDetent = entry.nullDetent
    }

    init(label: String, store: ParamStore, keyPath: WritableKeyPath<LiveParams, Float>,
         range: ClosedRange<Float>, defaultValue: Float, response: SliderResponse = .linear,
         nullDetent: Bool = false) {
        self.label = label
        self.store = store
        self.keyPath = keyPath
        self.range = range
        self.defaultValue = defaultValue
        self.response = response
        self.nullDetent = nullDetent
    }

    /// Half-width of the detent band, in track-position units.
    private static let detentHalfWidth: Float = 0.025

    /// Detent geometry, or nil when the detent doesn't apply. Returns the track
    /// position of zero and the two remapped edges either side of it.
    private var detent: (zeroPos: Float, lowEdge: Float, highEdge: Float)? {
        guard nullDetent, case .linear = response else { return nil }
        let lo = range.lowerBound
        let hi = range.upperBound
        guard lo < 0, hi > 0 else { return nil }
        let zeroPos = -lo / (hi - lo)
        let h = Self.detentHalfWidth
        // Refuse to engage if the band would eat one side of a very lopsided
        // range — better to behave like a plain slider than like a broken one.
        guard zeroPos - h > 0.01, zeroPos + h < 0.99 else { return nil }
        return (zeroPos, zeroPos - h, zeroPos + h)
    }

    // Track position (0...1) -> real value.
    private func valueFor(_ position: Float) -> Float {
        let p = min(max(position, 0.0), 1.0)
        let lo = range.lowerBound
        let hi = range.upperBound

        if let d = detent {
            if p <= d.lowEdge {
                // [0, lowEdge] covers the whole negative half.
                return lo * (1.0 - p / d.lowEdge)
            } else if p >= d.highEdge {
                // [highEdge, 1] covers the whole positive half.
                return hi * ((p - d.highEdge) / (1.0 - d.highEdge))
            } else {
                return 0.0
            }
        }

        switch response {
        case .linear:
            return lo + (hi - lo) * p
        case .tails(let skew):
            let smooth = p * p * (3.0 - 2.0 * p)
            return lo + (hi - lo) * pow(smooth, skew)
        case .geometric:
            guard lo > 0, hi > 0 else { return lo + (hi - lo) * p }
            return lo * pow(hi / lo, p)
        }
    }

    // Real value -> track position (0...1). Must be the exact inverse of
    // valueFor, or the knob drifts away from the number beside it.
    private func positionFor(_ v: Float) -> Float {
        let lo = range.lowerBound
        let hi = range.upperBound
        guard hi > lo else { return 0.0 }

        if let d = detent {
            let clampedV = min(max(v, lo), hi)
            if clampedV < 0 {
                return d.lowEdge * (1.0 - clampedV / lo)
            } else if clampedV > 0 {
                return d.highEdge + (clampedV / hi) * (1.0 - d.highEdge)
            } else {
                return d.zeroPos
            }
        }

        let normalized = min(max((v - lo) / (hi - lo), 0.0), 1.0)

        switch response {
        case .linear:
            return normalized
        case .tails(let skew):
            let smooth = pow(normalized, 1.0 / skew)
            // Closed-form inverse of smoothstep.
            let clamped = min(max(1.0 - 2.0 * smooth, -1.0), 1.0)
            return 0.5 - sin(asin(clamped) / 3.0)
        case .geometric:
            // Inverse of lo * (hi/lo)^p. `normalized` is deliberately unused
            // here — it is the linear mapping, and this case is defined
            // against the raw value.
            guard lo > 0, hi > 0 else { return normalized }
            let clampedV = min(max(v, lo), hi)
            return log(clampedV / lo) / log(hi / lo)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(action: {
                    value = defaultValue
                    store.set(keyPath, defaultValue)
                }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .help("Reset to default")

                Text(String(format: "%.2f", value))
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            // The track is always 0...1 and the value is derived, so a curved
            // response needs no change anywhere else — the reset button, the
            // readout, and the store write all still deal in real values.
            Slider(value: Binding(
                get: { positionFor(value) },
                set: { position in
                    let newValue = valueFor(position)
                    value = newValue
                    store.set(keyPath, newValue)
                }
            ), in: 0.0...1.0)
        }
        .onAppear {
            if !loaded {
                value = store.get(keyPath)
                loaded = true
            }
        }
    }
}

struct ParamToggle: View {
    let label: String
    let store: ParamStore
    let keyPath: WritableKeyPath<LiveParams, Float>

    @State private var isOn = false
    @State private var loaded = false

    // M27 Part 1: same shape as ParamSlider's two initializers above — the
    // registry-backed lookup is new, the explicit one is the untouched
    // original signature every existing ParamToggle call site already uses.
    init(_ keyPath: WritableKeyPath<LiveParams, Float>, store: ParamStore) {
        guard let entry = ParamRegistry.byKeyPath[keyPath] else {
            fatalError("ParamToggle(_:store:) called with a keyPath not in ParamRegistry. Either add it to ParamRegistry.all/.nonMappable, or use the explicit ParamToggle(label:store:keyPath:) initializer.")
        }
        self.label = entry.label
        self.store = store
        self.keyPath = keyPath
    }

    init(label: String, store: ParamStore, keyPath: WritableKeyPath<LiveParams, Float>) {
        self.label = label
        self.store = store
        self.keyPath = keyPath
    }

    var body: some View {
        Toggle(label, isOn: Binding(
            get: { isOn },
            set: { newValue in
                isOn = newValue
                store.set(keyPath, newValue ? 1.0 : 0.0)
            }
        ))
        .onAppear {
            if !loaded {
                isOn = store.get(keyPath) > 0.5
                loaded = true
            }
        }
    }
}

struct ParamPicker: View {
    enum Style { case segmented, menu, radio }

    let label: String
    let store: ParamStore
    let keyPath: WritableKeyPath<LiveParams, Float>
    let options: [(String, Int)]
    var style: Style = .segmented

    /// Whether to render the label row above segmented/radio controls. Off by
    /// default for `.menu` reasons doesn't apply — menu always shows its own
    /// inline title. For segmented/radio, set false when the surrounding
    /// layout already identifies the control some other way (a section header
    /// doing double duty, a combined row with another control) and a second
    /// label would be redundant. The label string is still passed to Picker()
    /// either way, for accessibility.
    var showLabel: Bool = true

    @State private var selection: Int = 0
    @State private var loaded = false

    // M27 Part 1: registry-backed lookup, same shape as ParamSlider and
    // ParamToggle above. Every existing ParamPicker call site in this
    // codebase tags its options 0, 1, 2... in order, which is exactly what
    // ParamRegistry.ParamKind.stepped(options:)'s array index gives for
    // free — entry.options[i] pairs with tag i, so the (String, Int) tuple
    // list is rebuilt here rather than needing a second copy of it in the
    // registry entry itself.
    init(_ keyPath: WritableKeyPath<LiveParams, Float>, store: ParamStore, style: Style = .segmented, showLabel: Bool = true) {
        guard let entry = ParamRegistry.byKeyPath[keyPath] else {
            fatalError("ParamPicker(_:store:) called with a keyPath not in ParamRegistry. Either add it to ParamRegistry.all/.nonMappable, or use the explicit ParamPicker(label:store:keyPath:options:) initializer.")
        }
        guard case .stepped(let options) = entry.kind else {
            fatalError("ParamPicker(_:store:) called with a keyPath whose registry entry isn't .stepped — its kind is \(entry.kind). Check ParamRegistry for '\(entry.id)'.")
        }
        self.label = entry.label
        self.store = store
        self.keyPath = keyPath
        self.options = options.enumerated().map { (index, name) in (name, index) }
        self.style = style
        self.showLabel = showLabel
    }

    init(label: String, store: ParamStore, keyPath: WritableKeyPath<LiveParams, Float>,
         options: [(String, Int)], style: Style = .segmented, showLabel: Bool = true) {
        self.label = label
        self.store = store
        self.keyPath = keyPath
        self.options = options
        self.style = style
        self.showLabel = showLabel
    }

    private var binding: Binding<Int> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                store.set(keyPath, Float(newValue))
            }
        )
    }

    var body: some View {
        Group {
            switch style {
            case .segmented:
                // The label used to be handed straight to Picker() as its
                // title. Outside a Form, macOS renders that title as a leading
                // Text competing for width against the full-width segmented
                // control — fine for a short label like "Border Behavior," but
                // "Rotation 1 + 2 Combine" collapsed to a sliver of a column
                // and wrapped one character per line. Same fix as ParamSlider:
                // the label gets its own row above the control (when
                // showLabel), and the Picker's built-in title is hidden so it
                // can't double up or fight for space again regardless of
                // label length.
                if showLabel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Picker(label, selection: binding) { optionViews }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                    }
                } else {
                    Picker(label, selection: binding) { optionViews }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                }
            case .menu:
                // Unaffected: a menu-style Picker's title sits beside a
                // fixed-size dropdown button, not squeezed against a
                // full-width control, so it has never shown this symptom.
                Picker(label, selection: binding) { optionViews }
                    .pickerStyle(.menu)
            case .radio:
                if showLabel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Picker(label, selection: binding) { optionViews }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                    }
                } else {
                    Picker(label, selection: binding) { optionViews }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                }
            }
        }
        .onAppear {
            if !loaded {
                selection = Int(store.get(keyPath))
                loaded = true
            }
        }
    }

    private var optionViews: some View {
        ForEach(options, id: \.1) { option in
            Text(option.0).tag(option.1)
        }
    }
}





