import AppKit
import Sparkle

/// Sparkle auto-updates. Checks the appcast from the latest GitHub release once a day.
/// Development builds run without an Info.plist feed URL and skip updating entirely.
@MainActor
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    private(set) var controller: SPUStandardUpdaterController!

    static var isConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: Self.isConfigured, updaterDelegate: nil, userDriverDelegate: self)
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    func checkForUpdates() {
        guard Self.isConfigured else { return }
        // Shift has no Dock icon; bring it forward so Sparkle's window shows on top.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Background apps should not pop windows over your work unannounced; Sparkle then shows them gently.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in NSApp.activate() }
    }
}
