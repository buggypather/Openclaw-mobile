import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var gatewayText: String
    @Published var bootstrapToken: String
    @Published var selectedSession = "main"
    @Published var draft = ""
    @Published var staged: [AttachmentDraft] = []
    @Published var showSessions = false
    @Published var showSettings = false
    @Published var alertText: String?

    @Published private(set) var client: GatewayClient

    private let defaults = UserDefaults.standard

    init() {
        let gateway = UserDefaults.standard.string(forKey: "gatewayURL") ?? "ws://127.0.0.1:18789"
        let token = UserDefaults.standard.string(forKey: "bootstrapToken") ?? ""
        gatewayText = gateway
        bootstrapToken = token
        client = GatewayClient(gatewayURL: URL(string: gateway)!, bootstrapToken: token)
    }

    func connect() { client.connect() }
    func disconnect() { client.close() }

    func applySettings() {
        guard let url = URL(string: gatewayText), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
            alertText = "Enter a ws:// or wss:// Gateway URL."
            return
        }
        defaults.set(gatewayText, forKey: "gatewayURL")
        defaults.set(bootstrapToken, forKey: "bootstrapToken")
        client.close()
        client = GatewayClient(gatewayURL: url, bootstrapToken: bootstrapToken)
        selectedSession = "main"
        client.selectSession("main")
        client.connect()
        showSettings = false
    }

    func selectSession(_ key: String) {
        selectedSession = key
        client.selectSession(key)
        showSessions = false
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !staged.isEmpty else { return }
        guard staged.isEmpty || client.connectionState == .connected else {
            alertText = "Attachments require a live Gateway connection."
            return
        }
        if let limit = client.maxAttachmentBytes, staged.contains(where: { $0.bytes.count > limit }) {
            alertText = "One of the selected files exceeds the Gateway attachment limit."
            return
        }
        let estimated = Int64(text.utf8.count) + staged.reduce(0) { partial, item in
            partial + Int64(((item.bytes.count + 2) / 3) * 4 + item.name.utf8.count + item.mimeType.utf8.count + 96)
        }
        if let limit = client.maxPayloadBytes, estimated > limit {
            alertText = "Message plus attachments exceed the Gateway payload limit."
            return
        }
        client.sendChat(text, attachments: staged)
        draft = ""
        staged = []
    }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentTypeKey])
            let mime = values?.contentType?.preferredMIMEType ?? "application/octet-stream"
            staged.append(AttachmentDraft(name: url.lastPathComponent, mimeType: mime, bytes: data))
        }
    }
}
