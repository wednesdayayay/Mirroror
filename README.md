# Mirroror

A real-time, hardware-accelerated video synthesizer for macOS. A picture goes
in — camera, video file, or a generated pattern — and gets folded, twisted,
and pushed out of shape live, at 60 frames a second, entirely on the GPU.


Built with SwiftUI and a single Metal fragment shader. No offline render step
— every control is playable while the image is running.

---

## Two ways to get this running

**Just want to use it?** Download the pre-built app. Skip to
[Running the app](#running-the-app).

**Want to read the code, modify it, or build it yourself?** Download the
Xcode project. Skip to [Building from source](#building-from-source).

Either way, read [A note on "unsigned"](#a-note-on-unsigned) first — macOS
will show you a warning the first time you open this app, and it's expected.

---

## Requirements

- **macOS 15** or later (have tested 15.4.1 and 26.6.1)
- **Apple Silicon** (M-series) — this is the primary target and what it's
  tested on.
- A camera, if you want to use one as a source. Video files and a built-in
  generated pattern work without one.

---

## A note on "unsigned"

This app is **not code-signed or notarized** by Apple. Signing/notarizing isn't
required to run software on your own Mac, only to make Gatekeeper trust it
automatically.

**What this means in practice:** macOS will refuse to open it with a normal
double-click, and may say the app is damaged or from an unidentified
developer. This is normal Gatekeeper behavior for any unsigned app, not a
sign that anything is wrong with this one. Two things it does *not* mean:
it does not mean the app has a virus, and it does not mean something has
gone wrong with the download.

**What this does not mean:** downloading and running unsigned software
generally carries more risk than software from the App Store, because
nobody at Apple has reviewed it. You're trusting the source you got it from.
This is the source — the code in this repository is exactly what the app
you're running was built from, so you can read any file here before you
run it, or build it yourself from source instead of running the pre-built
binary.

---

## Running the app

1. Download `Mirroror.app.zip` from this repository and unzip it.
2. **Do not double-click it yet.** A normal double-click on a fresh download
   will be blocked by Gatekeeper.
3. Instead, **right-click (or Control-click) `Mirroror.app`** and choose
   **Open** from the menu.
4. macOS will show a dialog warning that the developer cannot be verified.
   Click **Open** on that dialog. This exact step is only required the
   first time — after this, the app opens normally with a regular
   double-click.
5. The first time you select a camera as a source, macOS will ask for
   camera permission. Allow it if you want to use a camera; it's not
   required for the generated pattern or for video files.

If step 3 doesn't offer an "Open" option, or macOS still refuses:

- Open **System Settings ➔ Privacy & Security**, scroll down, and look for
  a message near the bottom naming `Mirroror.app` with an **Open Anyway**
  button. Click it, then try opening the app again.

---

## Building from source

If you'd rather build it yourself — to read the code first, to modify it,
or simply because you don't want to run someone else's binary — this is
the same source the pre-built app comes from.

1. Download `Mirroror.xcodeproj.zip` and unzip it.
2. Open `Mirroror.xcodeproj` in Xcode (a recent version — the project
   targets macOS 15.6).
3. In the project navigator, select the **Mirroror** project, then the
   **Mirroror** target, then the **Signing & Capabilities** tab.
4. Under **Team**, choose **your own** Apple ID / personal team from the
   dropdown, or select **None** if you just want to run it locally without
   any signing at all. Leave **Automatically manage signing** checked.
   You do not need a paid Apple Developer account for local builds — a
   free Apple ID is enough for Xcode to sign the app for your own Mac.
5. Build and run (⌘R). Xcode handles the rest, and because it's building
   and signing locally for you, none of the Gatekeeper steps above apply
   — it just runs.

If you plan to modify and redistribute the app yourself, note the license
below: any distributed version has to stay under GPLv3, source included.

---

## Documentation

The full manual — every module, every control, the signal path, MIDI
mapping, all of it — is in this repository:

- **`Mirroror-Manual.html`** — open it in any browser. This is the
  canonical, most current version.
- **`Mirroror-Manual.pdf`** — the same manual, for reading offline or
  printing.

Start with Chapter 0 (About this instrument) and Chapter 1 (First look) if
you're new to it. The manual ships without presets by design — every
chapter ends with a short **Starting points** section that gives you one
patch to dial in by hand, since the instrument doesn't come with any
sound-alike patches built in.


---

## License

GPLv3. See `LICENSE`. Source is provided in full — this repository is not
a stripped-down or binary-only release.

---

## Status

Version 1.0. Feature-complete and stable. Development happens in the open
here; issues and pull requests are welcome.
