import AppKit
import CrateCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary is run directly rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct CrateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel?
    @State private var startupError: String?
    @State private var shortcuts: DeckShortcuts?
    @AppStorage("decks.large") private var largeDecks = false
    @AppStorage("sampler.shown") private var showsSampler = false

    var body: some Scene {
        Window("Crate", id: "main") {
            Group {
                if let model {
                    MainView(model: model)
                } else if let startupError {
                    ContentUnavailableView(
                        "Crate could not open its library", systemImage: "exclamationmark.triangle",
                        description: Text(startupError))
                } else {
                    ProgressView()
                }
            }
            // Minimum, ideal and maximum are all given so that the window can answer "how big
            // could this content be?" without measuring every view in it. Without that, each
            // redraw of a playing waveform re-measured the whole window and typing lagged.
            .frame(minWidth: 1100, idealWidth: 1280, maxWidth: .infinity, minHeight: 720, idealHeight: 880, maxHeight: .infinity)
            .preferredColorScheme(.dark)  // one dark look throughout, as DJ software has
            .task { open() }
        }
        .defaultSize(width: 1280, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Folder to Library…") { model?.chooseFolder() }.keyboardShortcut("o")
                Button("New Crate") { model?.newCrate() }.keyboardShortcut("n")
                Button("Grab from TIDAL…") { model.map { $0.grab.open(crate: $0.currentCrate) } }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Export All Crates for rekordbox…") { model.map { $0.exportForRekordbox($0.crates) } }
                Divider()
                Button("Ask the Agent") { model?.draft.focus() }.keyboardShortcut("k")
            }
            CommandMenu("Playback") {
                // Space plays and pauses too, through DeckShortcuts, so that it still types a space in text fields.
                Button("Play / Pause") { model?.player.togglePlayPause() }
                Button("Next in Queue") { model?.player.skip() }.keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Divider()
                Button("Load Selection on Deck A") { model?.loadSelection(on: .a) }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Load Selection on Deck B") { model?.loadSelection(on: .b) }.keyboardShortcut(.rightArrow, modifiers: .command)
                Divider()
                Toggle("Large Decks", isOn: $largeDecks).keyboardShortcut("l", modifiers: [.command, .shift])
                Toggle("Sampler", isOn: $showsSampler).keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Auto DJ") { model?.director.isAuto.toggle() }
                Button(model?.mixer.isRecording == true ? "Stop Recording" : "Record the Mix") { model?.mixer.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Show Recordings in Finder") { NSWorkspace.shared.open(DJMixer.recordingsFolder) }
                Divider()
                Button("Deck Keyboard Shortcuts…") { model?.alert = DeckShortcuts.help }
            }
        }

        Settings {
            if let model { SettingsView(model: model) }
        }
    }

    private func open() {
        guard model == nil else { return }
        do {
            // CRATE_DB points the app at a different library file, for testing.
            let path: String
            if let override = ProcessInfo.processInfo.environment["CRATE_DB"] {
                path = override
            } else {
                path = try LibraryStore.defaultURL().path
            }
            let model = AppModel(store: try LibraryStore(path: path))
            self.model = model
            shortcuts = DeckShortcuts(model: model)
            model.agent.start()
            model.rescan()
            model.analyzePending()
            DebugDriver.runIfRequested(model: model)
        } catch {
            startupError = error.localizedDescription
        }
    }
}
