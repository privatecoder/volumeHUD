//
//  BrightnessMonitor.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// Polls the built-in display's brightness and shows the HUD for changes that look user-initiated.
/// When `MediaKeyInterceptor` handles brightness keys it shows the HUD itself; this monitor covers
/// the fallback case where keys reach the system.
@MainActor
final class BrightnessMonitor: ObservableObject {
    /// Key presses change brightness in 1/16 steps.
    private static let stepSize: Float = 1.0 / 16.0

    @Published var currentBrightness: Float = 0.0

    weak var hudController: HUDController?

    let logger: Logger = .init()

    private let isPreviewMode: Bool
    private var accessibilityEnabled: Bool
    private var isMonitoring = false
    private var previousBrightness: Float = 0.0
    private var brightnessPollingTimer: Timer?
    private var lastBrightnessKeyTime: TimeInterval = -.infinity
    private var hasLoggedBrightnessError = false
    private var hasLoggedNoDisplayDetected = false
    private var brightnessAvailable = false
    private var isObservingDisplayChanges = false
    private var restartTask: Task<Void, Never>?
    private var keyObserverToken: UUID?

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
        if isPreviewMode {
            accessibilityEnabled = false
            currentBrightness = 0.75
            brightnessAvailable = true
        } else {
            accessibilityEnabled = AXIsProcessTrusted()
        }
    }

    /// Update the accessibility status after permissions may have changed.
    func updateAccessibilityStatus() {
        let newAccessibilityEnabled = AXIsProcessTrusted()
        if newAccessibilityEnabled != accessibilityEnabled {
            logger.info("Brightness monitor accessibility status changed: \(accessibilityEnabled) -> \(newAccessibilityEnabled)")
            accessibilityEnabled = newAccessibilityEnabled
        }
    }

    // MARK: Lifecycle

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        if isPreviewMode {
            logger.debug("Skipping brightness monitoring in preview mode.")
            return
        }

        logger.debug("Starting brightness monitoring. DisplayServices available: \(DisplayBrightness.isAvailable)")

        // Read the initial brightness without showing the HUD.
        updateBrightnessOnStartup()

        brightnessPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForBrightnessChange() }
        }
        keyObserverToken = SystemDefinedEventObserver.shared.subscribe { [weak self] event in
            self?.handleSystemDefinedEvent(event)
        }
        startDisplayChangeMonitoring()

        logger.debug("Started monitoring for brightness changes.")
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        if isPreviewMode { return }

        brightnessPollingTimer?.invalidate()
        brightnessPollingTimer = nil
        if let token = keyObserverToken {
            SystemDefinedEventObserver.shared.unsubscribe(token)
            keyObserverToken = nil
        }
        stopDisplayChangeMonitoring()
        restartTask?.cancel()
        restartTask = nil

        logger.debug("Stopped monitoring for brightness changes.")
    }

    /// Recreates the key observation paths, for example after Accessibility is granted.
    func restartKeyMonitoring() {
        guard isMonitoring, !isPreviewMode else { return }
        SystemDefinedEventObserver.shared.restart()
        logger.debug("Restarted brightness key monitoring.")
    }

    // MARK: Brightness Reading

    /// Key presses change brightness by one to four 1/16 steps and land on a step boundary.
    private func isUserInitiatedBrightnessChange(_ delta: Float, rawBrightness: Float) -> Bool {
        let tolerance: Float = 0.0001
        let absDelta = abs(delta)

        for multiplier in 1 ... 4 {
            let expectedDelta = Self.stepSize * Float(multiplier)
            if abs(absDelta - expectedDelta) < tolerance {
                let rawStepPosition = rawBrightness * 16.0
                if abs(rawStepPosition - round(rawStepPosition)) < 0.01 {
                    return true
                }
            }
        }

        return false
    }

    private func updateBrightnessOnStartup() {
        if let brightness = getCurrentBrightness() {
            let quantizedBrightness = round(brightness * 16.0) / 16.0
            currentBrightness = quantizedBrightness
            previousBrightness = quantizedBrightness
            brightnessAvailable = true
            logger.debug("Initial brightness set: \(Int(quantizedBrightness * 100))%")
        } else {
            brightnessAvailable = false
            if !hasLoggedBrightnessError {
                logger.warning("Brightness control not available; this may be an external display or a system without brightness control.")
                hasLoggedBrightnessError = true
            }
        }
    }

    /// The built-in display's raw brightness, or nil if it cannot be read.
    private func getCurrentBrightness() -> Float? {
        guard DisplayBrightness.isAvailable else { return nil }

        guard let builtinDisplay = DisplayBrightness.builtinDisplayID() else {
            if !hasLoggedNoDisplayDetected {
                logger.warning("No built-in display detected.")
                hasLoggedNoDisplayDetected = true
            }
            return nil
        }

        guard DisplayBrightness.canChange(builtinDisplay) else {
            logger.warning("Built-in display cannot change brightness (id: \(builtinDisplay)).")
            return nil
        }

        guard let brightness = DisplayBrightness.brightness(of: builtinDisplay) else {
            logger.error("Reading brightness failed for display \(builtinDisplay).")
            return nil
        }
        return brightness
    }

    // MARK: Display Changes

    private func startDisplayChangeMonitoring() {
        guard !isObservingDisplayChanges else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil,
        )
        isObservingDisplayChanges = true
    }

    private func stopDisplayChangeMonitoring() {
        guard isObservingDisplayChanges else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil,
        )
        isObservingDisplayChanges = false
    }

    @objc
    private func displayConfigurationDidChange(_: Notification) {
        // Lid close/open can fire 3-4 notifications over about a second, so debounce them.
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return // A newer display change superseded this one.
            }
            guard let self else { return }
            logger.info("Display configuration stabilized, restarting brightness key monitoring.")
            restartKeyMonitoring()
        }
    }

    // MARK: Change Detection

    private func checkForBrightnessChange() {
        // Always probe brightness so monitoring recovers after display configuration changes.
        guard let brightness = getCurrentBrightness() else {
            if brightnessAvailable {
                brightnessAvailable = false
                logger.warning("Lost access to brightness control.")
            }
            return
        }

        if !brightnessAvailable {
            brightnessAvailable = true
            hasLoggedNoDisplayDetected = false
            logger.info("Regained access to brightness control.")
        }

        let quantizedBrightness = round(brightness * 16.0) / 16.0
        guard abs(quantizedBrightness - previousBrightness) > 0.001 else { return }

        let delta = quantizedBrightness - previousBrightness
        let timeSinceKeyPress = MonotonicClock.now - lastBrightnessKeyTime
        logger.debug("Brightness change: \(String(format: "%.4f", delta)) - Raw: \(String(format: "%.6f", brightness)) -> Quantized: \(String(format: "%.4f", quantizedBrightness)) - Time since key: \(String(format: "%.1f", timeSinceKeyPress))s")

        currentBrightness = quantizedBrightness
        previousBrightness = quantizedBrightness

        let isUserChange = isUserInitiatedBrightnessChange(delta, rawBrightness: brightness)
        // A recent key press is evidence even when the step pattern does not match.
        let hasKeyEvidence = accessibilityEnabled && timeSinceKeyPress < 1.0
        if isUserChange || hasKeyEvidence {
            logger.debug("Showing HUD: \(Int(quantizedBrightness * 100))% (step match: \(isUserChange), key evidence: \(hasKeyEvidence))")
            hudController?.showBrightnessHUD(brightness: quantizedBrightness)
        } else {
            logger.debug("Ignoring ambient/system change: \(Int(quantizedBrightness * 100))% (delta: \(delta), HUD not shown).")
        }
    }

    // MARK: Key Press Monitoring

    private func handleSystemDefinedEvent(_ event: SystemDefinedKeyEvent) {
        // Brightness keys are NX key types 2 (up) and 3 (down) with subtype 8.
        guard event.subtype == 8, event.isKeyDown, event.keyCode == 2 || event.keyCode == 3 else { return }

        logger.debug("Brightness key detected: \(event.keyCode == 2 ? "up" : "down")")
        lastBrightnessKeyTime = MonotonicClock.now
        showHUDForBrightnessKeyPressAtBoundary()
        // Check immediately instead of waiting for the next polling tick.
        checkForBrightnessChange()
    }

    /// A key press at 0% or 100% changes nothing, so show the HUD from the key press itself.
    private func showHUDForBrightnessKeyPressAtBoundary() {
        guard let brightness = getCurrentBrightness() else { return }
        let quantizedBrightness = round(brightness * 16.0) / 16.0
        guard quantizedBrightness <= 0.001 || quantizedBrightness >= 0.999 else { return }

        currentBrightness = quantizedBrightness
        hudController?.showBrightnessHUD(brightness: quantizedBrightness)
        logger.debug("Showing HUD for brightness key press at boundary: \(Int(quantizedBrightness * 100))%")
    }
}
