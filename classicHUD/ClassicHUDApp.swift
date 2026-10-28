//
//  ClassicHUDApp.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

import AppKit
import Foundation
import SwiftUI
@preconcurrency import UserNotifications

// MARK: - AppDelegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    // MARK: - Launch Detection

    /// Maximum system uptime to consider as "just logged in" (3 minutes)
    private nonisolated static let loginUptimeThreshold: TimeInterval = 180.0

    /// How often to retry starting media key interception until it succeeds
    private nonisolated static let interceptionRetryInterval: TimeInterval = 1.0

    var volumeMonitor: VolumeMonitor!
    #if !SANDBOX
        var brightnessMonitor: BrightnessMonitor!
        var mediaKeyInterceptor: MediaKeyInterceptor?
    #endif // !SANDBOX
    var hudController: HUDController!
    var aboutWindow: NSPanel?
    var loginItemManager: LoginItemManager!

    let logger: Logger = .init()

    #if !SANDBOX
        /// Check to see if brightness is enabled
        private var isBrightnessEnabled: Bool {
            UserDefaults.standard.bool(forKey: SettingsKey.brightnessEnabled)
        }

        /// Retries starting media key interception, for example after a late Accessibility grant
        private var interceptionRetryTimer: Timer?

        /// Whether key observation has been restarted since Accessibility became trusted
        private var didRestartObserversForTrust = false
    #endif // !SANDBOX

    // MARK: - On Finish Launching

    func applicationDidFinishLaunching(_: Notification) {
        // Skip full initialization if running in SwiftUI preview or test mode
        let isDevEnvironment = isRunningInDevEnvironment()
        if isDevEnvironment { return }

        // Check for other instances running from different bundle paths
        if let otherInstancePath = checkForConflictingInstance() {
            showConflictAlert(otherPath: otherInstancePath) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
            return
        }

        // Keep the app headless and out of the Dock
        NSApplication.shared.setActivationPolicy(.accessory)

        // Set up the notifications delegate BEFORE scheduling any notifications
        UNUserNotificationCenter.current().delegate = self

        // Initialize login item manager, monitors, and HUD controller
        loginItemManager = LoginItemManager()
        volumeMonitor = VolumeMonitor(isPreviewMode: false)
        #if !SANDBOX
            brightnessMonitor = BrightnessMonitor(isPreviewMode: false)
        #endif // !SANDBOX
        hudController = HUDController(isPreviewMode: false)

        // Set up bidirectional references
        volumeMonitor.hudController = hudController
        #if !SANDBOX
            brightnessMonitor.hudController = hudController
        #endif // !SANDBOX

        #if !SANDBOX
            // Request accessibility permissions if needed
            requestAccessibilityPermissionsIfNeeded()
        #endif // !SANDBOX

        // Request notification permission and post "started" notification
        requestNotificationAuthorizationIfNeeded { [weak self] granted in
            guard let self else { return }
            logger.debug("Notification permission granted: \(granted)")
            if granted {
                // Only show startup notification if launched manually
                if isManualLaunch() {
                    Task { @MainActor in
                        self.postUserNotification(title: "classicHUD started!", body: nil)
                    }
                } else {
                    logger.info("Skipping startup notification due to automatic launch.")
                }
            } else {
                logger.info("No notification permission; skipping startup notification.")
            }
        }

        // Start monitoring volume changes
        volumeMonitor.startMonitoring()

        #if !SANDBOX
            // Start brightness monitoring only if enabled in settings
            updateBrightnessMonitoring()

            // Start media key interceptor to hide system HUDs, retrying until it succeeds
            ensureMediaKeyInterception()
        #endif // !SANDBOX

        // Start monitoring display configuration changes
        hudController.startDisplayChangeMonitoring()
    }

    /// If we get a new "open" event, also show the about window
    func application(_: NSApplication, open _: [URL]) {
        showAboutWindow()
    }

    /// Open the about window when the app is opened while already running
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        showAboutWindow()
        return false
    }

    #if !SANDBOX
        /// Start or stop brightness monitoring to match the setting.
        @MainActor
        func updateBrightnessMonitoring() {
            if isBrightnessEnabled {
                logger.info("Brightness HUD enabled; starting brightness monitoring.")
                brightnessMonitor.startMonitoring()
            } else {
                logger.info("Brightness HUD disabled; stopping brightness monitoring.")
                brightnessMonitor.stopMonitoring()
            }
        }

        /// Start the media key interceptor to hide system HUDs. The interceptor automatically falls
        /// back to system HUDs if interception fails.
        @MainActor
        @discardableResult
        func startMediaKeyInterceptor() -> Bool {
            // Create the interceptor if not already created
            if mediaKeyInterceptor == nil {
                mediaKeyInterceptor = MediaKeyInterceptor()
                mediaKeyInterceptor?.hudController = hudController

                // Connect VolumeMonitor to interceptor so it can skip HUD updates when the
                // interceptor is handling volume changes
                volumeMonitor.mediaKeyInterceptor = mediaKeyInterceptor
            }

            guard mediaKeyInterceptor?.start() == true else { return false }
            logger.info("Media key interceptor started.")
            return true
        }
    #endif // !SANDBOX

    // MARK: - Notification Center Delegate

    /// Ensure banners appear even if the app is active
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler:
        @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        completionHandler([.banner])
    }

    /// Show the About window when the startup notification is tapped
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void,
    ) {
        Task { @MainActor in self.showAboutWindow() }
        completionHandler()
    }

    // MARK: - Environment Check

    /// Check to see if we're running in a development environment (SwiftUI preview, test mode,
    /// etc.)
    private nonisolated func isRunningInDevEnvironment() -> Bool {
        if
            ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
            NSClassFromString("XCTest") != nil ||
            ProcessInfo.processInfo.processName.contains("XCPreviewAgent") ||
            ProcessInfo.processInfo.processName.contains("PreviewHost")
        {
            return true
        }

        return false
    }

    /// Returns true if manual launch (user double-clicked), false for automatic (login item).
    private nonisolated func isManualLaunch() -> Bool {
        if isRunningInDevEnvironment() { return false }

        // Check 1: System uptime heuristic If the system just booted (uptime < 3 minutes), likely a
        // login item launch
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime < Self.loginUptimeThreshold {
            logger.debug("Launch detected via system uptime heuristic (uptime: \(String(format: "%.0f", uptime))s)")
            return false // Likely launched at login
        }

        // Default to manual launch
        logger.debug("Manual launch detected (uptime: \(String(format: "%.0f", uptime))s)")
        return true
    }

    /// Checks for another copy of this app (release, debug, or sandbox build) running from a different
    /// bundle path. Returns the conflicting bundle path if found, nil otherwise.
    private func checkForConflictingInstance() -> String? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundlePath = Bundle.main.bundleURL.standardizedFileURL.path

        // Debug and sandbox builds append ".debug" or ".mas" to the release bundle ID.
        guard let bundleID = Bundle.main.bundleIdentifier else {
            logger.warning("Could not determine bundle identifier for conflict detection")
            return nil
        }
        let baseBundleID = bundleID.replacing(/\.(debug|mas)$/, with: "")

        for app in NSWorkspace.shared.runningApplications {
            guard
                app.processIdentifier != currentPID,
                let otherID = app.bundleIdentifier,
                otherID == baseBundleID || otherID.hasPrefix(baseBundleID + "."),
                let otherPath = app.bundleURL?.standardizedFileURL.path,
                otherPath != currentBundlePath else { continue }
            return otherPath
        }
        return nil
    }

    /// Shows a warning alert when another instance is detected running from a different location.
    @MainActor
    private func showConflictAlert(otherPath: String, onDismiss: (() -> Void)? = nil) {
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String) ?? "This Application"

        let alert = NSAlert()
        alert.messageText = "Another \(appName) Instance Detected"
        alert.informativeText = """
        Another copy of \(appName) is already running from a different location:

        \(otherPath)

        This instance will now exit. Please quit the other instance first if you want to run this version instead.

        Tip: Use 'pkill -f \(appName)' in Terminal to stop all instances.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        let previousPolicy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        alert.runModal()

        if previousPolicy != .regular {
            NSApplication.shared.setActivationPolicy(previousPolicy)
        }

        onDismiss?()
    }

    // MARK: - Show About Window

    private func showAboutWindow() {
        // If window already exists and is visible, just bring it to the front
        if let window = aboutWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Create the About window
        let aboutView = AboutView(
            onQuit: { [weak self] in
                self?.aboutWindow?.close()
                self?.aboutWindow = nil
                self?.gracefulTerminate()
            },
            appDelegate: self,
        )
        .environment(\.loginItemManager, loginItemManager)

        let hostingController = NSHostingController(rootView: aboutView)

        // Use NSPanel to remain in accessory mode
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )

        panel.contentViewController = hostingController
        panel.title = "About classicHUD"

        // Prevent the panel from closing when clicking away
        panel.hidesOnDeactivate = false

        // Position at visual center of the screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let windowWidth: CGFloat = 600
            let windowHeight: CGFloat = 300

            let x = screenFrame.origin.x + (screenFrame.width - windowWidth) / 2
            let y = screenFrame.origin.y + screenFrame.height * 0.66 - windowHeight / 2

            panel.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: false)
        }

        panel.isReleasedWhenClosed = false

        aboutWindow = panel

        // Show the panel without changing activation policy
        panel.makeKeyAndOrderFront(nil)
    }

    #if !SANDBOX

        // MARK: - Accessibility Permissions

        private func requestAccessibilityPermissionsIfNeeded() {
            if AXIsProcessTrusted() {
                logger.info("Accessibility permissions already granted.")
                didRestartObserversForTrust = true // Observers start with permissions in place.
                return
            }

            logger.info("Prompting for accessibility permissions.")
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        /// Starts media key interception now, or keeps retrying until it succeeds. Covers both a
        /// late Accessibility grant and a tap that fails to install even though trust is granted.
        private func ensureMediaKeyInterception() {
            guard !startMediaKeyInterceptor() else { return }

            logger.warning("Media key interceptor not started yet; retrying until it is. Accessibility permissions may be required.")
            interceptionRetryTimer?.invalidate()
            interceptionRetryTimer = Timer.scheduledTimer(withTimeInterval: Self.interceptionRetryInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryMediaKeyInterception() }
            }
        }

        private func retryMediaKeyInterception() {
            guard AXIsProcessTrusted() else { return }

            if !didRestartObserversForTrust {
                // Key observation installed before the grant may be missing paths; recreate it once.
                didRestartObserversForTrust = true
                logger.info("Accessibility permissions granted; restarting key monitoring.")
                brightnessMonitor.updateAccessibilityStatus()
                volumeMonitor.restartKeyMonitoring()
                brightnessMonitor.restartKeyMonitoring()
            }

            guard startMediaKeyInterceptor() else { return }
            interceptionRetryTimer?.invalidate()
            interceptionRetryTimer = nil
        }
    #endif // !SANDBOX

    // MARK: - Notification Permissions

    private func requestNotificationAuthorizationIfNeeded(
        completion: @escaping @Sendable (Bool) -> Void,
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion(true)

            case .denied:
                completion(false)

            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    completion(granted)
                }

            @unknown default:
                completion(false)
            }
        }
    }

    // MARK: - Post Notification

    private func postUserNotification(title: String, body: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil,
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error { self.logger.warning("Failed to post notification: \(error)") }
        }
    }

    // MARK: - Graceful Termination

    /// Stop volume and brightness monitoring and quit the app
    private func gracefulTerminate() {
        logger.debug("Stopping monitoring and quitting.")
        volumeMonitor?.stopMonitoring()

        #if !SANDBOX
            interceptionRetryTimer?.invalidate()
            interceptionRetryTimer = nil
            brightnessMonitor?.stopMonitoring()
            mediaKeyInterceptor?.stop()
        #endif // !SANDBOX
        hudController?.stopDisplayChangeMonitoring()

        // Terminate without activating the app
        NSApp.terminate(nil)
    }
}

// MARK: - ClassicHUDApp

@main
@available(macOS 26.0, *)
struct ClassicHUDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Before any view or monitor reads a setting.
        SettingsKey.registerDefaults()
    }

    @available(macOS 26.0, *)
    var body: some Scene {
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 0, height: 0)
        .windowResizability(.contentSize)
    }
}
