//
//  MirrororApp.swift
//  Mirroror
//
//  Created by Nichole Pichon on 7/16/26.
//

import SwiftUI
import AppKit

// Finalizes an in-progress recording on quit rather than losing the take.
// Holds weak references only — AppController owns both objects for the app's
// lifetime and registers them here.
final class MirrororAppDelegate: NSObject, NSApplicationDelegate {
    weak var frameCapture: FrameCapture?
    // Mappings are already written on every edit; this is a final
    // belt-and-braces write, not the only save point.
    weak var controlSurface: ControlSurface?

    func applicationWillTerminate(_ notification: Notification) {
        // finalizeForTermination waits at most 3s — a stuck writer must not
        // hang the quit. movieFragmentInterval (set at Record) means even an
        // interrupted finalize leaves a playable partial file.
        frameCapture?.finalizeForTermination()
        controlSurface?.persistMappings()
    }
}

@main
struct MirrororApp: App {
    @NSApplicationDelegateAdaptor(MirrororAppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController()
    @Environment(\.openWindow) private var openWindow

    // Runs once, before any control reads the registry. DEBUG-only, so it
    // costs nothing in Release. Catches a LiveParams field added without a
    // matching registry entry in the build that introduced it, rather than
    // months later when a parameter turns out to have no way to be mapped.
    init() {
        ParamRegistry.runCensus()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .onAppear {
                    appDelegate.frameCapture = controller.frameCapture
                    appDelegate.controlSurface = controller.controlSurface
                }
        }
        // All three routes to Reset All — menu, shortcut, sidebar button —
        // set the confirmation flag rather than calling performResetAll
        // directly, so no path wipes a patch silently.
        //
        // Two-modifier shortcut on purpose: a destructive action on a
        // performance instrument should not be one accidental chord away.
        .commands {
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Reset All Parameters...") {
                    controller.showResetConfirmation = true
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                // Non-destructive — it only re-reads values already correct
                // in the store — so no confirmation.
                Button("Refresh Controls") {
                    controller.refreshControls()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                // ⌘⌥M, since ⌘⌥R is Reset All. The scene is declared once
                // below and reused on every open rather than rebuilt.
                Button("MIDI Mapping...") {
                    openWindow(id: "midi-osc-mapping")
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }

        // Closed at launch by default; reached from the menu command above
        // or the sidebar button. ControlSurface is NOT scoped to this
        // scene — it lives on AppController for the whole run, so mappings
        // work whether or not this window has ever been opened. Closing it
        // ends only its own view tree, and with it StatusLine's 10 Hz timer;
        // the MIDI engine underneath keeps running.
        Window("MIDI Mapping", id: "midi-osc-mapping") {
            MappingWindow(controlSurface: controller.controlSurface, store: controller.store)
        }
        .defaultSize(width: 720, height: 560)
    }
}

