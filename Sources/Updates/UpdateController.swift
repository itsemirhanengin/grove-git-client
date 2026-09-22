import Sparkle
import SwiftUI

/// Grove updating itself.
///
/// Sparkle checks a feed — the appcast named by `SUFeedURL` — and trusts what it
/// finds there because every archive in it carries an **EdDSA** signature made
/// with the private key in the releaser's Keychain, which Sparkle verifies
/// against the public key in `Info.plist`.
///
/// That signature scheme is Sparkle's own and entirely independent of Apple code
/// signing, which is the only reason any of this works while Grove still has no
/// Developer ID: an update cannot be tampered with in transit even though the
/// app it replaces is unsigned. What notarization would add is the *first*
/// install — Gatekeeper, not the update channel. See RELEASE.md.
@MainActor
@Observable
final class UpdateController {

    /// `nil` when this build cannot verify an update, which is the honest state
    /// of any build made before `bin/generate_keys` was first run.
    ///
    /// Constructing Sparkle's controller in that state is not harmless: it
    /// starts the updater immediately and reports an unverifiable feed as a
    /// *fatal* error, in an alert, on launch. So the check happens here, before
    /// Sparkle is touched, and a build without a key simply has no update
    /// command — which is also exactly what should happen in a fork or a
    /// checkout that has never published anything.
    static func ifConfigured() -> UpdateController? {
        func setting(_ key: String) -> String? {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            return (value?.isEmpty ?? true) ? nil : value
        }

        guard setting("SUPublicEDKey") != nil, setting("SUFeedURL") != nil else { return nil }
        return UpdateController()
    }

    private let controller: SPUStandardUpdaterController

    /// Whether the menu item should be enabled. False while a check or an
    /// install is already in flight.
    private(set) var canCheck: Bool

    /// Held only to keep the observation alive; it ends with this object, which
    /// lives as long as the app.
    private var observation: NSKeyValueObservation?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

        canCheck = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) {
            [weak self] _, change in
            // The **change**, not the updater. `SPUUpdater` is main-actor
            // isolated and KVO does not promise which thread it notifies on, so
            // the observed object is deliberately never touched in here — only
            // the `Bool` it handed over, which crosses isolation safely. A menu
            // item one hop late is not a problem.
            guard let canCheck = change.newValue else { return }
            Task { @MainActor in self?.canCheck = canCheck }
        }
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// The "Check for Updates…" menu item.
///
/// A view rather than a plain `Button` in the command group because a menu item
/// can only react to state — `canCheck` — through one.
struct CheckForUpdatesCommand: View {

    let updates: UpdateController

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheck)
    }
}
