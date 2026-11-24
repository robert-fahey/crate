import CrateCore
import SwiftUI

/// The agent: a line to ask on at the bottom of the window, what is worth asking above it,
/// and the conversation above that when it is open.
///
/// The conversation follows the sidebar. A crate has its own, so what was said about a crate is
/// there whenever that crate is; everything else is the library's conversation.
struct AgentPanel: View {
    let model: AppModel
    /// The height the track list and this panel have between them: the window less the decks.
    var room: CGFloat = 600
    /// How tall the bar is without the conversation: the offers and the text field.
    @State private var barHeight: CGFloat = 86
    /// The history starts closed at launch, so it does not take the track list's space until wanted.
    @State private var isExpanded = false
    /// The track whose name was last clicked in a reply, with what can be done with it.
    @State private var picked: Track?
    @AppStorage("agent.historyHeight") private var historyHeight = 240.0

    private var agent: AgentSession { model.agent }

    var body: some View {
        VStack(spacing: 0) {
            if showsConversation, !floats {
                conversation(height: max(Self.least, min(historyHeight, space - Self.listKept)))
            }
            bar
        }
        .background(DeckStyle.panel)
        // With no room between the decks and the bar (large decks in a small window) the conversation
        // lies over the decks instead of pushing anything off the window.
        .overlay(alignment: .top) {
            if showsConversation, floats {
                conversation(height: min(historyHeight, 280))
                    .background(DeckStyle.panel)
                    .overlay(alignment: .top) { Divider() }
                    .shadow(color: .black.opacity(0.5), radius: 12, y: -4)
                    .alignmentGuide(.top) { $0[.bottom] }
            }
        }
        // Something was asked: open the conversation to show the reply.
        .onChange(of: model.draft.sent) { isExpanded = true }
        .onChange(of: agent.conversation) { picked = nil }
    }

    /// The least height at which the conversation can be read, and what is left of the track list beside it.
    private static let least: CGFloat = 130
    private static let listKept: CGFloat = 96

    private var showsConversation: Bool { isExpanded && !agent.messages.isEmpty }
    /// What the list and the conversation can share once the bar has its height.
    private var space: CGFloat { room - barHeight - 1 }
    private var floats: Bool { space < Self.least }

    private func conversation(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            AgentTranscript(agent: agent) { id in picked = try? model.store.track(id: id) }
                .frame(height: min(height, max(Self.least, floats ? height : space)) - (picked == nil ? 0 : 34))
            if let picked {
                PickedTrackBar(model: model, track: picked) { self.picked = nil }.frame(height: 34)
            }
            Divider()
        }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            if agent.phase == .ready || agent.phase == .working {
                AgentOffers(model: model)
            }
            inputRow
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
    }

    /// Which conversation this is: the crate's name, or the library. Click to open or close it.
    private var badge: some View {
        Button {
            if !agent.messages.isEmpty { isExpanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: agent.conversation.isLibrary ? "sparkles" : "shippingbox.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(agent.title).font(.callout.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(.white.opacity(0.92))
            .background(
                LinearGradient(
                    colors: [DeckStyle.colors(0)[1].opacity(0.55), DeckStyle.colors(1)[1].opacity(0.45)],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Capsule())
            .frame(maxWidth: 220)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help(agent.conversation.isLibrary
            ? "The library's conversation with the agent. Each crate has its own: select a crate to talk about it."
            : "“\(agent.title)” has its own conversation with the agent, kept with the crate.")
    }

    @ViewBuilder
    private var inputRow: some View {
        HStack(spacing: 10) {
            badge
            switch agent.phase {
            case .ready, .working:
                AgentInput(model: model)
            case .starting, .connecting:
                Text("Starting the agent…").foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            case .signedOut:
                Text("Sign in to Cursor to use the agent. Requests are billed to your Cursor plan.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign In with Cursor") { agent.signIn() }
            case .signingIn:
                Text("Finish signing in to Cursor in your browser…").foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            case .unavailable(let reason):
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Try Again") { agent.start() }
            }
            if !agent.messages.isEmpty {
                if isExpanded {
                    Menu {
                        Button("Taller") { historyHeight = min(700, historyHeight + 120) }
                        Button("Shorter") { historyHeight = max(120, historyHeight - 120) }
                        Divider()
                        Button("Start Over") { agent.newConversation() }
                        Button("Clear History", role: .destructive) { agent.clearHistory() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Options for this conversation. Start Over has the agent forget it; Clear History empties what is shown.")
                }
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? "Hide" : "History", systemImage: isExpanded ? "chevron.down" : "clock.arrow.circlepath")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide the conversation" : "Show the conversation")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DeckStyle.hairline))
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 8)
    }
}

/// The line above the text field: what is worth asking with what is on screen, or, while the
/// agent is at work, what it is doing. It is its own view so that a change of selection redraws only this.
private struct AgentOffers: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 7) {
            if let activity = model.agent.activity {
                ProgressView().controlSize(.mini)
                if let elsewhere = model.agent.busyElsewhere {
                    Text("Working in “\(elsewhere)”: \(activity)…").lineLimit(1)
                } else {
                    Text("\(activity)…").lineLimit(1)
                }
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(model.agentContext().suggestions) { suggestion in
                            Button(suggestion.label) { model.use(suggestion) }
                                .buttonStyle(OfferStyle())
                                .help(suggestion.sendsAtOnce
                                    ? "Asks the agent: “\(suggestion.request)”"
                                    : "Puts “\(suggestion.request.trimmingCharacters(in: .whitespaces))” in the field below. Finish it if you like, then press Return.")
                        }
                    }
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 24)
        .padding(.horizontal, 14)
        .padding(.top, 7)
    }
}

private struct OfferStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : 0.82))
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(DeckStyle.hairline))
            .contentShape(Capsule())
    }
}

/// The text field. It is its own view so that typing redraws only this, not
/// the history above it or anything else in the window.
private struct AgentInput: View {
    let model: AppModel
    /// Which earlier request the arrow keys have recalled; nil while typing something new.
    @State private var recalled: Int?
    @State private var unsent = ""
    @FocusState private var isFocused: Bool

    private var agent: AgentSession { model.agent }

    var body: some View {
        @Bindable var draft = model.draft
        TextField(prompt, text: $draft.text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit(submit)
            .disabled(agent.phase == .working)
            .onKeyPress(.upArrow) { recall(-1) }
            .onKeyPress(.downArrow) { recall(1) }
            .onChange(of: draft.focusRequests) { isFocused = true }
            .help("Press ↑ and ↓ to bring back earlier requests")
        if agent.phase == .working {
            ProgressView().controlSize(.small)
            Button("Stop") { agent.cancel() }.keyboardShortcut(".", modifiers: .command)
        } else {
            Button("Send", action: submit)
                .disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var prompt: String {
        if agent.isOffline { return "Offline test agent: type words to search, or /tool name {json}" }
        if let elsewhere = agent.busyElsewhere { return "The agent is busy in “\(elsewhere)”. It takes one request at a time." }
        return model.agentContext().placeholder
    }

    private func submit() {
        let text = model.draft.text
        guard agent.phase == .ready, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.draft.text = ""
        recalled = nil
        unsent = ""
        model.ask(text)
    }

    /// Steps back (-1) or forward (1) through earlier requests, like a shell's history.
    private func recall(_ step: Int) -> KeyPress.Result {
        let past = agent.pastRequests
        guard !past.isEmpty else { return .ignored }
        if recalled == nil {
            guard step < 0 else { return .ignored }
            unsent = model.draft.text
            recalled = past.count - 1
        } else if let index = recalled {
            let next = index + step
            if next >= past.count {
                recalled = nil
                model.draft.text = unsent
                return .handled
            }
            recalled = max(0, next)
        }
        if let recalled { model.draft.text = past[recalled] }
        return .handled
    }
}

/// The conversation so far, including earlier sessions.
private struct AgentTranscript: View {
    let agent: AgentSession
    /// A track's name was clicked in a reply.
    let pick: (Int64) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in
                        if row.startsDay {
                            Text(row.message.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        MessageView(message: row.message, isLive: agent.isWorkingHere && row.id == agent.messages.last?.id)
                            .id(row.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Each conversation is its own scroll view, so changing crate starts at the end of that crate's.
            .id(agent.conversation)
            .onChange(of: agent.messages.last?.parts) { scrollToEnd(proxy) }
            .onChange(of: agent.messages.count) { scrollToEnd(proxy) }
            .onChange(of: agent.conversation) { scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
        // A track named in a reply is a link to it.
        .environment(\.openURL, OpenURLAction { url in
            guard let id = TrackLink.trackID(from: url) else { return .systemAction }
            pick(id)
            return .handled
        })
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = agent.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private struct Row: Identifiable {
        let message: ChatMessage
        /// The first message of its day, which gets the date above it.
        let startsDay: Bool
        var id: UUID { message.id }
    }

    /// Each message with what it needs to draw itself. Worked out in one go: a row that looked its neighbour up
    /// in the conversation later could find the conversation changed for a shorter one.
    private var rows: [Row] {
        let messages = agent.messages
        return messages.indices.map { index in
            Row(message: messages[index],
                startsDay: index == 0 || !Calendar.current.isDate(messages[index].date, inSameDayAs: messages[index - 1].date))
        }
    }
}

/// What can be done with a track whose name was clicked in a reply.
private struct PickedTrackBar: View {
    let model: AppModel
    let track: Track
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note").foregroundStyle(.secondary)
            Text(track.artist.isEmpty ? track.title : "\(track.artist) – \(track.title)")
                .fontWeight(.semibold)
                .lineLimit(1)
            Text(details).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
            Spacer(minLength: 8)
            if track.source == .local {
                Button("Deck A") { model.load(track, on: .a) }.help("Load on deck A")
                Button("Deck B") { model.load(track, on: .b) }.help("Load on deck B")
            }
            if let crate = model.currentCrate {
                Button("Add to “\(crate.name)”") { model.add([track.id], to: crate) }
            }
            Button("Show in List") { model.showInList(track) }
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06))
    }

    private var details: String {
        var parts: [String] = []
        if let bpm = track.bpm { parts.append(String(format: "%.0f BPM", bpm)) }
        if let key = track.key { parts.append(key) }
        parts.append(TrackFormat.duration(track.duration))
        return parts.joined(separator: " · ")
    }
}

private struct MessageView: View {
    let message: ChatMessage
    let isLive: Bool

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
                .help(message.date.formatted(date: .abbreviated, time: .shortened))
        case .notice:
            Text(message.text).font(.caption).foregroundStyle(.secondary)
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(message.parts) { part in
                    switch part {
                    case .text(_, let text):
                        Text(LocalizedStringKey(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                            .textSelection(.enabled)
                    case .tool(let tool):
                        HStack(spacing: 6) {
                            switch tool.state {
                            case .running: ProgressView().controlSize(.mini)
                            case .done: Image(systemName: "checkmark").foregroundStyle(.secondary)
                            case .failed: Image(systemName: "xmark").foregroundStyle(.orange)
                            }
                            Text(tool.server.map { "\($0): " + tool.summary } ?? tool.summary).lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                if isLive, message.isEmpty {
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Shown before any command the agent wants to run. Nothing runs without Approve.
struct CommandConfirmSheet: View {
    let request: CommandRequest
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The agent wants to run a command", systemImage: "terminal").font(.headline)
            Text(request.reason)
            ScrollView {
                Text(request.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 160)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text("Runs in \((request.workingDirectory as NSString).abbreviatingWithTildeInPath) with your user account's access. It can change or delete files.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Don't Run", role: .cancel) { decide(false) }.keyboardShortcut(.cancelAction)
                Button("Run Command") { decide(true) }
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}
