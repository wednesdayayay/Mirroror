import Foundation

// LiveParams: the complete UI-facing state of the synth, all stored as Float
// (Bools are 0/1, enums are their tag values). This is NOT an ObservableObject
// on purpose — writing to it must never trigger SwiftUI view invalidation.
//
// RATE-SLIDER CONVENTION (M0.5a): lfoRate, mirror1/2Speed, and
// mirror1/2AutoSpinSpeed store a BIPOLAR SLIDER POSITION in [-1, 1], NOT a raw
// rate. The renderer converts position -> rate via sign(x)*x²*maxRate each
// frame.
struct LiveParams {
    // Canvas
    // ZOOM, not a coordinate scale: higher magnifies. The renderer inverts it
    // into the shader's `scale` multiplier, which still works the other way
    // round and is unchanged. 1.0 fills the frame, above 1.0 magnifies, below
    // shrinks the picture toward the center.
    var zoom: Float = 1.0
    var edgeBehavior: Float = 0.0        // 0=Black, 1=Bleed, 2=Tile, 3=Reflect, 4=Gradient BG
    var preCropOn: Float = 0.0
    var preCropPixels: Float = 3.0       // 2...5 px

    // Routing
    // M15: geometryRouting removed. It was the old 3-way Pipeline Configuration
    // value, dead since M7 7.2 and kept only "so the legacy routing semantics
    // stay documented" — which is what this comment and the ROADMAP are for.
    // A sweep of all LiveParams fields found it was the only one referenced
    // nowhere outside this file. Not index-mapped to anything, so it is simply
    // deleted; there is no pad to leave behind.

    // Geometry routing chain. Each slot holds a warp-module ID:
    // 0=Mirror 1, 1=Mirror 2, 2=Rotation 1, 3=Rotation 2,
    // 4=Displacement, 5=Empty.
    //
    // M13: SLOTS ARE NUMBERED SOURCE ➔ OUTPUT. Slot 0 is the first thing done
    // to the source (innermost, buried under everything else); slot 4 is the
    // last thing seen (outermost, most visible). The shader walks them 4 ➔ 0
    // because it is warping coordinates rather than images — see the long
    // comment on the chain loop in Shaders.metal.
    //
    // These defaults are the M13 REVERSAL of the old 2,3,0,1,5 defaults and
    // produce a pixel-identical picture to pre-M13. Read source ➔ output they
    // are: Mirror 2 ➔ Mirror 1 ➔ Rotation 2 ➔ Rotation 1, which is what the
    // shipped default has actually looked like all along — the old
    // "Rotations➔Mirrors" label described coordinate-application order, not
    // what was on screen.
    var chainSlot0: Float = 5.0          // Empty
    var chainSlot1: Float = 1.0          // Mirror 2
    var chainSlot2: Float = 0.0          // Mirror 1
    var chainSlot3: Float = 3.0          // Rotation 2
    var chainSlot4: Float = 2.0          // Rotation 1 (outermost)

    // M14 Part 2: Luma Source Staging. ONE global control for every geometry
    // module's luma modulator. 0 = they all read the unwarped source (the
    // behavior since the beginning). 1 = each module reads the source at the
    // coordinate the chain has warped to by the time that module runs, which in
    // this single-sample pipeline is exactly the composite so far. Continuous
    // because the middle is real — the modulation drifts between tracking the
    // source and tracking the composite.
    //
    // Lives here beside the chain slots, and in the Geometry Order Routing
    // section in the UI, because it is a property of how the chain composes
    // rather than of any one module.
    var lumaStageDepth: Float = 0.0

    // Displacement Mesh (M8 Phase A). Additive coordinate field, cross-coupled:
    // the X oscillator's wave runs down the screen, the Y oscillator's across.
    // Amplitudes default to 0, so dropping the module into the chain changes
    // nothing until it is dialed in.
    var dispAmpX: Float = 0.0            // bipolar, -0.25...0.25
    var dispFreqX: Float = 5.0
    var dispSpeedX: Float = 0.0          // BIPOLAR SLIDER POSITION [-1,1], not a rate
    var dispWaveTypeX: Float = 0.0       // 0=Sine,1=Tri,2=Saw,3=S&H,4=Square
    var dispLagX: Float = 0.0
    var lumaModDispX: Float = 0.0        // bipolar, -0.30...0.30

    var dispAmpY: Float = 0.0
    var dispFreqY: Float = 5.0
    var dispSpeedY: Float = 0.0          // BIPOLAR SLIDER POSITION [-1,1], not a rate
    var dispWaveTypeY: Float = 0.0
    var dispLagY: Float = 0.0
    var lumaModDispY: Float = 0.0

    var dispRadialMode: Float = 0.0      // 0=Normal wave arg, 1=Radial wave arg
    var dispRadialPush: Float = 0.0      // 0=XY push direction, 1=radial/tangential

    // M16 Part 2: where this module stands. Same job as the mirrors' center
    // (M14 Part 1) — moves the wave arguments AND the radial push basis
    // together, so the pattern and the push direction re-anchor as one move
    // rather than drifting apart. Bipolar ±1, 0 = frame center = the
    // pre-M16-Part-2 behavior. High VCO Frequency turns a small move here
    // into a fast-looking scroll — expected, matches the mirrors' own
    // center at high ripple frequency.
    var dispCenterX: Float = 0.0
    var dispCenterY: Float = 0.0

    // Displacement -> holes (Collision) is retired, M12 Part 7 cleanup.
    // Keyer 3's Displacement feed keys on displacement directly; this narrower
    // magnitude-based signal wasn't earning its slider.

    // M12: rotation -> holes lost its mode picker, threshold, softness and
    // partner picker. Multiply is the only surviving behavior and is always
    // active, with torsionInHoles (below, in the keying block) as its depth.

    // LFO destinations added in M8 Phase C.5 (lfoToDispHoleThreshold retired
    // alongside Collision, M12 Part 7 cleanup). M16 folded lfoToDispAmpX/Y
    // into lfoToDisplacement and lfoToDispRadialPush into lfoToCharacter —
    // see the Global LFO block further down for both.

    // Rotation (torsion VCO)
    var torsionStrength: Float = 0.5     // bipolar amplitude, -3...3
    var torsionFrequency: Float = 5.0
    var lumaTorsion: Float = 0.0
    var torsionWaveType: Float = 0.0     // 0=Sine,1=Tri,2=Saw,3=S&H,4=Square
    var torsionLag: Float = 0.0
    var torsionRadialMode: Float = 1.0   // 0=Normal, 1=Radial (default Radial)
    var torsionOrbitDepth: Float = 0.0   // 0=static center, 1=full orbit
    // M16 Part 2: where this spiral stands, independent of Dynamic Orbit.
    // Seeded before the orbit gate in the shader — the orbit ADDS onto this
    // rather than replacing it, so the two work together whether Dynamic
    // Orbit is on or off. Bipolar ±1, 0 = frame center = pre-M16-Part-2.
    var torsionCenterX: Float = 0.0
    var torsionCenterY: Float = 0.0

    // Spiral 2 (M7 Phase 7.1) — nested inside Spiral 1's already-warped
    // output, full independent VCO block, planetary-epicycle look.
    var spiral2Strength: Float = 0.0     // bipolar VCO amplitude, -3...3
    var spiral2FreqOffset: Float = 0.0   // bipolar, added to torsionFrequency; -15...15
    var spiral2WaveType: Float = 0.0     // 0=Sine,1=Tri,2=Saw,3=S&H,4=Square
    var spiral2Lag: Float = 0.0
    var spiral2OrbitDepth: Float = 0.0   // 0=static center, 1=full orbit
    var spiral2OrbitPhase: Float = 0.0   // 0...1 -> 0...2π; walks Rotation 2 around its orbit vs Rotation 1
    var spiral2OrbitRatio: Float = 1.0   // Lissajous ratio, X axis only; 1=ellipse, 2=figure-eight, 3=trefoil
    var spiral2RadialMode: Float = 1.0   // 0=Normal, 1=Radial (independent of torsionRadialMode; default Radial)
    var spiralCombineMode: Float = 0.0   // 0=Additive, 1=Subtractive, 2=XOR — combines the two spirals' twist waves for Rotation Wave Mix
    // M16 Part 2: Rotation 2's own center, independent of Rotation 1's — same
    // reasoning as its axis-transposed orbit formula. Seeded before the orbit
    // gate; the orbit adds onto it.
    var spiral2CenterX: Float = 0.0
    var spiral2CenterY: Float = 0.0

    // Mirror 1
    var mirror1On: Float = 1.0
    var mirror1WaveType: Float = 0.0
    var mirror1Lag: Float = 0.0
    var mirror1AutoSpinOn: Float = 0.0
    var mirror1AutoSpinSpeed: Float = 0.0   // position; starts stationary when spin enabled
    var mirror1StaticAngle: Float = 0.0
    var mirror1RippleAmpRaw: Float = 0.0
    var mirror1RippleFreq: Float = 5.0
    var mirror1Speed: Float = 0.44721    // position; ×²×5.0 ≈ 1.0 rate
    var lumaMod1: Float = 0.0
    var mirror1RadialMode: Float = 0.0   // 0=Normal, 1=Radial
    // M14 Part 1: where this mirror stands. Moves the seam, moves the pivot the
    // angle turns about, and re-anchors Radial mode's rings — all one translate
    // in the shader. Bipolar ±1, 0 = screen center = the pre-M14 behavior.
    var mirror1CenterX: Float = 0.0
    var mirror1CenterY: Float = 0.0
    // M26: the doubled fold — a flat reflection line through this module's
    // center, at base angle + offset. Flag plus offset, both per module,
    // because the default offset is pi and one control alone would make "off"
    // an end stop and "opposed" a middle position — not a live gesture. The
    // flag also holds the offset while disabled. Same shape Spin uses above.
    var mirror1DoubleOn: Float = 0.0
    var mirror1DoubleOffset: Float = .pi    // radians, 0...2pi; pi = opposed

    // Mirror 2
    var mirror2On: Float = 1.0
    var mirror2WaveType: Float = 0.0
    var mirror2Lag: Float = 0.0
    var mirror2AutoSpinOn: Float = 0.0
    var mirror2AutoSpinSpeed: Float = 0.0   // position; starts stationary when spin enabled
    var mirror2StaticAngle: Float = 1.57079632679
    var mirror2RippleAmpRaw: Float = 0.0
    var mirror2RippleFreq: Float = 5.0
    var mirror2Speed: Float = 0.44721
    var lumaMod2: Float = 0.0
    var mirror2RadialMode: Float = 0.0
    // M14 Part 1: independent of Mirror 1's center on purpose — two seams
    // pivoting about different points is a geometry not reachable any other way.
    var mirror2CenterX: Float = 0.0
    var mirror2CenterY: Float = 0.0
    // M26: independent of Mirror 1's, same as everything else in this module.
    // Mirror 2's base angle defaults to pi/2, so the doubled partner sits at
    // 3pi/2 — the two modules together fold all four half-planes and the
    // statically-unwarped quadrant the default patch used to leave is gone.
    var mirror2DoubleOn: Float = 0.0
    var mirror2DoubleOffset: Float = .pi

    // Keying (hole cutter & keyers). M12 removed holeCutterPost — the Pre-FX
    // path is gone and Post-FX, the shipped default, is the only behavior.
    var invertEntireHoleKey: Float = 0.0
    var negativeSpace: Float = 0.0       // on/off toggle (0 or 1)
    var negativeSpaceThreshold: Float = 0.7
    var rectification: Float = 0.0
    var torsionInHoles: Float = 0.0
    // M12: one softness for every threshold in the section. Was five.
    var keySoftness: Float = 0.0         // key softness: ALL key thresholds

    var keyerThreshold1: Float = 1.0     // Keyer 1 (Mirrors), absolute
    var keyerOffset2: Float = 0.0        // Keyer 2 (Rotation), bipolar offset from Keyer 1
    var keyerOffset3: Float = 0.0        // Keyer 3 (Displacement), bipolar offset from Keyer 1
    var keyerPolarity: Float = 0.0       // global, all three keyers: 0=Brights, 1=Darks
    var keyerXOR1: Float = 0.0
    var keyerXOR2: Float = 0.0
    var keyerXOR3: Float = 0.0
    var keyerFeed1: Float = 0.0          // 0=Mirrors, 1=Warped Final
    var keyerFeed2: Float = 0.0          // 0=Rotation, 1=Warped Final
    var keyerFeed3: Float = 0.0          // 0=Displacement, 1=Warped Final

    // Global LFO (rate is a bipolar POSITION in -1...1; renderer curves it)
    var lfoRate: Float = 0.27386
    var lfoWaveType: Float = 0.0
    var lfoLag: Float = 0.0

    // ---- M16: family destinations, fed by the modulation bus ----
    // WAS eleven flat per-destination amounts. Each family below groups
    // destinations that form a genuine PAIR (or triple) within one module
    // family; busSpread (below) is the single global control setting the
    // phase angle between successive members. See LiquidRenderer.draw()'s
    // Global LFO block for busAt(), the one rule this reduces to.
    //
    // TWO KINDS OF FAMILY, and the difference is worth knowing:
    //
    //   AMPLITUDE families pair two SCALARS that belong together (Rotation 1
    //   + Rotation 2 strength; Mirror 1 + Mirror 2 ripple). The bus is not
    //   really 2D here — the members get PHASE-SHIFTED COPIES of one signal,
    //   which is what makes them counter-move or roll against each other.
    //
    //   CENTER families drive a genuine XY VECTOR (a fold center, an orbit
    //   center). Here the bus is 2D in the real sense: X drives X, Y drives
    //   Y, and the destination traces a PATH around the frame. The second
    //   member additionally takes the axes SWAPPED (its X reads the bus's Y
    //   and vice versa), which REFLECTS its path against the first member's
    //   so the two move oppositely rather than translating together.
    //
    // Rotation amplitude: Torsion Strength (leads), Rotation 2 Strength.
    var lfoToRotation: Float = 0.0
    // Rotation CENTER (2D): Rotation 1 takes the bus vector as (X, Y);
    // Rotation 2 takes it axis-SWAPPED as (Y, X), tracing mirror-image
    // paths — identical structure to Mirror Center below, and it SUMS with
    // Dynamic Orbit in the shader rather than fighting it: both can be on at
    // once. Sums ON TOP of each Rotation section's own Center X/Y sliders.
    var lfoToRotationCenter: Float = 0.0
    // Mirror amplitude: Mirror 1 Ripple (leads), Mirror 2 Ripple.
    var lfoToMirrors: Float = 0.0
    // Mirror CENTER (2D): Mirror 1 takes the bus vector as (X, Y); Mirror 2
    // takes it axis-SWAPPED as (Y, X), so the two fold centers trace
    // mirror-image paths. Sums ON TOP of the hand-set center sliders in each
    // Mirror section — those become an offset, not a replacement. Costs ZERO
    // ShaderParams pads: mirror1CenterX/Y and mirror2CenterX/Y already exist
    // as uniforms from M14 Part 1.
    var lfoToMirrorCenter: Float = 0.0
    // Displacement amplitude: Displace X Amp (leads), Displace Y Amp. At
    // busSpread 0.5 (quadrature) the two axes sit 90 degrees apart and the
    // field moves in circles rather than pulsing on a diagonal.
    var lfoToDisplacement: Float = 0.0
    // Displacement CENTER (2D): unlike the two above, Displacement has only
    // ONE center — there is no second member to swap axes against or spread.
    // X drives X, Y drives Y, plain. Sums on top of the hand Center X/Y
    // sliders. This asymmetry comes from the module having one anchor, not
    // from a decision to treat it differently.
    var lfoToDispCenter: Float = 0.0
    // Keying: Keyer Threshold 1 (leads), Keyer Offset 2, Keyer Offset 3 —
    // the three-member family, so Offset 3 sits at twice Offset 2's phase
    // angle and the two gaps never breathe together.
    var lfoToKeying: Float = 0.0

    // M16 revision: HOLES IS GONE as a destination family
    // (negativeSpaceThreshold + rectification). Rectification has a blip low
    // in its range that reads as a hiccup under continuous modulation;
    // rather than paper over it, both were withdrawn for re-evaluation
    // later. Neither PARAMETER was removed — both are still hand controls in
    // the Keying section. They simply have no LFO destination now.

    // M16 revision: Radial Push and Luma Source Staging are SEPARATE single
    // destinations rather than one "Character" family. They were paired
    // because both modulate character rather than depth — true, but not a
    // reason to weld them: Radial Push wants dialling in rarely and
    // deliberately, while Luma Staging suits a slow constant drift.
    // Different jobs, so different sliders.
    var lfoToRadialPush: Float = 0.0
    var lfoToLumaStage: Float = 0.0

    // M16: THE one global control shaping every family above. It is a PHASE
    // ANGLE, not a blend: member n of a family reads the whole LFO chain
    // evaluated at (phase + n * busSpread * pi). So
    //     0.0  = every member in step        (pre-M16 behavior, the default)
    //     0.25 = 45 degrees between members
    //     0.5  = 90 degrees  — QUADRATURE. Circular / rolling motion
    //     1.0  = 180 degrees — ANTIPHASE. Members exactly counter-move
    // and the negative half walks the same angles the other way round, which
    // reverses the direction a 2D center path travels.
    //
    // Because it is a TRUE phase shift — the waveform is re-evaluated at the
    // offset rather than crossfaded toward a quadrature copy — it is exact
    // for EVERY waveform: Square's edges land where they should, S&H holds a
    // genuinely different step, Saw wraps correctly. A crossfade would have
    // been right only for Sine.
    var busSpread: Float = 0.0

    // M16 revision: busFastClockAmount is GONE. It crossfaded the bus toward
    // the stop-motion trigger clock, which handed the Recording section's
    // Trigger Rate slider a second, hidden job — turning it up to a normal
    // capture rate also drove every modulation destination hard. That
    // coupling was a design mistake and is removed rather than tuned. Fast
    // modulation is reached the way it should be: the LFO's own rate range.

    // M16 revision: the Global LFO's rate RANGE. 0 = Slow (max 2 rad/s,
    // ~0.32 Hz — the range this instrument has always had, so every existing
    // patch's Rate slider position still means exactly what it always did),
    // 1 = Fast (max 20 rad/s, ~3.2 Hz). Discrete rather than simply widening
    // the Rate slider, precisely so that flipping ranges is the ONLY thing
    // that ever rescales what a given Rate position means. LFO 2's rate
    // offset scales with the range too, so the beat period stays
    // proportional instead of collapsing to a crawl in Fast.
    var lfoRateRange: Float = 0.0

    // ---- Complex LFO: second oscillator (M9) ----
    // A second LFO running at LFO 1's rate PLUS an offset, with its own
    // waveform, slew and fixed phase, combined with LFO 1 into the single
    // modulation bus every destination above already reads. Nothing here
    // reaches ShaderParams — the Global LFO is resolved entirely CPU-side in
    // LiquidRenderer, so M9 costs zero pads and cannot desync the structs.
    //
    // The characteristic behavior is BEATING: two oscillators a fraction of a
    // hertz apart drift in and out of phase, so the modulation swells and
    // cancels on a cycle far slower than either oscillator. That swell period
    // is the reciprocal of the frequency difference, which lfo2RateOffset
    // plays directly — small offset, very long swell; large offset, a wobble.
    //
    // DEFAULTS ARE PIXEL-IDENTICAL TO PRE-M9, but only because BOTH of these
    // hold: lfo2Depth 0 zeroes LFO 2's contribution, AND lfoCombineMode 0
    // (Additive) makes `lfo1 + 0 == lfo1`. This is NOT true of every mode —
    // XOR at depth 0 yields abs(lfo1), which is a real change in behavior, not
    // a bug. Same situation as combineSpiralWaves; documented here rather than
    // rediscovered later.
    var lfo2Depth: Float = 0.0           // 0...1 — scales LFO 2 before combining; 0 = M9 inert
    var lfo2RateOffset: Float = 0.0      // BIPOLAR -1...1 — Δf, applied AFTER LFO 1's rate curve
    var lfo2WaveType: Float = 0.0        // 0=Sine,1=Tri,2=Saw,3=S&H,4=Square
    var lfo2Lag: Float = 0.0             // S&H slew, same as lfoLag
    var lfo2PhaseOffset: Float = 0.0     // 0...1 -> 0...2π, fixed head start on LFO 2
    var lfoCombineMode: Float = 0.0      // 0=Additive,1=Subtractive,2=XOR,3=Multiply (ring mod)

    // M15: colorSeparation removed, and with it the whole Color section. The
    // RGB fringe was the only thing in the instrument that treated R, G and B
    // differently, and per-channel colour processing is deliberately not coming
    // back in any form. Colour is a byproduct of the geometry, not a dimension
    // the instrument processes.

    // Output (M1a): final wet/dry blend. 0 = dry (unwarped source), 1 = full
    // effected. Sits at the very end of the chain; the output-shape stage
    // (vignette) runs after it.
    var outputMix: Float = 1.0

    // Output Vignette (M2): screen-space shape matte applied at the very END of
    // the chain, AFTER the M1a output mix. 0 = Off skips it entirely (output
    // pixel-identical to pre-M2). Shape 1 = Circle, 2 = Rect. Center is bipolar
    // around screen center. Aspect is bipolar with no floor: -X stretches wide,
    // +Y stretches tall, 0 = uniform — and doubles as the Rect W/H ratio, so no
    // separate width/height params. Softness reuses the key-softness pattern
    // (0 = hard edge, up to 0.5 feather).
    var vignetteShape: Float = 0.0
    var vignetteCenterX: Float = 0.0
    var vignetteCenterY: Float = 0.0
    var vignetteSize: Float = 0.5
    var vignetteAspect: Float = 0.0
    var vignetteSoftness: Float = 0.0

    // M4.4 Part B: write the vignette's coverage into the ALPHA channel as
    // well as multiplying rgb by it. 0 = off (alpha stays 1.0 everywhere,
    // bit-identical to pre-M4.4), 1 = on. This is the ONE control in the
    // instrument whose effect is invisible on screen — the present pass
    // forces the drawable opaque — and shows up only in a ProRes 4444
    // recording or, with Q3 answered yes, a PNG screenshot. The UI says so at
    // the point of use rather than relying on that being remembered.
    //
    // Premultiplied alpha (rgb already multiplied by the same coverage). At
    // Edge Softness 0 premultiplied and straight are identical; the
    // distinction only exists once the edge is feathered, where an NLE may
    // need the clip set to Premultiplied to avoid a dark halo.
    var vignetteAlpha: Float = 0.0

    // Output Resolution (M18): what size PASS 1 actually renders at. Discrete
    // on purpose — never a continuous slider — because every distinct render
    // size means reallocating the offscreen texture AND invalidating
    // FrameCapture's CVPixelBuffer pool, which a slider drag would fire dozens
    // of times a second. This is LiveParams-only (like recordMode): main-
    // thread-edited discrete state, read once per frame by the renderer, no
    // ShaderParams field, no pad consumed.
    //   0 = Native      (drawable size, unrounded — bit-identical to pre-M18)
    //   1 = Native ÷ 2  (drawable / 2, forced even)
    //   2 = 640 × 480        5 = 1080 × 1080
    //   3 = 1280 × 720       6 = 1080 × 1920
    //   4 = 1920 × 1080      7 = 3840 × 2160
    // The fixed sizes themselves live in ONE place —
    // LiquidRenderer.fixedResolutionSize(forMode:) — shared by the renderer
    // (what to render at) and AppController.matchWindowAspect(toResolutionMode:)
    // (what aspect to reshape the window to), so the two can never drift apart.
    // Recording and screenshots inherit this directly; there is no separate
    // "recording resolution" (see the M18 plan, D6).
    var outputResolution: Float = 0.0


    // M12: the Output Glow block (M5) lived here — glowOn, glowRadius,
    // glowGain, glowMode, plus lfoToGlowGain above. Removed whole. LiveParams
    // fields are not index-mapped, so unlike ShaderParams these are deleted
    // outright rather than renamed to pads.

    // Recording (M4.2): chosen FPS for the NEXT take, picked via the segmented
    // preset picker or the free-entry field in the Recording section — both
    // write here. This is a continuous value edited on the main thread, so
    // per the established rule it belongs in ParamStore, NOT in RecorderState
    // (which is event-driven only). LiquidRenderer never reads this field
    // directly — it reads FrameCapture.activeFrameInterval instead. The flow
    // is: this value is read ONCE, when the Record button is pressed
    // (ContentView passes it into capture.record(fps:stopMotion:codec:)), at which point
    // FrameCapture clamps and snapshots it into its own private `lockedFPS`.
    // From then on activeFrameInterval derives from that locked snapshot, not
    // from this live value, so changing the picker mid-take (already
    // prevented by the UI being disabled) couldn't desync timestamps even if
    // it were still editable.
    var recordFPS: Float = 30.0

    // Recording codec (M4.4 Part A): which codec the NEXT take is written
    // with. Discrete state driving a control that is locked during a take, so
    // per the house rule it's a LOCAL @State mirror in the Recording section
    // written through here. LiveParams-only — no ShaderParams field, no pad;
    // this never reaches the GPU.
    //   0 = H.264          (DEFAULT — exactly the pre-M4.4 behavior)
    //   1 = ProRes 422 HQ  (intra-only master, no alpha)
    //   2 = ProRes 4444    (master WITH alpha — the vignette matte carrier)
    //
    // Read ONCE, at the moment Record is pressed, exactly like recordFPS:
    // ContentView passes it into capture.record(fps:stopMotion:codec:), which
    // snapshots it for the life of the take. The codec cannot change
    // mid-take any more than the frame rate can.
    //
    // WHY H.264 STAYS THE DEFAULT: every existing habit and every previously
    // recorded take stays consistent, and ProRes is one menu pick away. It
    // also keeps M4.4's "no regression" claim absolute — the default path
    // through beginWriterSession is byte-for-byte what shipped before.
    //
    // COLOR TAGGING lives on the ProRes branches ONLY. M4.2 found that
    // AVVideoColorPropertiesKey throws NSInvalidArgumentException at
    // AVAssetWriterInput init for avc1 in this settings shape. Do not add it
    // to the H.264 path — that crash is a shipped, confirmed finding, not a
    // theoretical risk.
    var recordCodec: Float = 0.0

    // Recording mode (M4.3): 0 = Long-form (continuous capture at recordFPS,
    // the 4.2 behavior), 1 = Stop-motion (single frames accumulated into one
    // clip; recordFPS becomes the PLAYBACK rate of that clip). This is discrete
    // state that drives conditional transport UI, so per the house rule it's
    // owned as a LOCAL @State mirror in the Recording section that writes
    // through here — never a binding into an ObservableObject. The renderer
    // reads it each frame to choose the capture-trigger path (pacing accumulator
    // vs. LFO edge); FrameCapture itself only learns the mode at Record time
    // (for the progress-publish throttle — stop-motion publishes every sparse
    // capture, long-form throttles to 1/sec).
    var recordMode: Float = 0.0

    // Stop-motion LFO auto-trigger (M4.3): 0/1 toggle. When on, one frame is
    // captured per Global LFO cycle. Kept live (readable mid-take) so it can be
    // armed/disarmed as a performance gesture. Only acted on while actively
    // recording in stop-motion mode.
    var stopMotionLFOTrigger: Float = 0.0

    // Stop-motion capture phase (M4.3): 0...1, the point WITHIN each LFO cycle
    // at which the auto-trigger grabs its one frame (0 = cycle start, 0.5 =
    // mid-cycle, approaching 1 = almost a full cycle later). This is the option
    // (b) reinterpretation of the roadmap's "pulse width": with single-capture
    // (non-burst) triggering, a square gate's rising edge sits at a fixed phase
    // regardless of duty, so instead of an inert duty control this shifts WHERE
    // in the cycle the frame is taken — a real, musical effect now (grab the
    // look at the LFO's peak vs. trough), with room for a future burst toggle.
    var stopMotionCapturePhase: Float = 0.5

    // Stop-motion trigger clock rate (M4.3b): bipolar POSITION in -1...1 per
    // the rate-slider convention; the renderer curves it via sign(x)·x²·maxRate
    // with maxRate 60 rad/s (≈9.5 Hz at full). This is the auto-trigger's OWN
    // clock, independent of the Global LFO, which is what lets stop-motion
    // capture run fast — the Global LFO tops out near 0.3 Hz and was the
    // ceiling before. It is a bare phase RAMP, not a waveform: only the cycle
    // wrap matters for edge detection, so no wave-type/lag params are needed.
    // Sign only reverses which way the playhead sweeps; captures still land
    // once per cycle either direction.
    var stopMotionTriggerRate: Float = 0.3

    // Global LFO ➔ stop-motion capture phase (M4.3b): bipolar amount. Sweeps
    // WHERE in each trigger cycle the frame is grabbed, at the Global LFO's
    // rate/waveform. Because the trigger fires on the playhead crossing that
    // moving point, sweeping it perturbs the spacing between captures —
    // automating the irregular/uneven triggering that hand-dragging the
    // Capture Phase slider produced. This is the ONLY way the Global LFO
    // participates in stop-motion triggering now; it no longer clocks it.
    var lfoToCapturePhase: Float = 0.0
}

// ParamStore: single source of truth shared between the UI thread and the
// render loop. Slider writes are a lock + one float assignment.
final class ParamStore {
    private var params = LiveParams()
    private let lock = NSLock()

    func set(_ keyPath: WritableKeyPath<LiveParams, Float>, _ newValue: Float) {
        lock.lock()
        params[keyPath: keyPath] = newValue
        lock.unlock()
    }

    func get(_ keyPath: KeyPath<LiveParams, Float>) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return params[keyPath: keyPath]
    }

    func snapshot() -> LiveParams {
        lock.lock()
        defer { lock.unlock() }
        return params
    }

    // M13: write an entire state atomically. One lock, one assignment — the
    // same shape and cost as `set`, and safe against the render thread's
    // snapshot() for the same reason.
    //
    // Deliberately built as a general replaceAll rather than a bare reset:
    // this is exactly the primitive a full-system-state preset manager would
    // need (see Parked Ideas in ROADMAP.md), and writing it general costs
    // nothing today. The manager itself is NOT built here.
    //
    // IMPORTANT for any caller: this changes values the UI has already cached.
    // Every control reads the store once in onAppear behind a `loaded` flag —
    // that is what keeps slider drags off the SwiftUI observation path — so a
    // caller MUST also force the control views to rebuild, or the sliders will
    // keep displaying stale numbers while the render path uses the new ones.
    // AppController.performResetAll() does both; follow that pattern.
    func replaceAll(_ newParams: LiveParams) {
        lock.lock()
        params = newParams
        lock.unlock()
    }

    func resetToDefaults() {
        replaceAll(LiveParams())
    }
}
















