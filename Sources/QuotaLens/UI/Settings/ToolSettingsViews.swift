import SwiftUI

public struct GlobalSettingsView: View {
    @ObservedObject private var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        SettingsView(state: state, scope: .global)
    }
}

public struct CodexSettingsView: View {
    @ObservedObject private var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        SettingsView(state: state, scope: .codex)
    }
}

public struct ClaudeSettingsView: View {
    @ObservedObject private var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        SettingsView(state: state, scope: .claude)
    }
}
