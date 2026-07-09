import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            Text(model.menuBarText)
                .foregroundStyle(model.labelColor)
        }
        .menuBarExtraStyle(.window)
    }
}
