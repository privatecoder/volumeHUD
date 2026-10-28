//
//  Logger.swift
//  by Danny Stewart (2026)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

import Foundation
import os

// MARK: - Logger

/// Wraps unified logging. Messages are only built when their level is enabled, so debug logging on
/// key-press and polling paths costs almost nothing when debug messages are not collected. Unified
/// logging records its own timestamps.
final class Logger: Sendable {
    private enum LogLevel {
        case debug
        case info
        case warning
        case error

        nonisolated var label: String {
            switch self {
            case .debug: "🛠️"
            case .info: "✅"
            case .warning: "⚠️"
            case .error: "❌"
            }
        }

        nonisolated var osLogType: OSLogType {
            switch self {
            case .debug: .debug
            case .info: .info
            case .warning: .default
            case .error: .error
            }
        }
    }

    private nonisolated let log: OSLog

    nonisolated init(category: String = "classicHUD") {
        let subsystem = Bundle.main.bundleIdentifier ?? "com.privatecoder.classicHUD"
        log = OSLog(subsystem: subsystem, category: category)
    }

    nonisolated func debug(_ message: @autoclosure () -> String) {
        write(.debug, message)
    }

    nonisolated func info(_ message: @autoclosure () -> String) {
        write(.info, message)
    }

    nonisolated func warning(_ message: @autoclosure () -> String) {
        write(.warning, message)
    }

    nonisolated func error(_ message: @autoclosure () -> String) {
        write(.error, message)
    }

    private nonisolated func write(_ level: LogLevel, _ message: () -> String) {
        guard log.isEnabled(type: level.osLogType) else { return }
        os_log("%{public}@", log: log, type: level.osLogType, "\(level.label) \(message())")
    }
}
