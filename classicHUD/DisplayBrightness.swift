//
//  DisplayBrightness.swift
//  by Danny Stewart (2025)
//  MIT License
//  https://github.com/privatecoder/classicHUD
//

#if !SANDBOX

    import CoreGraphics
    import Foundation

    // MARK: - DisplayBrightness

    /// Built-in display brightness through the private DisplayServices framework. The framework is
    /// loaded once and never unloaded, so the cached function pointers stay valid for the lifetime of
    /// the process.
    enum DisplayBrightness {
        private typealias CanChangeFunc = @convention(c) (CGDirectDisplayID) -> Bool
        private typealias GetFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> kern_return_t
        private typealias SetFunc = @convention(c) (CGDirectDisplayID, Float) -> kern_return_t

        private struct Functions {
            let canChange: CanChangeFunc
            let get: GetFunc
            let set: SetFunc?
        }

        private static let functions: Functions? = {
            let logger = Logger()
            guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) else {
                logger.error("Could not load DisplayServices framework: \(dlerror().map { String(cString: $0) } ?? "unknown error")")
                return nil
            }
            guard
                let canChangePtr = dlsym(handle, "DisplayServicesCanChangeBrightness"),
                let getPtr = dlsym(handle, "DisplayServicesGetBrightness") else
            {
                logger.error("Could not find DisplayServices brightness functions.")
                return nil
            }
            let setPtr = dlsym(handle, "DisplayServicesSetBrightness")
            logger.info("DisplayServices framework loaded.")
            return Functions(
                canChange: unsafeBitCast(canChangePtr, to: CanChangeFunc.self),
                get: unsafeBitCast(getPtr, to: GetFunc.self),
                set: setPtr.map { unsafeBitCast($0, to: SetFunc.self) },
            )
        }()

        /// Whether brightness can be read.
        static var isAvailable: Bool {
            functions != nil
        }

        /// Whether brightness can be written.
        static var canSet: Bool {
            functions?.set != nil
        }

        /// The built-in display's ID, if one is active.
        static func builtinDisplayID() -> CGDirectDisplayID? {
            var displayCount: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return nil }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else { return nil }
            return displays.prefix(Int(displayCount)).first { CGDisplayIsBuiltin($0) != 0 }
        }

        /// Whether the display supports brightness control.
        static func canChange(_ displayID: CGDirectDisplayID) -> Bool {
            functions?.canChange(displayID) ?? false
        }

        /// The display's brightness from 0 to 1, or nil if it cannot be read.
        static func brightness(of displayID: CGDirectDisplayID) -> Float? {
            guard let functions else { return nil }
            var brightness: Float = 0
            return functions.get(displayID, &brightness) == KERN_SUCCESS ? brightness : nil
        }

        /// Sets the display's brightness, clamped to 0...1. Returns false if the write fails.
        static func setBrightness(_ brightness: Float, on displayID: CGDirectDisplayID) -> Bool {
            guard let set = functions?.set else { return false }
            return set(displayID, max(0, min(1, brightness))) == KERN_SUCCESS
        }
    }

#endif // !SANDBOX
