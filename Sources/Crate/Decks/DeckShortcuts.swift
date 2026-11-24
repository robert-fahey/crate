import AppKit
import CrateCore

/// Keys for working the decks without the mouse. They are ignored while a text
/// field is being typed in, so searching and talking to the agent are unaffected.
///
///     Deck A   Q cue · W play · E sync · A/S nudge back/ahead · Z loop · X/C loop half/double · 1–4 hot cues
///     Deck B   I cue · O play · P sync · K/L nudge back/ahead · , loop · . and / loop half/double · 7–0 hot cues
///     Space    play or pause what is playing
@MainActor
final class DeckShortcuts {
    private var monitor: Any?
    private weak var model: AppModel?

    static let help = """
        Deck A:  Q cue,  W play/pause,  E sync,  A and S nudge back/ahead (hold),  Z loop,  X and C halve/double the loop,  1–4 hot cues
        Deck B:  I cue,  O play/pause,  P sync,  K and L nudge back/ahead (hold),  comma loop,  full stop and slash halve/double the loop,  7–0 hot cues
        Space:  play or pause.   ⌘← and ⌘→ load the selected track on deck A or B.
        """

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        // Only in the main window: a sheet (the grid editor, a confirmation) has its own keys.
        guard let model, let window = NSApp.keyWindow, window.attachedSheet == nil, window.sheetParent == nil else { return false }
        // Typing in a text field: leave the keys alone.
        if window.firstResponder is NSText { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1
        else { return false }
        let a = model.mixer.deck(.a), b = model.mixer.deck(.b)
        let down = event.type == .keyDown

        // Nudges act while held.
        let bends: [String: (DeckModel, Double)] = ["a": (a, -0.04), "s": (a, 0.04), "k": (b, -0.04), "l": (b, 0.04)]
        if let (deck, amount) = bends[key] {
            if !event.isARepeat { deck.bend(down ? amount : 0) }
            return true
        }
        guard down, !event.isARepeat else { return ["q", "w", "e", "z", "x", "c", "i", "o", "p", ",", ".", "/", " "].contains(key) }

        switch key {
        case " ": model.player.togglePlayPause()
        case "q": a.cue()
        case "w": a.togglePlay()
        case "e": a.isSynced.toggle()
        case "z": a.toggleLoop()
        case "x": a.scaleLoop(by: 0.5)
        case "c": a.scaleLoop(by: 2)
        case "1", "2", "3", "4": a.hotCue(Int(key) ?? 1)
        case "i": b.cue()
        case "o": b.togglePlay()
        case "p": b.isSynced.toggle()
        case ",": b.toggleLoop()
        case ".": b.scaleLoop(by: 0.5)
        case "/": b.scaleLoop(by: 2)
        case "7", "8", "9": b.hotCue((Int(key) ?? 7) - 6)
        case "0": b.hotCue(4)
        default: return false
        }
        return true
    }
}
