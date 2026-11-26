import CrateCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    /// The tab last looked at, so Settings opens where it was left.
    @AppStorage("settings.tab") private var tab = "library"

    var body: some View {
        TabView(selection: $tab) {
            LibrarySettings(model: model).tabItem { Label("Library", systemImage: "music.note.list") }.tag("library")
            AgentSettings(agent: model.agent).tabItem { Label("Agent", systemImage: "sparkles") }.tag("agent")
            ServiceSettings(model: model).tabItem { Label("Services", systemImage: "dot.radiowaves.left.and.right") }.tag("services")
            SharingSettings(sharing: model.sharing).tabItem { Label("Sharing", systemImage: "laptopcomputer.and.arrow.down") }.tag("sharing")
            AudioSettings(mixer: model.mixer, controller: model.controller).tabItem { Label("Audio", systemImage: "headphones") }.tag("audio")
        }
        .frame(width: 580, height: 460)
    }
}

private struct LibrarySettings: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Folders") {
                if model.folders.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                }
                ForEach(model.folders) { folder in
                    HStack {
                        Image(systemName: folder.volumeUUID == nil ? "folder" : "externaldrive")
                        Text((folder.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { model.removeFolder(folder) }
                            .help("Removes the folder and its tracks from the library. Files on disk are not touched.")
                    }
                }
                HStack {
                    Button("Add Folder…") { model.chooseFolder() }
                    Button("Rescan Now") { model.rescan() }.disabled(model.folders.isEmpty)
                }
            }
            Section {
                LabeledContent("Tracks", value: "\(model.stats.tracks)")
                LabeledContent("With BPM", value: "\(model.stats.withBPM)")
                LabeledContent("With key", value: "\(model.stats.withKey)")
            } footer: {
                Text("Files under a minute are skipped as samples. BPM and key marked “~” are Crate's own estimates.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettings: View {
    let agent: AgentSession
    @State private var servers = ""
    @State private var serverError: String?
    @State private var saved = false
    @State private var mixingStyle = ""
    @State private var styleSaved = false

    var body: some View {
        Form {
            Section("Cursor") {
                LabeledContent("Status", value: status)
                if agent.phase == .signedOut {
                    Button("Sign In with Cursor") { agent.signIn() }
                } else if !agent.isOffline, agent.phase == .ready {
                    Picker("Model", selection: Binding(get: { agent.selectedModel }, set: { agent.selectedModel = $0 })) {
                        ForEach(agent.models) { model in Text(model.name).tag(model.id) }
                    }
                    HStack {
                        Button("New Conversation") { agent.newConversation() }
                        Button("Sign Out") { agent.signOut() }
                    }
                }
            }
            Section {
                TextEditor(text: $mixingStyle)
                    .font(.callout)
                    .frame(height: 110)
                HStack {
                    Button("Save") {
                        agent.mixingStyle = mixingStyle
                        styleSaved = true
                    }
                    Button("Reset") { mixingStyle = AgentInstructions.defaultMixingStyle }
                    if styleSaved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Mixing style")
            } footer: {
                Text("How you like mixes done, in your own words. The agent reads this whenever it chooses or plans a mix.")
            }
            Section {
                TextEditor(text: $servers)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 120)
                HStack {
                    Button("Save") { save() }
                    if let serverError {
                        Text(serverError).font(.caption).foregroundStyle(.red)
                    } else if saved {
                        Text("Saved").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("MCP servers")
            } footer: {
                Text("Extra tools for the agent, in the same JSON shape as Cursor's mcp.json. Servers that need a browser sign-in are not supported; use ones that take a token.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            servers = agent.mcpServersText
            mixingStyle = agent.mixingStyle
        }
    }

    private var status: String {
        switch agent.phase {
        case .starting, .connecting: return "Starting…"
        case .signedOut: return "Signed out"
        case .signingIn: return "Waiting for sign-in in your browser"
        case .ready, .working:
            if agent.isOffline { return "Offline test agent (no AI)" }
            return "Signed in" + (agent.accountEmail.map { " as \($0)" } ?? "") + ", Cursor SDK \(agent.sdkVersion)"
        case .unavailable(let reason): return reason
        }
    }

    private func save() {
        do {
            _ = try AgentSession.parseMCPServers(servers)
            agent.mcpServersText = servers
            serverError = nil
            saved = true
            agent.reloadSession()
        } catch {
            saved = false
            serverError = (error as? ToolError)?.message ?? "That is not valid JSON."
        }
    }
}

private struct ServiceSettings: View {
    let model: AppModel
    @State private var spotifyClientID = ""
    @State private var tidalClientID = ""
    @State private var tidalSecret = ""
    @State private var spotifyConnected = false

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $spotifyClientID)
                HStack {
                    if model.isConnectingSpotify {
                        Button("Cancel") { model.cancelSpotifyConnect() }
                    } else if spotifyConnected {
                        Button("Disconnect") {
                            model.disconnectSpotify()
                            spotifyConnected = false
                        }
                    } else {
                        Button("Connect Spotify…") { model.connectSpotify(clientID: spotifyClientID) }
                            .disabled(spotifyClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text(model.spotifyStatus ?? (spotifyConnected ? "Connected." : "Not connected."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Spotify")
            } footer: {
                Text("Create an app at developer.spotify.com/dashboard, add the redirect URI \(SpotifyAPI.redirectURI), and paste its Client ID here. Crate searches Spotify and plays the tracks through the Spotify app.")
            }
            Section {
                TextField("Client ID", text: $tidalClientID)
                SecureField("Client secret", text: $tidalSecret)
                HStack {
                    Button("Save and Check") { model.saveTidal(clientID: tidalClientID, clientSecret: tidalSecret) }
                    Text(model.tidalStatus ?? (model.tidal.isConfigured ? "Saved." : "Not set up."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("TIDAL")
            } footer: {
                Text("Create an app at developer.tidal.com and paste its client ID and secret. Crate searches TIDAL and opens tracks in the TIDAL app, which it cannot pause or seek.")
            }
            Section {
                LabeledContent("tiddl") {
                    Text(model.grab.status).foregroundStyle(.secondary).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
                LabeledContent("Save to") {
                    HStack {
                        Text((model.grab.folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseGrabFolder() }
                    }
                }
                Picker("Quality", selection: Binding(get: { model.grab.quality }, set: { model.grab.quality = $0 })) {
                    ForEach(Tiddl.Quality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Grabbing from TIDAL")
            } footer: {
                Text("File > Grab from TIDAL downloads tracks as files with tiddl, a separate tool that signs in with your own TIDAL account, and adds them to the library. Crate uses the tiddl you have installed. The folder becomes a library folder.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.grab.check()
            spotifyClientID = model.spotify.clientID ?? ""
            spotifyConnected = model.spotify.isConnected
            tidalClientID = model.tidal.clientID ?? ""
        }
        .onChange(of: model.spotifyStatus) { spotifyConnected = model.spotify.isConnected }
    }

    private func chooseGrabFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.grab.folder)
        panel.prompt = "Save Here"
        panel.message = "Tracks grabbed from TIDAL go here, in folders by artist and album."
        if panel.runModal() == .OK, let url = panel.url { model.grab.folder = url.path }
    }
}

/// Settings > Audio: where the sound goes, and the DJ controller.
private struct AudioSettings: View {
    @Bindable var mixer: DJMixer
    @Bindable var controller: ControllerModel

    var body: some View {
        Form {
            Section {
                Picker("Play through", selection: $mixer.outputChoice) {
                    Text("Automatic").tag("auto")
                    Text("The Mac's sound output").tag("system")
                    Divider()
                    ForEach(mixer.outputs) { output in
                        Text(output.hasHeadphoneOutput ? "\(output.name) (with headphones)" : output.name).tag(output.uid)
                    }
                }
                LabeledContent("Now playing through", value: mixer.outputName.isEmpty ? "—" : mixer.outputName)
                LabeledContent("Headphones") {
                    Text(mixer.hasHeadphones ? "On outputs 3-4" : "Not available on this output").foregroundStyle(.secondary)
                }
            } header: {
                Text("Output")
            } footer: {
                Text("Automatic uses a DJ controller's sound card when one is plugged in, and the Mac's own output otherwise. On a sound card with four outputs the master mix goes to outputs 1-2 and the headphones to 3-4; the headphone buttons and the CUE·MIX knob in the mixer choose what the headphones hear.")
            }
            Section {
                LabeledContent("Controller") {
                    if let name = controller.name {
                        Label(name, systemImage: "circle.fill").foregroundStyle(.green)
                    } else {
                        Text("None connected").foregroundStyle(.secondary)
                    }
                }
                if controller.isConnected {
                    LabeledContent("Last control used", value: controller.lastEvent ?? "—")
                }
                Toggle("Tempo sliders run the other way", isOn: $controller.tempoReversed)
            } header: {
                Text("DJ controller")
            } footer: {
                Text("Crate works with the Pioneer DJ DDJ-FLX4. Plug it in and it is found. Its master and headphone level knobs act on the controller itself; everything else drives the decks on screen. If pushing a tempo slider towards “+” slows the deck down, switch the setting above.")
            }
        }
        .formStyle(.grouped)
    }
}
