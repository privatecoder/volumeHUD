//
//  HUDController.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// Owns the borderless HUD window: shows it, picks its screen, and hides it after a short delay.
@MainActor
final class HUDController: ObservableObject {
    private static let hudSize = NSSize(width: 200, height: 200)

    @Published var isShowing = false

    let logger: Logger = .init()

    private let isPreviewMode: Bool
    private var hudWindow: NSWindow?
    private var hostingView: NSHostingView<HUDView>?
    private var hideTimer: Timer?
    private var lastShownVolume: Float?
    private var lastShownMuted: Bool?
    private var lastShownBrightness: Float?
    private var lastShownHUDType: HUDType?
    private var isObservingDisplayChanges = false
    /// Incremented on every show. Hide timers and fade-out completions from an earlier show compare
    /// against it and do nothing if a newer show has happened since.
    private var presentationGeneration = 0

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
    }

    func showVolumeHUD(volume: Float, isMuted: Bool) {
        displayHUD(hudType: .volume, value: volume, isMuted: isMuted)
    }

    #if !SANDBOX
        func showBrightnessHUD(brightness: Float) {
            guard UserDefaults.standard.bool(forKey: SettingsKey.brightnessEnabled) else {
                logger.debug("Brightness HUD disabled; skipping display.")
                return
            }
            displayHUD(hudType: .brightness, value: brightness, isMuted: false)
        }
    #endif // !SANDBOX

    // MARK: Display Changes

    func startDisplayChangeMonitoring() {
        guard !isObservingDisplayChanges else { return }
        isObservingDisplayChanges = true

        if isPreviewMode {
            logger.debug("Skipping display monitoring in preview mode.")
            return
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil,
        )
        logger.debug("Started monitoring display configuration changes.")
    }

    func stopDisplayChangeMonitoring() {
        guard isObservingDisplayChanges else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil,
        )
        isObservingDisplayChanges = false
        logger.debug("Stopped monitoring display configuration changes.")
    }

    @objc
    private func displayConfigurationDidChange(_: Notification) {
        guard hudWindow != nil else { return }
        logger.debug("Display configuration changed, updating HUD position.")

        // Keep the visible HUD on the screen its type belongs on. Re-apply after a short delay,
        // since screen geometry may still be settling when the notification fires. The retry reads
        // the HUD type when it runs, in case a different HUD was shown in between.
        updateWindowPosition(for: lastShownHUDType)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateWindowPosition(for: self.lastShownHUDType)
            }
        }
    }

    // MARK: Positioning

    /// Picks the screen for a HUD type. Brightness always shows on the built-in display it controls;
    /// volume follows the user's preference.
    private func targetScreen(for hudType: HUDType?) -> (screen: NSScreen, reason: String)? {
        var candidates: [(NSScreen?, String)] = []

        #if !SANDBOX
            if hudType == .brightness {
                candidates.append((builtinScreen(), "brightness builtin"))
            }
        #endif // !SANDBOX

        if candidates.isEmpty {
            if UserDefaults.standard.bool(forKey: SettingsKey.followsMouse) {
                candidates.append((screenWithMouse(), "followsMouse"))
            } else {
                candidates.append((primaryScreen(), "primaryDisplay"))
            }
        }
        candidates.append((NSScreen.main, "fallback NSScreen.main"))
        candidates.append((NSScreen.screens.first, "fallback firstScreen"))

        for case let (screen?, reason) in candidates {
            return (screen, reason)
        }
        return nil
    }

    private func updateWindowPosition(for hudType: HUDType? = nil) {
        guard let window = hudWindow, let (screen, reason) = targetScreen(for: hudType) else { return }

        let displayID = Self.displayID(of: screen).map { String($0) } ?? "unknown"
        logger.debug("HUD screen selection: \(reason), displayID=\(displayID), frame=\(screen.frame)")

        // Use the full screen frame to ignore Dock positioning.
        let screenFrame = screen.frame
        let yPosition = UserDefaults.standard.bool(forKey: SettingsKey.useRelativePositioning)
            ? screenFrame.origin.y + screenFrame.height * 0.17 // 17% from bottom
            : screenFrame.origin.y + 140 // 140px from bottom

        let newWindowRect = NSRect(
            x: screenFrame.origin.x + (screenFrame.width - Self.hudSize.width) / 2,
            y: yPosition,
            width: Self.hudSize.width,
            height: Self.hudSize.height,
        )
        window.setFrame(newWindowRect, display: true)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    /// The screen that currently contains the mouse cursor.
    private func screenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouseLocation) }
    }

    /// The built-in display's screen, if present.
    private func builtinScreen() -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0).map { CGDisplayIsBuiltin($0) != 0 } ?? false }
    }

    /// macOS's primary (menu bar) display, if present.
    private func primaryScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first { Self.displayID(of: $0) == mainDisplayID }
    }

    // MARK: Show HUD

    private func displayHUD(hudType: HUDType, value: Float, isMuted: Bool) {
        hideTimer?.invalidate()
        presentationGeneration += 1

        if hudWindow == nil {
            createHUDWindow()
        }
        guard let window = hudWindow else { return }

        // Cancel any fade-out in progress. Its completion is ignored via the generation check.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().alphaValue = 1.0
        }
        window.alphaValue = 1.0

        let shouldUpdateContent: Bool =
            switch hudType {
            case .volume:
                hostingView == nil
                    || lastShownHUDType != hudType
                    || lastShownVolume.map { abs($0 - value) > 0.0005 } ?? true
                    || lastShownMuted != isMuted

            case .brightness:
                hostingView == nil
                    || lastShownHUDType != hudType
                    || lastShownBrightness.map { abs($0 - value) > 0.0005 } ?? true
            }

        if shouldUpdateContent || !window.isVisible {
            // Recreate the hosting view each time to avoid SwiftUI state issues.
            let newHostingView = NSHostingView(rootView: HUDView(hudType: hudType, value: value, isMuted: isMuted))
            newHostingView.frame = NSRect(origin: .zero, size: Self.hudSize)

            // Keep the hosting view background clear for proper material rendering.
            newHostingView.wantsLayer = true
            newHostingView.layer?.backgroundColor = NSColor.clear.cgColor

            window.contentView?.removeFromSuperview()
            window.contentView = newHostingView
            hostingView = newHostingView
        }

        // Reposition even when the content is unchanged, so a HUD that follows the mouse moves with it.
        updateWindowPosition(for: hudType)
        window.orderFront(nil)
        isShowing = true

        scheduleHideTimer()

        lastShownHUDType = hudType
        switch hudType {
        case .volume:
            lastShownVolume = value
            lastShownMuted = isMuted

        case .brightness:
            lastShownBrightness = value
        }
    }

    private func scheduleHideTimer() {
        let generation = presentationGeneration
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideHUD(generation: generation) }
        }
    }

    private func createHUDWindow() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.hudSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )

        // Use `.statusBar` level to appear above normal windows without blocking Exposé or Show
        // Desktop.
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // Avoid .stationary: it can interact badly with Mission Control / Show Desktop.
        // `canJoinAllSpaces` is sufficient for cross-space visibility.
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        window.orderOut(nil)

        hudWindow = window
        updateWindowPosition()
        logger.debug("Created HUD window.")
    }

    // MARK: Hide HUD

    private func hideHUD(generation: Int) {
        guard generation == presentationGeneration, let window = hudWindow else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.11
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0.0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // AppKit calls this even when the fade is cancelled, so skip it if a newer show
                // has started.
                guard let self, generation == self.presentationGeneration else { return }
                window.orderOut(nil)
                window.alphaValue = 1.0
                self.isShowing = false
            }
        }
    }
}
