import Foundation

// 128-Float packed CPU uniform block matching Shaders.metal exactly (512 bytes).
// RULE: Any field added/renamed here MUST be mirrored at the same index in
// the ShaderParams struct in Shaders.metal. Consume pad slots from the top.
//
// M15 — THE RECLAIMED POOL. Free slots are no longer only at the tail. A field
// that stops being used is renamed back to padNN AT ITS OWN INDEX and returned
// to the pool; it is never deleted, because deleting a field mid-struct shifts
// every index after it and silently corrupts every uniform downstream. That is
// what the static_assert exists to catch.
//
// A rename is not a move: every field keeps its byte offset, so the picture
// cannot change at any setting. The one silent failure mode is renaming index N
// in one struct and index M in the other — run the positional parity check
// after every struct edit, without exception.
//
// FREE SLOTS AFTER M15 (27 total):
//   Reclaimed, mid-struct: 3, 18, 28, 43, 44, 55, 56, 57, 64, 105, 106, 107,
//                          108, 109
//   Tail:                  115–127
// CONSUMPTION RULE: contiguous groups of related params take tail pads (115
// upward); single scalars may take a reclaimed mid-struct slot. Either way,
// rename at the same index in BOTH structs and run the parity check.
struct ShaderParams {
    var torsionStrength: Float = 0.5        // 0 (bipolar amplitude, -3...3)
    var torsionFrequency: Float = 5.0       // 1
    var lumaTorsion: Float = 0.0            // 2
    // M15: was torsionFirst, superseded by the routing chain (78–82) in M7 7.2.
    // Reclaimed rather than left frozen under a name that looked meaningful.
    var pad3: Float = 0.0                   // 3 (RECLAIMED, M15)

    var mirror1On: Float = 1.0              // 4
    var mirror1Angle: Float = 0.0           // 5
    var mirror1RippleAmp: Float = 0.0       // 6
    var mirror1RippleFreq: Float = 5.0      // 7

    var mirror1Phase: Float = 0.0           // 8
    var mirror1WaveType: Float = 0.0        // 9
    var mirror2On: Float = 1.0              // 10
    var mirror2Angle: Float = 1.57079632679 // 11

    var mirror2RippleAmp: Float = 0.0       // 12
    var mirror2RippleFreq: Float = 5.0      // 13
    var mirror2Phase: Float = 0.0           // 14
    var mirror2WaveType: Float = 0.0        // 15

    var lumaMod1: Float = 0.0               // 16
    var lumaMod2: Float = 0.0               // 17
    // M15: was colorSeparation. Note it had ALREADY stopped being read by the
    // shader when M1c split the fringe into three per-channel amounts — it was
    // carried as a live-looking field for the whole life of that feature.
    var pad18: Float = 0.0                  // 18 (RECLAIMED, M15)
    var scale: Float = 1.0                  // 19

    var edgeBehavior: Float = 0.0           // 20
    // M12: was holeCutterPost. The Pre-FX collision key ran a private copy of
    // both mirrors on the UNWARPED uv, so the key could be taken from geometry
    // that was not the geometry on screen. Post-FX was the shipped default and
    // is now the only path.
    var pad21: Float = 0.0                  // 21 (RECLAIMED, M12)
    var negativeSpace: Float = 0.0          // 22
    var negativeSpaceThreshold: Float = 0.7 // 23

    var rectification: Float = 0.0          // 24
    var torsionInHoles: Float = 0.0         // 25
    var keyerThreshold1: Float = 1.0        // 26 (Keyer 1, absolute — was lumaKeyThreshold)
    var keyerXOR1: Float = 0.0              // 27 (Keyer 1 XOR intersection — was lumaKeyInvert)

    // M15: was torsionCenterMode, superseded by the continuous orbit depth at
    // index 50 (0 = static) long before this. Reclaimed.
    var pad28: Float = 0.0                  // 28 (RECLAIMED, M15)
    var sourceType: Float = 0.0             // 29
    var pad30: Float = 0.0                  // 30 (RECLAIMED, M12 Part 7C — was keyerTarget)
    var time: Float = 0.0                   // 31

    // --- EXTENDED PARAMETERS (32–42) ---
    var mirror1Lag: Float = 0.0             // 32
    var mirror2Lag: Float = 0.0             // 33
    var pad34: Float = 0.0                  // 34 (RECLAIMED, M12 — was videoInvertMix)
    var keyerOffset2: Float = 0.0           // 35 (Keyer 2, bipolar offset from Keyer 1 — was lumaKeyThreshold2)
    var pad36: Float = 0.0                  // 36 (RECLAIMED, M12 Part 7C — was keyerTarget2)
    var keyerPolarity: Float = 0.0          // 37 (global: 0=Brights, 1=Darks — was lumaKey1Polarity)
    var pad38: Float = 0.0                  // 38 (RECLAIMED, M12 Part 7C — was lumaKey2Polarity)
    var keyerXOR3: Float = 0.0              // 39 (Keyer 3 XOR intersection — was lumaKeyInvert2)

    var pad40: Float = 0.0                  // 40 (RECLAIMED, M12 — was keyerPosterize)
    var invertEntireHoleKey: Float = 0.0    // 41
    var preCrop: Float = 0.0                // 42

    // --- RECLAIMED, M15 (43, 44, 64, 105–109) — THE "PARITY-ONLY" SLOTS ---
    // These eight held values the GPU never read. They were documented as
    // "carried for parity," which was a misnomer and the reason they survived:
    // parity is POSITIONAL. A field at index 105 preserves the layout because
    // it sits at index 105, not because it has a name — padNN preserves it
    // exactly as well, same bytes, same offset, same static_assert. The names
    // therefore bought documentation only, while making the struct read as
    // though the shader used them.
    //   43, 44  — the Global LFO's waveform and slew. The entire LFO resolves
    //             CPU-side in LiquidRenderer (the M9 finding); the GPU sees
    //             only already-modulated destination values.
    //   64      — the glow on/off toggle. The renderer decided whether to
    //             ENCODE the glow passes at all, so the shader never needed
    //             it. (M12 removed glow entirely; 65–68 joined this pool.)
    //   105–109 — M8 C.5's LFO destinations, all modulated and clamped
    //             renderer-side before the struct is built.
    // The LiveParams equivalents are all still live and still drive everything;
    // only these dead GPU-side mirrors are gone.
    // --- M0.5 PARAMETERS (45–47; 43–44 reclaimed above) ---
    var pad43: Float = 0.0                  // 43 (RECLAIMED, M15 — was lfoWaveType)
    var pad44: Float = 0.0                  // 44 (RECLAIMED, M15 — was lfoLag)
    var mirror1RadialMode: Float = 0.0      // 45
    var mirror2RadialMode: Float = 0.0      // 46
    var torsionRadialMode: Float = 1.0      // 47 (default Radial)

    // --- M1b / orbit-depth PARAMETERS (48–50) ---
    var torsionWaveType: Float = 0.0        // 48 (shared by rotation warp + hole mix)
    var torsionLag: Float = 0.0             // 49
    var torsionOrbitDepth: Float = 0.0      // 50 (0=static center, 1=full orbit)

    // --- KEY SOFTNESS (51; 52–53 reclaimed) ---
    // 0 = hard boolean edge (bit-identical to a plain threshold); >0 = a
    // smoothstep feather band of this half-width around the threshold.
    //
    // M12: ONE softness for every threshold in the keying section. There were
    // five — wave hole, Luma Key 1, Luma Key 2, displacement hole, rotation
    // hole — and in practice they were dialed together or left at zero. Index
    // 51 keeps the slot and the other four are reclaimed. UI range narrowed to
    // 0...0.35: one control now drives everything, and 0...0.5 put all the
    // useful travel in the bottom fifth.
    //
    // The vignette keeps its own `vignetteSoftness` (63). It is an output
    // shape, not a key — and since M12 Part 5 it is also a key EDGE, which is
    // a reason to keep it independent rather than a reason to fold it in.
    var keySoftness: Float = 0.0            // 51 (ALL key thresholds)
    var pad52: Float = 0.0                  // 52 (RECLAIMED, M12 — was lumaKey1Soft)
    var pad53: Float = 0.0                  // 53 (RECLAIMED, M12 — was lumaKey2Soft)

    // --- M1a OUTPUT MIX (54) ---
    // Final wet/dry blend applied after ALL effects. 0 = dry (raw source at the
    // unwarped screen uv; scale + edge behavior + pre-crop still apply, nothing
    // else), 1 = full effected. Default 1 = pixel-identical to pre-M1a output.
    // Any output-shape stage (the M2 vignette) mattes the MIXED result, i.e.
    // it runs AFTER this blend, not before.
    var outputMix: Float = 1.0              // 54

    // --- RECLAIMED, M15 (55–57) — were the three RGB fringe separations ---
    // The fringe is gone: nothing in the instrument treats R, G and B
    // differently any more. Colour is allowed to happen as a byproduct of the
    // geometry rather than being a dimension the instrument processes, and
    // per-channel colour processing is deliberately out of scope for good.
    // See the M15 status block in ROADMAP.md.
    var pad55: Float = 0.0                  // 55 (RECLAIMED, M15)
    var pad56: Float = 0.0                  // 56 (RECLAIMED, M15)
    var pad57: Float = 0.0                  // 57 (RECLAIMED, M15)

    // --- M2 OUTPUT VIGNETTE (58–63) — last of the original 64-float pads ---
    // End-of-chain screen-space shape matte. Applied AFTER the M1a output mix
    // (index 54): the mix blends effected-vs-dry first, then the vignette
    // shape-crops that blended result. Operates on raw screen uv, so it's
    // unaffected by zoom/warp — a physical output mask. Outside the shape goes
    // black. At vignetteShape == 0 (Off) the shader skips the whole block, so
    // output is pixel-identical to pre-M2.
    var vignetteShape: Float = 0.0          // 58 (0=Off, 1=Circle, 2=Rect)
    var vignetteCenterX: Float = 0.0        // 59 (bipolar, -0.5...0.5 around center)
    var vignetteCenterY: Float = 0.0        // 60 (bipolar, -0.5...0.5 around center)
    var vignetteSize: Float = 0.5           // 61 (0.05...1.0)
    // Bipolar aspect stretch (no floor): -X stretches the shape wide, +Y
    // stretches it tall, 0 = uniform. For the Rect shape this same knob sets its
    // width/height ratio, so no separate rect W/H params are needed.
    var vignetteAspect: Float = 0.0         // 62 (bipolar, -1...1)
    // Edge softness reuses the key-softness pattern: 0 = hard boolean edge,
    // >0 = smoothstep feather half-width on the SDF.
    var vignetteSoftness: Float = 0.0       // 63 (0...0.5)

    // --- RECLAIMED, M12 (64–68) — was M5 OUTPUT GLOW ---
    // M5 shipped and was confirmed working, then removed whole in M12. An
    // end-of-chain halo is an output-stage effect, and this instrument is
    // about geometry and the movement of the frame; light and colour are
    // byproducts of that work rather than things to add at the end.
    //
    // Removed with it: glowBlurShader and glowCompositeShader, three render
    // targets (two half-res ping-pong, one full-res composite — about 22 MB
    // at 2560x1440), and three of the five render passes.
    //
    // KEPT: the M3 two-pass structure. The `finalTexture` local glow left
    // behind was NOT kept — with glow gone it aliased the offscreen texture
    // and nothing else. What it protected is real and now lives as a rule in
    // a comment at LiquidRenderer's capture blit: any pass added after pass 1
    // that renders elsewhere must be wired into the capture tap AND the
    // present pass in the same edit.
    var pad64: Float = 0.0                  // 64 (RECLAIMED, M15 — was glowOn)
    var pad65: Float = 0.0                  // 65 (RECLAIMED, M12 — was glowRadius)
    var pad66: Float = 0.0                  // 66 (RECLAIMED, M12 — was glowGain)
    var pad67: Float = 0.0                  // 67 (RECLAIMED, M12 — was glowMode)
    var pad68: Float = 0.0                  // 68 (RECLAIMED, M12 — was glowBlurDir)

    // --- M7 PHASE 7.1: DUAL SPIRAL ENGINE (69–75) ---
    // Spiral 2 is a second torsion/spiral module nested inside Spiral 1 (a.k.a.
    // "Rotation") — a planetary epicycle. It warps whatever coordinate Spiral 1
    // already produced (chained in fragmentShader, not composed here), so its
    // orbit center and twist ring live in Spiral 1's already-warped space. At
    // spiral2Strength == 0 its warp is the identity, so output stays
    // pixel-identical to pre-M7.
    var spiral2Strength: Float = 0.0        // 69 (bipolar VCO amplitude, -3...3)
    // Spiral 2's own frequency is torsionFrequency + this offset, NOT an
    // absolute rate — that's what lets it run faster/slower than the spiral
    // it's nested inside (the "small fast planet in a slow orbit" feel).
    var spiral2FreqOffset: Float = 0.0      // 70 (bipolar, -15...15)
    var spiral2WaveType: Float = 0.0        // 71 (0=Sine,1=Tri,2=Saw,3=S&H,4=Square)

    var spiral2Lag: Float = 0.0             // 72 (S&H slew, mirrors torsionLag)
    var spiral2OrbitDepth: Float = 0.0      // 73 (0=static center, 1=full orbit, same Lissajous pattern as torsionOrbitDepth)
    // Independent of torsionRadialMode on purpose — per-spiral radial mode is
    // part of what makes Spiral 2 feel distinct rather than "Spiral 1 but
    // wobblier." Default Radial to match Spiral 1's default.
    var spiral2RadialMode: Float = 1.0      // 74 (0=Normal, 1=Radial)
    // Selects how Spiral 1's and Spiral 2's twist waves combine before
    // feeding the hole-cutter's Rotation Wave Mix (torsionInHoles). REPLACES
    // the old single-spiral-only signal that fed torsionInHoles; the
    // injection AMOUNT control (torsionInHoles) itself is unchanged. At
    // spiral2Strength == 0 the three MIXING modes collapse to "Spiral 1's
    // wave alone" (additive: a+0, subtractive: a-0, XOR: abs(a-0)=a), so this
    // stays pixel-identical to pre-M7 at defaults.
    //
    // M12: this comment said "all three modes" and had done since M8 Phase
    // C.4 added a fourth. Multiply is a ring modulator, not a mix, and it is
    // the one mode that does NOT reduce to twist1 when Spiral 2 is silent —
    // it reduces to zero, which is what a ring modulator with a dead input
    // should do. Default is Additive, so nothing shipped is affected.
    var spiralCombineMode: Float = 0.0      // 75 (0=Additive, 1=Subtractive, 2=XOR, 3=Multiply)

    // --- M0b FREE PAD SLOTS (76–127) ---
    // Struct grew 64 -> 128 floats (256 -> 512 bytes) in M0b. Pure extension:
    // indices 0–63 above are frozen byte-for-byte, nothing was reshuffled, and
    // the shader never reads anything below this line, so output is unchanged.
    // TO CONSUME A SLOT: rename padNN to the real field name, give it a default,
    // and make the SAME rename at the SAME index in Shaders.metal. Take them
    // from the top, in order. Never reorder, never resize.
    // --- M7 PHASE 7.1a: ROTATION 2 ORBIT DECORRELATION (76–77) ---
    // Rotation 2's orbit originally reused Rotation 1's Lissajous formula
    // verbatim, which made its center a pure scalar multiple of Rotation 1's —
    // the two centers stayed collinear with the origin at all times, so
    // different depths read as "same path, further out" instead of two orbits.
    // Fixed by (a) transposing Rotation 2's axes, and (b) these two controls.
    // Orbit phase offset, 0...1 mapped to 0...2π. Walks Rotation 2's center
    // around its orbit relative to Rotation 1: 0 = in step, 0.5 = opposite side.
    var spiral2OrbitPhase: Float = 0.0      // 76
    // Lissajous frequency ratio, applied to the X axis ONLY (applying it to
    // both axes would preserve the X:Y ratio and merely traverse the same
    // shape faster). 1 = base ellipse, 2 = figure-eight, 3 = trefoil, and
    // non-integer values give open, slowly-precessing paths.
    var spiral2OrbitRatio: Float = 1.0      // 77
    // --- M7 PHASE 7.2: GEOMETRY ROUTING CHAIN (78–82) ---
    // Replaces the fixed 3-entry Pipeline Configuration picker (index 3,
    // reclaimed to a pad in M15) with an ordered chain of warp-module slots.
    // The shader walks slots 0...4 in order and applies whichever module each
    // slot names, so all 24 orderings of the four modules are reachable, plus
    // partial chains via Empty.
    //
    // MODULE ID ENCODING (identical in Shaders.metal):
    //   0 = Mirror 1      1 = Mirror 2
    //   2 = Rotation 1    3 = Rotation 2
    //   4 = Displacement  (M8 Phase A — NOT YET VALID, treated as Empty)
    //   5 = Empty         (no-op)
    //
    // Duplicates across slots are ALLOWED on purpose (a module listed twice
    // applies its warp twice in sequence — a legitimate look). Note the hole
    // cutter side effect: if a mirror occupies two slots its interference wave
    // (w1/w2) is overwritten by the later pass, so the hole signal reads the
    // LAST wave that mirror computed, not both. Defined, not a bug.
    //
    // DEFAULTS reproduce the old geometryRouting == 1.0 (Torsion➔Mirrors)
    // default exactly: Rot1, Rot2, M1, M2, Empty. Do not "tidy" these into
    // index order — that would silently change the shipped default look.
    // M13: slots are numbered SOURCE ➔ OUTPUT. Slot 0 is applied to the source
    // first (innermost); slot 4 is the outermost, most visible stage. The
    // fragment shader walks them 4 ➔ 0 — see the chain loop comment in
    // Shaders.metal. These defaults are the M13 reversal of the old 2,3,0,1,5
    // and produce a pixel-identical picture. The renderer overwrites all five
    // from LiveParams every frame, so these are documentation more than
    // behavior, but they are kept in sync deliberately.
    var chainSlot0: Float = 5.0             // 78 (module ID at chain position 0)
    var chainSlot1: Float = 1.0             // 79 (module ID at chain position 1)

    var chainSlot2: Float = 0.0             // 80 (module ID at chain position 2)
    var chainSlot3: Float = 3.0             // 81 (module ID at chain position 3)
    // Slot 4 is allocated now but hidden in the UI until M8 Phase A gives it
    // Displacement to hold. Pre-allocating costs one pad and spares M8 Phase B
    // a coordinated two-struct change during its riskiest phase.
    var chainSlot4: Float = 2.0             // 82 (outermost stage)
    // --- M8 PHASE A: DISPLACEMENT MESH (83–96) ---
    // An additive coordinate field: uv_out = uv_in + (dx, dy). Distinct from
    // the mirrors, which FOLD (every pixel either untouched or reflected, which
    // is what makes hard mirror seams). Displacement nudges every pixel
    // continuously — no seam, no symmetry: the liquid / heat-shimmer family.
    //
    // Two oscillators, cross-coupled: the X oscillator's wave runs down the
    // screen and the Y oscillator's runs across. That crossing is what makes it
    // read as liquid; same-axis coupling would only shear.
    var dispAmpX: Float = 0.0               // 83 (bipolar, -0.25...0.25)
    var dispFreqX: Float = 5.0              // 84

    var dispPhaseX: Float = 0.0             // 85 (renderer accumulator)
    var dispWaveTypeX: Float = 0.0          // 86 (0=Sine,1=Tri,2=Saw,3=S&H,4=Square)
    var dispLagX: Float = 0.0               // 87 (S&H slew)
    var lumaModDispX: Float = 0.0           // 88 (bipolar, -0.30...0.30)

    var dispAmpY: Float = 0.0               // 89 (bipolar, -0.25...0.25)
    var dispFreqY: Float = 5.0              // 90
    var dispPhaseY: Float = 0.0             // 91 (renderer accumulator)
    var dispWaveTypeY: Float = 0.0          // 92

    var dispLagY: Float = 0.0               // 93
    var lumaModDispY: Float = 0.0           // 94 (bipolar, -0.30...0.30)
    var dispRadialMode: Float = 0.0         // 95 (0=Normal wave arg, 1=Radial wave arg)
    // Continuous blend of the displacement DIRECTION, resolving the plan's Q1
    // without picking a side. At 0 the nudge is axis-aligned (X pushes
    // horizontally, Y vertically). At 1 the same two oscillator outputs are
    // re-pointed into polar space: X pushes along the radius (out from / in to
    // center) and Y pushes tangentially (swirl around it), so both amplitudes
    // keep an independent meaning instead of one going dead. Follows the
    // continuous-depth-over-mode-switch convention set by Dynamic Orbit.
    var dispRadialPush: Float = 0.0         // 96 (0=XY direction, 1=radial/tangential)
    // --- M8 PHASE C.3: DISPLACEMENT INTO THE HOLE CUTTER — RETIRED, M12 ---
    // Built in M8, reduced to Threshold-only in M12 Part 4, had its toggle
    // folded into the threshold in Part 7D, and removed outright right after:
    // the user's call, on the grounds that Keyer 3's Displacement feed already
    // keys off displacement and a second, narrower displacement signal wasn't
    // earning its slider. Its three slots and the M8 Phase C.4 rotation-hole
    // slots right after it (both retired the same way, same session) are
    // consumed together below.
    // --- M16 PART 2: ROTATION + DISPLACEMENT CENTER (97–102) ---
    // Every warp module gets a place to stand: M14 Part 1 gave the mirrors
    // one (110–113 below); these six do the same for Displacement and both
    // Rotation modules. Taken as ONE contiguous run rather than at the tail
    // (120+) so the two remaining free stretches — 103–109 (seven) and
    // 120–127 (eight) — both stay intact instead of the tail being drained
    // down to two while a seven-slot hole sits unused in the middle.
    //
    // Displacement (97–98): applyDisplacement was implicitly anchored at the
    // frame's origin in TWO places — length(uv) for the radial-mode wave
    // arguments, and uv/r for the push-direction basis. dispCenterX/Y move
    // both together. The center enters the wave argument, not just the
    // radial basis, matching applySingleMirror: a center move drags the
    // pattern with it rather than sliding the fold across a fixed field.
    var dispCenterX: Float = 0.0             // 97 (bipolar, -1...1)
    var dispCenterY: Float = 0.0             // 98 (bipolar, -1...1)
    //
    // Rotation (99–102): applyTorsion and applySpiral2 already build an
    // orbit CENTER when Dynamic Orbit is on. These SEED that same variable
    // BEFORE the orbit gate (`center = seed`, then the orbit block changes
    // from `center =` to `center +=`) rather than living inside it, so a
    // hand-set or LFO-driven center has an effect with Dynamic Orbit off —
    // the common case — and the two sum correctly when both are on, instead
    // of the center silently vanishing whenever the orbit is what's active.
    // Rotation 2 gets its OWN pair rather than sharing Rotation 1's,
    // matching the axis-transposed independence its orbit formula already
    // has from Rotation 1's.
    var torsionCenterX: Float = 0.0          // 99  (bipolar, -1...1)
    var torsionCenterY: Float = 0.0          // 100 (bipolar, -1...1)
    var spiral2CenterX: Float = 0.0          // 101 (bipolar, -1...1)
    var spiral2CenterY: Float = 0.0          // 102 (bipolar, -1...1)
    // --- RECLAIMED, M15 (103–109) — were M8 C.5's LFO destination mirrors ---
    var pad103: Float = 0.0                  // 103 (RECLAIMED, M15)
    var pad104: Float = 0.0                  // 104 (RECLAIMED, M15)
    var pad105: Float = 0.0                  // 105 (RECLAIMED, M15)

    var pad106: Float = 0.0                  // 106 (RECLAIMED, M15)
    var pad107: Float = 0.0                  // 107 (RECLAIMED, M15)
    var pad108: Float = 0.0                  // 108 (RECLAIMED, M15)

    var pad109: Float = 0.0                  // 109 (RECLAIMED, M15)
    // --- M14 PART 1: MIRROR POSITION (110–113) ---
    // Until M14 a mirror had every control EXCEPT a place to stand: the seam
    // always passed through screen center and the angle always pivoted around
    // it. These four give each mirror its own center. applySingleMirror
    // translates in, folds, translates out, so at 0 the arithmetic is `uv - 0`
    // and `+ 0` — bit-for-bit identity, not approximately.
    //
    // The radial-anchoring fix falls out of the same change for free: the wave
    // argument is computed on the already-centered coordinate, so in Radial
    // mode the rings now ring the MIRROR center instead of screen center.
    //
    // Bipolar, no floor, ±1. `uv` is (in.uv - 0.5) * scale, so the visible
    // frame spans roughly ±0.5 at scale 1; ±1 therefore covers the frame with
    // room to push the seam fully off-frame, which is a useful state (part of
    // the image stops being folded at all) rather than wasted travel.
    // Centers are INDEPENDENT per mirror on purpose — two seams pivoting about
    // different points is a geometry that is not reachable any other way.
    var mirror1CenterX: Float = 0.0          // 110 (bipolar, -1...1)
    var mirror1CenterY: Float = 0.0          // 111 (bipolar, -1...1)

    var mirror2CenterX: Float = 0.0          // 112 (bipolar, -1...1)
    var mirror2CenterY: Float = 0.0          // 113 (bipolar, -1...1)
    // --- M14 PART 2: LUMA SOURCE STAGING (114) ---
    // Every geometry module's luma modulator (lumaMod1/2, lumaTorsion,
    // lumaModDispX/Y) has always read `rawLuma` — the luma of the UNWARPED
    // source — so a module late in the chain modulated off the source video
    // rather than off what the chain had already built.
    //
    // At depth 1 each module instead reads the source at the coordinate the
    // chain has warped to SO FAR. Because this is a single-sample coordinate
    // pipeline, that is not an approximation of the previous stage's output:
    // sampling the source at W_k(...W_1(uv)) returns exactly the
    // composite-so-far's value at this fragment. In between, the two blend.
    //
    // ONE GLOBAL CONTROL, not one per module — five staging sliders would be
    // five more controls in an instrument that is about to have controls
    // removed. Continuous rather than a mode switch, per the standing
    // convention: the middle is musically real.
    //
    // At 0 the shader takes no extra sample at all, so the output is
    // bit-identical to pre-M14 and the cost is exactly zero.
    var lumaStageDepth: Float = 0.0          // 114 (0 = source luma, 1 = chain-so-far luma)
    // 115–116 were briefly M12 Part 5's vignette-as-key-source pair
    // (vignetteInHoles + vignetteMatteOutput). Built, tested on hardware, and
    // removed: the vignette makes a clean output shape and a dull key, and the
    // Matte Output split only existed to serve the key. Reclaimed rather than
    // kept "in case" — an unused field is a claim about the future that the
    // roadmap does not support.
    //
    // M12 Part 7C consumed 115–119 from this pool for the three-keyer
    // restructure: Keyer 3's offset, Keyer 2's XOR (Keyer 3's XOR landed on
    // the reclaimed slot at 39 instead), and the three per-keyer feed toggles
    // (0=module family, 1=Warped Final).
    var keyerOffset3: Float = 0.0            // 115 (Keyer 3, bipolar offset from Keyer 1)
    var keyerXOR2: Float = 0.0               // 116 (Keyer 2 XOR intersection)

    var keyerFeed1: Float = 0.0              // 117 (Keyer 1: 0=Mirrors, 1=Warped Final)
    var keyerFeed2: Float = 0.0              // 118 (Keyer 2: 0=Rotation, 1=Warped Final)
    var keyerFeed3: Float = 0.0              // 119 (Keyer 3: 0=Displacement, 1=Warped Final)

    // M4.4 Part B: write the vignette's own coverage into the ALPHA channel,
    // so a ProRes 4444 take carries the matte as a real alpha channel instead
    // of only as black outside the shape. 0 = off (alpha stays 1.0
    // everywhere, bit-identical to every frame before M4.4), 1 = on.
    //
    // This is PREMULTIPLIED alpha on purpose: the vignette block already does
    // `color.rgb *= cov` before this writes `color.a = cov`, so stored rgb is
    // image x alpha, which is the definition. Chosen because it needs no
    // second code path anywhere — preview, present pass, and the PNG writer's
    // default path are all untouched — and because at Edge Softness 0 the
    // premultiplied and straight results are bit-identical anyway. See the
    // M4.4 plan for the straight-alpha alternative and what it would cost.
    //
    // PAD PLACEMENT (M16's amended convention: largest contiguous free run
    // that keeps the pool from fragmenting): this is a single isolated field,
    // not a group, so it takes the FIRST slot of the tail run rather than
    // breaking into the mid-struct 103-109 run. That leaves 103-109 (7) fully
    // intact for a future contiguous group — M6's coupling matrix being the
    // most likely consumer — and 121-127 (7) still contiguous behind it.
    var vignetteAlpha: Float = 0.0           // 120 (0 = opaque, 1 = matte to alpha)
    // --- M26: MIRROR DOUBLE FOLD (121–124) ---
    // A second fold per mirror module, from that module's own controls, at an
    // angle offset from its base angle. See applyMirrorModule in Shaders.metal.
    //
    // The partner is a FLAT reflection line through the module center — no
    // oscillator of its own. See applyFlatFold in Shaders.metal for why: a
    // second fold about a line offset from the center composes to a
    // TRANSLATION, not a mirror, and with the module's ripple driving that
    // offset the sample coordinate left the frame entirely (black on camera,
    // still-patterned on the procedural source, which is defined everywhere).
    //
    // The flag and the offset are both needed. The default offset is pi, so
    // with one control "off" would mean dragging to an end stop while
    // "opposed" would mean dragging back to the middle — not a live gesture.
    // The flag also PRESERVES the offset while disabled: a patch parked at 2.4
    // comes back at 2.4. Same toggle-plus-revealed-slider shape Spin uses.
    //
    // PAD PLACEMENT: four contiguous slots taken from the FRONT of the tail
    // run 121-127, leaving 103-109 (7) fully intact. Taking them from
    // mid-struct instead would have left runs of 3 and 5 where this leaves
    // 7 and 3 — a smaller largest-future-group, which is the thing the rule
    // is protecting.
    var mirror1DoubleOn: Float = 0.0         // 121 (0 = single fold, 1 = doubled)
    var mirror1DoubleOffset: Float = .pi     // 122 (radians, 0...2pi; pi = opposed)
    var mirror2DoubleOn: Float = 0.0         // 123
    var mirror2DoubleOffset: Float = .pi     // 124

    var pad125: Float = 0.0                  // 125
    var pad126: Float = 0.0                  // 126
    var pad127: Float = 0.0                  // 127
}











