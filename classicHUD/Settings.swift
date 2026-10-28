//
//  Settings.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

import Foundation

// MARK: - SettingsKey

/// User defaults keys shared by the settings window and the HUD logic.
enum SettingsKey {
    static let brightnessEnabled = "brightnessEnabled"
    static let followsMouse = "classicHUDFollowsMouse"
    static let useRelativePositioning = "useRelativePositioning"

    /// Registers the defaults the settings window shows, so code reading `UserDefaults` directly
    /// sees the same values before the user has changed anything.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            brightnessEnabled: false,
            followsMouse: true,
            useRelativePositioning: true,
        ])
    }
}

// MARK: - MonotonicClock

/// Seconds since boot. Unlike wall-clock time, this never jumps when the system clock changes, so it
/// is safe for measuring short intervals between events.
enum MonotonicClock {
    static var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
