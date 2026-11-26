import AppKit
import CoreMIDI
import CrateCore
import Observation

/// A DJ controller plugged into the Mac: the Pioneer DJ DDJ-FLX4.
///
/// Finds it over MIDI, turns what its buttons, wheels and faders send into the
/// same actions the window's controls perform, and keeps its lights and level
/// meters showing what the decks are doing.
@MainActor
@Observable
final class ControllerModel {
    private(set) var name: String?
    /// The last thing the controller sent, for checking a control does what it should.
    private(set) var lastEvent: String?
    var isConnected: Bool { name != nil }
    /// For a tempo slider that turns out to run the other way.
    var tempoReversed: Bool { didSet { UserDefaults.standard.set(tempoReversed, forKey: "controller.tempoReversed") } }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var input = MIDIPortRef()
    @ObservationIgnored private var output = MIDIPortRef()
    @ObservationIgnored private var source = MIDIEndpointRef()
    @ObservationIgnored private var destination = MIDIEndpointRef()
    @ObservationIgnored private var decoder = DDJFLX4.Decoder()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0

    // What the hands are doing.
    @ObservationIgnored private var touching = [false, false]
    @ObservationIgnored private var scratchTarget = [0.0, 0.0]
    @ObservationIgnored private var bendReset: [Task<Void, Never>?] = [nil, nil]
    @ObservationIgnored private var loopIn: [Double?] = [nil, nil]
    @ObservationIgnored private var loopHold: [Task<Void, Never>?] = [nil, nil]
    @ObservationIgnored private var padMode: [PadMode] = [.hotCue, .hotCue]
    /// Whether each tempo slider has hold of its deck's tempo. One that does not (the deck was
    /// synced, or set from the screen) is ignored until it is moved to where the tempo is.
    @ObservationIgnored private var sliderHolds = [false, false]
    @ObservationIgnored private var sliderWas: [Double?] = [nil, nil]
    @ObservationIgnored private var sliderSet: [Double?] = [nil, nil]
    @ObservationIgnored private var lit: [ControlLight: Bool] = [:]
    @ObservationIgnored private var meters = [-1, -1]

    /// Seconds of music per tick of the jog wheel: a turn of the platter is a turn of a record at 33⅓.
    private static let secondsPerTick = 1.8 / 720

    init(app: AppModel) {
        self.app = app
        tempoReversed = UserDefaults.standard.bool(forKey: "controller.tempoReversed")
        MIDIClientCreateWithBlock("Crate" as CFString, &client) { [weak self] _ in
            // A device was plugged in or pulled out.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.findController() } }
        }
        MIDIInputPortCreateWithProtocol(client, "Crate in" as CFString, ._1_0, &input) { [weak self] list, _ in
            // On a MIDI thread: pick out the three-byte messages and hand them to the main thread, in order.
            var messages: [(UInt8, UInt8, UInt8)] = []
            for packet in list.unsafeSequence() {
                let words = MIDIEventPacket.WordCollection(packet)
                for word in words where word >> 28 == 0x2 {
                    messages.append((UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0x7F), UInt8(word & 0x7F)))
                }
            }
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { for message in messages { self?.receive(message.0, message.1, message.2) } }
            }
        }
        MIDIOutputPortCreate(client, "Crate out" as CFString, &output)
        findController()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Finding it

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value)
        return (value?.takeRetainedValue() as String?) ?? ""
    }

    private func findController() {
        let sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
        let destinations = (0..<MIDIGetNumberOfDestinations()).map(MIDIGetDestination)
        let found = sources.first { DDJFLX4.isThisController(Self.name(of: $0)) }
        if found != source || found == nil {
            if source != 0 { MIDIPortDisconnectSource(input, source) }
            source = found ?? 0
            if source != 0 { MIDIPortConnectSource(input, source, nil) }
        }
        destination = destinations.first { DDJFLX4.isThisController(Self.name(of: $0)) } ?? 0
        let newName = source != 0 ? Self.name(of: source) : nil
        if newName != name {
            name = newName
            decoder = DDJFLX4.Decoder()
            lit = [:]
            meters = [-1, -1]
            sliderHolds = [false, false]
            if newName != nil { hello() }
        }
    }

    // MARK: Sending

    private func send(_ bytes: [UInt8]) {
        guard destination != 0, bytes.count == 3 else { return }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        let word = UInt32(0x2) << 28 | UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, [word])
        MIDISendEventList(output, destination, &list)
    }

    /// The "tell me where everything is" message. It is a system-exclusive message, which goes out in pieces of up to six bytes.
    private func hello() {
        guard destination != 0 else { return }
        let body = Array(DDJFLX4.hello.dropFirst().dropLast())
        var list = MIDIEventList()
        var packet = MIDIEventListInit(&list, ._1_0)
        let pieces = stride(from: 0, to: body.count, by: 6).map { Array(body[$0..<min(body.count, $0 + 6)]) }
        for (index, piece) in pieces.enumerated() {
            // 0: the whole message in one piece. 1: first piece. 2: a middle piece. 3: last piece.
            let place: UInt32 = pieces.count == 1 ? 0 : index == 0 ? 1 : index == pieces.count - 1 ? 3 : 2
            var bytes = piece + [UInt8](repeating: 0, count: 6 - piece.count)
            let first = UInt32(0x3) << 28 | place << 20 | UInt32(piece.count) << 16 | UInt32(bytes[0]) << 8 | UInt32(bytes[1])
            bytes.removeFirst(2)
            let second = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 2, [first, second])
        }
        MIDISendEventList(output, destination, &list)
    }

    // MARK: Lights and meters

    private func tick() {
        guard isConnected, let mixer = app?.mixer else { return }
        ticks += 1
        // The controller wants to hear from its software a few times a second.
        if ticks % 4 == 0 { hello() }
        // Now and then every light is sent afresh, in case one was missed.
        if ticks % 60 == 0 { lit = [:] }
        for deck in mixer.decks {
            let id = deck.id
            set(.play(id), deck.isPlaying)
            set(.cue(id), deck.isLoaded)
            set(.sync(id), deck.isSynced || (deck.isMaster && mixer.decks.contains { $0.isSynced }))
            set(.headphoneCue(id), deck.cueMonitor)
            set(.loaded(id), deck.isLoaded)
            let looping = deck.loop != nil
            set(.loopIn(id), looping || loopIn[id.rawValue] != nil)
            set(.loopOut(id), looping)
            set(.reloop(id), looping)
            set(.effect(id), deck.echoOn)
            let mode = padMode[id.rawValue]
            for kind in [PadMode.hotCue, .beatLoop, .beatJump, .sampler] { set(.padMode(id, kind), kind == mode) }
            for slot in 0..<SampleBank.size { set(.sample(id, slot), mode == .sampler && mixer.sampler.pads[Sampler.pad(slot, of: id)].isLoaded) }
            for slot in 1...8 { set(.hotCue(id, slot), mode == .hotCue && deck.cues[slot] != nil) }
            let length = deck.loop.flatMap { loop in deck.grid.map { $0.beatPosition(at: loop.upperBound) - $0.beatPosition(at: loop.lowerBound) } }
            for (index, beats) in DDJFLX4.Decoder.loopBeats.enumerated() {
                set(.beatLoop(id, index), mode == .beatLoop && length.map { abs($0 - beats) < 0.02 } == true)
            }
            let meter = DDJFLX4.meter(id, level: Double(deck.level))
            if Int(meter[2]) != meters[id.rawValue] {
                meters[id.rawValue] = Int(meter[2])
                send(meter)
            }
        }
    }

    private func set(_ light: ControlLight, _ on: Bool) {
        guard lit[light] != on else { return }
        lit[light] = on
        let message = DDJFLX4.message(for: light, on: on)
        if !message.isEmpty { send(message) }
    }

    // MARK: Receiving

    func receive(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) {
        guard let event = decoder.decode(status: status, data1: data1, data2: data2) else { return }
        handle(event)
        // Faders and wheels chatter; only the deliberate things are worth showing.
        switch event {
        case .jogScratch, .jogBend, .jogSearch, .tempo, .trim, .eq, .fader, .filter, .crossfader, .headphoneMix: break
        default: lastEvent = "\(event)"
        }
    }

    private func handle(_ event: ControlEvent) {
        guard let app else { return }
        let mixer = app.mixer
        switch event {
        case .play(let id): mixer.deck(id).togglePlay()
        case .cue(let id, let down): if down { mixer.deck(id).cueDown() } else { mixer.deck(id).cueUp() }
        case .jumpToStart(let id): mixer.deck(id).seek(to: 0)
        case .sync(let id): mixer.deck(id).isSynced.toggle()
        case .master(let id): mixer.deck(id).toggleMaster()
        case .shift: break

        case .jogTouch(let id, let down):
            let deck = mixer.deck(id)
            guard deck.isLoaded, touching[id.rawValue] != down else { return }
            touching[id.rawValue] = down
            if down {
                scratchTarget[id.rawValue] = deck.deck.state().position
                deck.beginScratch()
            } else {
                deck.endScratch()
            }
        case .jogScratch(let id, let ticks):
            let deck = mixer.deck(id)
            guard touching[id.rawValue] else { return nudge(deck, ticks) }
            scratchTarget[id.rawValue] = max(0, min(deck.duration, scratchTarget[id.rawValue] + Double(ticks) * Self.secondsPerTick))
            deck.scratch(to: scratchTarget[id.rawValue])
        case .jogBend(let id, let ticks):
            nudge(mixer.deck(id), ticks)
        case .jogSearch(let id, let ticks):
            let deck = mixer.deck(id)
            guard deck.isLoaded else { return }
            deck.seek(to: max(0, min(deck.duration, deck.deck.state().position + Double(ticks) * 0.5)))

        case .tempo(let id, let position):
            slider(mixer.deck(id), position)
        case .trim(let id, let position): mixer.deck(id).trim = (position * 2 - 1) * 12
        case .eq(let id, let band, let position): mixer.deck(id).eq[band] = position * 2 - 1
        case .fader(let id, let position): mixer.deck(id).fader = position
        case .filter(let id, let position):
            // A little slack at the middle, so "off" is easy to find.
            let turn = position * 2 - 1
            mixer.deck(id).filter = abs(turn) < 0.04 ? 0 : turn
        case .crossfader(let position): mixer.crossfader = position * 2 - 1
        case .headphoneMix(let position): mixer.headphoneMix = position
        case .headphoneCue(let id): mixer.deck(id).cueMonitor.toggle()

        case .loopIn(let id, let down):
            let deck = mixer.deck(id)
            loopHold[id.rawValue]?.cancel()
            guard down, deck.isLoaded else { return }
            loopIn[id.rawValue] = deck.snapped(deck.deck.state().position)
            // Held down, the button is "4 BEAT": a four-beat loop from here.
            loopHold[id.rawValue] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                self?.loopIn[id.rawValue] = nil
                deck.startLoop(beats: 4)
            }
        case .loopOut(let id):
            let deck = mixer.deck(id)
            guard let start = loopIn[id.rawValue] else { return }
            let end = deck.snapped(deck.deck.state().position)
            loopIn[id.rawValue] = nil
            if end > start + 0.02 { deck.setLoop(from: start, to: end) }
        case .reloop(let id): mixer.deck(id).toggleLoop()
        case .loopHalve(let id): mixer.deck(id).scaleLoop(by: 0.5)
        case .loopDouble(let id): mixer.deck(id).scaleLoop(by: 2)
        case .jump(let id, let beats): mixer.deck(id).jump(byBeats: beats)

        case .padMode(let id, let mode): padMode[id.rawValue] = mode
        case .sample(let id, let slot, let stop):
            let pad = Sampler.pad(slot, of: id)
            if stop { mixer.sampler.stop(pad) } else { mixer.sampler.hit(pad) }
        case .hotCue(let id, let slot): mixer.deck(id).hotCue(slot)
        case .clearHotCue(let id, let slot): mixer.deck(id).clearHotCue(slot)
        case .beatLoop(let id, let beats):
            let deck = mixer.deck(id)
            // The pad of the loop that is running stops it; any other starts its own.
            if let loop = deck.loop, let grid = deck.grid,
               abs(grid.beatPosition(at: loop.upperBound) - grid.beatPosition(at: loop.lowerBound) - beats) < 0.02 {
                deck.toggleLoop()
            } else {
                deck.loopBeats = beats
                deck.startLoop(beats: beats)
            }

        case .browse(let rows): app.moveSelection(by: rows)
        case .browsePush: app.loadSelection(on: mixer.freeDeck)
        case .load(let id): app.loadSelection(on: id)
        case .zoom(let steps):
            let key = "wave.pointsPerSecond"
            let current = UserDefaults.standard.object(forKey: key) as? Double ?? WaveZoom.standard
            UserDefaults.standard.set(WaveZoom.clamp(current * pow(1.12, Double(steps))), forKey: key)

        case .effect(let id): mixer.deck(id).echoOn.toggle()
        case .effectBeats(let longer):
            for deck in mixer.decks { deck.echoBeats = max(0.125, min(4, deck.echoBeats * (longer ? 2 : 0.5))) }
        }
    }

    /// The edge of the wheel: hurries a playing deck along or holds it back while it turns; moves a stopped one a little.
    private func nudge(_ deck: DeckModel, _ ticks: Int) {
        guard deck.isLoaded, ticks != 0 else { return }
        let index = deck.id.rawValue
        guard deck.isPlaying else {
            deck.seek(to: max(0, min(deck.duration, deck.deck.state().position + Double(ticks) * Self.secondsPerTick * 2)))
            return
        }
        deck.bend(max(-0.12, min(0.12, Double(ticks) * 0.012)))
        bendReset[index]?.cancel()
        bendReset[index] = Task {
            try? await Task.sleep(nanoseconds: 70_000_000)
            if !Task.isCancelled { deck.bend(0) }
        }
    }

    /// The tempo slider. A synced deck ignores it. Otherwise it sets the tempo, but only once it
    /// has been moved to where the tempo already is: a slider left at one end must not throw the
    /// tempo there the moment it is touched.
    private func slider(_ deck: DeckModel, _ position: Double) {
        let index = deck.id.rawValue
        let offset = deck.tempoRange * (2 * position - 1) * (tempoReversed ? -1 : 1)
        defer { sliderWas[index] = offset }
        guard !(deck.isSynced && !deck.isMaster) else {
            sliderHolds[index] = false
            return
        }
        let current = deck.tempoOffset
        // Something else has moved the tempo since the slider last set it.
        if let set = sliderSet[index], abs(set - current) > 0.0004 { sliderHolds[index] = false }
        if !sliderHolds[index] {
            let crossed = sliderWas[index].map { ($0 - current) * (offset - current) <= 0 } ?? false
            guard crossed || abs(offset - current) < 0.002 else { return }
            sliderHolds[index] = true
        }
        deck.setTempoOffset(offset)
        sliderSet[index] = deck.tempoOffset
    }
}
