//
//  VolumeMonitor.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

import AppKit
import Combine
import AudioToolbox
import CoreAudio
import Foundation

/// Observes the default output device's volume and mute state and shows the HUD for changes that
/// look user-initiated. When `MediaKeyInterceptor` handles a key press it shows the HUD itself, and
/// this monitor suppresses its duplicate.
@MainActor
final class VolumeMonitor: ObservableObject {
    private struct VolumeSnapshot {
        let rawVolume: Float
        let displayVolume: Float
        let isMuted: Bool
    }

    /// How long a key press counts as evidence that a following CoreAudio change was user-initiated.
    private static let keyEvidenceWindow: TimeInterval = 1.0

    @Published var currentVolume: Float = 0.0
    @Published var isMuted: Bool = false

    weak var hudController: HUDController?
    #if !SANDBOX
        weak var mediaKeyInterceptor: MediaKeyInterceptor?
    #endif // !SANDBOX

    let logger: Logger = .init()

    private let isPreviewMode: Bool
    private var isMonitoring = false
    private var deviceID: AudioDeviceID = kAudioObjectUnknown
    private var lastVolumeKeyTime: TimeInterval = -.infinity
    private var lastMuteKeyTime: TimeInterval = -.infinity
    private var previousRawVolume: Float = 0.0
    private var previousMuteState: Bool = false
    private var isOptionShiftHeld = false
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private var listenerRetryTask: Task<Void, Never>?
    /// Listeners whose property the current device does not have, so they are not retried.
    private var unsupportedListeners: Set<String> = []
    private var deviceObserverToken: UUID?

    #if !SANDBOX
        private var lastCapsLockTime: TimeInterval = -.infinity
        private var keyObserverToken: UUID?
    #endif // !SANDBOX

    init(isPreviewMode: Bool = false) {
        self.isPreviewMode = isPreviewMode
        if isPreviewMode {
            currentVolume = 0.5
            isMuted = false
        }
    }

    // MARK: Lifecycle

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        if isPreviewMode {
            logger.debug("Skipping volume monitoring in preview mode.")
            return
        }

        // Subscribe before reading the device, so a change in between is still delivered.
        deviceObserverToken = DefaultOutputDeviceObserver.shared.subscribe { [weak self] newDeviceID in
            self?.handleDefaultDeviceChanged(to: newDeviceID)
        }

        // With no output device, keep observing so monitoring starts once one appears.
        if let deviceID = AudioOutput.defaultOutputDevice() {
            self.deviceID = deviceID
            // Read the initial state without showing the HUD.
            resetVolumeBaseline()
            installVolumeListeners()
        } else {
            // No device, or a transient read error. The observer reports the device once a read
            // succeeds, even if CoreAudio sends no change notification.
            logger.warning("Could not read the default output device; waiting for one.")
            DefaultOutputDeviceObserver.shared.refresh()
        }

        #if !SANDBOX
            keyObserverToken = SystemDefinedEventObserver.shared.subscribe { [weak self] event in
                self?.handleSystemDefinedEvent(event)
            }
        #endif // !SANDBOX

        logger.debug("Started monitoring for volume changes.")
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        if isPreviewMode { return }

        removeVolumeListeners()
        unsupportedListeners.removeAll()
        deviceID = kAudioObjectUnknown
        #if !SANDBOX
            if let token = keyObserverToken {
                SystemDefinedEventObserver.shared.unsubscribe(token)
                keyObserverToken = nil
            }
        #endif // !SANDBOX
        if let token = deviceObserverToken {
            DefaultOutputDeviceObserver.shared.unsubscribe(token)
            deviceObserverToken = nil
        }
        logger.debug("Stopped monitoring for volume changes.")
    }

    #if !SANDBOX
        /// Recreates the key observation paths, which may only work once Accessibility is granted.
        func restartKeyMonitoring() {
            guard isMonitoring, !isPreviewMode else { return }
            SystemDefinedEventObserver.shared.restart()
            logger.debug("Restarted volume key monitoring.")
        }
    #endif // !SANDBOX

    // MARK: Change Detection

    private func isAlignedToStep(_ value: Float, stepCount: Float, tolerance: Float = 0.01) -> Bool {
        let scaledValue = value * stepCount
        return abs(scaledValue - round(scaledValue)) < tolerance
    }

    private func preferredVolumeStepCount(for rawVolume: Float) -> Float {
        if isOptionShiftHeld { return 64.0 }
        if isAlignedToStep(rawVolume, stepCount: 16.0) { return 16.0 }
        if isAlignedToStep(rawVolume, stepCount: 64.0) { return 64.0 }
        return 16.0
    }

    /// Key presses change volume by one to four 1/16 or 1/64 steps and land on a step boundary.
    private func isUserInitiatedVolumeChange(_ delta: Float, rawVolume: Float) -> Bool {
        let tolerance: Float = 0.001
        let absDelta = abs(delta)

        for stepCount: Float in [16.0, 64.0] {
            let baseStepSize = 1.0 / stepCount
            for multiplier in 1 ... 4 {
                let expectedDelta = baseStepSize * Float(multiplier)
                if abs(absDelta - expectedDelta) < tolerance, isAlignedToStep(rawVolume, stepCount: stepCount) {
                    return true
                }
            }
        }

        return false
    }

    private func currentSnapshot() -> VolumeSnapshot {
        var rawVolume = previousRawVolume
        var displayVolume = currentVolume
        if let volume = AudioOutput.volume(of: deviceID) {
            rawVolume = volume
            let steps = preferredVolumeStepCount(for: volume)
            displayVolume = round(volume * steps) / steps
        }
        let muted = AudioOutput.isMuted(deviceID) ?? isMuted
        return VolumeSnapshot(rawVolume: rawVolume, displayVolume: displayVolume, isMuted: muted)
    }

    /// Reads the current state as the new baseline without showing the HUD.
    private func resetVolumeBaseline() {
        let snapshot = currentSnapshot()
        currentVolume = snapshot.displayVolume
        isMuted = snapshot.isMuted
        previousRawVolume = snapshot.rawVolume
        previousMuteState = snapshot.isMuted
        logger.debug("Volume baseline: \(Int(snapshot.displayVolume * 100))%, muted: \(snapshot.isMuted)")
    }

    private func updateVolumeValues() {
        let snapshot = currentSnapshot()
        let rawVolumeDelta = snapshot.rawVolume - previousRawVolume
        let volumeChanged = abs(rawVolumeDelta) > 0.001
        let muteChanged = snapshot.isMuted != previousMuteState
        guard volumeChanged || muteChanged else { return }

        logger.debug("Volume updated: \(Int(snapshot.displayVolume * 100))%, muted: \(snapshot.isMuted)")
        currentVolume = snapshot.displayVolume
        isMuted = snapshot.isMuted
        previousRawVolume = snapshot.rawVolume
        previousMuteState = snapshot.isMuted

        let (shouldShowHUD, reason) = hudDecision(
            volumeChanged: volumeChanged,
            muteChanged: muteChanged,
            rawVolumeDelta: rawVolumeDelta,
            rawVolume: snapshot.rawVolume,
        )
        logger.debug(reason)
        if shouldShowHUD {
            hudController?.showVolumeHUD(volume: snapshot.displayVolume, isMuted: snapshot.isMuted)
        }
    }

    private func hudDecision(volumeChanged: Bool, muteChanged: Bool, rawVolumeDelta: Float, rawVolume: Float) -> (Bool, String) {
        let stepPatternMatched = volumeChanged && isUserInitiatedVolumeChange(rawVolumeDelta, rawVolume: rawVolume)

        #if SANDBOX
            // No key observation is available, so rely on the step pattern for volume. Mute changes
            // other than key presses are rare, so show them.
            if stepPatternMatched {
                return (true, "Showing HUD because the volume delta matched user key step patterns.")
            }
            if muteChanged, !volumeChanged {
                return (true, "Showing HUD for a mute change.")
            }
            return (false, "Ignoring volume change without heuristic evidence in sandbox mode.")
        #else
            if let interceptor = mediaKeyInterceptor,
               MonotonicClock.now - interceptor.lastVolumeChangeTime <= MediaKeyInterceptor.volumeChangeCooldown
            {
                return (false, "Suppressing duplicate HUD because MediaKeyInterceptor already handled this change.")
            }

            let now = MonotonicClock.now
            if volumeChanged, stepPatternMatched || now - lastVolumeKeyTime < Self.keyEvidenceWindow {
                return (true, stepPatternMatched
                    ? "Showing HUD because the volume delta matched user key step patterns."
                    : "Showing HUD because a recent volume key press corroborated the CoreAudio change.")
            }
            if muteChanged, now - lastMuteKeyTime < Self.keyEvidenceWindow {
                return (true, "Showing HUD because a recent mute key press corroborated the mute change.")
            }
            return (false, "Ignoring non-user volume or mute change with no corroborating key evidence.")
        #endif // SANDBOX
    }

    #if !SANDBOX

        // MARK: Key Press Monitoring

        private func handleSystemDefinedEvent(_ event: SystemDefinedKeyEvent) {
            let now = MonotonicClock.now

            // Option+Shift selects 1/64 steps instead of 1/16.
            isOptionShiftHeld = event.modifierFlags.contains(.option) && event.modifierFlags.contains(.shift)

            if event.subtype == 211 {
                lastCapsLockTime = now
                logger.debug("Caps Lock event detected, ignoring volume events for 0.5 seconds.")
                return
            }

            guard event.subtype == 8 else { return }
            if now - lastCapsLockTime < 0.5 {
                logger.debug("Ignoring volume event, too close to Caps Lock.")
                return
            }
            guard event.isKeyDown else { return }

            switch event.keyCode {
            case 0, 1: // Volume up, volume down
                lastVolumeKeyTime = now
                showHUDForVolumeKeyPressAtBoundary(isVolumeUp: event.keyCode == 0)

            case 7: // Mute
                lastMuteKeyTime = now
                logger.debug("Mute key detected.")

            default:
                break
            }
        }

        /// A key press at 0% or 100% changes nothing in CoreAudio, so show the HUD from the key press
        /// itself. Presses between the boundaries are handled by the CoreAudio listener instead.
        private func showHUDForVolumeKeyPressAtBoundary(isVolumeUp: Bool) {
            let atMinVolume = currentVolume <= 0.001
            let atMaxVolume = currentVolume >= 0.999
            guard atMinVolume || atMaxVolume else { return }

            hudController?.showVolumeHUD(volume: currentVolume, isMuted: isMuted)
            logger.debug("Showing HUD for volume \(isVolumeUp ? "up" : "down") key press at boundary: \(Int(currentVolume * 100))%, muted: \(isMuted)")
        }
    #endif // !SANDBOX

    // MARK: Device Changes

    private func handleDefaultDeviceChanged(to newDeviceID: AudioDeviceID) {
        guard isMonitoring, newDeviceID != deviceID else { return }
        logger.debug("Default output device changed: \(deviceID) -> \(newDeviceID)")

        // The new device is already known, so the old listeners can be detached safely.
        removeVolumeListeners()
        unsupportedListeners.removeAll()
        deviceID = newDeviceID
        resetVolumeBaseline()
        installVolumeListeners()
    }

    // MARK: CoreAudio Listeners

    /// Installs the volume and mute listeners on the current device. Properties the device does not
    /// have are skipped. If CoreAudio rejects a supported one, retries every second until it succeeds
    /// or the device changes.
    private func installVolumeListeners() {
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        guard deviceID != kAudioObjectUnknown else { return }

        if volumeListenerBlock == nil {
            volumeListenerBlock = addListener(for: AudioOutput.volumeAddress, name: "volume")
        }
        if muteListenerBlock == nil {
            muteListenerBlock = addListener(for: AudioOutput.muteAddress, name: "mute")
        }

        let volumeMissing = volumeListenerBlock == nil && !unsupportedListeners.contains("volume")
        let muteMissing = muteListenerBlock == nil && !unsupportedListeners.contains("mute")
        guard volumeMissing || muteMissing else { return }
        let targetDeviceID = deviceID
        listenerRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, isMonitoring, deviceID == targetDeviceID else { return }
            installVolumeListeners()
        }
    }

    private func addListener(for address: AudioObjectPropertyAddress, name: String) -> AudioObjectPropertyListenerBlock? {
        guard !unsupportedListeners.contains(name) else { return nil }
        guard AudioOutput.hasProperty(address, on: deviceID) else {
            unsupportedListeners.insert(name)
            logger.info("Device \(deviceID) has no \(name) property; not observing it.")
            return nil
        }

        // CoreAudio calls the block on the main queue.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateVolumeValues() }
        }
        var address = address
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        guard status == noErr else {
            logger.warning("Failed to add \(name) listener on device \(deviceID) (\(status)); will retry.")
            return nil
        }
        return block
    }

    private func removeVolumeListeners() {
        listenerRetryTask?.cancel()
        listenerRetryTask = nil

        if let block = volumeListenerBlock {
            var address = AudioOutput.volumeAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
            volumeListenerBlock = nil
        }
        if let block = muteListenerBlock {
            var address = AudioOutput.muteAddress
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, block)
            muteListenerBlock = nil
        }
    }
}
