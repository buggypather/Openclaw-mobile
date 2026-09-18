import SwiftUI

@main
struct OpenClawMobileApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ChatView(model: model, client: model.client)
                .onAppear { model.connect() }
        }
    }
}
