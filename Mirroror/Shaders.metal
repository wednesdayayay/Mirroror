#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// --- M7 PHASE 7.2: ROUTING CHAIN CONSTANTS ---
// Module IDs stored in chainSlot0...chainSlot4 (indices 78–82). These must stay
// in sync with the ChainModule enum in ContentView.swift.
#define CHAIN_SLOT_COUNT            5
#define CHAIN_MODULE_MIRROR1        0
#define CHAIN_MODULE_MIRROR2        1
#define CHAIN_MODULE_ROTATION1      2
#define CHAIN_MODULE_ROTATION2      3
#define CHAIN_MODULE_DISPLACEMENT   4
#define CHAIN_MODULE_EMPTY          5

// M8 Phase C.3: displacement magnitude normalizer — one axis at full amplitude
// (0.25) plus full luma modulation (0.30). Both axes at maximum saturate into
// the top of the range, which is the intended behavior.
#define DISP_MAGNITUDE_REF          0.55

// 128-Float Packed Uniform Struct matching Swift layout (512 bytes)
struct ShaderParams {
    float torsionStrength;          // 0 (bipolar amplitude, -3...3)
    float torsionFrequency;         // 1
    float lumaTorsion;              // 2
    float pad3;                     // 3 (RECLAIMED, M15 — was torsionFirst)

    float mirror1On;                // 4
    float mirror1Angle;             // 5
    float mirror1RippleAmp;         // 6
    float mirror1RippleFreq;        // 7

    float mirror1Phase;             // 8
    float mirror1WaveType;          // 9 (0=Sine, 1=Triangle, 2=Saw, 3=S&H, 4=Square)
    float mirror2On;                // 10
    float mirror2Angle;             // 11

    float mirror2RippleAmp;         // 12
    float mirror2RippleFreq;        // 13
    float mirror2Phase;             // 14
    float mirror2WaveType;          // 15 (0=Sine, 1=Triangle, 2=Saw, 3=S&H, 4=Square)

    float lumaMod1;                 // 16
    float lumaMod2;                 // 17
    float pad18;                    // 18 (RECLAIMED, M15 — was colorSeparation)
    float scale;                    // 19

    float edgeBehavior;             // 20 (0=Black, 1=Bleed, 2=Tile, 3=Reflect, 4=Math BG)
    float pad21;                    // 21 (RECLAIMED, M12 — was holeCutterPost)
    float negativeSpace;            // 22 (depth)
    float negativeSpaceThreshold;   // 23

    float rectification;            // 24 (wave solarization fold)
    float torsionInHoles;           // 25 (rotation-wave mix into holes)
    float keyerThreshold1;          // 26 (Keyer 1, absolute — was lumaKeyThreshold)
    float keyerXOR1;                // 27 (Keyer 1 XOR intersection — was lumaKeyInvert)

    float pad28;                    // 28 (RECLAIMED, M15 — was torsionCenterMode)
    float sourceType;               // 29 (0=Procedural, 1=Camera, 2=Video)
    float pad30;                    // 30 (RECLAIMED, M12 Part 7C — was keyerTarget)
    float time;                     // 31

    // --- EXTENDED PARAMETERS (32–42) ---
    float mirror1Lag;               // 32 (S&H Lag coefficient)
    float mirror2Lag;               // 33 (S&H Lag coefficient)
    float pad34;                    // 34 (RECLAIMED, M12 — was videoInvertMix)
    float keyerOffset2;             // 35 (Keyer 2, bipolar offset from Keyer 1 — was lumaKeyThreshold2)
    float pad36;                    // 36 (RECLAIMED, M12 Part 7C — was keyerTarget2)
    float keyerPolarity;            // 37 (global: 0=Brights, 1=Darks — was lumaKey1Polarity)
    float pad38;                    // 38 (RECLAIMED, M12 Part 7C — was lumaKey2Polarity)
    float keyerXOR3;                // 39 (Keyer 3 XOR intersection — was lumaKeyInvert2)

    float pad40;                    // 40 (RECLAIMED, M12 — was keyerPosterize)
    float invertEntireHoleKey;      // 41 (1=Invert composite mask)
    float preCrop;                  // 42 (pixels to crop off raw input edges; 0=off)

    // --- RECLAIMED, M15 (43, 44, 64, 105–109) — the "parity-only" slots ---
    // Eight fields the shader never read. Parity is POSITIONAL: padNN at the
    // same index preserves the layout exactly as well as a named field, so
    // the names bought documentation only while implying a GPU-side read that
    // never existed. Their LiveParams equivalents are all still live.
    // --- M0.5 PARAMETERS (45–47; 43–44 reclaimed) ---
    float pad43;                    // 43 (RECLAIMED, M15 — was lfoWaveType)
    float pad44;                    // 44 (RECLAIMED, M15 — was lfoLag)
    float mirror1RadialMode;        // 45
    float mirror2RadialMode;        // 46
    float torsionRadialMode;        // 47 (default 1 = Radial)

    // --- M1b / orbit-depth PARAMETERS (48–50) ---
    float torsionWaveType;          // 48 (shared by rotation warp + hole mix)
    float torsionLag;               // 49
    float torsionOrbitDepth;        // 50 (0=static center, 1=full orbit)

    // --- KEY SOFTNESS PARAMETERS (51–53) ---
    // M12: ONE softness for every threshold in the keying section. Was five
    // separate sliders (wave hole, Luma Key 1, Luma Key 2, displacement hole,
    // rotation hole); index 51 keeps the name-slot and the other four are
    // reclaimed. Range narrowed to 0...0.35 in the UI, since one control now
    // drives everything and 0...0.5 put all the useful travel at the bottom.
    float keySoftness;              // 51 (feather half-width, ALL key thresholds)
    float pad52;                    // 52 (RECLAIMED, M12 — was lumaKey1Soft)
    float pad53;                    // 53 (RECLAIMED, M12 — was lumaKey2Soft)

    // --- M1a OUTPUT MIX (54) ---
    float outputMix;                // 54 (0=dry raw source, 1=full effected; final blend)

    // --- RECLAIMED, M15 (55–57) — were the three RGB fringe separations ---
    float pad55;                    // 55 (RECLAIMED, M15)
    float pad56;                    // 56 (RECLAIMED, M15)
    float pad57;                    // 57 (RECLAIMED, M15)

    // --- M2 OUTPUT VIGNETTE (58–63) — last of the original 64-float pads ---
    float vignetteShape;            // 58 (0=Off, 1=Circle, 2=Rect)
    float vignetteCenterX;          // 59 (bipolar, -0.5...0.5 around center)
    float vignetteCenterY;          // 60 (bipolar, -0.5...0.5 around center)
    float vignetteSize;             // 61 (0.05...1.0)
    float vignetteAspect;           // 62 (bipolar; -X wide, +Y tall, 0 = uniform)
    float vignetteSoftness;         // 63 (0 = hard edge; smoothstep feather above)

    // --- RECLAIMED, M12 (64–68) — was M5 OUTPUT GLOW ---
    // M5 shipped, was confirmed working, and was then removed whole in M12:
    // an end-of-chain halo is an output-stage effect, and this instrument is
    // about geometry and the movement of the frame. The two blur passes and
    // the composite pass went with it, along with ~22 MB of render targets.
    // The M3 two-pass structure stays. The `finalTexture` local went with
    // the glow — see the rule stated at LiquidRenderer's capture blit.
    float pad64;                    // 64 (RECLAIMED, M15 — was glowOn)
    float pad65;                    // 65 (RECLAIMED, M12 — was glowRadius)
    float pad66;                    // 66 (RECLAIMED, M12 — was glowGain)
    float pad67;                    // 67 (RECLAIMED, M12 — was glowMode)
    float pad68;                    // 68 (RECLAIMED, M12 — was glowBlurDir)

    // --- M7 PHASE 7.1: DUAL SPIRAL ENGINE (69–75) ---
    // Spiral 2: a second torsion/spiral module nested inside Spiral 1 — warps
    // Spiral 1's already-warped output, so its orbit center and twist ring
    // live in Spiral 1's output space (the planetary-epicycle look). At
    // spiral2Strength == 0 its warp is the identity: pixel-identical to
    // pre-M7.
    float spiral2Strength;          // 69 (bipolar VCO amplitude, -3...3)
    float spiral2FreqOffset;        // 70 (bipolar offset added to torsionFrequency; -15...15)
    float spiral2WaveType;          // 71 (0=Sine,1=Tri,2=Saw,3=S&H,4=Square)

    float spiral2Lag;               // 72 (S&H slew, mirrors torsionLag)
    float spiral2OrbitDepth;        // 73 (0=static center, 1=full orbit; same Lissajous pattern as torsionOrbitDepth)
    float spiral2RadialMode;        // 74 (0=Normal, 1=Radial; independent of torsionRadialMode)
    // Combine mode for Spiral 1's + Spiral 2's twist waves feeding the hole
    // cutter's Rotation Wave Mix (torsionInHoles). REPLACES the old
    // single-spiral signal; torsionInHoles itself (the injection amount)
    // is unchanged. At spiral2Strength == 0 all three modes reduce to
    // "Spiral 1's wave alone."
    float spiralCombineMode;        // 75 (0=Additive, 1=Subtractive, 2=XOR, 3=Multiply)

    // --- M0b FREE PAD SLOTS (76–127) ---
    // Grew 64 -> 128 floats (256 -> 512 bytes) in M0b. Indices 0–63 above are
    // frozen byte-for-byte. Nothing in this shader reads a pad. To consume one,
    // rename padNN here AND at the same index in ShaderParams.swift.
    // --- M7 PHASE 7.1a: ROTATION 2 ORBIT DECORRELATION (76–77) ---
    // Rotation 2's orbit reused Rotation 1's Lissajous verbatim, leaving the
    // two centers collinear with the origin (scalar multiples of each other).
    // Fixed by transposing Rotation 2's axes plus these two controls.
    float spiral2OrbitPhase;        // 76 (0...1 -> 0...2π offset; walks R2 around its orbit vs R1)
    float spiral2OrbitRatio;        // 77 (Lissajous ratio, X axis ONLY; 1=ellipse, 2=figure-eight, 3=trefoil)
    // --- M7 PHASE 7.2: GEOMETRY ROUTING CHAIN (78–82) ---
    // Replaces the fixed 3-way routing branch that used to be driven by index 3
    // (reclaimed to a pad in M15). fragmentShader walks these five slots in
    // order and applies whichever warp module each names.
    //
    // MODULE ID ENCODING (identical in ShaderParams.swift):
    //   0 = Mirror 1      1 = Mirror 2
    //   2 = Rotation 1    3 = Rotation 2
    //   4 = Displacement  (M8 Phase A — NOT YET VALID, falls through as Empty)
    //   5 = Empty         (no-op)
    //
    // Duplicates are allowed by design. Hole-cutter side effect of a duplicated
    // mirror: w1/w2 hold the LAST wave that mirror computed, so the four-case
    // interference below reads that one. Defined behavior, not a bug.
    float chainSlot0;               // 78 (module ID at chain position 0)
    float chainSlot1;               // 79 (module ID at chain position 1)

    float chainSlot2;               // 80 (module ID at chain position 2)
    float chainSlot3;               // 81 (module ID at chain position 3)
    float chainSlot4;               // 82 (reserved for M8 Displacement; Empty until then)
    // --- M8 PHASE A: DISPLACEMENT MESH (83–96) ---
    // Additive coordinate field, uv_out = uv_in + (dx, dy). See applyDisplacement.
    float dispAmpX;                 // 83 (bipolar, -0.25...0.25)
    float dispFreqX;                // 84

    float dispPhaseX;               // 85 (renderer accumulator)
    float dispWaveTypeX;            // 86 (0=Sine,1=Tri,2=Saw,3=S&H,4=Square)
    float dispLagX;                 // 87 (S&H slew)
    float lumaModDispX;             // 88 (bipolar, -0.30...0.30)

    float dispAmpY;                 // 89 (bipolar, -0.25...0.25)
    float dispFreqY;                // 90
    float dispPhaseY;               // 91 (renderer accumulator)
    float dispWaveTypeY;            // 92

    float dispLagY;                 // 93
    float lumaModDispY;             // 94 (bipolar, -0.30...0.30)
    float dispRadialMode;           // 95 (0=Normal wave arg, 1=Radial wave arg)
    float dispRadialPush;           // 96 (0=XY direction, 1=radial/tangential direction)
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
    float dispCenterX;               // 97 (bipolar, -1...1)
    float dispCenterY;               // 98 (bipolar, -1...1)
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
    float torsionCenterX;            // 99  (bipolar, -1...1)
    float torsionCenterY;            // 100 (bipolar, -1...1)
    float spiral2CenterX;            // 101 (bipolar, -1...1)
    float spiral2CenterY;            // 102 (bipolar, -1...1)
    // --- RECLAIMED, M15 (103–109) — were M8 C.5's LFO destination mirrors ---
    float pad103;                   // 103 (RECLAIMED, M15)
    float pad104;                   // 104 (RECLAIMED, M15)
    float pad105;                   // 105 (RECLAIMED, M15)

    float pad106;                   // 106 (RECLAIMED, M15)
    float pad107;                   // 107 (RECLAIMED, M15)
    float pad108;                   // 108 (RECLAIMED, M15)

    float pad109;                   // 109 (RECLAIMED, M15)
    // --- M14 PART 1: MIRROR POSITION (110–113) ---
    // Per-mirror fold center. applySingleMirror translates in, folds,
    // translates out; at 0 that is `uv - 0` / `+ 0`, a bit-for-bit identity.
    // The wave argument is built on the centered coordinate, so Radial mode
    // now rings the MIRROR center rather than screen center — that anchoring
    // fix is a free consequence of the same translate, not separate code.
    float mirror1CenterX;            // 110 (bipolar, -1...1)
    float mirror1CenterY;            // 111 (bipolar, -1...1)

    float mirror2CenterX;            // 112 (bipolar, -1...1)
    float mirror2CenterY;            // 113 (bipolar, -1...1)
    // --- M14 PART 2: LUMA SOURCE STAGING (114) ---
    // 0 = every module's luma modulator reads the unwarped source (the
    // behavior since the beginning). 1 = each module reads the source at the
    // coordinate the chain has warped to so far, which in a single-sample
    // coordinate pipeline IS the composite-so-far at this fragment. Read by
    // the chain loop only; at 0 no extra sample is taken.
    float lumaStageDepth;            // 114
    // 115–116 were briefly M12 Part 5's vignette-as-key-source pair. Built,
    // tested on hardware, and removed: the vignette makes a clean shape and a
    // dull key. Reclaimed rather than kept "in case."
    //
    // M12 Part 7C consumed 115–119 from this pool for the three-keyer
    // restructure: Keyer 3's offset, Keyer 2's XOR (Keyer 3's XOR landed on
    // the reclaimed slot at 39 instead), and the three per-keyer feed toggles
    // (0=module family, 1=Warped Final).
    float keyerOffset3;              // 115 (Keyer 3, bipolar offset from Keyer 1)
    float keyerXOR2;                 // 116 (Keyer 2 XOR intersection)

    float keyerFeed1;                // 117 (Keyer 1: 0=Mirrors, 1=Warped Final)
    float keyerFeed2;                // 118 (Keyer 2: 0=Rotation, 1=Warped Final)
    float keyerFeed3;                // 119 (Keyer 3: 0=Displacement, 1=Warped Final)

    // M4.4 Part B: vignette coverage -> alpha channel. 0 = off (alpha stays
    // 1.0, bit-identical to pre-M4.4), 1 = on. Premultiplied, because the
    // vignette block multiplies rgb by the same coverage immediately before
    // writing it. See the matching comment in ShaderParams.swift.
    float vignetteAlpha;             // 120 (0 = opaque, 1 = matte to alpha)
    // --- M26: MIRROR DOUBLE FOLD (121–124) ---
    // A second fold per mirror module, from that module's own controls, at an
    // angle offset from its base angle. See applyMirrorModule below.
    //
    // The partner is a FLAT reflection line through the module center — no
    // oscillator of its own. See applyFlatFold for why. The flag and the
    // offset are both needed: the default offset is pi, so with one control
    // "off" would mean dragging to an end stop while "opposed" would mean
    // dragging back to the middle. The flag preserves the offset while off.
    //
    // PAD PLACEMENT: four contiguous slots from the FRONT of the tail run
    // 121-127, leaving 103-109 (7) fully intact.
    float mirror1DoubleOn;           // 121 (0 = single fold, 1 = doubled)
    float mirror1DoubleOffset;       // 122 (radians, 0...2pi; pi = opposed)
    float mirror2DoubleOn;           // 123
    float mirror2DoubleOffset;       // 124

    float pad125;                    // 125
    float pad126;                    // 126
    float pad127;                    // 127
};

// Compile-time guarantee that this struct is still exactly 128 floats / 512
// bytes, i.e. byte-identical in layout to ShaderParams.swift. If a field is
// ever added without consuming a pad, the shader fails to BUILD instead of
// silently shifting every uniform after it by one slot.
static_assert(sizeof(ShaderParams) == 512, "ShaderParams must stay 128 floats / 512 bytes (mirror of ShaderParams.swift)");

vertex VertexOut vertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    out.uv = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(out.uv * 2.0 - 1.0, 0.0, 1.0);
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

// Procedural Gradient Synth pattern (shared by source + background)
float3 gradientSynthPattern(float2 uv_warped, float time) {
    return float3(
        sin(uv_warped.x * 6.0 + time) * 0.5 + 0.5,
        cos(uv_warped.y * 6.0 - time * 0.8) * 0.5 + 0.5,
        sin((uv_warped.x + uv_warped.y) * 3.0 + time * 1.2) * 0.5 + 0.5
    );
}

// Custom GPU coordinate wrap + optional edge pre-crop.
float4 sampleTexture(texture2d<float, access::sample> tex, float2 uv_warped, constant ShaderParams& params) {
    float2 uv = uv_warped + 0.5;
    sampler s(address::clamp_to_edge, filter::linear);

    float2 cropMin = float2(0.0);
    float2 cropMax = float2(1.0);
    if (params.preCrop > 0.5) {
        float2 texSize = float2(max(tex.get_width(), 1u), max(tex.get_height(), 1u));
        float2 c = params.preCrop / texSize;
        cropMin = c;
        cropMax = 1.0 - c;
    }

    float edgeBehavior = params.edgeBehavior;

    if (edgeBehavior < 0.5) { // Black Borders
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }
        return tex.sample(s, mix(cropMin, cropMax, uv));
    } else if (edgeBehavior < 1.5) { // Bleed / Clamp
        return tex.sample(s, mix(cropMin, cropMax, clamp(uv, 0.0, 1.0)));
    } else if (edgeBehavior < 2.5) { // Tile
        return tex.sample(s, mix(cropMin, cropMax, fract(uv)));
    } else if (edgeBehavior < 3.5) { // Reflect Tiling
        float2 m = abs(fract(uv * 0.5 + 0.5) * 2.0 - 1.0);
        return tex.sample(s, mix(cropMin, cropMax, m));
    } else { // Gradient Synth BG
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
            return float4(gradientSynthPattern(uv_warped, params.time), 1.0);
        }
        return tex.sample(s, mix(cropMin, cropMax, uv));
    }
}

// Evaluates procedural synthesis engine or standard texture inputs
float4 sampleSource(texture2d<float, access::sample> tex, float2 uv_warped, constant ShaderParams& params) {
    if (params.sourceType < 0.5) {
        return float4(gradientSynthPattern(uv_warped, params.time), 1.0);
    }
    return sampleTexture(tex, uv_warped, params);
}

// M15: the chromatic-aberration sampler lived here — it fetched R, G and B at
// three separately-shifted coordinates to make the RGB fringe. Removed with the
// rest of that module. Its two call sites now call sampleSource directly, which
// is exactly what the fringe sampler itself returned whenever the separation
// amounts were zero, so removing it is bit-identical at the fringe's defaults.
//
// Nothing in the chain treats R, G and B differently any more. If a colour
// module is ever wanted it should be designed as one, not rebuilt in this shape.

// Pseudo-random hash generator for Sample & Hold Waveforms
float hash(float x) {
    return fract(sin(x * 12.9898) * 43758.5453) * 2.0 - 1.0;
}

// Sample & Hold Random Waveform with GPU-side Lag/Slew processor
float getSNH(float x, float lag) {
    float i = floor(x);
    float f = fract(x);
    float v0 = hash(i - 1.0);
    float v1 = hash(i);
    if (lag < 0.01) {
        return v1;
    }
    if (f < lag) {
        float t = smoothstep(0.0, 1.0, f / lag);
        return mix(v0, v1, t);
    }
    return v1;
}

// Modular Waveform Evaluation Engine
float evaluateWaveform(float x, float type, float lag) {
    if (type < 0.5) {
        return sin(x);
    } else if (type < 1.5) {
        float t = fract(x / (2.0 * 3.14159265));
        return abs(t * 2.0 - 1.0) * 2.0 - 1.0;
    } else if (type < 2.5) {
        float t = fract(x / (2.0 * 3.14159265));
        return t * 2.0 - 1.0;
    } else if (type < 3.5) {
        return getSNH(x, lag);
    } else {
        float t = fract(x / (2.0 * 3.14159265));
        return (t < 0.5) ? 1.0 : -1.0;
    }
}

// ---- Soft key coverage helpers (key softness feature) ----
// A "key" is a threshold comparison. Hard version: signal > thr -> 1 else 0.
// Soft version: a smoothstep feather of half-width `soft` centered on `thr`,
// returning a continuous 0..1 coverage. When soft <= 0 this collapses to the
// exact hard step, so all-zero softness is bit-identical to the old booleans.
// `polarity` flips the direction (key dark instead of bright).
float softKeyAbove(float signal, float thr, float soft) {
    if (soft <= 0.0001) {
        return (signal > thr) ? 1.0 : 0.0;
    }
    return smoothstep(thr - soft, thr + soft, signal);
}
float softKeyBelow(float signal, float thr, float soft) {
    if (soft <= 0.0001) {
        return (signal < thr) ? 1.0 : 0.0;
    }
    return 1.0 - smoothstep(thr - soft, thr + soft, signal);
}
// Soft logic ops. At {0,1} inputs these equal boolean OR / XOR / NOT exactly.
float softOR(float a, float b)  { return max(a, b); }
float softXOR(float a, float b) { return abs(a - b); }
// M8 Phase C: soft AND completes the set. min is to AND what max is to OR —
// it collapses to a hard boolean when both inputs are already hard.
// M12: softAND removed with the AND hole modes — nothing called it.
float softNOT(float a)          { return 1.0 - a; }

// Shared oscillator-argument builder (Normal vs Radial).
float computeWaveArg(float2 uv, float2 center, float freq, float phase, float radialMode) {
    if (radialMode > 0.5) {
        float r = length(uv - center);
        return freq * r + phase;
    }
    return freq * uv.y + phase;
}

// Coordinate Torsion Block (a.k.a. Rotation). Center orbits along a Lissajous
// path scaled by torsionOrbitDepth (0 = static). Twist wave runs through the
// full oscillator menu.
float2 applyTorsion(float2 uv, constant ShaderParams& params, float luma) {
    // M16 Part 2: seeded BEFORE the orbit gate, not inside it — the orbit
    // block below now ADDS onto this rather than overwriting it, so a
    // hand-set or LFO-driven center still moves the twist origin with
    // Dynamic Orbit off (the common case), and the two sum correctly when
    // both are on. At torsionCenterX/Y == 0 this is float2(0.0), identical
    // to every frame before this change.
    float2 center = float2(params.torsionCenterX, params.torsionCenterY);
    if (params.torsionOrbitDepth > 0.001) {
        float orbitX = sin(params.mirror1Phase) * (0.3 + abs(params.mirror1RippleAmp) * 0.5);
        float orbitY = cos(params.mirror2Phase) * (0.3 + abs(params.mirror2RippleAmp) * 0.5);
        center += params.torsionOrbitDepth * float2(orbitX, orbitY);
    }
    float2 d_uv = uv - center;
    float r = length(d_uv);
    if (r < 0.001) return uv;
    float phi = atan2(d_uv.y, d_uv.x);

    float twistArg;
    if (params.torsionRadialMode > 0.5) {
        twistArg = params.torsionFrequency * r - params.time * 0.2;
    } else {
        twistArg = params.torsionFrequency * uv.y - params.time * 0.2;
    }
    float twistWave = evaluateWaveform(twistArg, params.torsionWaveType, params.torsionLag);

    // M12 PART 1.3 — AC-COUPLED, to match the mirror seam fix below.
    //
    // Was: luma * lumaTorsion * 10.0, with luma in 0...1. That term was
    // unipolar, so it could only ever ADD twist, and it carried a large DC
    // offset: at lumaTorsion's maximum a mid-grey frame sat permanently 1.5
    // radians away from wherever Torsion Strength was set. The strength slider
    // effectively lost its zero.
    //
    // Now: (luma - 0.5) centres the modulator on mid-grey, so bright pixels
    // twist one way and dark pixels the other, and the twist wobbles AROUND
    // Torsion Strength instead of dragging it. The 20.0 (was 10.0) keeps the
    // total authority identical: (±0.5) * 0.30 * 20.0 = ±3.0 radians, exactly
    // what (1.0) * 0.30 * 10.0 gave before. Only the polarity and the centring
    // changed, not the reach.
    //
    // Identity gate: at lumaTorsion == 0 both expressions are exactly 0.0.
    float dynamicStrength = params.torsionStrength + ((luma - 0.5) * params.lumaTorsion * 20.0);
    float phi_distorted = phi + dynamicStrength * twistWave;

    return center + float2(r * cos(phi_distorted), r * sin(phi_distorted));
}

// M7 Phase 7.1: Spiral 2 — a second torsion/spiral nested inside Spiral 1.
// Takes Spiral 1's ALREADY-WARPED output as its own input uv, so its orbit
// center and twist ring are defined in Spiral 1's output space — that's what
// makes this read as "riding on top of" Spiral 1 rather than a second
// independent twist (the planetary-epicycle look: a fast spiral revolving
// within a slower one). Structurally mirrors applyTorsion but with its own
// full parameter set (strength/frequency-offset/wave-type/lag/orbit-depth/
// radial-mode), all independent of Spiral 1's. At spiral2Strength == 0 this
// is the identity transform.
float2 applySpiral2(float2 uv, constant ShaderParams& params, float luma) {
    // M16 Part 2: same restructure as applyTorsion above, with its own pair
    // of fields — Rotation 2 gets an independent center, matching the
    // axis-transposed independence its orbit formula already has from
    // Rotation 1's.
    float2 center = float2(params.spiral2CenterX, params.spiral2CenterY);
    if (params.spiral2OrbitDepth > 0.001) {
        // Rotation 2's orbit is deliberately NOT Rotation 1's formula:
        //  1. Axes are transposed — X now derives from mirror 2's phase and
        //     Y from mirror 1's (Rotation 1 does the opposite). Without this
        //     the two centers are scalar multiples of each other and stay
        //     collinear with the origin no matter how the depths are set.
        //  2. spiral2OrbitPhase offsets both terms, sliding Rotation 2 around
        //     its orbit relative to Rotation 1 (0 = in step, 0.5 = opposite).
        //  3. spiral2OrbitRatio multiplies the X term ONLY. Lissajous shape
        //     comes from the X:Y frequency ratio, so scaling both axes would
        //     just trace the same figure faster; scaling one changes the
        //     figure itself (1 = ellipse, 2 = figure-eight, 3 = trefoil).
        float th = params.spiral2OrbitPhase * 6.28318530718;
        float orbitX = cos(params.mirror2Phase * params.spiral2OrbitRatio + th)
                       * (0.3 + abs(params.mirror2RippleAmp) * 0.5);
        float orbitY = sin(params.mirror1Phase + th)
                       * (0.3 + abs(params.mirror1RippleAmp) * 0.5);
        center += params.spiral2OrbitDepth * float2(orbitX, orbitY);
    }
    float2 d_uv = uv - center;
    float r = length(d_uv);
    if (r < 0.001) return uv;
    float phi = atan2(d_uv.y, d_uv.x);

    // Frequency is Spiral 1's frequency PLUS an offset, not an absolute rate —
    // this is what lets Spiral 2 run faster or slower than its host spiral.
    float freq2 = params.torsionFrequency + params.spiral2FreqOffset;

    float twistArg;
    if (params.spiral2RadialMode > 0.5) {
        twistArg = freq2 * r - params.time * 0.2;
    } else {
        twistArg = freq2 * uv.y - params.time * 0.2;
    }
    float twistWave = evaluateWaveform(twistArg, params.spiral2WaveType, params.spiral2Lag);

    float phi_distorted = phi + params.spiral2Strength * twistWave;

    return center + float2(r * cos(phi_distorted), r * sin(phi_distorted));
}

// M8 Phase A: Displacement Mesh. An ADDITIVE coordinate field — every pixel gets
// a continuous nudge, uv_out = uv_in + (dx, dy). This is the structural opposite
// of a mirror, which folds: a mirror leaves a pixel either untouched or exactly
// reflected, and that binary is what produces hard mirror seams.
// Displacement has no seam and no symmetry, which is where the liquid /
// heat-shimmer / feedback-wobble look comes from.
//
// TWO OSCILLATORS, CROSS-COUPLED. The X oscillator's wave is evaluated along
// uv.y and the Y oscillator's along uv.x, so horizontal push varies as you move
// DOWN the screen and vertical push varies as you move ACROSS it. That crossing
// is the whole trick; driving each axis from its own coordinate would give a
// plain shear instead of a wobble.
//
// DIRECTION BLEND (dispRadialPush). At 0 the two oscillator outputs steer the
// cartesian axes. At 1 the SAME two outputs are re-pointed into polar space:
// the X oscillator pushes along the radius (breathing out from / in to the
// center) and the Y oscillator pushes tangentially (swirl). Both amplitudes stay
// independently meaningful in either regime, and the in-between positions are
// real, usable territory rather than a crossfade between two presets.
//
// Note the tangential push is NOT a rotation: applyTorsion rotates every pixel
// about a shared center by an angle, preserving radius exactly. This displaces
// each pixel by a fixed distance along its own tangent, which pulls pixels off
// their circles — closer to a swirl smear than a twist.
float2 applyDisplacement(float2 uv, constant ShaderParams& params, float luma,
                         thread float& magnitudeOut) {
    // M16 Part 2: dispCenterX/Y give this module a place to stand, matching
    // what M14 Part 1 gave the mirrors. At (0,0) c_uv == uv and every line
    // below is exactly what shipped before this change.
    //
    // The center enters the WAVE ARGUMENT here (c_uv.y / c_uv.x below), not
    // only the radial basis — same choice applySingleMirror already made, so
    // a center move drags the pattern along with it rather than sliding the
    // push across a field that stays fixed to the frame. One consequence
    // worth knowing: dispFreqX/Y reach 60, so at high frequency a small
    // center move is a large phase shift and reads as fast scrolling under
    // LFO drive. The mirrors have had this property since M14; it is what
    // makes their center modulation expressive, not a bug in this one.
    //
    // The ending stays `uv + ...`, NOT `center + ...` — applyDisplacement
    // builds an OFFSET FIELD, unlike applyTorsion/applySpiral2's polar
    // re-point. Adding the center back here would pan the whole frame by
    // that amount on every pixel; re-anchoring the field is exactly NOT
    // that, so the center only ever appears on the way IN.
    float2 c_uv = uv - float2(params.dispCenterX, params.dispCenterY);
    float r = length(c_uv);

    // Wave arguments. Normal mode is the cross-coupled cartesian case above;
    // radial mode drives BOTH oscillators from the radius, which collapses them
    // onto concentric rings — pond ripple rather than shimmer.
    float argX;
    float argY;
    if (params.dispRadialMode > 0.5) {
        argX = params.dispFreqX * r + params.dispPhaseX;
        argY = params.dispFreqY * r + params.dispPhaseY;
    } else {
        argX = params.dispFreqX * c_uv.y + params.dispPhaseX;
        argY = params.dispFreqY * c_uv.x + params.dispPhaseY;
    }

    // Luma modulation is additive per axis, exactly matching lumaMod1/lumaMod2
    // on the mirrors: brighter source pushes further.
    float dx = params.dispAmpX * evaluateWaveform(argX, params.dispWaveTypeX, params.dispLagX)
             + luma * params.lumaModDispX;
    float dy = params.dispAmpY * evaluateWaveform(argY, params.dispWaveTypeY, params.dispLagY)
             + luma * params.lumaModDispY;

    float2 cartesian = float2(dx, dy);

    // M8 Phase C.3: how hard this pixel is being pushed, regardless of
    // direction — bright at the wave peaks, dark at the zero crossings, so it
    // reads as a moving contour map of the field itself. Taken AFTER luma
    // modulation so it reflects what actually happened to the pixel, and
    // normalized by one axis at full amplitude plus full luma mod (0.25 + 0.30)
    // so a single axis sweeps the whole threshold range instead of leaving the
    // top third of the slider dead. The direction blend below cannot change
    // this length, so it is correct to measure here.
    magnitudeOut = clamp(length(cartesian) / DISP_MAGNITUDE_REF, 0.0, 1.0);

    // Skip the polar re-point at the exact CENTER (now dispCenterX/Y, not
    // necessarily the frame's), where the radial direction is undefined, and
    // whenever the blend is fully cartesian.
    if (params.dispRadialPush < 0.001 || r < 0.001) {
        return uv + cartesian;
    }

    float2 radialDir = c_uv / r;                                // unit vector pointing out from the CENTER
    float2 tangentDir = float2(-radialDir.y, radialDir.x);      // 90 degrees around it
    float2 polar = dx * radialDir + dy * tangentDir;

    return uv + mix(cartesian, polar, clamp(params.dispRadialPush, 0.0, 1.0));
}

// Single mirror-fold pass (shared by both mirrors, all routings, and the keyer
// feed matrix).
//
// M14 PART 1 — THE MIRROR NOW HAS A PLACE TO STAND.
// Everything below the translate is untouched; `center` wraps the existing
// body in a translate-in / translate-out. Three things fall out of that one
// change, and it is worth being explicit that they are one change and not
// three:
//
//  1. The SEAM moves. The fold happens at uv_m.x < seam in the rotated frame,
//     and that frame is now anchored at `center`, so the mirror line passes
//     through the center instead of always through screen middle.
//  2. The PIVOT moves. `rot` is applied to (uv - center), so turning the
//     angle slider swings the seam about the center rather than about screen
//     middle — the thing that made off-center-looking setups impossible.
//  3. RADIAL MODE anchors correctly. computeWaveArg is still called with
//     float2(0.0) as its center, but its input `uv_m` is now expressed
//     relative to the mirror center, so length(uv_m) is distance from the
//     MIRROR center. In Normal mode the same applies to the wave's phase
//     origin. computeWaveArg itself needed no change at all.
//
// At center == 0 this is `uv - 0` then `+ 0`: bit-for-bit identical to the
// pre-M14 fold, which is the pixel-identity gate for this part.
//
// CALL SITES — M26 CHANGED THE SHAPE OF THIS WARNING, IT DID NOT RETIRE IT.
// Until M26 there were four direct call sites (six until M12 removed the
// Pre-FX path; M12 Part 7C relocated two from getKeyerLuma into
// getMirrorsCombinedLuma without changing the count): two in
// getMirrorsCombinedLuma (Keyer 1's family tap) and two in the chain loop, all
// four of which had to pass the SAME centers or the key would silently
// disagree with the visible geometry.
//
// This function now has exactly TWO callers, both inside applyMirrorModule
// below (the base fold and its doubled partner). The four pipeline sites call
// THAT instead. The invariant is unchanged and now has one place to be
// maintained: the four sites must agree about center, doubling and offset, and
// they do so by construction because there is nothing at those sites to get
// wrong. Anything new that wants to fold a mirror calls applyMirrorModule, not
// this — calling this directly re-opens the failure mode by hand.
float2 applySingleMirror(float2 uv, float2 center, float angle, float rippleFreq, float phase, float rippleAmp,
                         float waveType, float lag, float luma, float lumaMod,
                         float radialMode, thread float& waveOut) {
    float2x2 rot = float2x2(cos(angle), -sin(angle), sin(angle), cos(angle));
    float2x2 inv = float2x2(cos(-angle), -sin(-angle), sin(-angle), cos(-angle));
    float2 uv_m = rot * (uv - center);

    float arg = computeWaveArg(uv_m, float2(0.0), rippleFreq, phase, radialMode);
    waveOut = evaluateWaveform(arg, waveType, lag);

    // M12 PART 1.2 — THE LUMA MODULATION SCALING FIX.
    //
    // Was: rippleAmp * waveOut + (luma * lumaMod * 2.0).
    //
    // The seam is a position in the same coordinate space as uv_m.x, which
    // spans about ±0.71 at scale 1. The two terms added into it had wildly
    // different authority over that space:
    //
    //     rippleAmp * waveOut     ->  ±0.4   (scaled against the coordinate)
    //     luma * lumaMod * 2.0    ->  -4...+4 (never scaled against anything)
    //
    // Ten times the ripple's authority and six times the coordinate's own
    // range. Past |luma * lumaMod * 2| > ~0.71 the seam left the frame
    // entirely, and since the fold is the binary test `uv_m.x < seam`, one of
    // two things happened: every pixel folded to somewhere off-frame (black or
    // tiled), or NO pixel folded and the mirror silently became the identity
    // transform. That is the "mirror switches itself off" defect.
    //
    // Worse, because `luma` varies per pixel there was no sweep through the
    // transition — the image split into always-folds and never-folds regions.
    // The control was behaving as a hard luma KEY on the mirror, not as a
    // modulator of where the mirror line sits.
    //
    // Now: (luma - 0.5) * lumaMod. Two changes in one expression.
    //
    //  1. SCALE. The *2.0 goes, and the UI range narrows from ±2 to ±1.5, so
    //     full deflection is ±0.75 — the seam pushed just past the frame edge
    //     rather than six frames away. The whole slider is now usable travel.
    //  2. AC-COUPLING. (luma - 0.5) centres the modulator on mid-grey: bright
    //     pixels push the seam one way, dark pixels the other, and it wobbles
    //     AROUND wherever Mirror Angle and Mirror Centre put it instead of
    //     carrying a large DC offset that shoved the mirror line off-screen
    //     before the ripple ever got a say.
    //
    // Identity gate: at lumaMod == 0 both expressions are exactly 0.0, so the
    // shipped default and every patch that never touched Luma ➔ Pivot is
    // bit-identical.
    //
    // The general lesson, worth applying to any future modulator added to a
    // geometric quantity: check its authority against BOTH the thing it
    // modulates AND the coordinate range that quantity lives in. The ripple
    // term beside it was scaled carefully against the coordinate. This one
    // never was.
    float seam = rippleAmp * waveOut + (luma - 0.5) * lumaMod;
    if (uv_m.x < seam) {
        uv_m.x = 2.0 * seam - uv_m.x;
    }
    return inv * uv_m + center;
}

// M26 — THE FLAT FOLD: the doubled partner's reflection line.
//
// A STRAIGHT reflection line through the module center at `angle`. No wave, no
// ripple amplitude, no luma offset, no seam term at all — the fold line is
// exactly uv_m.x == 0 in the rotated frame, which is to say it passes through
// the module center, always.
//
// WHY FLAT, when the first attempt gave the partner the module's full
// oscillator: because a fold about a line that is OFFSET from the center does
// not mirror, it TRANSLATES. Reflect about x = s1, then reflect about
// x = s2, and the composition of two reflections in parallel lines is a
// translation by 2*(s1 + s2) — classical result, and the reason two parallel
// barbershop mirrors repeat rather than mirror. With the module's own ripple
// driving s2 that translation swung about +/-0.8 in a coordinate space whose
// visible frame is only +/-0.5, so the sample coordinate left the frame
// entirely. On the procedural source that still returns pattern, because
// gradientSynthPattern is defined everywhere; on camera or video, Black Borders
// returns exactly float4(0,0,0,1) outside the frame. Hence: works on the
// gradient synth, solid black on the webcam. Same bug, two appearances.
//
// Holding this line at the center makes s2 == 0, which kills the translation
// term and leaves a pure reflection — which is what a doubled mirror should be
// and what Paul's two-module reference (Mirror 1 rippled -> Mirror 2 at 3.14
// with VCO Amplitude at 0) was already producing by hand. This function IS that
// second module, folded into the first.
//
// It also keeps Radial mode honest: with no oscillator of its own there is no
// second wave argument to disagree with the base fold's, in either mode. Radial
// simply behaves as Normal does here, which is what was asked for.
float2 applyFlatFold(float2 uv, float2 center, float angle) {
    float2x2 rot = float2x2(cos(angle), -sin(angle), sin(angle), cos(angle));
    float2x2 inv = float2x2(cos(-angle), -sin(-angle), sin(-angle), cos(-angle));
    float2 uv_m = rot * (uv - center);
    if (uv_m.x < 0.0) {
        uv_m.x = -uv_m.x;
    }
    return inv * uv_m + center;
}

// M26 — THE MIRROR *MODULE*: the flat partner fold, THEN the rippled base fold.
//
// applySingleMirror above is untouched by M26 — not one line.
//
// ORDER IS THE WHOLE MILESTONE. Read this before changing it.
//
// The reference this has to match is Mirror 1 (rippled, angle 0) with Mirror 2
// (angle 3.14, VCO Amplitude 0) after it in the routing chain. But the chain
// applies its slots to the COORDINATE in reverse: slot 1 acts on the source and
// slot 5 is seen last, so the walk runs 4 -> 0 and the module sitting LATER in
// the chain has its warp applied to the coordinate FIRST. "Mirror 1 -> Mirror 2"
// therefore means the flat 3.14 fold hits the coordinate first and the rippled
// fold second. The first two builds of this milestone had it the other way
// round, and that single transposition is the difference between what Paul
// asked for and what he got.
//
// It is not a subtle difference, because folds do not commute:
//
//   RIPPLE THEN FLAT (wrong): the rippled fold pushes everything to one side of
//   its seam, then the flat fold mirrors that whole result about the center. One
//   wiggling crease, with the image symmetric about it. This is "it mirrors the
//   underlay and does nothing with the opposite side."
//
//   FLAT THEN RIPPLE (right): the flat fold folds the frame about the straight
//   center line first, so the coordinate arrives at the rippled fold already
//   symmetric — and the rippled seam then cuts that symmetric field, which puts
//   the SAME wiggle on both sides at once, at x = +|seam| and x = -|seam|.
//   Two mirrored wiggling seams from one module. That is the doubled mirror.
//
// Verified numerically before writing: at seam = -0.20 the wrong order creases
// at {-0.41, -0.20, 0.0} and the right order at {-0.20, 0.0, +0.20} — a mirrored
// pair about the center, which is the thing being asked for.
//
// waveOut still carries the base fold's wave: the partner evaluates no
// oscillator, and the base fold runs second, so it writes last regardless.
float2 applyMirrorModule(float2 uv, float2 center, float angle,
                         float rippleFreq, float phase, float rippleAmp,
                         float waveType, float lag, float luma, float lumaMod,
                         float radialMode, float doubleOn, float doubleOffset,
                         thread float& waveOut) {
    float2 uv_out = uv;
    if (doubleOn > 0.5) {
        uv_out = applyFlatFold(uv_out, center, angle + doubleOffset);
    }
    return applySingleMirror(uv_out, center, angle, rippleFreq, phase,
                             rippleAmp, waveType, lag, luma, lumaMod,
                             radialMode, waveOut);
}

// M12: applyMirrors() lived here. It ran BOTH mirrors unconditionally,
// outside the routing chain, and existed only to serve the Pre-FX collision
// key — a key computed on geometry that was not necessarily the geometry on
// screen. Pre-FX is gone, so the function had no callers. The chain loop in
// fragmentShader captures w1/w2 per mirror as each one executes and runs the
// same four-case interference selection once afterwards; that is now the only
// place mirror interference is computed.

// M12 Part 7C — THE THREE-KEYER RESTRUCTURE.
//
// getKeyerLuma's seven-way dispatch (Warped, Raw, Rotation 1, Mirror 1,
// Mirror 2, Rotation 2, Displacement) is gone. Seven taps and two seven-way
// menus become three keyers fixed to the instrument's own module families —
// Keyer 1 reads Mirrors, Keyer 2 reads Rotation, Keyer 3 reads Displacement —
// each with a two-way feed toggle (its family, or Warped Final). Assigning
// rather than splitting: every useful pairing is one click away and each
// keyer's cost is fixed and knowable instead of depending on which of seven
// options a menu happens to have picked.
//
// Raw / Source Input is dropped entirely — with Warped Final available on
// every keyer, the unwarped source is already reachable by emptying the
// routing chain, so the tap bought nothing a toggle didn't already cover.
//
// Warped Final needs no function of its own (it's just sampleSource at
// uv_warped, evaluated once in fragmentShader and shared by whichever keyers
// select it). The two combined-family taps below are new: M1-then-M2 and
// Rot1-then-Rot2, standalone on the raw uv, same isolation rule the old
// individual taps used ("what does this module do by itself," not where it
// sits in the chain) — except now it's what the FAMILY does together, since
// M12's finding was that the relationship between taps, not any one tap
// alone, is what's worth keying on.
//
// M14 note carried forward: these taps deliberately do NOT take staged luma,
// for the same reason the individual taps never did — there is no
// chain-so-far for a standalone tap to stage against.

// Keyer 1's family tap: Mirror 1 then Mirror 2, both standalone on the raw
// uv, nested in that order. Either stage is skipped (identity) if its own
// on/off toggle is off, matching every other reference to mirror1On/mirror2On
// in the file.
float getMirrorsCombinedLuma(float2 uv, float rawLuma,
                             texture2d<float, access::sample> tex, constant ShaderParams& params) {
    // M26: both stages go through applyMirrorModule, so this tap sees the
    // doubled folds too. Sites 1 and 2 of four; if either were left on
    // applySingleMirror, Keyer 1 would key off half the folds that are on
    // screen — a quieter version of the same failure the center arguments
    // could cause, and harder to spot because the key would still look
    // plausible.
    float w = 0.0;
    float2 uv_c = uv;
    if (params.mirror1On > 0.5) {
        uv_c = applyMirrorModule(uv_c, float2(params.mirror1CenterX, params.mirror1CenterY),
                                 params.mirror1Angle, params.mirror1RippleFreq, params.mirror1Phase,
                                 params.mirror1RippleAmp, params.mirror1WaveType, params.mirror1Lag,
                                 rawLuma, params.lumaMod1, params.mirror1RadialMode,
                                 params.mirror1DoubleOn, params.mirror1DoubleOffset, w);
    }
    if (params.mirror2On > 0.5) {
        uv_c = applyMirrorModule(uv_c, float2(params.mirror2CenterX, params.mirror2CenterY),
                                 params.mirror2Angle, params.mirror2RippleFreq, params.mirror2Phase,
                                 params.mirror2RippleAmp, params.mirror2WaveType, params.mirror2Lag,
                                 rawLuma, params.lumaMod2, params.mirror2RadialMode,
                                 params.mirror2DoubleOn, params.mirror2DoubleOffset, w);
    }
    return dot(sampleSource(tex, uv_c, params).rgb, float3(0.299, 0.587, 0.114));
}

// Keyer 2's family tap: Rotation 1 then Rotation 2, nested — no on/off toggle
// on either rotation by design, same convention the chain loop follows
// (bypass a rotation by taking its VCO amplitude to 0).
float getRotationCombinedLuma(float2 uv, float rawLuma,
                              texture2d<float, access::sample> tex, constant ShaderParams& params) {
    float2 uv_c = applyTorsion(uv, params, rawLuma);
    uv_c = applySpiral2(uv_c, params, rawLuma);
    return dot(sampleSource(tex, uv_c, params).rgb, float3(0.299, 0.587, 0.114));
}

// Keyer 3's family tap: Displacement alone, standalone on the raw uv — the
// same TAP 6 the old seven-way matrix offered, just under its own name now.
// Reads a displaced SAMPLE OF THE SOURCE (what the wobble is pointing at) —
// how hard the field is pushing is a different signal (magnitude, not luma).
// M8 Phase C.3 built that as a separate keyer input, Collision; retired right
// after M12 Part 7 gave it a standalone tap of its own, on the grounds that
// this feed already covers displacement-based keying and a second, narrower
// signal wasn't earning its slider.
float getDisplacementLuma(float2 uv, float rawLuma,
                          texture2d<float, access::sample> tex, constant ShaderParams& params) {
    float ignoredMag = 0.0;
    float2 uv_d = applyDisplacement(uv, params, rawLuma, ignoredMag);
    return dot(sampleSource(tex, uv_d, params).rgb, float3(0.299, 0.587, 0.114));
}

// M7 Phase 7.1: combines Spiral 1's and Spiral 2's independent twist-wave
// signals (each the same radial-wave shape torsionInHoles has always used)
// into one signal, per spiralCombineMode. REPLACES the old single-spiral-only
// value that fed the hole cutter's Rotation Wave Mix — the injection AMOUNT
// (torsionInHoles) is untouched, only which signal it injects. At
// spiral2Wave == 0 every mode reduces to twist1 alone (additive: a+0,
// subtractive: a-0, XOR/soft: abs(a-0)=a), so this is pixel-identical to
// pre-M7 at spiral2Strength's default of 0.
float combineSpiralWaves(float twist1, float twist2, float combineMode) {
    if (combineMode < 0.5) {
        return twist1 + twist2;              // Additive
    } else if (combineMode < 1.5) {
        return twist1 - twist2;              // Subtractive
    } else if (combineMode < 2.5) {
        return abs(twist1 - twist2);         // XOR (soft — matches the softXOR convention used elsewhere)
    } else {
        // M8 Phase C.4: Multiply — ring modulation. Unlike the three above,
        // which are all mixing operations, this produces a signal containing
        // the SUM and DIFFERENCE frequencies of the two spirals and neither
        // original. It nulls wherever either wave crosses zero, so both
        // spirals' nodal rings punch through hard, and the fringes between
        // them beat at the frequency difference — which Frequency Offset
        // plays directly.
        //
        // NOTE, and it is expected rather than a bug: unlike the other three
        // modes, this does NOT reduce to twist1 when Rotation 2 is silent — it
        // reduces to zero. A ring modulator with nothing on one input outputs
        // nothing. Multiply therefore requires Rotation 2 to have some
        // amplitude before it does anything at all. Default combine mode is
        // Additive, so no shipped state is affected.
        return twist1 * twist2;
    }
}

// M8 Phase C: the rotation twist-wave signal, factored out of the two places
// that were computing it identically. Returns the combined bipolar wave.
float rotationHoleWave(float2 check_uv, constant ShaderParams& params) {
    float r = length(check_uv);
    float twist1 = evaluateWaveform(r * params.torsionFrequency * 2.0 - params.time * 0.5,
                                    params.torsionWaveType, params.torsionLag);
    float spiral2Freq = params.torsionFrequency + params.spiral2FreqOffset;
    float twist2raw = evaluateWaveform(r * spiral2Freq * 2.0 - params.time * 0.5,
                                       params.spiral2WaveType, params.spiral2Lag);
    float twist2 = twist2raw * clamp(abs(params.spiral2Strength), 0.0, 1.0);
    return combineSpiralWaves(twist1, twist2, params.spiralCombineMode);
}

// Builds the soft composite hole coverage (0..1) from the wave hole + three
// luma keyers, applying the same OR/XOR/invert logic as before but
// continuously. Returns coverage; caller mixes toward black by coverage *
// negativeSpace.
// M12 Part 7C: two keyers became three, fixed to Mirrors / Rotation /
// Displacement. Keyer 1's threshold is absolute; Keyers 2 and 3 are bipolar
// OFFSETS from it, clamped 0...1 after summing — computed here and nowhere
// else, so there is exactly one place that can disagree with the gate
// fragmentShader used to decide whether to evaluate each tap at all (it must
// compute the same clamped values, for the same reason 7B's gate had to match
// this function's "< 0.99 = off" convention). Polarity is one control for all
// three keyers.
// M12 Part 7 cleanup: Collision (displacement magnitude -> holes) is retired.
// Keyer 3's Displacement feed already keys on displacement; a second, magnitude-
// based signal wasn't earning its slider. See ROADMAP for the fuller history —
// the build-then-assemble AND/XOR machinery this used to need was the most
// delicate code in the keying path, and it is simply gone now, not hidden.
float compositeHoleCoverage(float active_wave, float keyLuma1, float keyLuma2, float keyLuma3,
                            constant ShaderParams& params) {
    // Wave hole placement (soft).
    float waveCov = softKeyAbove(active_wave, params.negativeSpaceThreshold, params.keySoftness);

    float threshold1 = params.keyerThreshold1;
    float threshold2 = clamp(threshold1 + params.keyerOffset2, 0.0, 1.0);
    float threshold3 = clamp(threshold1 + params.keyerOffset3, 0.0, 1.0);
    bool darks = params.keyerPolarity > 0.5;

    // Keyer 1 (Mirrors, or Warped Final — see keyerFeed1). Gated by "threshold
    // nearly 1 = off," same convention every depth control in the instrument
    // follows.
    float key1Cov = 0.0;
    if (threshold1 < 0.99) {
        key1Cov = darks ? softKeyBelow(keyLuma1, threshold1, params.keySoftness)
                        : softKeyAbove(keyLuma1, threshold1, params.keySoftness);
    }

    // Keyer 2 (Rotation, or Warped Final).
    float key2Cov = 0.0;
    if (threshold2 < 0.99) {
        key2Cov = darks ? softKeyBelow(keyLuma2, threshold2, params.keySoftness)
                        : softKeyAbove(keyLuma2, threshold2, params.keySoftness);
    }

    // Keyer 3 (Displacement, or Warped Final).
    float key3Cov = 0.0;
    if (threshold3 < 0.99) {
        key3Cov = darks ? softKeyBelow(keyLuma3, threshold3, params.keySoftness)
                        : softKeyAbove(keyLuma3, threshold3, params.keySoftness);
    }

    // Stage 1: wave vs Keyer 1. Offset zero on Keyers 2/3, XOR'd against
    // whatever they're paired with, is exactly the difference key that
    // reshaped this milestone: two keyers at the same threshold on different
    // taps.
    float cov = (params.keyerXOR1 > 0.5) ? softXOR(waveCov, key1Cov) : softOR(waveCov, key1Cov);
    // Stage 2: Keyer 2 folds in.
    cov = (params.keyerXOR2 > 0.5) ? softXOR(cov, key2Cov) : softOR(cov, key2Cov);
    // Stage 3: Keyer 3 folds in.
    cov = (params.keyerXOR3 > 0.5) ? softXOR(cov, key3Cov) : softOR(cov, key3Cov);

    // Stage 4: global invert.
    if (params.invertEntireHoleKey > 0.5) {
        cov = softNOT(cov);
    }
    return cov;
}

// ---- M2: Output Vignette matte (screen-space shape crop) ----
// A physical output mask applied at the very END of the chain, AFTER the M1a
// output mix. It operates on raw screen uv (in.uv), so it's completely
// unaffected by zoom/scale or any warp — it just shape-crops the finished
// frame. Returns coverage 0..1: 1 = fully inside the shape (keep the pixel),
// 0 = outside (the caller multiplies rgb by this, so outside goes black).
//
// The aspect knob anisotropically scales the SDF coordinates before measuring
// distance: because a coordinate scaled UP reaches the shape radius at a
// SMALLER screen distance, +aspect (scale X up, Y down) makes the shape narrow
// in X and tall in Y (stretched tall), and -aspect does the opposite (wide).
// 0 = uniform. For the Rect shape this same knob sets its width/height ratio,
// so no separate rect W/H params are needed.
//
// Softness reuses the exact key-softness pattern: at 0 it collapses to a hard
// boolean edge (smoothstep with equal edges is undefined on GPU), and above 0
// it feathers with a smoothstep band of half-width `soft` around the SDF's
// zero contour.
float vignetteCoverage(float2 screenUV, constant ShaderParams& params) {
    // Center on screen middle, then offset by the (bipolar) center controls.
    float2 p = (screenUV - 0.5) - float2(params.vignetteCenterX, params.vignetteCenterY);

    // Anisotropic aspect stretch. exp() keeps it symmetric & always-positive:
    // +aspect -> aniso = (>1, <1) -> tall; -aspect -> (<1, >1) -> wide.
    float k = 0.75; // stretch strength
    float2 aniso = float2(exp(k * params.vignetteAspect), exp(-k * params.vignetteAspect));
    p *= aniso;

    float d;
    if (params.vignetteShape < 1.5) {
        // Circle: signed distance to a circle of radius = size (negative inside).
        d = length(p) - params.vignetteSize;
    } else {
        // Rect: standard 2D box signed-distance function, half-extent = size.
        float2 q = abs(p) - float2(params.vignetteSize);
        d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    }

    float soft = params.vignetteSoftness;
    if (soft <= 0.0001) {
        // Hard edge: keep inside (d <= 0), drop outside. Bit-identical to a
        // plain boolean crop.
        return (d <= 0.0) ? 1.0 : 0.0;
    }
    // Feathered: 1 deep inside, 0.5 exactly on the edge, 0 well outside.
    return 1.0 - smoothstep(-soft, soft, d);
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                               texture2d<float, access::sample> inputTexture [[texture(0)]],
                               constant ShaderParams& params [[buffer(0)]]) {
    float2 uv = (in.uv - 0.5) * params.scale;

    float4 rawSample = sampleSource(inputTexture, uv, params);
    float rawLuma = dot(rawSample.rgb, float3(0.299, 0.587, 0.114));

    float2 uv_warped = uv;
    float waveInterference = 0.0;
    // Hoisted out of the chain block below because the hole cutter needs them:
    // whether each mirror actually executed (the interference selection), and
    // the displacement magnitude with a flag for whether displacement ran at all.
    bool m1Ran = false;
    bool m2Ran = false;
    bool dispRan = false;
    float dispMagnitude = 0.0;

    // ===================== CORE WARPING PIPELINE =====================
    // M13: THE LOOP RUNS BACKWARDS ON PURPOSE — READ THIS BEFORE CHANGING IT.
    //
    // This pipeline is a COORDINATE WARP sampled exactly once, at the end. No
    // module ever sees an image; each one bends WHERE WE LOOK, not what we see.
    // The result is source(W_last(...W_first(uv))), so the module applied to uv
    // FIRST is the lens nearest the eye — the outermost, most visible operation
    // — and the module applied LAST sits flat against the raw source, buried
    // under everything the others do afterwards.
    //
    // Slots are numbered source ➔ output, the way a patch reads: slot 0 is the
    // first thing done to the source, slot 4 is the last thing seen. To make
    // the picture match the numbering, the walk therefore runs 4 ➔ 0. Running
    // it 0 ➔ 4 (as it did before M13) silently inverts every chain: a mirror in
    // the last slot folds the SOURCE and then everything else smears the fold,
    // instead of mirroring the finished composite.
    //
    // Nothing is lost by the single-sample design — mirroring the fully
    // composited image is exactly "apply the mirror to the coordinate first,"
    // which is what slot 4 now does.
    //
    // M7 Phase 7.2: the fixed 3-way routing branch (index 3, reclaimed in M15)
    // is replaced by a walk over the five chain slots. Each slot names one warp
    // module by ID; every ordering of
    // Mirror 1 / Mirror 2 / Rotation 1 / Rotation 2 is reachable — including
    // interleavings like M1 ➔ Rot1 ➔ M2 ➔ Rot2 that the old picker could not
    // express, and reversed nesting (Rot2 ➔ Rot1), which is a genuinely
    // different instrument because nesting is not commutative.
    //
    // The rotations are no longer welded together: Rotation 2 still nests
    // inside whatever coordinate it receives (that is inherent to applySpiral2
    // reading the incoming uv), but that coordinate no longer has to be
    // Rotation 1's output.
    //
    // Hole-cutter interference: this used to be computed inside a dual-mirror
    // helper, but in a chain the two mirrors are separate slots, so the loop
    // captures w1/w2 as each mirror executes and the SAME four-case
    // calculation runs once after the loop. (M12 deleted that helper outright
    // along with the Pre-FX path, its only remaining caller.)
    // (Routing branch 2 — the old M1➔Torsion➔M2 — already worked exactly this
    // way, so this is a generalization of shipped behavior, not a new pattern.)
    {
        // Metal cannot dynamically index struct fields, so the slots are copied
        // into a local array first — a normal, free pattern. Loop bounds are
        // compile-time constant, so this unrolls into essentially the same
        // shape as the old branch.
        float slots[CHAIN_SLOT_COUNT] = { params.chainSlot0, params.chainSlot1,
                                          params.chainSlot2, params.chainSlot3,
                                          params.chainSlot4 };

        float w1 = 1.0;
        float w2 = 1.0;
        bool m1Active = (params.mirror1On > 0.5);
        bool m2Active = (params.mirror2On > 0.5);
        float slotMag = 0.0;

        // A mirror can now be toggled ON but absent from the chain, which was
        // impossible before 7.2 — every routing branch ran both mirrors. The
        // interference selection below must key off "did this mirror actually
        // execute," not "is its toggle on," or w1/w2 stay at their identity
        // value of 1.0 and the hole cutter is fed a flat constant field with no
        // spatial structure to threshold against.

        // M13: descending. Slot 4 (outermost / last seen) is applied to uv
        // first; slot 0 (nearest the source) is applied last.
        for (int i = CHAIN_SLOT_COUNT - 1; i >= 0; i--) {
            int id = int(slots[i]);

            // ---- M14 PART 2: LUMA SOURCE STAGING ----
            // Which luma does THIS module get to modulate off?
            //
            // At depth 0, rawLuma — the unwarped source, which is what every
            // module has always used. At depth 1, the source sampled at
            // uv_warped, i.e. at the coordinate the chain has bent to by this
            // point. That is not an approximation of "the previous stage's
            // output": in a single-sample coordinate pipeline the composite
            // after stages 1..k IS source(W_k(...W_1(uv))), so sampling the
            // source at the current uv_warped returns exactly that value at
            // this fragment. A mirror in slot 4 therefore luma-modulates off
            // what the four modules under it built, not off the source video.
            //
            // Scope, stated so it is not mistaken for a bug: "so far" means
            // GEOMETRY so far. Keying, wave folding and the output stages all
            // run after the chain, so they are not included — which is the
            // right meaning for a geometry module's luma input.
            //
            // COST: the branch is on a uniform, so every fragment in the draw
            // takes the same path. At depth 0 there is no extra sample and the
            // output is bit-identical to pre-M14. When on, the worst case is
            // one extra sampleSource per OCCUPIED slot — and note that on the
            // procedural source sampleSource re-runs gradientSynthPattern from
            // scratch rather than hitting a texture cache, so a full five-module
            // chain costs five extra pattern evaluations. Empty slots are
            // skipped precisely because of that.
            float stageLuma = rawLuma;
            if (params.lumaStageDepth > 0.001 && id != CHAIN_MODULE_EMPTY) {
                float4 stageSample = sampleSource(inputTexture, uv_warped, params);
                stageLuma = mix(rawLuma,
                                dot(stageSample.rgb, float3(0.299, 0.587, 0.114)),
                                params.lumaStageDepth);
            }

            if (id == CHAIN_MODULE_MIRROR1) {
                // The on/off toggle bypasses the stage wherever it sits in the
                // chain; w1 keeps its identity value of 1.0 when bypassed, so
                // the interference cases below behave exactly as before.
                if (m1Active) {
                    // M26 site 3 of 4. Doubling lives inside applyMirrorModule,
                    // so a mirror occupying several slots doubles in each of
                    // them — same rule the module already followed, applied to
                    // a module that now contains two folds.
                    uv_warped = applyMirrorModule(uv_warped, float2(params.mirror1CenterX, params.mirror1CenterY),
                                                  params.mirror1Angle, params.mirror1RippleFreq, params.mirror1Phase,
                                                  params.mirror1RippleAmp, params.mirror1WaveType, params.mirror1Lag,
                                                  stageLuma, params.lumaMod1, params.mirror1RadialMode,
                                                  params.mirror1DoubleOn, params.mirror1DoubleOffset, w1);
                    m1Ran = true;
                }
            } else if (id == CHAIN_MODULE_MIRROR2) {
                if (m2Active) {
                    // M26 site 4 of 4.
                    uv_warped = applyMirrorModule(uv_warped, float2(params.mirror2CenterX, params.mirror2CenterY),
                                                  params.mirror2Angle, params.mirror2RippleFreq, params.mirror2Phase,
                                                  params.mirror2RippleAmp, params.mirror2WaveType, params.mirror2Lag,
                                                  stageLuma, params.lumaMod2, params.mirror2RadialMode,
                                                  params.mirror2DoubleOn, params.mirror2DoubleOffset, w2);
                    m2Ran = true;
                }
            } else if (id == CHAIN_MODULE_ROTATION1) {
                // No on/off toggle by design — a rotation is bypassed by taking
                // its VCO Amplitude to 0, which is the identity warp.
                uv_warped = applyTorsion(uv_warped, params, stageLuma);
            } else if (id == CHAIN_MODULE_ROTATION2) {
                uv_warped = applySpiral2(uv_warped, params, stageLuma);
            } else if (id == CHAIN_MODULE_DISPLACEMENT) {
                // M8 Phase A. No on/off toggle, matching the rotations — both
                // amplitudes at 0 is an exact identity, and an Empty slot is
                // already a real bypass.
                uv_warped = applyDisplacement(uv_warped, params, stageLuma, slotMag);
                // M8 Phase C.3: last-executed wins when displacement occupies
                // several slots, matching the w1/w2 rule for duplicated mirrors.
                // M13 NOTE: the RULE is unchanged, but because the walk now
                // descends, "last executed" is the LOWEST-numbered displacement
                // slot rather than the highest. Not a regression — the rule
                // simply lands on a different slot now.
                dispMagnitude = slotMag;
                dispRan = true;
            }
            // CHAIN_MODULE_EMPTY (5) is a no-op. An all-Empty chain is a
            // legitimate state: the unwarped source.
        }

        // The relocated four-case interference calculation, run once, selected
        // on what actually executed. M13: order-independent. w1/w2 are captured
        // per-execution and combined only after the loop, and m1Ran/m2Ran are
        // booleans, so reversing the walk cannot change this result for any
        // given set of executed modules. Stated explicitly because it looks
        // like it should matter and does not. A chain with no mirror in it lands in the
        // last case and yields 0.0 — the same signal pre-7.2 produced with both
        // mirrors toggled off, so the Post-FX hole cutter then depends on the
        // Rotation Wave Mix injection for its structure, exactly as before.
        if (m1Ran && m2Ran) {
            waveInterference = abs(w1 * w2);
        } else if (m1Ran) {
            waveInterference = abs(w1);
        } else if (m2Ran) {
            waveInterference = abs(w2);
        } else {
            waveInterference = 0.0;
        }
    }

    // M12: the Pre-FX collision-key path was removed here. It ran a private
    // copy of both mirrors on the UNWARPED uv and keyed off that, so the key
    // was computed on geometry that need not be the geometry on screen — the
    // shipped default was Post-FX and that is now the only behavior.
    float active_wave = waveInterference;

    if (params.rectification > 0.0) {
        float folded = sin(active_wave * params.rectification * 15.0);
        active_wave = abs(folded);
    }

    // Rotation-wave mix into the hole signal. M7 Phase 7.1: the injected
    // signal is now Spiral 1's and Spiral 2's twist waves combined per
    // spiralCombineMode, not Spiral 1 alone — torsionInHoles (the amount)
    // is unchanged. Spiral 2's wave contribution is scaled by its own
    // strength (consistent with how the geometry warp above already gates
    // on spiral2Strength), so at spiral2Strength == 0 every combine mode
    // reduces to "Spiral 1's wave alone": pixel-identical to pre-M7.
    // M12: the mode switch is gone. Multiply is the only rotation-into-holes
    // behavior and is always available, gated purely on its own depth
    // (torsionInHoles), which is how every other depth control in the
    // instrument behaves. At the shipped default the mode WAS Multiply, so
    // this is pixel-identical; the only reachable state that changes is
    // "mode Off with a non-zero depth," which nothing shipped with.
    if (params.torsionInHoles > 0.0) {
        float rotSignal = clamp(rotationHoleWave(uv_warped, params) * 0.5 + 0.5, 0.0, 1.0);
        // M8 Phase C.2 — THE CARRIER FALLBACK.
        // This injection is a ring modulator: rotation is the modulator and the
        // mirror interference is the carrier. Before the routing chain existed
        // there was always a carrier, because every routing branch ran both
        // mirrors. Now a chain can contain no mirror at all, active_wave is 0,
        // and multiplying by the modulator yields silence — which is exactly
        // why the wave hole went dead in rotation-only and displacement-only
        // chains.
        //
        // When no mirror ran, the rotation wave BECOMES the carrier rather than
        // modulating a zero. Bit-identical whenever a mirror is in the chain.
        float carried = (m1Ran || m2Ran) ? (active_wave * rotSignal) : rotSignal;
        active_wave = mix(active_wave, carried, params.torsionInHoles);
    }

    // M12 Part 7A — THE DISPLACEMENT CARRIER FALLBACK.
    // Symmetric to M8 Phase C.2's rotation fallback above, for the same reason:
    // Wave Folding (just above, `rectification`) and the wave-hole threshold
    // both act on `active_wave`, which IS the mirror interference. In a chain
    // with no mirror and no rotation injection, active_wave is still 0 at this
    // point even though Displacement ran.
    //
    // (Historical note: at the time this was written, Collision — a separate
    // keyer input, since retired — read the chain-captured dispMagnitude below
    // and never touched active_wave, which is why Collision worked in a
    // displacement-only chain while Wave Folding did nothing. Collision is
    // gone now, along with the note's original reason for existing, but
    // dispRan/dispMagnitude live on: this fallback is their only caller.)
    //
    // Guard is `torsionInHoles <= 0.0`, not `!m1Ran && !m2Ran` alone: if
    // rotation's own fallback just ran (no mirror, torsionInHoles > 0), it has
    // already promoted itself into active_wave and must not be overwritten.
    // Rotation goes first because it is the older, shipped-with-patches
    // behavior; displacement is the second and lower-priority fallback.
    //
    // Bit-identical whenever a mirror is in the chain, or when displacement did
    // not run, or when rotation's own fallback already supplied a carrier. NOT
    // identity-free otherwise: a displacement-only chain (no mirror, no
    // rotation injection) that shows no wave hole today will start showing one,
    // driven by the displacement magnitude itself. That is the fix.
    if (!m1Ran && !m2Ran && dispRan && params.torsionInHoles <= 0.0) {
        active_wave = dispMagnitude;
    }

    // ---- Keyer feed luma ----
    // M12: keyer posterization removed. It quantized the keyer FEED before
    // thresholding (banded key edges, not posterized output video), which is a
    // fine idea and never earned its slider.
    //
    // M12 Part 7C — THREE KEYERS, FIXED TO THE MODULE FAMILIES. Keyer 1 reads
    // Mirrors, Keyer 2 reads Rotation, Keyer 3 reads Displacement; each has a
    // two-way feed (its family, or Warped Final — see keyerFeed1/2/3). The
    // seven-way tap menu and Raw / Source Input are both gone.
    //
    // Thresholds: Keyer 1 is absolute (keyerThreshold1). Keyers 2 and 3 are
    // bipolar OFFSETS from it (keyerOffset2/3), clamped 0...1 after summing —
    // this clamped value, not the raw offset, is what "< 0.99 = off" is
    // tested against, and it MUST match compositeHoleCoverage's own
    // computation of the same two thresholds or the gate and the composite
    // disagree about what "live" means. Offset zero is the rest position:
    // Keyer 2 or 3 at the same threshold as Keyer 1, XOR'd, is the difference
    // key finding that reshaped this milestone.
    //
    // 7B's gate carries forward per keyer: a threshold >= 0.99 contributes
    // zero coverage regardless of its luma, so skipping that keyer's tap
    // evaluation is identity-free.
    float keyerThreshold2 = clamp(params.keyerThreshold1 + params.keyerOffset2, 0.0, 1.0);
    float keyerThreshold3 = clamp(params.keyerThreshold1 + params.keyerOffset3, 0.0, 1.0);
    bool keyer1Live = params.keyerThreshold1 < 0.99;
    bool keyer2Live = keyerThreshold2 < 0.99;
    bool keyer3Live = keyerThreshold3 < 0.99;

    // ONE evaluation of the source at the final warped coordinate, shared by
    // the keyers' Warped Final feed and by the output colour further down.
    //
    // M22: these used to be two separate sampleSource calls with identical
    // arguments — one here, one at `float4 color = ...` below. `uv_warped`
    // takes its last write inside the chain block above and is final from
    // there on, and sampleSource has no side effects, so the two calls could
    // only ever return the same value. Sharing one sample is exact, not an
    // approximation.
    //
    // The `needsWarpedFinal` gate that used to wrap this came out with it. It
    // existed to avoid paying for a SAMPLE no keyer wanted; now that the
    // sample happens regardless (the output colour needs it), the only thing
    // left to gate was a dot product — three multiplies and two adds, cheaper
    // than the three comparisons and two ORs the gate itself cost. Warped
    // Final is still sampled at most once per fragment no matter how many
    // keyers select it; that is now structural rather than something a gate
    // has to maintain.
    float4 warpedSample = sampleSource(inputTexture, uv_warped, params);
    float warpedFinalLuma = dot(warpedSample.rgb, float3(0.299, 0.587, 0.114));

    float keyLuma1 = 0.0;
    if (keyer1Live) {
        keyLuma1 = (params.keyerFeed1 > 0.5)
            ? warpedFinalLuma
            : getMirrorsCombinedLuma(uv, rawLuma, inputTexture, params);
    }
    float keyLuma2 = 0.0;
    if (keyer2Live) {
        keyLuma2 = (params.keyerFeed2 > 0.5)
            ? warpedFinalLuma
            : getRotationCombinedLuma(uv, rawLuma, inputTexture, params);
    }
    float keyLuma3 = 0.0;
    if (keyer3Live) {
        keyLuma3 = (params.keyerFeed3 > 0.5)
            ? warpedFinalLuma
            : getDisplacementLuma(uv, rawLuma, inputTexture, params);
    }

    // M12: the Pre-FX branch was removed here. It sampled the source a second
    // time, ran a private copy of both mirrors, recomputed the rotation wave
    // and recomputed the displacement magnitude — an entire shadow pipeline
    // built only so the key could be taken from geometry other than the
    // geometry on screen. Post-FX was the shipped default and is now the only
    // path, so what follows is the old else-branch, unindented.
    //
    // Collision (Displacement -> Holes) is retired, M12 Part 7 cleanup:
    // Keyer 3's Displacement feed already keys on displacement, so a second,
    // magnitude-based signal wasn't earning its slider.
    float cov = compositeHoleCoverage(active_wave, keyLuma1, keyLuma2, keyLuma3, params);

    // M22: `warpedSample` above IS this sample — same function, same three
    // arguments, and uv_warped has not moved since. See the comment at its
    // declaration in the keyer block.
    float4 color = warpedSample;
    color = mix(color, float4(0.0, 0.0, 0.0, 1.0), cov * params.negativeSpace);

    // ---- M1a: Output Mix (A/B) ----
    // FINAL wet/dry blend, applied after EVERYTHING above. "Dry" is the raw
    // source sampled at the un-warped screen uv: scale, edge behavior, and
    // pre-crop still apply (they're baked into `uv` and sampleSource), but no
    // mirrors/torsion/keys. At outputMix >= ~1 this branch is skipped so
    // defaults stay pixel-identical. Any output-shape stage (the M2 vignette
    // below) must run AFTER this line so it mattes the mixed result.
    //
    // M22: the dry sample used to be a second sampleSource call at `uv`.
    // `uv` is assigned once at the top of this function and never reassigned,
    // so `rawSample` — taken at the very first line of the shader, at that
    // same coordinate — already holds exactly this value. Copying it here is
    // bit-identical to re-sampling and costs one whole source evaluation
    // less on every fragment of every wet/dry patch; on the Gradient Synth
    // source that saving is a full pattern evaluation rather than a cached
    // texture fetch. `dryColor` is a copy, so writing its alpha below cannot
    // reach back into `rawSample`.
    if (params.outputMix < 0.999) {
        float4 dryColor = rawSample;
        dryColor.a = 1.0;
        color = mix(dryColor, color, params.outputMix);
    }

    // ---- M2: Output Vignette ----
    // Screen-space shape matte. Runs AFTER the M1a mix above (per the confirmed
    // M1a ordering decision): the mix blends effected-vs-dry first, then this
    // shape-crops the already-mixed output. Outside the shape goes to black;
    // alpha is left at 1. At vignetteShape == Off (0) the block is skipped so
    // the output is pixel-identical to pre-M2. This is the LAST op before
    // return.
    // M4.4 Part B: the same coverage value can also be written to ALPHA, so a
    // ProRes 4444 take carries the matte as a real alpha channel rather than
    // only as black outside the shape. This is PREMULTIPLIED alpha — rgb was
    // multiplied by cov on the line above before alpha is written, which is
    // the definition — and it is deliberately the only alpha behavior in the
    // shader, so preview, present pass, and screenshots need no second path.
    //
    // Two identity gates, both intact: at vignetteAlpha == 0 this line does
    // not execute and alpha stays 1.0; at vignetteShape == Off the whole
    // block is skipped. Default patches are bit-identical to pre-M4.4.
    if (params.vignetteShape > 0.5) {
        float cov = vignetteCoverage(in.uv, params);
        color.rgb *= cov;
        if (params.vignetteAlpha > 0.5) {
            color.a = cov;
        }
    }

    return color;
}


// ---- M3: Present-pass blit ----
// Pass 2 of the two-pass structure introduced in M3. Pass 1 renders the entire
// synth into an offscreen texture; this copies that texture onto the
// drawable — 1:1 when the two are the same size (Native), scaled to fit
// inside a letterboxed viewport when they're not (M18's fixed resolutions and
// Native ÷2). It is deliberately trivial — no math, no params — and stays
// that way; only the SAMPLER became bindable, not the shape of this function.
// Pass 1's offscreen texture remains the frame tap M4's recorder reads.
//
// It reuses the SAME vertexShader as the synth pass, on purpose. That vertex
// shader flips uv.y after computing position, so `in.uv` is the destination
// pixel's position with origin at top-left — exactly the convention
// texture::sample() uses for the source. Running the same vertex shader in both
// passes therefore yields an exact identity copy. Adding a second vertex shader
// that flips again is the classic way this lands upside-down.
//
// M18: the sampler moved from a baked-in constexpr to a bound argument.
// LiquidRenderer picks nearest + clamp_to_edge (when the offscreen texture is
// pixel-for-pixel the same size as the drawable — Native, still an exact 1:1
// copy) or linear + clamp_to_edge (any other Output Resolution) and binds it
// at encode time, alongside the viewport/scissor rect that does the letterbox
// fit. One shader, one pipeline; the choice lives entirely on the CPU side —
// see the present-pass encoding in LiquidRenderer.draw().
fragment float4 blitFragmentShader(VertexOut in [[stage_in]],
                                   texture2d<float, access::sample> sourceTexture [[texture(0)]],
                                   sampler s [[sampler(0)]]) {
    // M4.4 Part B: alpha is forced to 1.0 on the way to the DRAWABLE.
    //
    // This is exactly an identity today (the offscreen texture's alpha was
    // 1.0 everywhere before M4.4) and stays an identity for the visible
    // IMAGE forever — rgb is passed through untouched. What it buys is a
    // guarantee: once the vignette can write a sub-1 alpha into pass 1's
    // target, that value must not be allowed to reach the window and make it
    // see-through depending on how CAMetalLayer happens to have its opacity
    // configured elsewhere. Stating the contract here is cheaper and more
    // certain than depending on a layer property set in another file, and it
    // does NOT make this pass do image math — pass 2 stays trivial.
    //
    // The recorder is unaffected: it taps pass 1's texture directly and never
    // passes through this shader, which is exactly why the alpha survives
    // into the file while the window stays solid.
    return float4(sourceTexture.sample(s, in.uv).rgb, 1.0);
}

// M12: glowBlurShader and glowCompositeShader lived here (M5). Removed whole,
// together with the two half-res ping-pong targets and the full-res composite
// target in LiquidRenderer. See the note at index 64-68 in ShaderParams.













