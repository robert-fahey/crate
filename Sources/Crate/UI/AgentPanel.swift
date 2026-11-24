import CrateCore
import SwiftUI

/// The agent: a command line at the bottom of the window with the
/// conversation's history above it.
struct AgentPanel: View {
    let agent: AgentSession
    /// The history starts closed at launch, so it does not take the track list's space until wanted.
    @State private var isExpanded = false
    @AppStorage("agent.historyHeight") private var historyHeight = 240.0

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded, !agent.messages.isEmpty {
                AgentTranscript(agent: agent)
                    .frame(height: historyHeight)
                Divider()
            }
            inputRow
        }
        .background(DeckStyle.panel)
    }

    @ViewBuilder
    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(LinearGradient(
                    colors: [DeckStyle.colors(0)[1], DeckStyle.colors(1)[1]], startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: DeckStyle.colors(0)[1].opacity(0.6), radius: 5)
            switch agent.phase {
            case .ready, .working:
                AgentInput(agent: agent) { isExpanded = true }
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
                        Button("New Conversation") { agent.newConversation() }
                        Button("Clear History", role: .destructive) { agent.clearHistory() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("History options")
                }
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? "Hide" : "History", systemImage: isExpanded ? "chevron.down" : "clock.arrow.circlepath")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide the conversation history" : "Show the conversation history")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DeckStyle.hairline))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The text field. It is its own view so that typing redraws only this, not
/// the history above it or anything else in the window.
private struct AgentInput: View {
    let agent: AgentSession
    let didSend: () -> Void
    @State private var draft = ""
    /// Which earlier request the arrow keys have recalled; nil while typing something new.
    @State private var recalled: Int?
    @State private var unsent = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit(submit)
            .disabled(agent.phase == .working)
            .onKeyPress(.upArrow) { recall(-1) }
            .onKeyPress(.downArrow) { recall(1) }
            .help("Press ↑ and ↓ to bring back earlier requests")
        if agent.phase == .working {
            ProgressView().controlSize(.small)
            Button("Stop") { agent.cancel() }.keyboardShortcut(".", modifiers: .command)
        } else {
            Button("Send", action: submit)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var prompt: String {
        agent.isOffline
            ? "Offline test agent: type words to search, or /tool name {json}"
            : "Ask for music: “find everything around 122 BPM in 5A”, “mix into the next track”…"
    }

    private func submit() {
        guard agent.phase == .ready, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        agent.send(draft)
        draft = ""
        recalled = nil
        unsent = ""
        didSend()
    }

    /// Steps back (-1) or forward (1) through earlier requests, like a shell's history.
    private func recall(_ step: Int) -> KeyPress.Result {
        let past = agent.pastRequests
        guard !past.isEmpty else { return .ignored }
        if recalled == nil {
            guard step < 0 else { return .ignored }
            unsent = draft
            recalled = past.count - 1
        } else if let index = recalled {
            let next = index + step
            if next >= past.count {
                recalled = nil
                draft = unsent
                return .handled
            }
            recalled = max(0, next)
        }
        if let recalled { draft = past[recalled] }
        return .handled
    }
}

/// The conversation so far, including earlier sessions.
private struct AgentTranscript: View {
    let agent: AgentSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(agent.messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(message.date, inSameDayAs: agent.messages[index - 1].date) {
                            Text(message.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        MessageView(message: message, isLive: agent.phase == .working && message.id == agent.messages.last?.id)
                            .id(message.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.messages.last?.parts) { scrollToEnd(proxy) }
            .onChange(of: agent.messages.count) { scrollToEnd(proxy) }
            .onAppear { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = agent.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
