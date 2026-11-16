import ActivityKit
import Foundation

/// Drives the Dynamic Island / Live Activity that shows the synced lyric
/// of the song playing in the Lizi web player.
///
/// Adapted from island-lyrics, but deliberately NOT @MainActor: the Lizi
/// WebHost that owns this manager is not MainActor-isolated, and Swift
/// rejects creating a MainActor object as a default property value in a
/// nonisolated context. ActivityKit calls are hopped to the main actor
/// internally, so the actual island updates still run on the main thread.
///
/// Hard rules (learned from the sibling kun project):
/// - Starting requires ONLY `areActivitiesEnabled`. A switched-off
///   "More Frequent Updates" (frequentPushesEnabled, iOS 17.2+) is a warning,
///   never a gate — otherwise the island silently stays black.
/// - `staleDate` is 15 seconds on every push, so the island disappears
///   shortly after playback stops.
/// - Ending uses dismissalPolicy `.immediate`.
final class LiveActivityManager {

    enum IslandAuthorization {
        /// System Live Activities are on. Frequent updates may still be off;
        /// that is reported separately as a warning.
        case allowed
        /// System Live Activities are off; nothing can be started.
        case notAllowed
        /// Live Activities are on, but "More Frequent Updates" is off.
        /// Starting still works; updates may be throttled by the system.
        case frequentUpdatesOffWarning
    }

    private(set) var isRunning: Bool = false
    private(set) var lastError: String?
    private(set) var authorization: IslandAuthorization = .notAllowed

    private var activity: Activity<LiziLyricsAttributes>?

    init() {
        refreshAuthorization()
        // Clear any activity left over from a previous launch.
        Task { @MainActor in await self.endAllActivities() }
    }

    /// Re-reads the system authorization state. Call when the app returns
    /// to the foreground.
    func refreshAuthorization() {
        let info = ActivityAuthorizationInfo()
        if !info.areActivitiesEnabled {
            authorization = .notAllowed
        } else if !info.frequentPushesEnabled {
            authorization = .frequentUpdatesOffWarning
        } else {
            authorization = .allowed
        }
    }

    /// Starts (or restarts) the island activity for a track.
    /// If an activity is already running it is ended first.
    func startActivity(title: String, artist: String, state: LiziLyricsAttributes.ContentState) {
        refreshAuthorization()
        guard authorization != .notAllowed else {
            lastError = "系统未允许 Live Activities，请在 iOS 设置中开启"
            return
        }
        Task { @MainActor in
            if let existing = self.activity {
                await existing.end(nil, dismissalPolicy: .immediate)
                self.activity = nil
            }
            let attributes = LiziLyricsAttributes(title: title, artist: artist)
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15))
            do {
                let newActivity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
                self.activity = newActivity
                self.isRunning = true
                self.lastError = nil
            } catch {
                self.lastError = "启动灵动岛失败：\(error.localizedDescription)"
                self.isRunning = false
            }
        }
    }

    /// Pushes a new state to the running activity. No-op when none is running.
    /// The coordinator throttles calls: only on lyric-line / track change,
    /// or a progress refresh at most every 5 seconds.
    func updateActivity(state: LiziLyricsAttributes.ContentState) {
        guard let activity else { return }
        Task { @MainActor in
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15))
            await activity.update(content)
        }
    }

    /// Ends the activity immediately. No-op when none is running.
    func endActivity() {
        guard let activity else { return }
        self.activity = nil
        isRunning = false
        Task { @MainActor in
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Ends every live activity of this type, including ones left over from
    /// a previous launch. (In this SDK `Activity.activities` is a plain
    /// array, not an async sequence.)
    private func endAllActivities() async {
        for activity in Activity<LiziLyricsAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        if activity == nil {
            isRunning = false
        }
    }
}
