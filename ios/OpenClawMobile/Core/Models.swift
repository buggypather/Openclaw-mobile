import Foundation

struct SessionSummary: Identifiable, Codable, Hashable {
    let key: String
    var title: String
    var updatedAt: Int64
    var id: String { key }
}

struct AttachmentDraft: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let mimeType: String
    let bytes: Data
}

struct ChatMessage: Identifiable, Codable, Hashable {
    let id: String
    let role: String
    var text: String
    var attachments: [String] = []
    var streaming: Bool = false
    var failed: Bool = false
}

enum ConnectionState: String, Codable {
    case disconnected, connecting, connected, reconnecting, pairingRequired
}
