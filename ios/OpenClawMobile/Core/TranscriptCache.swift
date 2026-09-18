import Foundation
import CryptoKit

final class TranscriptCache {
    private let root: URL

    init(gatewayURL: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("OpenClaw/chat-cache/\(Self.hash(gatewayURL))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func saveSessions(_ sessions: [SessionSummary]) {
        write(sessions, to: root.appendingPathComponent("sessions.json"))
    }

    func loadSessions() -> [SessionSummary] {
        read([SessionSummary].self, from: root.appendingPathComponent("sessions.json")) ?? []
    }

    func saveMessages(_ messages: [ChatMessage], sessionKey: String) {
        write(messages, to: sessionFile(sessionKey))
    }

    func loadMessages(sessionKey: String) -> [ChatMessage] {
        read([ChatMessage].self, from: sessionFile(sessionKey)) ?? []
    }

    private func sessionFile(_ key: String) -> URL {
        root.appendingPathComponent("session-\(Self.hash(key)).json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
