import AppKit
import ApplicationServices

enum SessionSnapshotService {

    // MARK: - Capture

    /// Snapshot window positions for all running pinned apps in a profile.
    static func captureSnapshot(for profile: Profile) -> SessionSnapshot {
        var windows: [WindowSnapshot] = []
        var zIndex = 0

        for app in profile.pinnedApps {
            guard let running = app.runningApplication else { continue }
            let axApp = AXUIElementCreateApplication(running.processIdentifier)

            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                // Only capture standard windows
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXRoleAttribute as CFString, &roleRef)
                let role = (roleRef as? String) ?? ""
                guard role == (kAXWindowRole as String) else { continue }

                // Title
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                // Position
                var posRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                var position = CGPoint.zero
                if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &position) }

                // Size
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                var size = CGSize.zero
                if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }

                // Minimized
                var minRef: CFTypeRef?
                let minResult = AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef)
                let isMinimized = (minResult == .success) && (minRef as? Bool == true)

                windows.append(WindowSnapshot(
                    bundleIdentifier: app.bundleIdentifier,
                    windowTitle: title,
                    frame: CGRect(origin: position, size: size),
                    isMinimized: isMinimized,
                    zIndex: zIndex
                ))
                zIndex += 1
            }
        }

        return SessionSnapshot(
            profileId: profile.id,
            capturedAt: Date(),
            windows: windows,
            displayConfigKey: SessionSnapshot.currentDisplayConfigKey
        )
    }

    // MARK: - Restore

    /// Restore saved window positions for all running pinned apps in a profile.
    static func restoreSnapshot(_ snapshot: SessionSnapshot, for profile: Profile) {
        // Group saved windows by bundle ID
        var remaining: [String: [WindowSnapshot]] = [:]
        for ws in snapshot.windows {
            remaining[ws.bundleIdentifier, default: []].append(ws)
        }

        for app in profile.pinnedApps {
            guard let running = app.runningApplication,
                  var saved = remaining[app.bundleIdentifier],
                  !saved.isEmpty
            else { continue }

            let axApp = AXUIElementCreateApplication(running.processIdentifier)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else { continue }

            var windowIndex = 0
            for axWindow in axWindows {
                guard !saved.isEmpty else { break }

                // Match by title first; fall back to positional order (not always index 0)
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                let matchIndex: Int
                if let exactMatch = saved.firstIndex(where: { $0.windowTitle == title }) {
                    matchIndex = exactMatch
                } else if windowIndex < saved.count {
                    matchIndex = windowIndex
                } else {
                    matchIndex = 0
                }
                let match = saved.remove(at: matchIndex)
                windowIndex += 1

                // Set position
                var position = match.frame.origin
                if let posValue = AXValueCreate(.cgPoint, &position) {
                    AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
                }

                // Set size
                var size = match.frame.size
                if let sizeValue = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
                }

                // Restore minimized state
                AXUIElementSetAttributeValue(
                    axWindow,
                    kAXMinimizedAttribute as CFString,
                    match.isMinimized as CFBoolean
                )
            }
        }

        // Restore z-ordering: raise windows from back to front
        let sortedWindows = snapshot.windows.sorted { $0.zIndex > $1.zIndex }
        for ws in sortedWindows {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: ws.bundleIdentifier).first else { continue }
            let axApp = AXUIElementCreateApplication(running.processIdentifier)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                if (titleRef as? String) == ws.windowTitle {
                    AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                    break
                }
            }
        }
    }

    // MARK: - Hide / Unhide

    /// Hide outgoing profile's apps, skipping any shared with the incoming profile.
    static func hideProfileApps(_ outgoing: Profile, excluding incoming: Profile) {
        let incomingBundles = Set(incoming.pinnedApps.map(\.bundleIdentifier))
        for app in outgoing.pinnedApps {
            guard !incomingBundles.contains(app.bundleIdentifier) else { continue }
            app.runningApplication?.hide()
        }
    }

    /// Quit outgoing profile's apps, skipping any shared with the incoming profile.
    /// Apps that can't be quit (Finder) are hidden instead.
    static func quitProfileApps(_ outgoing: Profile, excluding incoming: Profile) {
        let incomingBundles = Set(incoming.pinnedApps.map(\.bundleIdentifier))
        for app in outgoing.pinnedApps {
            guard !incomingBundles.contains(app.bundleIdentifier),
                  let running = app.runningApplication else { continue }
            if app.bundleIdentifier == "com.apple.finder" || !running.terminate() {
                running.hide()
            }
        }
    }

    /// Unhide all running apps belonging to a profile.
    static func unhideProfileApps(_ profile: Profile) {
        for app in profile.pinnedApps {
            guard let running = app.runningApplication, running.isHidden else { continue }
            running.unhide()
        }
    }

    // MARK: - Save & Close / Restore

    /// Quit all running apps in a profile (used for "Save & Close").
    static func quitProfileApps(_ profile: Profile) {
        for app in profile.pinnedApps {
            app.runningApplication?.terminate()
        }
    }

    /// Launch all pinned apps in a profile that aren't already running.
    static func launchProfileApps(_ profile: Profile) {
        for app in profile.pinnedApps {
            launchAndVerify(app, attemptsLeft: launchAttempts)
        }
    }

    private static let launchAttempts = 3
    private static let launchVerifyDelay: TimeInterval = 4

    /// Launch an app, then check it is still running and try again if not.
    ///
    /// Some apps exit right after launch instead of opening a window — VS Code
    /// does this when HopTab starts it, quitting ~0.1s in after an Electron
    /// code-signing check. A later attempt usually succeeds, so retry a few times
    /// rather than leaving the profile without the app.
    private static func launchAndVerify(_ app: PinnedApp, attemptsLeft: Int) {
        guard app.runningApplication == nil, let url = app.applicationURL else { return }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("[SessionSnapshotService] Launch of %@ failed: %@",
                      app.bundleIdentifier, error.localizedDescription)
            }
        }

        guard attemptsLeft > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + launchVerifyDelay) {
            guard app.runningApplication == nil else { return }
            NSLog("[SessionSnapshotService] %@ did not stay running — retrying (%d left)",
                  app.bundleIdentifier, attemptsLeft - 1)
            launchAndVerify(app, attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Check if any pinned apps in a profile are currently running.
    static func hasRunningApps(_ profile: Profile) -> Bool {
        profile.pinnedApps.contains { $0.isRunning }
    }
}
