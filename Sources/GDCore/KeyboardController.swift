import Foundation
import AppKit
import CoreGraphics
import os

public let keyboardLog = Logger(subsystem: "app.greatdisplay", category: "keyboard")

/// Intercepts the hardware brightness keys through a session event tap.
///
/// The tap is installed only when Accessibility access has been granted. When
/// it is not available the app still works from its menu.
public final class KeyboardController: ObservableObject {
    public static let shared = KeyboardController()

    /// Live Accessibility trust. macOS gives no direct callback, so this is
    /// refreshed from the accessibility distributed notification and a light
    /// poll; `onTrustChanged` lets the app start the tap without a relaunch.
    @Published public private(set) var trusted: Bool = AXIsProcessTrusted()
    public var onTrustChanged: ((Bool) -> Void)?
    private var trustTimer: Timer?
    /// Volume keys whose key-down went to DDC. The matching repeats and key-up
    /// must follow the same route, or macOS keeps its volume HUD open waiting
    /// for a release it never sees.
    private var routedVolumeKeys: Set<Int> = []

    /// Called with +1 or -1; the receiver applies the configured step size.
    public var onBrightnessStep: ((Double) -> Void)?
    /// Called when a mute key press is observed (used for the OSD only).
    public var onMuteToggle: (() -> Void)?

    public enum VolumeKey { case up, down, mute }
    /// Asked on every volume/mute key event: true when the keys should drive a
    /// monitor's DDC volume instead of macOS (audio goes to a DP/HDMI monitor).
    public var handlesVolumeKeys: (() -> Bool)?

    /// Thread-safe answer to "should volume keys go to DDC right now?", kept
    /// current by the main thread so the tap thread never has to ask it.
    private let routingLock = NSLock()
    private var volumeRouting = false
    public func setVolumeKeyRouting(_ enabled: Bool) {
        routingLock.lock(); volumeRouting = enabled; routingLock.unlock()
    }
    private var isVolumeRoutingEnabled: Bool {
        routingLock.lock(); defer { routingLock.unlock() }
        return volumeRouting
    }
    /// Performs a volume key press routed to DDC.
    public var onVolumeKey: ((VolumeKey) -> Void)?

    /// Thread-safe answer to "would a brightness key change any display right
    /// now?". When it would not (every display mirrored, or keyboard control
    /// switched off for all of them) the keys are left to macOS instead of
    /// being swallowed with no effect.
    private var brightnessHandling = true
    public func setBrightnessKeyHandling(_ enabled: Bool) {
        routingLock.lock(); brightnessHandling = enabled; routingLock.unlock()
    }
    private var isBrightnessHandlingEnabled: Bool {
        routingLock.lock(); defer { routingLock.unlock() }
        return brightnessHandling
    }
    /// Whether the brightness key press in progress is ours. Decided on the
    /// key-down so its repeats and key-up take the same route (tap thread only).
    private var brightnessPressRouted = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The tap runs on its own thread: if it shared the main thread, any main
    /// thread stall (display reconfiguration, a slow monitor) made macOS
    /// disable the tap for timing out and the keys stopped working.
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var isRunning = false
    private var lastEventTime: CFTimeInterval = 0

    private init() {}

    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public var isTapRunning: Bool { isRunning }

    // MARK: Conflicting apps

    /// Other display utilities that intercept the brightness keys. Only one app
    /// can own them: whichever tap sits first swallows the key-down.
    public static let conflictingBundleIDs: [String: String] = [
        "me.guillaumeb.MonitorControl": "MonitorControl",
        "fyi.lunar.Lunar": "Lunar",
    ]

    @Published public private(set) var conflictingApps: [NSRunningApplication] = []

    public func refreshConflicts() {
        let found = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return KeyboardController.conflictingBundleIDs[id] != nil
        }
        if found.map(\.processIdentifier) != conflictingApps.map(\.processIdentifier) {
            conflictingApps = found
            if !found.isEmpty {
                keyboardLog.notice("brightness keys also handled by: \(found.compactMap(\.localizedName).joined(separator: ", "), privacy: .public)")
            }
        }
    }

    public func startMonitoringTrust() {
        guard trustTimer == nil else { return }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshConflicts()
            }
        }
        refreshConflicts()
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [weak self] _ in
            // The trust database is updated just after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.checkTrust() }
        }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkTrust()
        }
        checkTrust()
    }

    public func checkTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        keyboardLog.notice("accessibility trust changed: \(now, privacy: .public)")
        trusted = now
        onTrustChanged?(now)
    }

    /// Removes this app's Accessibility entry so macOS asks again. Needed when
    /// System Settings shows the app enabled but the grant belongs to a
    /// differently signed earlier build.
    public func resetAccessibilityPermission(bundleIdentifier: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]
        try? process.run()
        process.waitUntilExit()
        checkTrust()
    }

    @discardableResult
    public func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }
        guard AXIsProcessTrusted() else {
            keyboardLog.notice("tap not started: Accessibility not trusted")
            return false
        }

        let systemDefined = CGEventType(rawValue: 14)!
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << systemDefined.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: { proxy, type, event, userInfo in
                                              guard let userInfo else { return Unmanaged.passUnretained(event) }
                                              let controller = Unmanaged<KeyboardController>.fromOpaque(userInfo).takeUnretainedValue()
                                              return controller.handle(proxy: proxy, type: type, event: event)
                                          },
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            keyboardLog.error("tap not started: CGEvent.tapCreate failed")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.tapRunLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "GreatDisplay.KeyboardTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        tapThread = thread
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        keyboardLog.notice("tap started")
        releaseStuckVolumeHUD()
        return true
    }

    /// Posts a key-up for the volume keys. A press whose release was swallowed
    /// (by an earlier build) leaves the macOS volume HUD waiting on screen; a
    /// lone key-up only completes that press and changes nothing else.
    private func releaseStuckVolumeHUD() {
        for keyCode in [0, 1] {
            let data1 = (keyCode << 16) | (0x0B << 8)
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: 0xB00),
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                 context: nil, subtype: 8, data1: data1, data2: -1),
                  let cgEvent = event.cgEvent else { continue }
            // Posted after the tap so it reaches macOS, not our own handler.
            cgEvent.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource, let tapRunLoop {
            CFRunLoopRemoveSource(tapRunLoop, runLoopSource, .commonModes)
            CFRunLoopStop(tapRunLoop)
        }
        tap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        isRunning = false
        keyboardLog.notice("tap stopped")
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            keyboardLog.error("tap disabled by system (\(type.rawValue, privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        if type.rawValue == 14, nsEvent.subtype.rawValue == 8 {
            // data1: key code in bits 16–23, key state in bits 8–15
            // (0x0A down, 0x0B up), repeat flag in bit 0.
            let data = nsEvent.data1
            let keyCode = (data & 0xFFFF_0000) >> 16
            let keyState = (data & 0xFF00) >> 8
            let isDown = keyState == 0x0A
            if [0, 1, 2, 3, 7].contains(keyCode) {
                keyboardLog.notice("media key \(keyCode, privacy: .public) state \(keyState, privacy: .public)")
            }
            switch keyCode {
            case 2, 3:  // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
                if isDown && data & 0x1 == 0 { brightnessPressRouted = isBrightnessHandlingEnabled }
                guard brightnessPressRouted else { return Unmanaged.passUnretained(event) }
                if isDown { adjust(keyCode == 2 ? 1 : -1, allowRepeat: true) }
                return nil   // both down and up belong to us
            case 0, 1, 7:  // NX_KEYTYPE_SOUND_UP / _DOWN / _MUTE
                let isRepeat = data & 0x1 != 0
                if isDown && !isRepeat {
                    // Decide once per press, on the first key-down.
                    if isVolumeRoutingEnabled {
                        routedVolumeKeys.insert(keyCode)
                    } else {
                        routedVolumeKeys.remove(keyCode)
                    }
                }
                guard routedVolumeKeys.contains(keyCode) else { return Unmanaged.passUnretained(event) }
                if isDown {
                    switch keyCode {
                    case 0: onVolumeKey?(.up)
                    case 1: onVolumeKey?(.down)
                    default: if !isRepeat { onVolumeKey?(.mute) }
                    }
                } else {
                    routedVolumeKeys.remove(keyCode)
                }
                return nil   // down, repeats and up all stay with DDC
            default:
                // Every other media key (play, next, keyboard light…) is untouched.
                return Unmanaged.passUnretained(event)
            }
        }

        if type == .keyDown {
            // Function keys only (never letters) for diagnosing brightness keys.
            let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 145, 144]
            if functionKeys.contains(nsEvent.keyCode) {
                keyboardLog.debug("function key \(nsEvent.keyCode, privacy: .public)")
            }
            // F14 / F15: the brightness keys on most non-Apple keyboards.
            let flags = nsEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            if flags.isEmpty && isBrightnessHandlingEnabled {
                if nsEvent.keyCode == 107 { adjust(-1, allowRepeat: true); return nil }
                if nsEvent.keyCode == 113 { adjust(1, allowRepeat: true); return nil }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Posts one brightness key press (down + up) into the HID stream, so the
    /// whole path — tap, decoding, adjustment — can be checked without a keyboard.
    public func postBrightnessKey(up: Bool) {
        let code = up ? 2 : 3
        for state in [0x0A, 0x0B] {
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                 context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1),
                  let cgEvent = event.cgEvent else { continue }
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    private func adjust(_ direction: Double, allowRepeat: Bool) {
        keyboardLog.notice("brightness step \(direction, privacy: .public)")
        let now = CACurrentMediaTime()
        if now - lastEventTime < 0.03 { return }
        lastEventTime = now
        onBrightnessStep?(direction)
    }
}
