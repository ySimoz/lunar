import AppKit
import Foundation
import Observation

/// Coordinates preference editing, `NSApp.appearance` sync, and `PUT /api/preferences`.
@Observable
@MainActor
public final class SettingsViewModel {
    public var preferences: UserPreferences
    public private(set) var isSaving: Bool = false
    public var errorMessage: String?

    private var client: (any CoreClientProtocol)?

    public init(
        preferences: UserPreferences = UserPreferences(),
        client: (any CoreClientProtocol)? = nil
    ) {
        self.preferences = preferences
        self.client = client
    }

    public func configure(client: any CoreClientProtocol) {
        self.client = client
    }

    public nonisolated static func resolvedAppearance(for colorMode: String?) -> NSAppearance? {
        switch colorMode?.lowercased() {
        case "light":
            return NSAppearance(named: .aqua)
        case "dark":
            return NSAppearance(named: .darkAqua)
        default:
            return nil
        }
    }

    public func applySystemAppearance() {
        NSApplication.shared.appearance = Self.resolvedAppearance(for: preferences.colorMode)
    }

    public func update(_ mutate: (inout UserPreferences) -> Void) async {
        var draft = preferences
        mutate(&draft)
        preferences = draft
        applySystemAppearance()

        guard let client else { return }
        isSaving = true
        defer { isSaving = false }

        do {
            let saved = try await client.updatePreferences(draft)
            preferences = saved
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
