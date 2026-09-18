import Foundation
import Combine

@MainActor
final class GatewayClient: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var activeRunId: String?
    @Published private(set) var pairingRequestId: String?
    @Published private(set) var statusDetail: String = "Offline cache"

    var maxAttachmentBytes: Int64?
    var maxImageBytes: Int64?
    var maxPayloadBytes: Int64?

    private let gatewayURL: URL
    private let bootstrapToken: String
    private let store = DeviceIdentityStore()
    private let cache: TranscriptCache
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var closing = false
    private var reconnectAttempt = 0
    private var lastSeq: Int64?
    private var connectId: String?
    private var pending: [String: String] = [:]
    private var selectedSession = "main"
    private var streamingMessageId: String?
    private let scopes = ["operator.read", "operator.write", "operator.approvals"]

    init(gatewayURL: URL, bootstrapToken: String) {
        self.gatewayURL = gatewayURL
        self.bootstrapToken = bootstrapToken
        self.cache = TranscriptCache(gatewayURL: gatewayURL.absoluteString)
        self.session = URLSession(configuration: .default)
        self.sessions = cache.loadSessions()
        self.messages = cache.loadMessages(sessionKey: "main")
    }

    func connect() {
        closing = false
        reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        connectionState = .connecting
        statusDetail = "Connecting…"
        let task = session.webSocketTask(with: gatewayURL)
        socket = task
        task.resume()
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
    }

    func close() {
        closing = true
        receiveTask?.cancel()
        reconnectTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        connectionState = .disconnected
    }

    func selectSession(_ key: String) {
        selectedSession = key
        messages = cache.loadMessages(sessionKey: key)
        hydrate()
    }

    func hydrate() {
        guard connectionState == .connected else { return }
        _ = request("sessions.subscribe", params: ["limit": 100, "ownerFirst": true])
        _ = request("sessions.messages.subscribe", params: ["sessionKey": selectedSession])
        _ = request("chat.history", params: ["sessionKey": selectedSession, "limit": 200])
    }

    func sendChat(_ text: String, attachments: [AttachmentDraft] = []) {
        guard connectionState == .connected else { return }
        var params: [String: Any] = [
            "sessionKey": selectedSession,
            "message": text,
            "idempotencyKey": UUID().uuidString
        ]
        if !attachments.isEmpty {
            params["attachments"] = attachments.map {
                [
                    "type": "file",
                    "mimeType": $0.mimeType,
                    "fileName": $0.name,
                    "content": $0.bytes.base64EncodedString()
                ]
            }
        }
        messages.append(ChatMessage(id: "local-\(UUID().uuidString)", role: "user", text: text, attachments: attachments.map(\.name)))
        cache.saveMessages(messages, sessionKey: selectedSession)
        _ = request("chat.send", params: params)
    }

    func pauseOrStop() {
        var params: [String: Any] = ["sessionKey": selectedSession]
        if let activeRunId { params["runId"] = activeRunId }
        _ = request("chat.abort", params: params)
    }

    func resume() { sendChat("Continue from where you left off.") }

    func retry(_ message: ChatMessage) {
        guard message.role == "assistant",
              let idx = messages.firstIndex(where: { $0.id == message.id }), idx > 0 else { return }
        let previousUser = messages[..<idx].last(where: { $0.role == "user" })
        if let previousUser { sendChat(previousUser.text) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await task.receive()
                switch message {
                case .string(let text): await handleText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { await handleText(text) }
                @unknown default: break
                }
            }
        } catch {
            if !closing {
                connectionState = .disconnected
                statusDetail = error.localizedDescription
                scheduleReconnect()
            }
        }
    }

    private func handleText(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if obj["type"] as? String == "event", let seq = number(obj["seq"]) {
            if let previous = lastSeq, seq > previous + 1 {
                statusDetail = "Refreshing after event gap…"
                hydrate()
            }
            if let previous = lastSeq, seq <= previous { return }
            lastSeq = seq
        }
        handle(obj)
    }

    private func handle(_ obj: [String: Any]) {
        let type = obj["type"] as? String ?? ""
        if type == "event", obj["event"] as? String == "connect.challenge",
           let payload = obj["payload"] as? [String: Any],
           let nonce = payload["nonce"] as? String,
           let ts = number(payload["ts"]) {
            sendConnect(nonce: nonce, signedAt: ts)
            return
        }

        if type == "res", obj["id"] as? String == connectId {
            if obj["ok"] as? Bool == true {
                connectionState = .connected
                statusDetail = "Connected"
                pairingRequestId = nil
                reconnectAttempt = 0
                lastSeq = nil
                if let payload = obj["payload"] as? [String: Any] {
                    if let auth = payload["auth"] as? [String: Any], let token = auth["deviceToken"] as? String, !token.isEmpty {
                        let role = auth["role"] as? String ?? "operator"
                        let scopes = Set(auth["scopes"] as? [String] ?? [])
                        try? store.saveToken(DeviceToken(token: token, role: role, scopes: scopes))
                    }
                    if let policy = payload["policy"] as? [String: Any] {
                        maxPayloadBytes = number(policy["maxPayload"])
                        if let attachments = policy["attachments"] as? [String: Any] {
                            maxAttachmentBytes = number(attachments["maxBytes"])
                            maxImageBytes = number(attachments["maxImageBytes"])
                        }
                    }
                }
                hydrate()
            } else if let error = obj["error"] as? [String: Any], error["code"] as? String == "PAIRING_REQUIRED" {
                let details = error["details"] as? [String: Any]
                pairingRequestId = details?["requestId"] as? String
                connectionState = .pairingRequired
                statusDetail = pairingRequestId.map { "Pair \($0)" } ?? "Pairing required"
            }
            return
        }

        if type == "res", let id = obj["id"] as? String {
            let method = pending.removeValue(forKey: id)
            guard obj["ok"] as? Bool == true else { return }
            let payload = obj["payload"]
            switch method {
            case "chat.send":
                if let p = payload as? [String: Any] {
                    activeRunId = (p["runId"] as? String) ?? (p["id"] as? String)
                }
            case "chat.abort":
                activeRunId = nil
                streamingMessageId = nil
                finishStreaming()
            case "chat.history": parseHistory(payload)
            case "sessions.subscribe", "sessions.list": parseSessions(payload)
            default: break
            }
        }

        if type == "event", let event = obj["event"] as? String,
           ["agent", "chat", "session.message"].contains(event),
           let payload = obj["payload"] as? [String: Any] {
            if let run = payload["runId"] as? String, !run.isEmpty { activeRunId = run }
            let delta = extractText(payload)
            if !delta.isEmpty { appendAssistantDelta(delta) }
            let phase = (payload["phase"] as? String) ?? (payload["lifecycle"] as? String) ?? ""
            if ["end", "final", "done", "completed", "aborted", "error"].contains(phase) {
                activeRunId = nil
                finishStreaming()
            }
        }
    }

    private func sendConnect(nonce: String, signedAt: Int64) {
        do {
            let identity = try store.identity()
            let saved = store.token()
            let authToken = saved?.token ?? bootstrapToken
            let platform = "ios"
            let family = "mobile"
            let signingPayload = [
                "v3", identity.id, "cli", "cli", "operator", scopes.joined(separator: ","),
                String(signedAt), authToken, nonce, platform, family
            ].joined(separator: "|")
            let device: [String: Any] = [
                "id": identity.id,
                "publicKey": identity.publicKey,
                "signature": try store.sign(identity, payload: signingPayload),
                "signedAt": signedAt,
                "nonce": nonce
            ]
            var auth: [String: Any] = ["token": authToken]
            if let saved { auth["deviceToken"] = saved.token }
            let params: [String: Any] = [
                "minProtocol": 4,
                "maxProtocol": 4,
                "client": ["id": "cli", "version": "0.7.0-dev", "platform": platform, "deviceFamily": family, "mode": "cli"],
                "role": "operator",
                "scopes": scopes,
                "caps": [],
                "commands": [],
                "permissions": [:],
                "auth": auth,
                "locale": Locale.current.identifier,
                "userAgent": "openclaw-mobile-ios/0.7.0-dev",
                "device": device
            ]
            connectId = request("connect", params: params)
        } catch {
            statusDetail = "Identity error: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func request(_ method: String, params: [String: Any] = [:]) -> String {
        let id = UUID().uuidString
        pending[id] = method
        let envelope: [String: Any] = ["type": "req", "id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let text = String(data: data, encoding: .utf8) else { return id }
        socket?.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.statusDetail = error.localizedDescription }
        }
        return id
    }

    private func scheduleReconnect() {
        guard !closing else { return }
        connectionState = .reconnecting
        let exponent = min(reconnectAttempt, 6)
        let delayMs = min(500 * (1 << exponent), 30_000)
        reconnectAttempt += 1
        statusDetail = "Retrying in \(Double(delayMs) / 1000.0)s"
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.connect() }
        }
    }

    private func parseSessions(_ payload: Any?) {
        let array: [[String: Any]]
        if let direct = payload as? [[String: Any]] { array = direct }
        else if let dict = payload as? [String: Any] { array = (dict["sessions"] as? [[String: Any]]) ?? (dict["items"] as? [[String: Any]]) ?? [] }
        else { return }
        sessions = array.compactMap { item in
            let key = (item["key"] as? String) ?? (item["sessionKey"] as? String) ?? ""
            guard !key.isEmpty else { return nil }
            let title = (item["title"] as? String) ?? (item["name"] as? String) ?? key
            let updated = number(item["updatedAt"]) ?? number(item["lastActivityAt"]) ?? 0
            return SessionSummary(key: key, title: title, updatedAt: updated)
        }
        cache.saveSessions(sessions)
    }

    private func parseHistory(_ payload: Any?) {
        let array: [[String: Any]]
        if let direct = payload as? [[String: Any]] { array = direct }
        else if let dict = payload as? [String: Any] {
            array = (dict["messages"] as? [[String: Any]]) ?? (dict["items"] as? [[String: Any]]) ?? (dict["history"] as? [[String: Any]]) ?? []
        } else { return }
        let fresh = array.enumerated().compactMap { index, item -> ChatMessage? in
            let nested = item["message"] as? [String: Any]
            let role = (item["role"] as? String) ?? (nested?["role"] as? String) ?? ""
            guard ["user", "assistant", "system", "tool"].contains(role) else { return nil }
            let text = extractText(item)
            guard !text.isEmpty || role == "tool" else { return nil }
            let id = (item["id"] as? String) ?? (item["messageId"] as? String) ?? "hist-\(index)"
            return ChatMessage(id: id, role: role, text: text, attachments: attachmentNames(item))
        }
        if !fresh.isEmpty || messages.isEmpty {
            messages = fresh
            streamingMessageId = nil
            cache.saveMessages(messages, sessionKey: selectedSession)
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        if let id = streamingMessageId, let i = messages.firstIndex(where: { $0.id == id }) {
            let old = messages[i].text
            messages[i].text = delta.hasPrefix(old) && delta.count > old.count ? delta : old + delta
        } else {
            let id = "stream-\(UUID().uuidString)"
            messages.append(ChatMessage(id: id, role: "assistant", text: delta, streaming: true))
            streamingMessageId = id
        }
        cache.saveMessages(messages, sessionKey: selectedSession)
    }

    private func finishStreaming() {
        if let id = streamingMessageId, let i = messages.firstIndex(where: { $0.id == id }) { messages[i].streaming = false }
        streamingMessageId = nil
        cache.saveMessages(messages, sessionKey: selectedSession)
    }

    private func extractText(_ item: [String: Any]) -> String {
        for key in ["delta", "text", "content"] { if let value = item[key] as? String, !value.isEmpty { return value } }
        if let message = item["message"] as? [String: Any] { return extractText(message) }
        if let content = item["content"] as? [[String: Any]] {
            return content.compactMap { block in
                guard let type = block["type"] as? String, ["text", "output_text", "input_text"].contains(type) else { return nil }
                return block["text"] as? String
            }.joined()
        }
        return ""
    }

    private func attachmentNames(_ item: [String: Any]) -> [String] {
        let nested = item["message"] as? [String: Any]
        let attachments = (item["attachments"] as? [[String: Any]]) ?? (nested?["attachments"] as? [[String: Any]]) ?? []
        return attachments.map { ($0["fileName"] as? String) ?? ($0["name"] as? String) ?? "attachment" }
    }

    private func number(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}
