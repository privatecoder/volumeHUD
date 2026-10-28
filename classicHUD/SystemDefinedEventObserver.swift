//
//  SystemDefinedEventObserver.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

#if !SANDBOX

    import AppKit
    import CoreGraphics

    // MARK: - SystemDefinedKeyEvent

    /// The fields classicHUD needs from an `NSSystemDefined` event, such as a media key press.
    struct SystemDefinedKeyEvent {
        /// 8 for media keys (NX_SUBTYPE_AUX_CONTROL_BUTTONS), 211 for Caps Lock.
        let subtype: Int
        /// NX key type: 0 volume up, 1 volume down, 2 brightness up, 3 brightness down, 7 mute.
        let keyCode: Int
        /// 0x0A for key down, 0x0B for key up.
        let keyState: Int
        let modifierFlags: NSEvent.ModifierFlags

        var isKeyDown: Bool {
            keyState == 0x0A
        }

        /// Whether two events describe the same key transition. Modifier flags are ignored because
        /// they can differ between delivery paths for the same physical press.
        func isSameKey(as other: Self) -> Bool {
            subtype == other.subtype && keyCode == other.keyCode && keyState == other.keyState
        }

        init?(_ event: NSEvent) {
            guard event.type == .systemDefined else { return nil }
            let data1 = Int(event.data1)
            subtype = Int(event.subtype.rawValue)
            keyCode = (data1 & 0xFFFF_0000) >> 16
            keyState = ((data1 & 0x0000_FFFF) & 0xFF00) >> 8
            modifierFlags = event.modifierFlags
        }
    }

    // MARK: - SystemDefinedEventObserver

    /// Observes system-defined events without consuming them, shared by the volume and brightness
    /// monitors. Each event can arrive through a global NSEvent monitor, a session-level tap, and a
    /// HID-level tap; the redundant paths keep key observation working if one of them is unavailable.
    /// Copies of the same event that arrive within a short window are delivered once.
    @MainActor
    final class SystemDefinedEventObserver {
        static let shared = SystemDefinedEventObserver()

        private static let duplicateWindow: TimeInterval = 0.05

        private var subscribers: [UUID: @MainActor (SystemDefinedKeyEvent) -> Void] = [:]
        private let logger: Logger = .init()
        private var globalMonitor: Any?
        private var taps: [(port: CFMachPort, source: CFRunLoopSource)] = []
        private var lastEvent: SystemDefinedKeyEvent?
        private var lastEventTime: TimeInterval = 0

        private init() {}

        /// Adds a handler, called on the main actor for each distinct event, and returns a token for
        /// `unsubscribe`. Observation starts with the first subscriber.
        func subscribe(_ handler: @escaping @MainActor (SystemDefinedKeyEvent) -> Void) -> UUID {
            let token = UUID()
            subscribers[token] = handler
            start()
            return token
        }

        /// Removes a handler. Observation stops with the last subscriber.
        func unsubscribe(_ token: UUID) {
            subscribers[token] = nil
            if subscribers.isEmpty {
                stop()
            }
        }

        /// Recreates all observation paths, for example after permissions or displays change.
        func restart() {
            guard !subscribers.isEmpty else { return }
            stop()
            start()
        }

        private func start() {
            if globalMonitor == nil {
                globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                    guard let keyEvent = SystemDefinedKeyEvent(event) else { return }
                    MainActor.assumeIsolated { self?.deliver(keyEvent) }
                }
            }
            if taps.isEmpty {
                for location in [CGEventTapLocation.cgSessionEventTap, .cghidEventTap] {
                    installTap(at: location)
                }
            }
        }

        private func stop() {
            if let monitor = globalMonitor {
                NSEvent.removeMonitor(monitor)
                globalMonitor = nil
            }
            for tap in taps {
                CGEvent.tapEnable(tap: tap.port, enable: false)
                // Disabling pauses delivery; invalidating unregisters the tap from WindowServer.
                CFMachPortInvalidate(tap.port)
                CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
                CFRunLoopSourceInvalidate(tap.source)
            }
            taps.removeAll()
        }

        private func installTap(at location: CGEventTapLocation) {
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            guard
                let port = CGEvent.tapCreate(
                    tap: location,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: 1 << 14, // NX_SYSDEFINED
                    callback: { _, type, cgEvent, userInfo in
                        if let userInfo {
                            let observer = Unmanaged<SystemDefinedEventObserver>.fromOpaque(userInfo).takeUnretainedValue()
                            // The tap's run loop source is on the main run loop.
                            MainActor.assumeIsolated { observer.handleTapEvent(type: type, cgEvent: cgEvent) }
                        }
                        return Unmanaged.passUnretained(cgEvent)
                    },
                    userInfo: userInfo,
                ),
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else
            {
                logger.debug("System-defined event tap at \(location == .cghidEventTap ? "HID" : "session") level unavailable.")
                return
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            taps.append((port, source))
        }

        private func handleTapEvent(type: CGEventType, cgEvent: CGEvent) {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                for tap in taps {
                    CGEvent.tapEnable(tap: tap.port, enable: true)
                }
                return
            }
            guard
                type.rawValue == 14,
                let nsEvent = NSEvent(cgEvent: cgEvent),
                let keyEvent = SystemDefinedKeyEvent(nsEvent) else { return }
            deliver(keyEvent)
        }

        private func deliver(_ event: SystemDefinedKeyEvent) {
            let now = MonotonicClock.now
            if let lastEvent, event.isSameKey(as: lastEvent), now - lastEventTime < Self.duplicateWindow {
                return
            }
            lastEvent = event
            lastEventTime = now
            for handler in subscribers.values {
                handler(event)
            }
        }
    }

#endif // !SANDBOX
