import AppKit
import CrateCore

/// Drives the running app from a script, for checking it without clicking.
/// Off unless CRATE_DEBUG is set, e.g.
///
///     CRATE_DEBUG='wait:2;ask:boogie;play:0;wait:3;status;snapshot:/tmp/crate.png;quit'
///
/// Steps: wait:<seconds>  ask:<text for the agent>  await (the agent's reply)
///        play:<row>  seek:<seconds>  pause  status  sidebar:<all|tag|crate name>
///        search:<text>  approve  decline  snapshot:<png path>[:settings]  settings:<tab>  texts  quit
/// Output goes to stderr, prefixed with "debug:".
@MainActor
enum DebugDriver {
    static func runIfRequested(model: AppModel) {
        guard let script = ProcessInfo.processInfo.environment["CRATE_DEBUG"], !script.isEmpty else { return }
        watchForStalls()
        Task { @MainActor in
            for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                await run(parts[0], argument, model: model)
            }
        }
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("debug: \(text)\n".utf8))
    }

    private static var savedFrame: NSRect?

    // The longest the main thread has gone without running, which is how long the interface stood still.
    private static var lastTurn = CFAbsoluteTimeGetCurrent()
    private static var worstStall = 0.0

    /// A timer that should fire every 4 ms: when the main thread is held up, the gap between two firings is the stall.
    private static func watchForStalls() {
        let timer = Timer(timeInterval: 0.004, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CFAbsoluteTimeGetCurrent()
                worstStall = max(worstStall, now - lastTurn - 0.004)
                lastTurn = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func run(_ command: String, _ argument: String, model: AppModel) async {
        switch command {
        case "wait":
            await sleep(Double(argument) ?? 1)
        case "ask":
            // Wait for the agent to be ready, as a person would.
            for _ in 0..<100 where model.agent.phase != .ready { await sleep(0.1) }
            log("agent phase \(model.agent.phase)")
            model.ask(argument)
        case "await":
            for _ in 0..<600 where model.agent.phase == .working && model.agent.pendingCommand == nil { await sleep(0.1) }
            if let last = model.agent.messages.last {
                log("reply: \(last.text.prefix(600))")
                for tool in last.tools { log("tool: \(tool.summary) [\(tool.state)]") }
            }
        case "approve", "decline":
            for _ in 0..<50 where model.agent.pendingCommand == nil { await sleep(0.1) }
            log("command pending: \(model.agent.pendingCommand?.command ?? "none")")
            model.agent.resolveCommand(approved: command == "approve")
        case "play":
            let row = Int(argument) ?? 0
            guard model.tracks.indices.contains(row) else { return log("no row \(row); \(model.tracks.count) tracks") }
            model.play(model.tracks[row])
        case "seek":
            model.player.seek(to: Double(argument) ?? 0)
        case "pause":
            model.player.togglePlayPause()
        case "status":
            log("tracks \(model.tracks.count), crates \(model.crates.map { "\($0.name)(\($0.trackCount))" }), activity \(model.activity ?? "-")")
            log("player \(model.player.statusJSON().encoded())")
            log(String(format: "level %.1f dBFS, waveform %d bins", model.player.localLevel, model.mixer.focus.peaks?.count ?? 0))
        case "midi":
            // midi:90 0B 7F,90 0B 00 — as if those came from the (pretend) controller.
            for message in argument.split(separator: ",") { FakeController.shared?.send(hex: String(message).trimmingCharacters(in: .whitespaces)) }
            await sleep(0.15)
        case "controller":
            log("controller \(model.controller.name ?? "none") | last: \(model.controller.lastEvent ?? "-") | output \(model.mixer.outputName) headphones \(model.mixer.hasHeadphones) | cue \(model.mixer.decks.map(\.cueMonitor)) mix \(model.mixer.headphoneMix) crossfader \(String(format: "%.2f", model.mixer.crossfader)) faders \(model.mixer.decks.map { String(format: "%.2f", $0.fader) }) | selected \(model.selectedTracks.first?.title ?? "-")")
            if let fake = FakeController.shared { log("controller received: \(fake.report())") }
        case "sharing":
            let sharing = model.sharing
            log("sharing \(sharing.isOn ? "on" : "off") as \(sharing.deviceName) port \(sharing.port) | connected: \(sharing.peers.map { "\($0.device.name)@\($0.host):\($0.port)" }) | problem: \(sharing.problem ?? "-") | tracks here \(model.tracks.filter(\.isOnThisMac).count) elsewhere \(model.away.count) unreachable \(model.unavailable.count) | fetching \(sharing.fetching.count)")
        case "waitfor":
            // waitfor:tracks:20, waitfor:crate:Name or waitfor:peer — up to two minutes.
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            for _ in 0..<1200 {
                switch parts.first {
                case "tracks" where model.tracks.count >= Int(parts.last ?? "") ?? 1: return
                case "crate" where model.crates.contains(where: { $0.name == parts.last }): return
                case "peer" where !model.sharing.peers.isEmpty: return
                default: await sleep(0.1)
                }
            }
            log("waitfor \(argument): gave up")
        case "mkcrate":
            _ = try? model.store.createCrate(name: argument)
            model.reload()
        case "addtocrate", "removefromcrate":
            // addtocrate:Name:row — the row of the track list as it is now.
            let parts = argument.split(separator: ":").map(String.init)
            guard parts.count == 2, let row = Int(parts[1]), model.tracks.indices.contains(row),
                  let crate = model.crates.first(where: { $0.name == parts[0] })
            else { return log("\(command):<crate>:<row>") }
            if command == "addtocrate" {
                model.add([model.tracks[row].id], to: crate)
            } else {
                _ = try? model.store.removeFromCrate(id: crate.id, trackIDs: [model.tracks[row].id])
            }
        case "crates":
            for crate in model.crates {
                var query = TrackQuery()
                query.crateID = crate.id
                log("crate \(crate.name): \(((try? model.store.tracks(query)) ?? []).map(\.title))")
            }
        case "stall":
            // The longest the interface has stood still since this was last asked.
            log(String(format: "longest stall %.0f ms%@", worstStall * 1000, argument.isEmpty ? "" : " (\(argument))"))
            worstStall = 0
        case "load":
            // load:A:3 puts row 3 on deck A.
            let parts = argument.split(separator: ":")
            guard parts.count >= 2, let row = Int(parts[1]), model.tracks.indices.contains(row) else { return log("load:<A|B>:<row>[:nowait]") }
            if parts.count > 2 {
                // As a click sends it: the script carries straight on while the track is on its way.
                model.load(model.tracks[row], on: parts[0] == "B" ? .b : .a)
            } else {
                // Waits for the track to land, so the next step finds it there. The interface is not held up meanwhile.
                await model.loadAndWait(model.tracks[row], on: parts[0] == "B" ? .b : .a)
            }
        case "deck":
            // deck:B:play, deck:A:sync, deck:A:seek=90, deck:B:tempo=0.03 …
            let parts = argument.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return log("deck:<A|B>:<action>") }
            let deck = model.mixer.deck(parts[0] == "B" ? .b : .a)
            let action = parts[1].split(separator: "=", maxSplits: 1)
            let value = action.count > 1 ? Double(action[1]) ?? 0 : 0
            switch String(action[0]) {
            case "play": deck.togglePlay()
            case "cue": deck.cue()
            case "cuedown": deck.cueDown()
            case "cueup": deck.cueUp()
            case "sync": deck.isSynced.toggle()
            case "master": deck.toggleMaster()
            case "key": deck.keyLock.toggle()
            case "loop": deck.toggleLoop()
            case "seek": deck.seek(to: value)
            case "tempo": deck.setTempoOffset(value)
            case "hotcue": deck.hotCue(Int(value))
            case "echo": deck.echoOn.toggle()
            case "low": deck.eq[0] = value
            case "kill": deck.kills[Int(value)].toggle()
            case "filter": deck.filter = value
            case "fader": deck.fader = value
            case "stop": deck.tapeStop()
            default: log("unknown deck action \(action[0])")
            }
        case "grab":
            // grab:folder=<path>  grab:find=<line>|<line>  grab:pick=<row>,<match or ->  grab:go  grab:tidal (the selected
            // TIDAL tracks)  grab:wait  grab:list  grab:show  grab:hide
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            let grab = model.grab
            switch parts[0] {
            case "folder": grab.folder = value
            case "find":
                grab.open(crate: model.currentCrate)
                grab.text = value.replacingOccurrences(of: "|", with: "\n")
                grab.find()
            case "pick":
                let numbers = value.split(separator: ",").map(String.init)
                guard numbers.count == 2, let row = Int(numbers[0]), grab.rows.indices.contains(row) else { return log("no such row") }
                grab.choose(Int(numbers[1]).flatMap { grab.rows[row].matches.indices.contains($0) ? grab.rows[row].matches[$0].id : nil }, for: grab.rows[row].id)
            case "go": grab.grab()
            case "tidal": grab.grab(streaming: model.selectedTracks)
            case "missing": grab.open(finding: model.selectedTracks, crate: model.currentCrate)
            case "show": grab.isShown = true
            case "hide": grab.isShown = false
            case "wait":
                for _ in 0..<3000 where grab.isBusy { await sleep(0.1) }
            default: break
            }
            log("grab: \(grab.stage)\(grab.isBusy ? ", busy" : "")\(grab.problem.map { ", problem: \($0)" } ?? "")\(grab.summary.map { ", \($0)" } ?? "")")
            if parts[0] == "list" || parts[0] == "wait" {
                for (index, row) in grab.rows.enumerated() {
                    log("  \(index) [\(row.state)] asked “\(row.asked)” chosen: \(row.chosen.map(GrabRowText.line) ?? "none")")
                    if parts[0] == "list" { for (number, hit) in row.matches.enumerated() { log("      \(number): \(GrabRowText.line(hit))") } }
                }
            }
        case "rekordbox":
            // rekordbox:<crate name|all>:<path> writes the export without asking where.
            let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return log("rekordbox:<crate|all>:<path>") }
            let crates = parts[0] == "all" ? model.crates : model.crates.filter { $0.name == parts[0] }
            log("rekordbox: " + model.exportForRekordbox(crates, to: URL(fileURLWithPath: parts[1])).replacingOccurrences(of: "\n\n", with: " | "))
        case "mixplan":
            // mixplan:<crate> opens the mix editor; mixplan:<crate>:suggest saves Crate's own transition for every pair
            // that has none; :list prints them; :play plays the crate as a mix; :preview:<n> tries the nth transition;
            // mixplan:close shuts the editor.
            let parts = argument.split(separator: ":").map(String.init)
            if parts.first == "close" { model.mixEditing = nil; return }
            guard let crate = model.crates.first(where: { $0.name.caseInsensitiveCompare(parts.first ?? "") == .orderedSame }) else { return log("no such crate") }
            let tracks = ((try? model.store.tracks(inCrate: crate.id)) ?? []).filter { $0.source == .local }
            func steps() -> [MixStep] { (try? model.store.mixSteps(crate: crate.id)) ?? [] }
            switch parts.count > 1 ? parts[1] : "open" {
            case "suggest":
                var added: [MixStep] = []
                for (from, to) in zip(tracks, tracks.dropFirst()) where !steps().contains(where: { $0.from == from.id && $0.to == to.id }) {
                    added.append(MixPlanner.suggest(from: MixSide(track: from, store: model.store), to: MixSide(track: to, store: model.store)))
                }
                try? model.store.setMixSteps(crate: crate.id, added)
            case "clear": try? model.store.removeMixSteps(crate: crate.id)
            case "play": await model.director.playMix(crate)
            case "nearout":
                // Winds the playing deck on to twelve seconds before the point where its saved transition starts.
                if let deck = model.mixer.decks.first(where: \.isPlaying), let id = deck.track?.id, let step = steps().first(where: { $0.from == id }) {
                    deck.seek(to: max(0, step.outAt - 12))
                }
            case "preview":
                let saved = steps()
                let index = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                if tracks.indices.contains(index + 1), let step = saved.first(where: { $0.from == tracks[index].id && $0.to == tracks[index + 1].id }) {
                    do { try await model.director.preview(step) } catch { log("preview refused: \(error.localizedDescription)") }
                }
            case "list": break
            default: model.mixEditing = crate.id
            }
            let titles = Dictionary(tracks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
            log("mix of \(crate.name): " + zip(tracks, tracks.dropFirst()).map { from, to in
                guard let step = steps().first(where: { $0.from == from.id && $0.to == to.id }) else { return "\(from.title.prefix(14)) → \(to.title.prefix(14)): -" }
                return String(format: "%@ → %@: %@ %.0f beats out %.1f in %.1f (%@)", String((titles[step.from] ?? "").prefix(14)), String((titles[step.to] ?? "").prefix(14)), step.style.rawValue, step.beats, step.outAt, step.inAt, step.author.rawValue)
            }.joined(separator: " | "))
        case "cues":
            // cues:A opens the cue editor on deck A; cues:close shuts it. cues:A:suggest fills the empty pads
            // with Crate's suggestions; cues:A:list prints the pads.
            let parts = argument.split(separator: ":").map(String.init)
            if parts.first == "close" { model.cueEditing = nil; return }
            let deck = model.mixer.deck(parts.first == "B" ? .b : .a)
            switch parts.count > 1 ? parts[1] : "open" {
            case "suggest":
                deck.setCuePoints(CueSuggester.filling(Array(deck.cuePoints.values), with: deck.suggestedCues(), beat: 0.5))
            case "clear": deck.setCuePoints([])
            case "list": break
            default: model.cueEditing = deck.id
            }
            log("cues on \(deck.id.name): " + deck.cuePoints.values.sorted { $0.slot < $1.slot }.map {
                String(format: "%d %@ %.2f%@", $0.slot, $0.name.isEmpty ? "-" : $0.name, $0.position, $0.loopEnd.map { String(format: " loop to %.2f", $0) } ?? "")
            }.joined(separator: " | "))
        case "sampler":
            // sampler:show, sampler:hide, sampler:load:<pad>:<row>, sampler:take:<pad>:<A|B>, sampler:hit:<pad>,
            // Pads count from 1: 1 to 8 are deck A's bank, 9 to 16 deck B's.
            // sampler:loop:<pad>, sampler:sync:<pad>, sampler:beats:<pad>:<beats>, sampler:file:<pad>:<path>, sampler:quantize:<off|beats>,
            // sampler:stop, sampler:list. Pads count from 1.
            let parts = argument.split(separator: ":").map(String.init)
            let sampler = model.mixer.sampler!
            let pad = (parts.count > 1 ? Int(parts[1]) ?? 1 : 1) - 1
            switch parts.first {
            case "show": UserDefaults.standard.set(true, forKey: "sampler.shown")
            case "hide": UserDefaults.standard.set(false, forKey: "sampler.shown")
            case "load":
                if parts.count > 2, let row = Int(parts[2]), model.tracks.indices.contains(row) { sampler.load(model.tracks[row], on: pad) }
                for _ in 0..<100 where sampler.pads.indices.contains(pad) && sampler.pads[pad].isLoading { await sleep(0.1) }
            case "take": sampler.capture(from: model.mixer.deck(parts.last == "B" ? .b : .a), on: pad)
            case "hit": sampler.hit(pad)
            case "loop": sampler.setLoops(!sampler.pads[pad].loops, on: pad)
            case "sync": sampler.setSync(!sampler.pads[pad].syncs, on: pad)
            case "bank":
                // sampler:bank:<A|B>:new, :use:<name>, :rename:<name>, :duplicate, :delete, :tie, :untie. Then the banks are listed.
                let deck: DeckID = parts.count > 1 && parts[1] == "B" ? .b : .a
                let name = parts.count > 3 ? parts[3...].joined(separator: ":") : ""
                switch parts.count > 2 ? parts[2] : "" {
                case "new": sampler.newBank(on: deck)
                case "use": if let bank = sampler.banks.first(where: { $0.name == name }) { sampler.show(bank.id, on: deck) }
                case "rename": sampler.renameBank(on: deck, to: name)
                case "duplicate": sampler.duplicateBank(on: deck)
                case "delete": sampler.deleteBank(on: deck)
                case "tie": sampler.setBankTied(true, on: deck)
                case "untie": sampler.setBankTied(false, on: deck)
                default: break
                }
                for _ in 0..<100 where sampler.pads.contains(where: \.isLoading) { await sleep(0.1) }
                log("sample banks: " + sampler.banks.map { bank in
                    let on = DeckID.allCases.first { sampler.bankOn[$0.rawValue] == bank.id }
                    let tied = on.map { sampler.bankIsTied[$0.rawValue] } ?? false
                    return "\(bank.name)" + (on.map { " on \($0.name)" } ?? "") + (tied ? " tied to its track" : "") + " (\(bank.pads.compactMap { $0 }.count) pads)"
                }.joined(separator: " | "))
            case "quantize":
                // sampler:quantize:off, or a grid in beats: 0.25, 0.5, 1 or 4 (a bar).
                if parts.count > 1, let size = Double(parts[1]), SamplerSync.grids.contains(size) {
                    sampler.quantum = size
                    sampler.isQuantized = true
                } else {
                    sampler.isQuantized = false
                }
            case "beats": if parts.count > 2, let beats = Int(parts[2]) { sampler.setBeats(beats, on: pad) }
            case "file":
                if parts.count > 2 { sampler.load(path: parts[2...].joined(separator: ":"), on: pad) }
                for _ in 0..<100 where sampler.pads.indices.contains(pad) && sampler.pads[pad].isLoading { await sleep(0.1) }
            case "stop": sampler.stop()
            default: break
            }
            log("sampler: quantize " + (sampler.isQuantized ? SamplerModel.gridName(sampler.quantum) : "off") + " | " + sampler.pads.filter(\.isLoaded).map { pad in
                var text = String(format: "%@%d %@ %.2fs%@", pad.deck.name, pad.slot + 1, pad.name, pad.seconds, pad.loops ? " loop" : "")
                if pad.syncs, pad.loops {
                    let state = sampler.syncState(of: pad.id)
                    text += " sync" + (pad.bpm.map { String(format: " %.1f BPM", $0) } ?? "") + String(format: " x%.3f", state.rate)
                    if let error = state.error { text += String(format: " off by %+.3f beats", error) }
                }
                if pad.isPlaying { text += String(format: " playing %.0f%%", pad.progress * 100) }
                return text
            }.joined(separator: " | ") + (sampler.problem.map { " | problem: \($0)" } ?? ""))
        case "grid":
            // grid:A opens the grid editor on deck A; grid:close shuts it.
            model.gridEditing = argument == "close" ? nil : (argument == "B" ? .b : .a)
        case "gridedit":
            // gridedit:A:move=32,16.08 · add=40 · remove=40 · straight=64 · tempo=32,124 · metronome · undo · info
            let parts = argument.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return log("gridedit:<A|B>:<edit>") }
            let deck = model.mixer.deck(parts[0] == "B" ? .b : .a)
            let edit = parts[1].split(separator: "=", maxSplits: 1)
            let values = edit.count > 1 ? edit[1].split(separator: ",").compactMap { Double($0) } : []
            switch String(edit[0]) {
            case "move" where values.count == 2:
                deck.beginGridDrag()
                deck.dragGrid { $0.movingMarker(atBeat: Int(values[0]), to: values[1]) }
                deck.endGridDrag()
            case "add" where values.count == 1: deck.editGrid { $0.addingMarker(atBeat: Int(values[0])) }
            case "remove" where values.count == 1: deck.editGrid { $0.removingMarker(atBeat: Int(values[0])) }
            case "straight" where values.count == 1: deck.editGrid { $0.straightened(from: Int(values[0])) }
            case "tempo" where values.count == 2: deck.editGrid { $0.settingSegmentTempo(after: Int(values[0]), bpm: values[1]) }
            case "metronome": deck.metronome.toggle()
            case "undo": deck.undoGrid()
            case "info": break
            default: return log("unknown grid edit \(parts[1])")
            }
            if let grid = deck.grid {
                log(String(
                    format: "grid %@: %d beats, %d markers %@, %.2f BPM, %@, transients %d, undo %@, beat 32 at %.3f, beat 48 at %.3f",
                    deck.id.name, grid.count, grid.markers.count, "\(grid.markers.prefix(6))", grid.bpm, grid.isSteady ? "steady" : "drifts",
                    deck.transients.count, deck.canUndoGrid ? "yes" : "no", grid.beats[min(32, grid.count - 1)], grid.beats[min(48, grid.count - 1)]))
            }
        case "mix":
            // mix:bass_swap:16 mixes out of the playing deck into the other at the next bar.
            let parts = argument.split(separator: ":")
            var request = MixRequest()
            request.style = Transition.Style(rawValue: String(parts.first ?? "bass_swap")) ?? .bassSwap
            request.beats = parts.count > 1 ? Double(parts[1]) ?? 32 : 32
            request.start = .nextBar
            do {
                log("mix scheduled: \(try await model.director.schedule(request).encoded())")
            } catch {
                log("mix refused: \(error.localizedDescription)")
            }
        case "auto":
            model.director.isAuto.toggle()
            log("auto DJ \(model.director.isAuto ? "on" : "off"), \(model.player.upNext.count) up next")
        case "mixstatus":
            log("mix: \(model.director.summary ?? "idle") | auto: \(model.director.activity ?? "-") | up next \(model.player.upNext.count)")
        case "window":
            // window:2300x1300 resizes the main window for a snapshot; window:restore puts it back.
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil }) else { return }
            if argument == "restore" {
                if let frame = savedFrame { window.setFrame(frame, display: true) }
            } else {
                let parts = argument.split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2 else { return log("window:<width>x<height>") }
                if savedFrame == nil { savedFrame = window.frame }
                let origin = window.screen?.visibleFrame.origin ?? .zero
                window.setFrame(NSRect(x: origin.x, y: origin.y, width: parts[0], height: parts[1]), display: true)
                log("window \(Int(window.frame.width))x\(Int(window.frame.height))")
            }
        case "large":
            UserDefaults.standard.set(argument != "off", forKey: "decks.large")
        case "offers":
            // What the agent bar is offering, and what its text field says. offers:1 clicks the second offer.
            let context = model.agentContext()
            if let index = Int(argument), context.suggestions.indices.contains(index) { model.use(context.suggestions[index]) }
            log("conversation “\(model.agent.title)” | offers: \(context.suggestions.map { $0.label + ($0.sendsAtOnce ? " (asks)" : " (fills)") }.joined(separator: ", ")) | field: \(model.draft.text.isEmpty ? context.placeholder : "typed “\(model.draft.text)”")")
        case "select":
            // select:0,3 selects those rows of the list; select: clears the selection.
            let rows = argument.split(separator: ",").compactMap { Int($0) }.filter { model.tracks.indices.contains($0) }
            model.selection = Set(rows.map { model.tracks[$0].id })
        case "history":
            log("history: \(model.agent.messages.count) messages; requests \(model.agent.pastRequests); last: \(model.agent.messages.last?.text.prefix(80) ?? "-")")
        case "plays":
            // plays prints the mix history; plays:show puts it in the window.
            if argument == "show" { model.sidebar = .history }
            log("mix history: \(model.history.playCount) plays in \(model.history.sessions.count) sessions")
            for session in model.history.sessions.prefix(3) {
                log("  session \(HistoryView.day(session.startedAt)) \(HistoryView.span(session)): " + session.plays.map { play in
                    "[\(play.deck)] \(model.history.tracks[play.trackID]?.title ?? "?")"
                        + (play.fromTrackID.map { " (from \(model.history.tracks[$0]?.title ?? "?"))" } ?? "")
                }.joined(separator: " → "))
            }
        case "volume":
            model.mixer.masterVolume = Double(argument) ?? 1
        case "crossfader":
            model.mixer.crossfader = Double(argument) ?? 0
        case "meters":
            // meters:-3,2 has the master meter show those levels, left and right, in decibels: scripted
            // checks play in silence, which leaves it dark. meters:off goes back to the mix's own.
            let levels = argument.split(separator: ",").compactMap { Float($0) }.map { Float(pow(10, Double($0) / 20)) }
            model.mixer.masterPeaksForTesting = levels.count == 2 ? (levels[0], levels[1]) : nil
        case "record":
            model.mixer.toggleRecording()
            log("recording \(model.mixer.isRecording) → \(model.mixer.lastRecording?.path ?? "-")")
        case "decks":
            for deck in model.mixer.decks {
                let state = deck.deck.state()
                log(String(
                    format: "deck %@: %@ | %@ at %.2fs speed %.3f | bpm %@ tempo %+.2f%% | sync %@ master %@ phase %@ | grid %@ wave %@ | level %.2f",
                    deck.id.name, deck.track?.title ?? "(empty)", state.isPlaying ? "playing" : "stopped", state.position, state.speed,
                    deck.bpm.map { String(format: "%.2f", $0) } ?? "-", deck.tempoOffset * 100, deck.isSynced ? "on" : "off",
                    deck.isMaster ? "yes" : "no", deck.phaseError.map { String(format: "%+.3f", $0) } ?? "-",
                    deck.grid.map { "\($0.count) beats" } ?? "none", deck.detail == nil ? "none" : "yes", deck.level)
                    + (deck.isCueing ? " | cue held" : ""))
            }
            log(String(
                format: "master level %.2f (%.1f dB) lights %d/%d over %@ | channel lights %@",
                model.mixer.masterLevel, MeterScale.decibels(model.mixer.masterLevel), model.mixer.masterMeters[0].lit,
                model.mixer.masterMeters[1].lit, model.mixer.isClipping ? "yes" : "no",
                model.mixer.decks.map { "\($0.meter.lit)" }.joined(separator: "/")))
        case "sidebar":
            if argument == "all" {
                model.sidebar = .all
            } else if argument == "tag" {
                model.sidebar = .needsTagging
            } else if let crate = model.crates.first(where: { $0.name.caseInsensitiveCompare(argument) == .orderedSame }) {
                model.sidebar = .crate(crate.id)
            }
        case "sort":
            // sort:key or sort:bpm:desc, as if that column header had been clicked; then the top of the list.
            let parts = argument.split(separator: ":").map(String.init)
            let order: SortOrder = parts.last == "desc" ? .reverse : .forward
            switch parts.first {
            case "bpm": model.sortOrder = [KeyPathComparator(\Track.sortBPM, order: order)]
            case "key": model.sortOrder = [KeyPathComparator(\Track.sortKey, order: order)]
            case "artist": model.sortOrder = [KeyPathComparator(\Track.artist, order: order)]
            default: break
            }
            log("sorted \(TrackSorting.description(of: model.sortLevels) ?? "by one column"): "
                + model.tracks.prefix(14).map { "\($0.bpm.map { String(format: "%.1f", $0) } ?? "-") \($0.key ?? "-")" }.joined(separator: " | "))
        case "search":
            model.searchText = argument
        case "mouse":
            // mouse:259,283:down, :move, :up, or :double — the mouse at a point measured from the top left corner
            // of the window (of the sheet, when one is up), sent to it as a real click would be. For buttons
            // that act while held and for things that are dragged. Set the window's size first so the point is
            // where it is expected to be.
            let parts = argument.split(separator: ":").map(String.init)
            let at = parts.first?.split(separator: ",").compactMap { Double($0) } ?? []
            guard parts.count == 2, at.count == 2,
                  let main = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && $0.contentView != nil })
            else { return log("mouse:<x>,<y>:<down|move|up|double>") }
            let window = main.attachedSheet ?? main
            // A window that is not in front takes its first click only to come forward.
            if !main.isKeyWindow, !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                await sleep(0.4)
            }
            func post(_ type: NSEvent.EventType, clicks: Int = 1) {
                if let event = NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: at[0], y: window.frame.height - at[1]), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) {
                    // Through the app's queue, as the window server delivers it: controls that follow the mouse
                    // themselves (every SwiftUI button) pick the release up from there.
                    NSApp.postEvent(event, atStart: false)
                }
            }
            switch parts[1] {
            case "down": post(.leftMouseDown)
            case "move": post(.leftMouseDragged)
            case "up": post(.leftMouseUp)
            case "double":
                post(.leftMouseDown)
                post(.leftMouseUp)
                post(.leftMouseDown, clicks: 2)
                post(.leftMouseUp, clicks: 2)
            default: log("mouse:<x>,<y>:<down|move|up|double>")
            }
        case "settings":
            // settings:audio opens the Settings window on that tab.
            UserDefaults.standard.set(argument, forKey: "settings.tab")
            let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.title.hasPrefix("Settings") })
            if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) } else { log("no Settings menu item") }
        case "snapshot":
            snapshot(to: argument)
        case "texts":
            // Every piece of text the window exposes to accessibility, e.g. to check the sidebar.
            var found: [String] = []
            func walk(_ element: Any, depth: Int) {
                guard depth < 40, let object = element as? NSAccessibilityProtocol else { return }
                for candidate in [object.accessibilityLabel(), object.accessibilityValue() as? String, object.accessibilityTitle()] {
                    if let text = candidate, !text.isEmpty, text.count < 60, !found.contains(text) { found.append(text) }
                }
                for child in object.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
            }
            for window in NSApp.windows where window.isVisible { walk(window, depth: 0) }
            log("texts: " + found.joined(separator: " | "))
        case "quit":
            model.agent.stop()
            await sleep(0.3)
            NSApp.terminate(nil)
        default:
            log("unknown step \(command)")
        }
    }

    /// The window as the screen shows it, sidebar and toolbar included. macOS lets an app
    /// photograph its own windows without screen-recording permission. The function is no
    /// longer offered to Swift, so it is looked up by name; nil if it has gone or refuses.
    private static func photograph(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        // This window alone (8), without its shadow (1), at full resolution (8).
        guard let image = capture(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue(),
              image.width > 1, image.height > 1
        else { return nil }
        return image
    }

    /// Saves the app's own window as a PNG. Needs no screen-recording permission.
    /// A photograph of the window when macOS allows it; otherwise drawn from the layer
    /// tree, which leaves the sidebar and toolbar blank.
    private static func snapshot(to path: String) {
        // A sheet is its own window; when one is up, that is what there is to see.
        // snapshot:<path>:settings takes the Settings window instead.
        var path = path
        var wantsSettings = false
        if path.hasSuffix(":settings") {
            path.removeLast(":settings".count)
            wantsSettings = true
        }
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }
        let settings = windows.first(where: { $0.identifier?.rawValue.contains("Settings") == true })
        let main = wantsSettings ? settings : windows.first(where: { $0 != settings }) ?? windows.first
        guard let window = main?.attachedSheet ?? main ?? (wantsSettings ? nil : NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })),
              let view = window.contentView?.superview ?? window.contentView, let layer = view.layer
        else { return log("no window to snapshot") }
        if let image = photograph(window),
           let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
           (try? data.write(to: URL(fileURLWithPath: path))) != nil {
            return log("snapshot \(path) \(image.width)x\(image.height) pixels, from the screen")
        }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return log("could not create a drawing context") }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return log("could not encode the snapshot") }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            log("snapshot \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
        } catch {
            log("snapshot failed: \(error.localizedDescription)")
        }
    }
}
