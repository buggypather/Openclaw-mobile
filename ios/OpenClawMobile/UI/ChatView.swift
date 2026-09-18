import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ChatView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: GatewayClient
    @State private var importing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBar(client: client)
                Divider()
                transcript
                if !model.staged.isEmpty { attachmentStrip }
                composer
            }
            .navigationTitle(model.selectedSession)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showSessions = true } label: { Label("Sessions", systemImage: "sidebar.left") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $model.showSessions) { SessionSheet(model: model, client: client) }
            .sheet(isPresented: $model.showSettings) { SettingsSheet(model: model) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.importFiles(urls) }
            }
            .alert("OpenClaw", isPresented: Binding(get: { model.alertText != nil }, set: { if !$0 { model.alertText = nil } })) {
                Button("OK", role: .cancel) { model.alertText = nil }
            } message: { Text(model.alertText ?? "") }
            .alert("Pairing required", isPresented: Binding(get: { client.pairingRequestId != nil }, set: { _ in })) {
                Button("Copy command") {
                    if let id = client.pairingRequestId { UIPasteboard.general.string = "openclaw devices approve \(id)" }
                }
                Button("OK", role: .cancel) { }
            } message: {
                if let id = client.pairingRequestId { Text("Approve on the Gateway host:\nopenclaw devices approve \(id)") }
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if client.messages.isEmpty {
                        ContentUnavailableView("Start a conversation", systemImage: "bubble.left.and.bubble.right")
                            .padding(.top, 80)
                    }
                    ForEach(client.messages) { message in
                        MessageBubble(message: message,
                                      onContinue: { client.resume() },
                                      onRetry: { client.retry(message) })
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: client.messages) { _, newValue in
                if let id = newValue.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(model.staged) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        Text(item.name).lineLimit(1)
                        Button { model.staged.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                }
            }.padding(.horizontal).padding(.vertical, 6)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { importing = true } label: { Image(systemName: "plus.circle.fill").font(.title2) }
                .accessibilityLabel("Attach files")
            TextField("Message OpenClaw", text: $model.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
            if client.activeRunId != nil {
                Button { client.pauseOrStop() } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                    .accessibilityLabel("Pause execution")
            } else {
                Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(client.connectionState != .connected && !model.staged.isEmpty)
                    .accessibilityLabel("Send")
            }
        }
        .padding(10)
        .background(.bar)
    }
}

private struct StatusBar: View {
    @ObservedObject var client: GatewayClient
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(client.statusDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if client.connectionState == .disconnected || client.connectionState == .pairingRequired {
                Button("Reconnect") { client.connect() }.font(.caption)
            }
        }.padding(.horizontal).padding(.vertical, 6)
    }
    private var color: Color {
        switch client.connectionState {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .pairingRequired: .yellow
        case .disconnected: .gray
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let onContinue: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(message.attachments, id: \.self) { file in
                    Label(file, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                }
                Text(message.text).textSelection(.enabled)
                if message.streaming { ProgressView().controlSize(.small) }
                if message.role == "assistant" && !message.streaming {
                    HStack(spacing: 18) {
                        Button { UIPasteboard.general.string = message.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button(action: onContinue) { Label("Continue", systemImage: "arrow.forward") }
                        Button(action: onRetry) { Label("Retry", systemImage: "arrow.clockwise") }
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(message.role == "user" ? Color.accentColor.opacity(0.13) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            if message.role != "user" { Spacer(minLength: 42) }
        }
    }
}

private struct SessionSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var client: GatewayClient
    var body: some View {
        NavigationStack {
            List {
                ForEach(client.sessions) { session in
                    Button { model.selectSession(session.key) } label: {
                        VStack(alignment: .leading) {
                            Text(session.title).foregroundStyle(.primary)
                            if session.title != session.key { Text(session.key).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.showSessions = false } } }
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway") {
                    TextField("wss://gateway.example", text: $model.gatewayText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Bootstrap token", text: $model.bootstrapToken)
                }
                Section {
                    Text("Use wss:// for remote connections. ws:// is enabled in this development build for LAN testing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.showSettings = false } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { model.applySettings() } }
            }
        }
    }
}
