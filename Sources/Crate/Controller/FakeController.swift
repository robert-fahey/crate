import CoreMIDI
import CrateCore
import Foundation

/// Stands in for a DDJ-FLX4 so the MIDI link can be checked without one: a pretend
/// controller that appears to the system as a MIDI device. Only made when
/// CRATE_FAKE_CONTROLLER is set. Messages are fed in as if its buttons were pressed,
/// and what Crate sends back (lights, meters, the hello) is kept for inspection.
///
/// Its receiving end uses the older byte-stream interface on purpose: that is the
/// form in which a real USB controller gets its messages.
@MainActor
final class FakeController {
    static let shared: FakeController? = ProcessInfo.processInfo.environment["CRATE_FAKE_CONTROLLER"] != nil ? FakeController() : nil

    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()
    private let lock = NSLock()
    private nonisolated(unsafe) var received: [[UInt8]] = []

    private init() {
        MIDIClientCreateWithBlock("Crate test controller" as CFString, &client, nil)
        MIDISourceCreateWithProtocol(client, "DDJ-FLX4 (test)" as CFString, ._1_0, &source)
        MIDIDestinationCreateWithBlock(client, "DDJ-FLX4 (test)" as CFString, &destination) { [weak self] list, _ in
            var messages: [[UInt8]] = []
            for packet in list.unsafeSequence() {
                // One packet can carry several short messages end to end, or one long (system-exclusive) one.
                let bytes = Array(packet.bytes())
                if bytes.first == 0xF0 || bytes.count % 3 != 0 {
                    messages.append(bytes)
                } else {
                    messages.append(contentsOf: stride(from: 0, to: bytes.count, by: 3).map { Array(bytes[$0..<$0 + 3]) })
                }
            }
            guard let self else { return }
            self.lock.withLock { self.received.append(contentsOf: messages) }
        }
    }

    /// Presses a button or moves a control: "90 0B 7F".
    func send(hex: String) {
        let bytes = hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 3 else { return }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        let word = UInt32(0x2) << 28 | UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[2])
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, [word])
        MIDIReceivedEventList(source, &list)
    }

    /// What Crate has sent since this was last asked: which lights are on, and whether the hello arrived whole.
    func report() -> String {
        let messages = lock.withLock { () -> [[UInt8]] in
            defer { received = [] }
            return received
        }
        var lights: [String: UInt8] = [:]
        var hellos = 0, meters = 0, other = 0
        for message in messages {
            if message == DDJFLX4.hello {
                hellos += 1
            } else if message.count == 3, message[0] & 0xF0 == 0x90 {
                lights[String(format: "%02X %02X", message[0], message[1])] = message[2]
            } else if message.count == 3, message[0] & 0xF0 == 0xB0 {
                meters += 1
            } else {
                other += 1
            }
        }
        let on = lights.filter { $0.value > 0 }.keys.sorted()
        return "hellos \(hellos), meter messages \(meters), unrecognised \(other), lights on: \(on)"
    }
}
