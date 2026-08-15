# Mirroror

A real-time, hardware-accelerated video synthesizer for macOS. A picture goes
in — camera, video file, or a generated pattern — and gets folded, twisted,
and pushed out of shape live, at 60 frames a second, entirely on the GPU.


Built with SwiftUI and a single Metal fragment shader. No offline render step
— every control is playable while the image is running.

<img width="600" height="450" alt="2026-08-09_21-59-24" src="https://github.com/user-attachments/assets/dd8e3585-93bd-4c6d-8b56-37fb69f17430" />
<img width="700" height="500" alt="2026-08-14_21-34-23" src="https://github.com/user-attachments/assets/91095e16-fbc0-41e5-a0fe-54aac6cab1b9" />
<img width="600" height="450" alt="2026-08-10_07-17-57" src="https://github.com/user-attachments/assets/1511ab9d-8487-4a9a-abdf-136db3ff6891" />
<img width="800" height="550" alt="2026-08-14_21-09-17" src="https://github.com/user-attachments/assets/0c49d31b-8fac-4cfb-862d-ae3a2f266a30" />
<img width="800" height="550" alt="2026-08-14_21-41-15" src="https://github.com/user-attachments/assets/56b7160f-8eaa-42bc-a27e-4d9b8df097a3" />
<img width="250" height="225" alt="Screenshot 2026-08-15 at 8 12 58 AM" src="https://github.com/user-attachments/assets/a53da425-e166-4b02-87d2-52dc3f6ac1f9" />
<img width="600" height="350" alt="2026-08-09_15-04-27" src="https://github.com/user-attachments/assets/2ff23722-9cb7-49b0-afa6-d4c42e184e55" />




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
