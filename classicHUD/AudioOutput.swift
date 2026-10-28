//
//  AudioOutput.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

import AudioToolbox
import CoreAudio
import Foundation

// MARK: - AudioOutput

/// Thin wrappers around the CoreAudio properties classicHUD reads and writes on the default output
/// device.
enum AudioOutput {
    static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
    }

    static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
    }

    static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
    }

    /// The current default output device, or nil if CoreAudio cannot report one.
    static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutputDeviceAddress
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// The device's volume from 0 to 1, or nil if it cannot be read.
    static func volume(of deviceID: AudioDeviceID) -> Float? {
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = volumeAddress
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    /// Sets the device's volume, clamped to 0...1. Returns false if CoreAudio rejects the write.
    static func setVolume(_ volume: Float, on deviceID: AudioDeviceID) -> Bool {
        var newVolume = max(0, min(1, volume))
        var address = volumeAddress
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &newVolume)
        return status == noErr
    }

    /// Whether the device is muted, or nil if it has no readable mute control.
    static func isMuted(_ deviceID: AudioDeviceID) -> Bool? {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = muteAddress
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        return status == noErr ? muted != 0 : nil
    }

    /// What kind of mute control a device has.
    enum MuteSupport {
        case absent
        case readOnly
        case settable
    }

    /// The device's mute control, or nil if CoreAudio cannot tell whether it is writable.
    static func muteSupport(_ deviceID: AudioDeviceID) -> MuteSupport? {
        var address = muteAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return .absent }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else { return nil }
        return settable.boolValue ? .settable : .readOnly
    }

    /// Whether the device has the property at all.
    static func hasProperty(_ address: AudioObjectPropertyAddress, on deviceID: AudioDeviceID) -> Bool {
        var address = address
        return AudioObjectHasProperty(deviceID, &address)
    }

    /// Sets the device's mute state. Returns false if CoreAudio rejects the write.
    static func setMuted(_ muted: Bool, on deviceID: AudioDeviceID) -> Bool {
        var value: UInt32 = muted ? 1 : 0
        var address = muteAddress
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        return status == noErr
    }
}

// MARK: - DefaultOutputDeviceObserver

/// Tells subscribers on the main actor about the default output device whenever CoreAudio reports
/// that it may have changed. Subscribers compare the reported device with their own, so a change that
/// happens while one is starting up is never lost. Uses a CoreAudio property listener, falls back to
/// polling once a second if the listener cannot be installed, and retries a failed device read.
@MainActor
final class DefaultOutputDeviceObserver {
    static let shared = DefaultOutputDeviceObserver()

    private let logger: Logger = .init()
    private var subscribers: [UUID: @MainActor (AudioDeviceID) -> Void] = [:]
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var pollingTimer: Timer?
    private var retryTask: Task<Void, Never>?

    private init() {}

    /// Adds a handler and returns a token for `unsubscribe`. Subscribe before reading the current
    /// device, so any change after that read is delivered.
    func subscribe(_ handler: @escaping @MainActor (AudioDeviceID) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        if subscribers.count == 1 {
            start()
        }
        return token
    }

    func unsubscribe(_ token: UUID) {
        subscribers[token] = nil
        if subscribers.isEmpty {
            stop()
        }
    }

    /// Reads the default device now and reports it to every subscriber, retrying until a read
    /// succeeds. Call this when a subscriber could not read the device itself.
    func refresh() {
        check()
    }

    private func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.check() }
        }
        var address = AudioOutput.defaultOutputDeviceAddress
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr {
            listenerBlock = block
        } else {
            logger.warning("Default output device listener failed (\(status)); polling once a second instead.")
            pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    private func stop() {
        if let block = listenerBlock {
            var address = AudioOutput.defaultOutputDeviceAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            listenerBlock = nil
        }
        pollingTimer?.invalidate()
        pollingTimer = nil
        retryTask?.cancel()
        retryTask = nil
    }

    private func check() {
        retryTask?.cancel()
        retryTask = nil
        // A callback queued before the last unsubscribe must not restart the retry loop.
        guard !subscribers.isEmpty else { return }

        guard let deviceID = AudioOutput.defaultOutputDevice() else {
            // No device, or a transient read error: look again shortly instead of dropping the change.
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.check()
            }
            return
        }

        for handler in subscribers.values {
            handler(deviceID)
        }
    }
}
