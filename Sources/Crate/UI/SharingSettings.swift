import AppKit
import CrateCore
import SwiftUI

/// Settings > Sharing: one library on all your Macs.
struct SharingSettings: View {
    @Bindable var sharing: SharingModel
    @State private var name = ""
    @State private var typedCode = ""

    var body: some View {
        Form {
            Section {
                Toggle("Share this library with my other Macs", isOn: $sharing.isOn)
                LabeledContent("This Mac is called") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { if !name.isEmpty { sharing.deviceName = name } }
                }
            } footer: {
                Text("Each Mac keeps its own copy of the library. When two of them can see each other with Crate open, they bring each other up to date: playlists, track details, cue points and beat grids. Music files are copied the first time you load a track that is on another Mac.")
            }
            Section("Sharing code") {
                if sharing.code.isEmpty {
                    Text("On your first Mac, make a code. On the others, type that same code in.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("Code") {
                        Text(sharing.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
                HStack {
                    TextField("Code from your other Mac", text: $typedCode).textFieldStyle(.roundedBorder).frame(width: 220)
                    Button("Use This Code") {
                        sharing.setCode(typedCode)
                        typedCode = ""
                    }
                    .disabled(typedCode.trimmingCharacters(in: .whitespaces).count < 8)
                    Spacer()
                    Button(sharing.code.isEmpty ? "Make a Code" : "Make a New Code") { sharing.makeCode() }
                        .help("A new code disconnects Macs that have the old one until they are given the new one.")
                }
            }
            Section {
                Toggle("Find my Macs with Tailscale", isOn: $sharing.usesTailscale)
                TextField("Other addresses, one per line", text: $sharing.addresses, axis: .vertical).lineLimit(2...4)
                if sharing.isOn {
                    if let problem = sharing.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if sharing.peers.isEmpty {
                        Text("No other Mac is connected.").foregroundStyle(.secondary)
                    }
                    ForEach(sharing.peers, id: \.device.id) { peer in
                        Label("\(peer.device.name) — connected at \(peer.host)", systemImage: "circle.fill").foregroundStyle(.green)
                    }
                }
            } header: {
                Text("My Macs")
            } footer: {
                Text("With Tailscale running, your Macs find each other wherever they are. An address is only needed for a Mac Tailscale does not list: its name or number, with “:port” if it is not \(String(SyncService.defaultPort)).")
            }
            Section("Music copied from other Macs") {
                HStack {
                    Text((sharing.musicFolder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { sharing.musicFolder = url.path }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = sharing.deviceName }
    }
}
