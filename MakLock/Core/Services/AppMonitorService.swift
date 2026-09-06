import AppKit
import Combine

/// Monitors app launches and activations to detect when a protected app starts.
final class AppMonitorService: ObservableObject {
    static let shared = AppMonitorService()

    /// Published when a protected app is launched or activated.
    @Published var detectedApp: ProtectedApp?

    /// Callback invoked when a protected app is detected.
    var onProtectedAppDetected: ((ProtectedApp) -> Void)?

    private var cancellables = Set<AnyCancellable>()

    /// Apps that have been authenticated in the current session.
    /// Cleared when the app terminates, on idle timeout, sleep, or manual clear.
    private var authenticatedApps: Set<String> = []

    /// Bundle IDs that have a pending overlay prompt (not yet authenticated or cancelled).
    /// Prevents checkRunningApps from triggering duplicate prompts.
    private var pendingLockBundleIDs: Set<String> = []

    private var windowPollTimer: Timer?
    private var lastHadWindows: [String: Bool] = [:]

    private init() {}

    /// Start monitoring app launches and activations.
    func startMonitoring() {
        let workspace = NSWorkspace.shared

        // Monitor app launches
        workspace.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                self?.updateWindowPolling()
                self?.handleAppEvent(app, trigger: .launch)
            }
            .store(in: &cancellables)

        // Monitor app activations (switching to a running protected app)
        workspace.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                self?.handleAppEvent(app, trigger: .activate)
            }
            .store(in: &cancellables)

        // Monitor app terminations — clear auth when a protected app quits
        workspace.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                guard let bundleID = app.bundleIdentifier else { return }
                self?.pendingLockBundleIDs.remove(bundleID)
                if self?.authenticatedApps.contains(bundleID) == true {
                    self?.authenticatedApps.remove(bundleID)
                    NSLog("[MakLock] App terminated, auth cleared: %@", bundleID)
                }
                DispatchQueue.main.async { self?.updateWindowPolling() }
            }
            .store(in: &cancellables)

        // Monitor app deactivation — clear auth when user quits an app that stays
        // alive in the background (e.g. Messages closes windows on Cmd+Q but process
        // survives). Does NOT clear auth on Cmd+H (hide) or simple app switch.
        workspace.notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                guard let self, let bundleID = app.bundleIdentifier else { return }
                guard self.authenticatedApps.contains(bundleID) else { return }

                if Defaults.shared.appSettings.requireAuthOnActivate,
                   ProtectedAppsManager.shared.isProtected(bundleID) {
                    self.authenticatedApps.remove(bundleID)
                    NSLog("[MakLock] App deactivated, auth cleared (auth on switch): %@", bundleID)
                    return
                }

                // Delay to let window close animations finish
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    if app.isTerminated {
                        self.authenticatedApps.remove(bundleID)
                        self.pendingLockBundleIDs.remove(bundleID)
                        NSLog("[MakLock] App terminated (deactivate check), auth cleared: %@", bundleID)
                    } else if !app.isHidden && !self.appHasWindows(app) {
                        self.authenticatedApps.remove(bundleID)
                        self.pendingLockBundleIDs.remove(bundleID)
                        NSLog("[MakLock] App quit (no windows), auth cleared: %@", bundleID)
                    }
                }
            }
            .store(in: &cancellables)

        updateWindowPolling()

        NSLog("[MakLock] App monitor started")

        // Check already-running protected apps (e.g. after MakLock restart)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkRunningApps()
        }
    }

    /// Scan currently running apps and trigger lock for any protected ones.
    private func checkRunningApps() {
        let protectedList = Defaults.shared.protectedApps
        let settings = Defaults.shared.appSettings

        NSLog("[MakLock] checkRunningApps: %d protected, protection=%@",
              protectedList.count, settings.isProtectionEnabled ? "ON" : "OFF")

        guard settings.isProtectionEnabled else { return }

        let workspace = NSWorkspace.shared
        for runningApp in workspace.runningApplications {
            guard let bundleID = runningApp.bundleIdentifier else { continue }

            if let protectedApp = protectedList.first(where: {
                $0.bundleIdentifier == bundleID && $0.isEnabled
            }) {
                guard !authenticatedApps.contains(bundleID) else { continue }
                guard !pendingLockBundleIDs.contains(bundleID) else { continue }
                guard !OverlayWindowService.shared.isShowing else { continue }

                NSLog("[MakLock] Found running protected app: %@ (%@)", protectedApp.name, bundleID)
                detectedApp = protectedApp
                onProtectedAppDetected?(protectedApp)
                return // Only lock one at a time
            }
        }
    }

    /// Stop monitoring.
    func stopMonitoring() {
        cancellables.removeAll()
        stopWindowPolling()
        NSLog("[MakLock] App monitor stopped")
    }

    /// Mark an app as authenticated. It stays unlocked until the app quits, idle, or sleep.
    func markAuthenticated(_ bundleIdentifier: String) {
        authenticatedApps.insert(bundleIdentifier)
        pendingLockBundleIDs.remove(bundleIdentifier)
        NSLog("[MakLock] App session authenticated: %@", bundleIdentifier)
    }

    /// Clear all authentication sessions (called on idle timeout, sleep, Watch out of range).
    func clearAllAuthentications() {
        authenticatedApps.removeAll()
        pendingLockBundleIDs.removeAll()
        NSLog("[MakLock] All app sessions cleared")
    }

    /// Clear authentication for a specific app.
    func clearAuthentication(for bundleIdentifier: String) {
        authenticatedApps.remove(bundleIdentifier)
        pendingLockBundleIDs.remove(bundleIdentifier)
    }

    /// Check if an app is currently authenticated.
    func isAuthenticated(_ bundleIdentifier: String) -> Bool {
        authenticatedApps.contains(bundleIdentifier)
    }

    /// Check if an app has any normal-level windows (layer 0).
    /// Returns false when an app was Cmd+Q'd but its process stayed alive.
    private func appHasWindows(_ app: NSRunningApplication) -> Bool {
        guard let pids = pidsWithWindows(options: .optionAll) else { return true }
        return pids.contains(app.processIdentifier)
    }

    private func pidsWithWindows(options: CGWindowListOption) -> Set<Int32>? {
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var pids = Set<Int32>()
        for info in windowList {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            if let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
               let w = bounds["Width"], let h = bounds["Height"],
               w < 50 || h < 50 { continue }
            pids.insert(pid)
        }
        return pids
    }

    private enum Trigger {
        case launch
        case activate
    }

    private func startWindowPolling() {
        guard windowPollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollWindows()
        }
        timer.tolerance = 0.1
        windowPollTimer = timer
    }

    private func stopWindowPolling() {
        windowPollTimer?.invalidate()
        windowPollTimer = nil
        lastHadWindows.removeAll()
    }

    private func updateWindowPolling() {
        let running = NSWorkspace.shared.runningApplications
        let anyProtectedRunning = Defaults.shared.protectedApps.contains { protectedApp in
            protectedApp.isEnabled && running.contains { $0.bundleIdentifier == protectedApp.bundleIdentifier }
        }
        if anyProtectedRunning {
            startWindowPolling()
        } else {
            stopWindowPolling()
        }
    }

    private func pollWindows() {
        guard Defaults.shared.appSettings.isProtectionEnabled else { return }
        let protectedList = Defaults.shared.protectedApps.filter(\.isEnabled)
        guard !protectedList.isEmpty else { return }
        guard let pidsWithWindows = pidsWithWindows(options: .optionOnScreenOnly) else { return }

        let running = NSWorkspace.shared.runningApplications
        for protectedApp in protectedList {
            let bundleID = protectedApp.bundleIdentifier
            guard let app = running.first(where: { $0.bundleIdentifier == bundleID }) else {
                lastHadWindows[bundleID] = nil
                continue
            }

            let hasWindows = pidsWithWindows.contains(app.processIdentifier)
            let had = lastHadWindows[bundleID]
            lastHadWindows[bundleID] = hasWindows
            guard let had, had != hasWindows else { continue }

            if !hasWindows {
                if app.isActive && !app.isHidden && authenticatedApps.contains(bundleID) {
                    authenticatedApps.remove(bundleID)
                    pendingLockBundleIDs.remove(bundleID)
                    NSLog("[MakLock] All windows closed, auth cleared: %@", bundleID)
                }
            } else if app.isActive {
                handleAppEvent(app, trigger: .activate)
            }
        }
    }

    private func handleAppEvent(_ runningApp: NSRunningApplication, trigger: Trigger) {
        guard let bundleID = runningApp.bundleIdentifier else { return }

        // Skip blacklisted system apps
        guard !SafetyManager.isBlacklisted(bundleID) else { return }

        // Check if this app is in the protected list
        let protectedApps = Defaults.shared.protectedApps
        guard let protectedApp = protectedApps.first(where: {
            $0.bundleIdentifier == bundleID && $0.isEnabled
        }) else { return }

        // Check if global protection is enabled
        let settings = Defaults.shared.appSettings
        guard settings.isProtectionEnabled else { return }

        // Skip if app is already authenticated in this session
        guard !authenticatedApps.contains(bundleID) else { return }

        if trigger == .launch && !settings.requireAuthOnLaunch {
            markAuthenticated(bundleID)
            NSLog("[MakLock] Launch auth disabled, session opened: %@", bundleID)
            return
        }

        // Don't show overlay if one is already showing
        guard !OverlayWindowService.shared.isShowing else { return }

        // Don't trigger if a prompt is already pending for this app
        guard !pendingLockBundleIDs.contains(bundleID) else { return }

        NSLog("[MakLock] Protected app detected: %@ (%@)", protectedApp.name, bundleID)
        pendingLockBundleIDs.insert(bundleID)
        detectedApp = protectedApp
        onProtectedAppDetected?(protectedApp)
    }
}
