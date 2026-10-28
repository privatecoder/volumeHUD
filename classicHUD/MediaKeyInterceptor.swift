//
//  MediaKeyInterceptor.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation

/// Intercepts media key events at the HID level to suppress the system HUDs. When active, this
/// class consumes volume/brightness key events before macOS sees them, adjusts the values itself,
/// and shows the custom HUD.
///
/// The change is applied inside the tap callback, so whether to consume a key press is decided with
/// the outcome known. The callback does a fixed, small amount of work (a few CoreAudio or
/// DisplayServices property calls, whose own latency depends on the driver); the HUD and feedback
/// sound are deferred until after the callback returns.
///
/// Fallback: if a key press fails before anything was changed (for example brightness on an
/// external display, or a device that rejects volume or mute writes), interception for that type is
/// disabled and the press passes through to macOS. If a failure happens after a change was already
/// applied, the press is still consumed, since macOS would apply it a second time. Later presses pass
/// through until the device or display configuration changes or the app restarts.
@MainActor
final class MediaKeyInterceptor {
    private struct VolumeControlState {
        let deviceID: AudioDeviceID
        let requestedVolume: Float
        let readbackVolume: Float
    }

    private enum NXKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
    }

    /// The result of handling one key press.
    private enum KeyOutcome {
        /// The change was applied.
        case handled
        /// Nothing was changed, so the press can safely pass through to macOS.
        case failedBeforeChange
        /// Part of the change was applied, so passing the press to macOS would apply it twice.
        case failedAfterChange
    }

    /// How long to suppress VolumeMonitor HUD updates after an intercepted change.
    nonisolated static let volumeChangeCooldown: TimeInterval = 0.2

    /// Bridges the C event tap callback to the instance. The tap's run loop source is on the main
    /// run loop, so the callback runs on the main thread. Events that are passed through are the
    /// caller's own object and must be returned unretained.
    private static let eventTapCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        // The event is only used synchronously on the main thread before the callback returns.
        nonisolated(unsafe) let event = cgEvent
        let shouldConsume = MainActor.assumeIsolated {
            interceptor.handleTapEvent(type: type, cgEvent: event)
        }
        return shouldConsume ? nil : Unmanaged.passUnretained(cgEvent)
    }

    weak var hudController: HUDController?

    let logger: Logger = .init()

    /// Monotonic timestamp of the last volume change made by this interceptor, so VolumeMonitor
    /// can skip its duplicate HUD.
    private(set) var lastVolumeChangeTime: TimeInterval = -.infinity

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var feedbackSoundData: Data?
    private var activeFeedbackPlayers: [AVAudioPlayer] = []
    private var isRunning = false

    /// Whether volume interception is working (resets on device change or app restart).
    private var volumeInterceptionWorking = true

    /// Whether brightness interception is working (resets on display change or app restart).
    private var brightnessInterceptionWorking = true

    /// Last logical target and its physical read-back, which may differ on hardware-quantized devices.
    private var volumeControlState: VolumeControlState?

    /// Per NX key code, for the key currently held: true while every key-down of the hold (including
    /// autorepeats) was consumed, false once macOS received one. Decides whether the key-up is consumed,
    /// so macOS always gets the release of a hold it saw.
    private var consumeKeyUp: [Int: Bool] = [:]

    private var isObservingDisplayChanges = false
    private var deviceObserverToken: UUID?
    private var lastKnownAudioDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// Standard step (1/16th, matching macOS default).
    private let standardStep: Float = 1.0 / 16.0

    /// Fine step when Option+Shift is held (1/64th).
    private let fineStep: Float = 1.0 / 64.0

    /// Whether the brightness HUD feature is enabled in settings.
    private var brightnessHUDEnabled: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.brightnessEnabled)
    }

    // MARK: Public Methods

    /// Start intercepting media key events. Returns true if the event tap is running.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else {
            logger.debug("MediaKeyInterceptor already running.")
            return true
        }

        // Reset fallback states on start (allows re-testing each app launch).
        volumeInterceptionWorking = true
        brightnessInterceptionWorking = true
        volumeControlState = nil
        consumeKeyUp.removeAll()

        guard AXIsProcessTrusted() else {
            logger.debug("MediaKeyInterceptor: Accessibility permissions not granted. Cannot intercept media keys.")
            return false
        }

        // Load DisplayServices now rather than on the first brightness key inside the tap callback.
        _ = DisplayBrightness.isAvailable

        // Tap at the HID level with .defaultTap (not .listenOnly) so events can be consumed.
        let systemDefinedMask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: systemDefinedMask,
                callback: Self.eventTapCallback,
                userInfo: userInfo,
            ) else
        {
            logger.debug("MediaKeyInterceptor: Failed to create CGEvent tap.")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            logger.debug("MediaKeyInterceptor: Failed to create run loop source.")
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true

        startDeviceChangeMonitoring()

        logger.debug("Started intercepting media keys.")
        return true
    }

    /// Stop intercepting media key events.
    func stop() {
        guard isRunning else { return }

        stopDeviceChangeMonitoring()

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Disabling pauses delivery; invalidating unregisters the tap from WindowServer.
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }

        runLoopSource = nil
        eventTap = nil
        isRunning = false
        consumeKeyUp.removeAll()

        logger.debug("Stopped intercepting media keys.")
    }

    // MARK: Private - Event Handling

    /// Returns true to consume the event, or false to pass it through.
    private func handleTapEvent(type: CGEventType, cgEvent: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // While the tap was off, macOS may have received key-downs of keys held now, so their
            // key-ups must reach it too.
            for keyCode in consumeKeyUp.keys {
                consumeKeyUp[keyCode] = false
            }
            return false
        }

        guard
            type.rawValue == 14,
            let nsEvent = NSEvent(cgEvent: cgEvent),
            nsEvent.type == .systemDefined,
            nsEvent.subtype.rawValue == 8 else
        {
            return false
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyState = ((data1 & 0x0000_FFFF) & 0xFF00) >> 8

        guard let keyType = NXKeyType(rawValue: keyCode) else {
            return false
        }

        // 0x0A = key down (including autorepeat), 0x0B = key up.
        if keyState == 0x0B {
            return consumeKeyUp.removeValue(forKey: keyCode) ?? false
        }
        guard keyState == 0x0A else {
            return false
        }

        let consumed = handleKeyDown(keyType: keyType, nsEvent: nsEvent, cgEvent: cgEvent)
        // A non-repeat key-down starts a new hold. Once macOS has seen any key-down of the hold,
        // it must also get the key-up. A repeat with no tracked hold means the hold started before
        // this tap saw it, so macOS already has its first key-down.
        let isRepeat = (data1 & 0x1) != 0
        let earlierDownsConsumed = isRepeat ? (consumeKeyUp[keyCode] ?? false) : true
        consumeKeyUp[keyCode] = consumed && earlierDownsConsumed
        return consumed
    }

    /// Applies a key-down if it is intercepted. Returns true to consume it.
    private func handleKeyDown(keyType: NXKeyType, nsEvent: NSEvent, cgEvent: CGEvent) -> Bool {
        // Read modifiers from every source; some keyboards only report them in one.
        let sessionFlags = CGEventSource.flagsState(.combinedSessionState)
        let optionHeld = nsEvent.modifierFlags.contains(.option)
            || cgEvent.flags.contains(.maskAlternate)
            || sessionFlags.contains(.maskAlternate)
        let shiftHeld = nsEvent.modifierFlags.contains(.shift)
            || cgEvent.flags.contains(.maskShift)
            || sessionFlags.contains(.maskShift)
        let useFineStep = optionHeld && shiftHeld

        let outcome: KeyOutcome
        switch keyType {
        case .soundUp, .soundDown, .mute:
            guard volumeInterceptionWorking else { return false }
            logger.debug("Volume key: shift=\(shiftHeld), option=\(optionHeld)")
            outcome = handleVolumeKey(keyType: keyType, useFineStep: useFineStep, shiftHeld: shiftHeld, optionHeld: optionHeld)

        case .brightnessUp, .brightnessDown:
            // With the brightness HUD off, leave brightness keys to the system entirely.
            guard brightnessHUDEnabled, brightnessInterceptionWorking else { return false }
            outcome = handleBrightnessKey(keyType: keyType, useFineStep: useFineStep)
        }

        if outcome == .failedBeforeChange {
            logger.info("Passing the failed key press through to the system.")
            return false
        }
        return true
    }

    /// Runs UI work after the tap callback returns, keeping the callback itself short.
    private func afterCallback(_ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in work() }
    }

    /// Handle a volume key press by adjusting volume and showing our HUD.
    private func handleVolumeKey(keyType: NXKeyType, useFineStep: Bool, shiftHeld: Bool, optionHeld: Bool) -> KeyOutcome {
        switch keyType {
        case .soundUp, .soundDown:
            let step = useFineStep ? fineStep : standardStep
            let outcome = adjustVolume(delta: keyType == .soundUp ? step : -step)
            if outcome == .handled {
                afterCallback { [weak self] in
                    guard let self, shouldPlayVolumeFeedback(shiftHeld: shiftHeld, optionHeld: optionHeld) else { return }
                    playFeedbackSound()
                }
            }
            return outcome

        case .mute:
            return toggleMute()

        default:
            return .handled
        }
    }

    /// Handle a brightness key press by adjusting brightness and showing our HUD.
    private func handleBrightnessKey(keyType: NXKeyType, useFineStep: Bool) -> KeyOutcome {
        let step = useFineStep ? fineStep : standardStep
        return adjustBrightness(delta: keyType == .brightnessUp ? step : -step)
    }

    // MARK: Private - Volume Control

    /// Adjust volume by delta and show the HUD. Disables volume interception if any required
    /// CoreAudio call fails.
    private func adjustVolume(delta: Float) -> KeyOutcome {
        guard let deviceID = AudioOutput.defaultOutputDevice() else {
            return volumeFailure("cannot get audio device", .failedBeforeChange)
        }

        guard let currentVolume = AudioOutput.volume(of: deviceID) else {
            return volumeFailure("cannot read volume", .failedBeforeChange)
        }

        // Continue from our logical target when the device still reports the physical result of our
        // previous request. Some devices map 1/16 targets to different hardware-supported values.
        let baseVolume: Float
        if
            let state = volumeControlState,
            state.deviceID == deviceID,
            abs(state.readbackVolume - currentVolume) <= 0.001
        {
            baseVolume = state.requestedVolume
        } else {
            baseVolume = currentVolume
            volumeControlState = nil
        }

        let steps = 1.0 / abs(delta)
        let expectedVolume = max(0.0, min(1.0, round((baseVolume + delta) * steps) / steps))
        let shouldBeMuted = expectedVolume <= 0.001

        // Mute follows the level like macOS: unmute when raising from mute, mute at 0%. A device
        // without a mute control skips this; one whose mute state cannot be read or changed when
        // it must be is a failure.
        guard let muteSupport = AudioOutput.muteSupport(deviceID) else {
            return volumeFailure("cannot query mute control", .failedBeforeChange)
        }
        var isMuted = false
        var didUnmute = false
        if muteSupport != .absent {
            guard let muted = AudioOutput.isMuted(deviceID) else {
                return volumeFailure("cannot read mute state", .failedBeforeChange)
            }
            isMuted = muted
            if muted, !shouldBeMuted {
                guard muteSupport == .settable, AudioOutput.setMuted(false, on: deviceID) else {
                    return volumeFailure("cannot unmute", .failedBeforeChange)
                }
                isMuted = false
                didUnmute = true
            }
        }

        guard AudioOutput.setVolume(expectedVolume, on: deviceID) else {
            volumeControlState = nil
            return volumeFailure("cannot set volume", didUnmute ? .failedAfterChange : .failedBeforeChange)
        }

        // The volume has changed from here on, so failures must not hand the press to macOS.
        guard let actualVolume = AudioOutput.volume(of: deviceID) else {
            volumeControlState = nil
            return volumeFailure("cannot read volume after setting it", .failedAfterChange)
        }
        volumeControlState = VolumeControlState(deviceID: deviceID, requestedVolume: expectedVolume, readbackVolume: actualVolume)

        if shouldBeMuted, !isMuted, muteSupport == .settable {
            guard AudioOutput.setMuted(true, on: deviceID) else {
                return volumeFailure("cannot mute at 0%", .failedAfterChange)
            }
            isMuted = true
        }

        lastVolumeChangeTime = MonotonicClock.now

        // Show the quantized target rather than the read-back, so the bars move in clean steps.
        afterCallback { [weak self] in self?.hudController?.showVolumeHUD(volume: expectedVolume, isMuted: isMuted) }
        logger.debug("Volume adjusted: \(Int(expectedVolume * 100))%, muted: \(isMuted)")
        return .handled
    }

    /// Toggle mute and show the HUD. Disables volume interception on failure.
    private func toggleMute() -> KeyOutcome {
        guard let deviceID = AudioOutput.defaultOutputDevice() else {
            return volumeFailure("cannot get audio device", .failedBeforeChange)
        }
        guard let isMuted = AudioOutput.isMuted(deviceID) else {
            return volumeFailure("cannot read mute state", .failedBeforeChange)
        }
        guard let currentVolume = AudioOutput.volume(of: deviceID) else {
            return volumeFailure("cannot read volume", .failedBeforeChange)
        }
        guard AudioOutput.setMuted(!isMuted, on: deviceID) else {
            return volumeFailure("cannot set mute state", .failedBeforeChange)
        }

        lastVolumeChangeTime = MonotonicClock.now
        let displayVolume = round(currentVolume * 16.0) / 16.0
        afterCallback { [weak self] in self?.hudController?.showVolumeHUD(volume: displayVolume, isMuted: !isMuted) }
        logger.debug("Mute toggled: \(!isMuted)")
        return .handled
    }

    /// Disable volume interception, log the reason, and return the given outcome.
    private func volumeFailure(_ reason: String, _ outcome: KeyOutcome) -> KeyOutcome {
        if volumeInterceptionWorking {
            volumeInterceptionWorking = false
            logger.warning("Volume key interception disabled: \(reason). Future volume keys will pass through to system.")
        }
        return outcome
    }

    // MARK: Private - Brightness Control

    /// Adjust brightness by delta and show the HUD. Disables brightness interception if the change
    /// cannot be made or does not take effect.
    private func adjustBrightness(delta: Float) -> KeyOutcome {
        guard DisplayBrightness.canSet else {
            return brightnessFailure("DisplayServices not available", .failedBeforeChange)
        }
        guard let displayID = DisplayBrightness.builtinDisplayID() else {
            return brightnessFailure("no built-in display found", .failedBeforeChange)
        }
        guard DisplayBrightness.canChange(displayID) else {
            return brightnessFailure("display does not support brightness control", .failedBeforeChange)
        }
        guard let currentBrightness = DisplayBrightness.brightness(of: displayID) else {
            return brightnessFailure("cannot read brightness", .failedBeforeChange)
        }

        let steps = 1.0 / abs(delta)
        let expectedBrightness = max(0.0, min(1.0, round((currentBrightness + delta) * steps) / steps))
        let atBoundary = (currentBrightness <= 0.001 && delta < 0) || (currentBrightness >= 0.999 && delta > 0)

        guard DisplayBrightness.setBrightness(expectedBrightness, on: displayID) else {
            return brightnessFailure("cannot set brightness", .failedBeforeChange)
        }
        guard let actualBrightness = DisplayBrightness.brightness(of: displayID) else {
            return brightnessFailure("cannot read brightness after setting it", .failedAfterChange)
        }

        // An unchanged value away from the boundaries means the write had no effect, so nothing
        // was changed and the press can pass through to macOS.
        if !atBoundary, abs(actualBrightness - currentBrightness) <= 0.001 {
            return brightnessFailure("brightness change did not take effect", .failedBeforeChange)
        }

        let quantizedBrightness = round(actualBrightness * 16.0) / 16.0
        afterCallback { [weak self] in self?.hudController?.showBrightnessHUD(brightness: quantizedBrightness) }
        logger.debug("Brightness adjusted: \(Int(quantizedBrightness * 100))%")
        return .handled
    }

    /// Disable brightness interception, log the reason, and return the given outcome.
    private func brightnessFailure(_ reason: String, _ outcome: KeyOutcome) -> KeyOutcome {
        if brightnessInterceptionWorking {
            brightnessInterceptionWorking = false
            logger.warning("Brightness key interception disabled: \(reason). Future brightness keys will pass through to system.")
        }
        return outcome
    }

    // MARK: Private - Feedback Sound

    /// Determine whether feedback should play for this keypress. Default follows macOS preference.
    /// Shift alone inverts the preference. Option+Shift remains silent, matching macOS behavior.
    private func shouldPlayVolumeFeedback(shiftHeld: Bool, optionHeld: Bool) -> Bool {
        if optionHeld, shiftHeld {
            return false
        }

        let feedbackSetting = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["com.apple.sound.beep.feedback"]
        let feedbackPreferenceEnabled: Bool = switch feedbackSetting {
        case let value as Int:
            value == 1
        case let value as Bool:
            value
        case let value as NSNumber:
            value.intValue == 1
        default:
            false
        }

        return shiftHeld ? !feedbackPreferenceEnabled : feedbackPreferenceEnabled
    }

    /// Play the volume feedback sound.
    private func playFeedbackSound() {
        prepareFeedbackSoundDataIfNeeded()
        activeFeedbackPlayers.removeAll { !$0.isPlaying }

        guard let feedbackSoundData else {
            logger.warning("Volume feedback skipped: sound data unavailable.")
            return
        }

        do {
            let player = try AVAudioPlayer(data: feedbackSoundData)
            player.volume = 1.0
            player.numberOfLoops = 0
            player.prepareToPlay()

            if player.play() {
                // Keep overlapping players alive until they finish, within a small cap.
                activeFeedbackPlayers.append(player)
                if activeFeedbackPlayers.count > 12 {
                    activeFeedbackPlayers.removeFirst(activeFeedbackPlayers.count - 12)
                }
            } else {
                logger.warning("Volume feedback player failed to start playback.")
            }
        } catch {
            logger.warning("Failed to create volume feedback player: \(error.localizedDescription)")
        }
    }

    /// Load the feedback sound from the app's data asset, falling back to the system sound file.
    private func prepareFeedbackSoundDataIfNeeded() {
        guard feedbackSoundData == nil else { return }

        if let volumeDataAsset = NSDataAsset(name: "volume") {
            feedbackSoundData = volumeDataAsset.data
            return
        }
        logger.warning("Bundled volume feedback data asset is unavailable.")

        let soundPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        do {
            feedbackSoundData = try Data(contentsOf: URL(fileURLWithPath: soundPath))
        } catch {
            logger.warning("Failed to load volume feedback sound: \(error.localizedDescription)")
        }
    }

    // MARK: Private - Device Change Monitoring

    private func startDeviceChangeMonitoring() {
        if deviceObserverToken == nil {
            // Subscribe before reading the device, so a change in between is still delivered.
            deviceObserverToken = DefaultOutputDeviceObserver.shared.subscribe { [weak self] deviceID in
                self?.handleAudioDeviceChange(to: deviceID)
            }
            if let deviceID = AudioOutput.defaultOutputDevice() {
                lastKnownAudioDeviceID = deviceID
            } else {
                lastKnownAudioDeviceID = kAudioObjectUnknown
                DefaultOutputDeviceObserver.shared.refresh()
            }
        }

        guard !isObservingDisplayChanges else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil,
        )
        isObservingDisplayChanges = true
    }

    private func stopDeviceChangeMonitoring() {
        if let token = deviceObserverToken {
            DefaultOutputDeviceObserver.shared.unsubscribe(token)
            deviceObserverToken = nil
        }

        guard isObservingDisplayChanges else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil,
        )
        isObservingDisplayChanges = false
    }

    /// Re-test volume interception with a new default output device.
    private func handleAudioDeviceChange(to deviceID: AudioDeviceID) {
        guard deviceID != lastKnownAudioDeviceID else { return }
        logger.info("MediaKeyInterceptor: Audio device changed: \(lastKnownAudioDeviceID) -> \(deviceID)")
        lastKnownAudioDeviceID = deviceID
        volumeControlState = nil
        if !volumeInterceptionWorking {
            volumeInterceptionWorking = true
            logger.info("Volume interception re-enabled due to audio device change.")
        }
    }

    /// Re-test brightness interception with the new display configuration.
    @objc
    private func displayConfigurationDidChange(_: Notification) {
        if !brightnessInterceptionWorking {
            brightnessInterceptionWorking = true
            logger.info("Brightness interception re-enabled due to display configuration change.")
        }
    }
}
